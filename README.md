# hdmi-resolution

Two display rules for laptops running KDE Plasma 6 on Wayland, with a small
terminal menu to control them.

| Rule | When it acts | What it does |
|---|---|---|
| **Mirror rule** | An external display mirrors the laptop screen | Switches the laptop screen to a target mode (1920x1080 by default). When mirroring ends, the laptop screen returns to the mode you had before. |
| **Extend rule** | Exactly one external display is extended | Places that display above the laptop screen, horizontally centred. |

Both work with any connector: HDMI, USB-C / DisplayPort, DVI, VGA and docks.
The name is historical; the first version only handled HDMI.

Everything runs as your own user. Nothing is installed system-wide and nothing
needs root.

## Why

- A high-resolution laptop screen mirrored to a 1080p projector gives a poor
  picture on one of the two. Dropping the laptop to the projector's mode while
  mirroring fixes that, and it should undo itself afterwards.
- Plasma puts a newly connected display to the right. If your monitor sits
  above the laptop, you re-arrange it for every new display.

## Requirements

- KDE Plasma 6 on Wayland (developed and tested on Plasma 6.7, Fedora 44)
- `kscreen-doctor` (part of Plasma), `jq`, `whiptail` (package `newt`)
- `bash`, coreutils, systemd user services
- `tmux`, only for running the test suite

## Install

```bash
git clone https://github.com/<your-user>/hdmi-resolution.git
cd hdmi-resolution
bash install.sh
```

This copies the two scripts to `~/.local/bin`, installs and starts a systemd
**user** service, and creates `~/.config/hdmi-resolution/config` if you do not
have one. To remove it again: `bash uninstall.sh`.

## Use

```bash
hdmi-resolution-tui                                   # settings menu
hdmi-resolution status                                # what the service sees right now
journalctl --user -u hdmi-resolution.service -f       # what it did and why
systemctl --user restart hdmi-resolution.service      # after editing the config by hand
```

The service is a user service, so `sudo systemctl ...` will not find it.

```
┌────────────────────┤ Display Rules (hdmi-resolution) ├─────────────────────┐
│ Mirror rule ON: while a display mirrors the laptop screen, the             │
│ laptop screen uses 1920x1080. Your own resolution is saved first and       │
│ restored when mirroring ends.                                              │
│ Extend rule ON: a single extended display is placed above the              │
│ laptop screen, centred.                                                    │
│                                                                            │
│ Displays:                                                                  │
│   DELL P2723DE [USB-C/DisplayPort] (DP-3, extended): mirror rule on        │
│                                                                            │
│                auto     Mirror rule, all displays: ON                      │
│                displays Mirror rule per display: 1 of 1 on                 │
│                target   Mirrored target: 1920x1080                         │
│                extend   Extend rule (above, centred): ON                   │
│                restore  Restore user mode: ON (always)                     │
│                save     Save and restart service                           │
│                quit     Exit without saving                                │
└────────────────────────────────────────────────────────────────────────────┘
```

| Menu entry | Meaning |
|---|---|
| Mirror rule, all displays | Master switch for the mirror rule |
| Mirror rule per display | Checklist of displays; unticked ones are left alone when mirroring |
| Mirrored target | Laptop screen mode used while mirroring: 1080p, 1440p or 720p |
| Extend rule (above, centred) | Switch for the extend rule |
| Restore user mode | Explanation only; restoring is always on |

Nothing is written until you choose "Save and restart service".

## Behaviour in detail

**Mirror rule**

- It only acts in mirror mode. Extended layouts never have their resolution
  changed, and the external display's own mode is never touched.
- The mode to return to is whatever you had selected before mirroring. It is
  not hardcoded.
- It can be switched off for individual displays. A display is recognised by
  its EDID, so the setting follows the monitor to any port. New displays start
  switched on.
- Switching the rule off while mirroring puts the laptop screen back at once.

**Extend rule**

- It is applied each time extend mode starts: plugging in, leaving mirror
  mode, logging in, restarting the service.
- After that you can drag the screens elsewhere in System Settings. That
  layout is kept until extend mode next starts.
- While the screens are still where the service put them, it re-centres after
  a resolution, scale or rotation change.
- It does nothing with two or more external displays, with the laptop screen
  off (lid closed), or when the only other output is a virtual one.

## Configuration

`~/.config/hdmi-resolution/config`, normally written by the menu:

```
enabled=1
target_width=1920
target_height=1080
extend_top_center=1
auto_off_display=edid:0123456789abcdef0123456789abcdef Example Monitor [HDMI]
```

| Setting | Meaning |
|---|---|
| `enabled` | Mirror rule master switch, `1` or `0` |
| `target_width`, `target_height` | Laptop screen mode used while mirroring. Any size your panel offers works, not only the three in the menu; `kscreen-doctor -o` lists them. |
| `extend_top_center` | Extend rule, `1` or `0` |
| `auto_off_display` | One line per display excluded from the mirror rule: its key, then a label. `hdmi-resolution status` prints the key of each connected display. |

The file is read as data, not executed. A line that is not exactly one of
these settings is ignored and reported in the service log. A missing setting
keeps its default (both rules on, 1920x1080).

## Limitations

- Plasma 6 on Wayland only. It has not been tried elsewhere; without Plasma's
  `kscreen-doctor` answering, the service does nothing.
- The extend rule overrides "Extend to left/right" chosen from Plasma's
  display switcher (Meta+P), because that choice also starts extend mode.
  Switch the rule off in the menu if you want those.
- The extend rule handles one external display. With more, the layout is left
  to Plasma.
- USB-C displays use DisplayPort signalling and the kernel names them `DP-n`,
  the same as a full-size DisplayPort socket, so both are labelled
  `USB-C/DisplayPort`.
- The service relies on KWin rewriting `~/.config/kwinoutputconfig.json` when
  the display configuration changes. See [docs/DESIGN.md](docs/DESIGN.md).

## Security notes

- Runs entirely as the logged-in user: no root, no setuid, no network access.
  The service unit sets `NoNewPrivileges=yes`.
- The only programs it controls are `kscreen-doctor` (to read the layout and
  to set a mode or position) and, from the menu, `systemctl --user restart`.
- The config and state files are parsed as data and validated; they are never
  sourced or evaluated.
- Monitor names come from the monitor's own EDID and are therefore untrusted.
  They are reduced to printable ASCII, passed to `whiptail` behind `--`, and
  never reach a shell parser. Output names are checked before being used in a
  path.
- `HDMI_RESOLUTION_KSCREEN_DOCTOR` and `HDMI_RESOLUTION_DRM_DIR` are test
  hooks. They redirect the service to a different program and directory, so
  do not set them in the service's environment.

Found a problem? Please open an issue.

## Development

```bash
bash tests/run-tests.sh              # tests the scripts in bin/
bash tests/run-tests.sh ~/.local/bin # tests the installed copies
```

The suite takes about three minutes and never touches real displays, settings
or services: `kscreen-doctor` is replaced by a mock and all paths point at
temporary directories. Both scripts are `shellcheck`-clean.

How it works, the design constraints and the things that will bite when you
change it are in [docs/DESIGN.md](docs/DESIGN.md).

## License

MIT, see [LICENSE](LICENSE).
