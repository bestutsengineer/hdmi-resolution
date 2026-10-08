# Design and maintenance notes

For anyone changing `hdmi-resolution`. The README covers what it does and how
to use it; this covers how it works and how to change it without breaking it.

## Files

| In the repository | Installed as | Role |
|---|---|---|
| `bin/hdmi-resolution` | `~/.local/bin/hdmi-resolution` | The service (bash). Also provides `status` and `list-displays`. |
| `bin/hdmi-resolution-tui` | `~/.local/bin/hdmi-resolution-tui` | Settings menu (bash + `whiptail`). It gets its display list from `hdmi-resolution list-displays`, so the two must sit in the same directory. |
| `systemd/hdmi-resolution.service` | `~/.config/systemd/user/hdmi-resolution.service` | User unit, enabled under `graphical-session.target`. |
| `config.example` | `~/.config/hdmi-resolution/config` | Settings; copied only if no config exists. |
| `tests/` | not installed | Test suite, mock `kscreen-doctor`, EDID fixtures. |

Runtime state, in `~/.local/state/hdmi-resolution/`:

| File | Meaning |
|---|---|
| `baseline-mode` | The panel mode the user last chose (width, height, refresh rate; tab-separated). |
| `pending-mode` | Exists only while a restore is owed, i.e. while the mirror rule holds the panel at the target mode. |
| `displays/<key>.baseline`, `displays/<key>.pending` | X11 only: the same two things for an external display. |

Files it depends on but does not own:

- `~/.config/kwinoutputconfig.json` belongs to KWin. Under Wayland the
  service reads its timestamp, as a "the display configuration changed"
  signal.
- `xrandr --current` and `xrandr --current --props` are read under X11, for
  the same signal and for EDIDs.
- `/sys/class/drm/card*-<connector>/edid` is read to identify displays.
- `/usr/share/hwdata/pnp.ids` turns a vendor code into a vendor name.

## How it works

### Session type

The script decides once, at start: it is an X11 session when
`XDG_SESSION_TYPE=x11` and `WAYLAND_DISPLAY` is empty, and a Wayland session
in every other case. The X11 handling is additive (`if [[ "$SESSION" == x11
]]` branches and the functions in the "X11" section); the Wayland path does
not run any of it. `hdmi-resolution status` prints which one is in effect.

### Trigger

The service loops once a second and does nothing but look at a cheap "stamp"
(`watch_stamp`). Only when the stamp changes does it query Plasma.

Under Wayland the stamp is the timestamp, size and inode of KWin's
`kwinoutputconfig.json`. KWin rewrites that file whenever the display
configuration changes (hotplug, mode, position, mirror/extend).

Under X11 KWin does not manage outputs and never touches that file, so the
stamp is a checksum of `xrandr --current`. `--current` returns the X server's
cached state without probing the outputs, and takes a few milliseconds. After
a change the service waits until the stamp has been the same for a second, so
a change made in several steps is looked at once.

This is deliberate. An early version called `kscreen-doctor -j` every second,
and that competed with Plasma's own display dialog. **Do not add anything that
calls `kscreen-doctor` on a timer.**

The cost of this design under Wayland: if a future Plasma stops rewriting
that file on display changes, detection stops silently. `hdmi-resolution status` would
still show the right layout while the journal shows no "Display configuration
changed" lines.

### Snapshot and layout

On each change, `refresh_snapshot` runs `kscreen-doctor -j` once and a `jq`
program classifies the layout. Every later decision in that pass reads the
same snapshot (the `snap` helper), so the rules never see two different
states.

| Layout | Meaning | What the rules do |
|---|---|---|
| `no-display` | Panel on, no enabled external display | Restore if owed; track the user's panel mode |
| `extend` | Panel on, external display(s), none mirroring the panel | Same, then the extend rule |
| `mirror` | An external display mirrors the panel and the mirror rule applies | Mirror rule |
| `mirror-manual` | Mirroring, but the rule is off (master switch, or every mirroring display is excluded) | Restore if owed; track the user's panel mode |
| `panel-off` | Panel disabled or absent (lid closed, "external only") | Nothing at all |
| `unknown` | `kscreen-doctor` gave no usable answer | Nothing at all |

Definitions, all in the `JQ_DEFS` block near the top of the script:

- **Panel**: the output whose name starts with `eDP-`, `LVDS-` or `DSI-`.
- **External display**: any other output that is connected and enabled.
- **Mirroring**: the display's `replicationSource` is the panel's id, or the
  other way round, or both sit at the same position. Plasma reports mirror
  mode through `replicationSource`; the geometry can still look extended. The
  same-position test is only a fallback.
- **Logical size**: the current mode's size, width and height swapped for 90°
  rotations (KScreen rotation values 2, 8, 32, 128), divided by the scale and
  rounded. This matches the geometry KWin reports.

### Mirror rule

Two state files make the restore reliable:

- `baseline-mode` is updated whenever the panel mode is the user's to choose
  (every layout except `mirror`, `panel-off` and `unknown`).
- `pending-mode` is written from the baseline on entering `mirror`, just
  before the panel is switched. It is deleted once the restore succeeds.

The restore is driven by the pending file, not by remembering the previous
layout. Any pass that is not in `mirror` and finds a pending file restores the
panel. That covers a service restart while mirrored, a display unplugged while
mirrored, and the rule being switched off while mirrored.

The baseline exists because the service often notices mirror mode after the
panel has already been changed (for example after a restart), so "the current
mode" cannot be trusted at that moment.

Plasma renumbers mode IDs when outputs come and go. The files therefore store
width, height and refresh rate, and the ID is looked up fresh every time.

### Mirror rule under X11

Plasma's "Unify outputs" is a different thing under X11 (`cloneScreens` in
kscreen's `kded/generator.cpp`):

- It sets no `replicationSource`. It enables every output at position `0,0`
  in the largest size they all support. The same-position test is therefore
  how mirroring is recognised under X11.
- That changes the panel's mode before this service sees anything, and
  kscreen remembers the mode per output, so every later preset (extend,
  laptop only) keeps the panel at the mirrored size. Putting the user's mode
  back is entirely this service's job. Only an unplug restores it, because
  kscreen then loads its saved laptop-only layout.
- Nothing scales a mirrored output. Outputs of different sizes at `0,0` show
  different parts of the desktop.

What follows from that, all in the "X11" section of the script:

- `x11_apply_mirror_mode` sets the panel and every mirroring display to the
  target size in one `kscreen-doctor` call, skipping outputs already there. If
  a display has no mode of the target size it changes nothing.
- `x11_save_display_pendings` notes, on entering mirror mode, what each
  mirroring display has to go back to: its `baseline` (the mode it was last
  seen with in extend mode) or else its current mode, which is the size Plasma
  mirrored at.
- `x11_restore_or_track` runs in `no-display` and `extend`. It puts back every
  owed mode (panel and displays) in one call, clears a restore that is already
  satisfied without calling anything, and only when nothing is owed tracks the
  current modes as baselines.
- In `mirror` and `mirror-manual` nothing is tracked, because the modes are
  the mirrored ones. In `mirror-manual` nothing is restored either: pulling
  the panel out of the shared size would break the mirror.

The panel's `baseline-mode` and `pending-mode` files are shared between the
two session types. They hold a size and refresh rate, which resolve to a mode
in either.

### Extend rule

`placement_geometry` computes the target from logical sizes. The wider of the
two outputs starts at x = 0 and the narrower is centred against it. The
display sits at y = 0 and the panel directly below it. Coordinates are never
negative.

Worked example: a 2560x1440 monitor at scale 1 and a 2560x1600 panel at scale
1.25, which occupies 2048x1280. The monitor goes to `0,0` and the panel to
`(2560 - 2048) / 2 = 256`, `1440`.

`place_extended_display` applies it in two cases only:

1. Extend mode has just started with this display (the "signature", connector
   name plus display key, differs from the previous pass).
2. The outputs are still exactly where the service last put them, but the
   target has moved (a resolution, scale or rotation change).

If the positions differ from what the service applied, the user has moved the
screens and the service stays out until extend mode next starts. A failed
apply is logged and not retried.

Both positions go to `kscreen-doctor` in one call so the change is atomic.
KWin stores the result as the layout for that display pair, so on the next
plug-in KWin itself restores it and the service only logs "already above ...
and centred".

### Display identity and labels

- Key: `edid:<md5>` of the display's EDID. This is the same value KWin stores
  as `edidHash` in `kwinoutputconfig.json`. A display with no readable EDID
  gets `connector:<name>` instead.
- The EDID is read from sysfs under Wayland. Under X11 it is taken from
  `xrandr --current --props`, because X names outputs differently from the
  kernel (its `HDMI-1` is `HDMI-A-1` in sysfs). Both give the same bytes, so a
  display has the same key in either session.
- Model: the EDID monitor-name descriptor. If the EDID has none, the vendor
  name and product code. If there is no EDID, `Unidentified display`.
- Connector kind, from the connector name: `HDMI-*` is HDMI, `DP-*` is
  USB-C/DisplayPort, `DVI-*` is DVI, `VGA-*` is VGA.

### Config

`load_config` exists in both scripts and must stay identical in what it
accepts. It reads the file line by line and takes only lines that match one
of three strict patterns; values are assigned with `printf -v`. Nothing from
the file is ever sourced or evaluated. `save_config` in the menu writes the
same format through a temporary file and a rename.

## Trust boundaries

| Input | Trusted? | Handling |
|---|---|---|
| Config file | User-owned, but treated as data | Strict line patterns; never executed |
| State files | User-owned | Validated as three numbers before use |
| `kscreen-doctor -j` output | From the compositor | Only read through `jq`; names are passed as single quoted arguments |
| `xrandr` output (X11) | From the X server | The EDID is accepted only as hex digits; the rest is only checksummed |
| Monitor name (EDID) | **Untrusted**, supplied by the monitor | Printable ASCII only, length-capped, `--` before `whiptail` arguments, never passed through a shell parser |
| Output names | From the compositor | Rejected in `edid_file` unless `[A-Za-z0-9_-]+`, since they become part of a path |
| Environment test hooks | Trusted | Whoever controls the service's environment already controls the account |

## Changing it safely

1. Edit the scripts in `bin/`.
2. Check syntax and lint:
   ```bash
   bash -n bin/hdmi-resolution && bash -n bin/hdmi-resolution-tui
   shellcheck bin/* tests/run-tests.sh tests/mock-kscreen-doctor install.sh uninstall.sh
   ```
3. Run the tests: `bash tests/run-tests.sh`
4. Install and read the log:
   ```bash
   bash install.sh
   journalctl --user -u hdmi-resolution.service -n 20
   ```

### The test suite

`run-tests.sh` starts the real service script against a mock:

- `HDMI_RESOLUTION_KSCREEN_DOCTOR` points the script at
  `tests/mock-kscreen-doctor`, which keeps a fake display state in a JSON
  file, applies mode and position settings to it, and rewrites the watched
  file as KWin would.
- `HDMI_RESOLUTION_DRM_DIR` points EDID lookups at a throwaway directory.
- `HDMI_RESOLUTION_XRANDR` points the X11 path at `tests/mock-xrandr`, which
  prints the same fake state and serves EDIDs for the X11 cases.
- `XDG_SESSION_TYPE` and `WAYLAND_DISPLAY` are set per test. Every test runs
  as a Wayland session unless it calls `x11_session`, so the result does not
  depend on the session the suite is started from. In an X11 test the mocks
  leave `kwinoutputconfig.json` untouched, as real X11 does.
- `XDG_CONFIG_HOME` and `XDG_STATE_HOME` are temporary, so the real config
  and state are never read or written.
- The menu is driven through `tmux` with a fake `systemctl` first in `PATH`.

It covers: placement for wider, narrower, fractional-scale and rotated
displays; every case where placement must not happen; the hands-off and
re-centre behaviour; mirror detection in all three forms; restore after
unplug, restart, lid close and renumbered mode IDs; the per-display and
master switches; refused and unanswered `kscreen-doctor` calls; shell code
and junk in the config; a monitor name that looks like a command-line option;
an output name containing a path; display labels; every menu entry including
save; and the X11 cases: Plasma's own unify followed by laptop-only, extend
and unplug, both outputs set to the target together and both restored, a
display without the target size, the rule switched off, a refused restore, and
identification through the X server.

To add a case, copy an existing block. `sandbox` starts a clean test, `start`
launches the service on an initial state, `change` simulates Plasma changing
the state, and `check` compares. States are built with `panel` and `output`.

Fixtures: `dell-p2723de.edid` is a real monitor EDID with the serial number
blanked. `no-name-lg.edid` and `hostile-name.edid` are synthetic.

`kscreen-doctor output.<name>.mirror.<source|none>` switches mirror mode from
the command line. It is not listed in `--help`, and it is handy for trying
the mirror rule on real hardware.

### Things that will bite

- **No timers on `kscreen-doctor`.** See "Trigger". The once-a-second
  `xrandr --current` under X11 is fine; never drop `--current`, since a plain
  `xrandr` probes every output each time.
- **Keep the Wayland path free of X11 calls.** Running `xrandr` in a Wayland
  session would start Xwayland for nothing.
- **Under X11, never track a mode as the user's while anything mirrors the
  panel**, and never restore the panel while it is mirrored. Plasma, not the
  user, chose that mode, and X11 cannot mirror outputs of different sizes.
- **No retry loops.** Every `kscreen-doctor` setting makes KWin rewrite the
  watched file, which wakes the service again. Anything that re-applies on
  every pass becomes an endless loop. Each action is tied to a transition or
  to a file that the action itself removes.
- **Never store mode IDs.** They change between hotplugs.
- **Refresh the snapshot after changing a mode.** The extend rule runs later
  in the same pass and needs the panel's new size. `apply_mirror_mode` and
  `restore_user_mode` already do this.
- **Do not save the baseline while a restore is owed.** The panel is at the
  target mode then, and the baseline would be overwritten with it.
- **The same-position mirror fallback** means the extend rule must never put
  two outputs at the same coordinates. It cannot today, since the panel is
  always below the display.
- **Never go back to sourcing the config.** Besides executing whatever is in
  it, an unclosed `(` in a sourced file corrupts the parsing of the script
  that sourced it.
- **Keep `--` in every `whiptail` call** that shows a display name.
- **The running service keeps its old behaviour until restarted.**
- **Restarting the service re-applies the extend rule**, because a start
  counts as extend mode starting. Saving from the menu restarts the service.
- **Web uploads drop the executable bit.** `install.sh` sets modes itself and
  `run-tests.sh` restores them, so invoke both through `bash`.
