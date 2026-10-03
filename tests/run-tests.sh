#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose
# Regression tests for hdmi-resolution and hdmi-resolution-tui.
#
# Nothing here touches the real displays, config or service: kscreen-doctor is
# replaced by tests/mock-kscreen-doctor, sysfs by a throwaway directory, and
# the config/state directories by temporary ones.
#
# Usage: bash tests/run-tests.sh [directory holding the two scripts]
#        (default: ../bin; pass ~/.local/bin to test the installed copies)
# Takes about three minutes. Exit status 0 means every check passed.
set -u

HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
BIN_DIR=$(readlink -f "${1:-$HERE/../bin}")
DAEMON="$BIN_DIR/hdmi-resolution"
TUI="$BIN_DIR/hdmi-resolution-tui"
DELL_KEY="edid:$(md5sum < "$HERE/fixtures/dell-p2723de.edid" | cut -d' ' -f1)"
HOSTILE_KEY="edid:$(md5sum < "$HERE/fixtures/hostile-name.edid" | cut -d' ' -f1)"

# A web upload or a zip from some tools drops the executable bit.
chmod +x "$DAEMON" "$TUI" "$HERE/mock-kscreen-doctor" 2>/dev/null
for f in "$DAEMON" "$TUI" "$HERE/mock-kscreen-doctor"; do
    [[ -x "$f" ]] || { echo "not executable: $f" >&2; exit 2; }
done

pass=0
fail=0
T=''
daemon_pid=''

export HDMI_RESOLUTION_KSCREEN_DOCTOR="$HERE/mock-kscreen-doctor"

# --- Fake display states ----------------------------------------------------

PANEL_MODES='[
 {"id":"32","name":"2560x1600@60","refreshRate":59.99399948120117,"size":{"width":2560,"height":1600}},
 {"id":"38","name":"2560x1440@60","refreshRate":59.96099853515625,"size":{"width":2560,"height":1440}},
 {"id":"39","name":"1920x1080@60","refreshRate":59.9630012512207,"size":{"width":1920,"height":1080}},
 {"id":"42","name":"1280x720@60","refreshRate":59.85499954223633,"size":{"width":1280,"height":720}}]'
# The same panel after Plasma renumbered its mode IDs.
PANEL_MODES_RENUMBERED='[
 {"id":"7","name":"1920x1080@60","refreshRate":59.9630012512207,"size":{"width":1920,"height":1080}},
 {"id":"9","name":"2560x1600@60","refreshRate":59.99399948120117,"size":{"width":2560,"height":1600}}]'
QHD_MODES='[
 {"id":"1","name":"2560x1440@60","refreshRate":59.951,"size":{"width":2560,"height":1440}},
 {"id":"4","name":"1920x1080@60","refreshRate":60,"size":{"width":1920,"height":1080}}]'
FHD_MODES='[{"id":"1","name":"1920x1080@60","refreshRate":60,"size":{"width":1920,"height":1080}}]'
UHD_MODES='[{"id":"1","name":"3840x2160@60","refreshRate":60,"size":{"width":3840,"height":2160}}]'

# output NAME ID ENABLED X Y SCALE ROTATION REPLICATION-SOURCE CURRENT-MODE MODES
output() {
    jq -cn --arg name "$1" --argjson id "$2" --argjson enabled "$3" --argjson x "$4" --argjson y "$5" \
        --argjson scale "$6" --argjson rotation "$7" --argjson repl "$8" --arg mode "$9" --argjson modes "${10}" \
        '{name: $name, id: $id, connected: true, enabled: $enabled, pos: {x: $x, y: $y}, scale: $scale,
          rotation: $rotation, replicationSource: $repl, currentModeId: $mode, modes: $modes}'
}
state() { jq -cn '{outputs: $ARGS.positional}' --jsonargs "$@"; }
# panel X Y [MODE-ID] [ENABLED]: the laptop screen, id 2, scale 1.25.
panel() { output eDP-1 2 "${4:-true}" "$1" "$2" 1.25 1 0 "${3:-32}" "$PANEL_MODES"; }

# --- Harness ----------------------------------------------------------------

stop_daemon() {
    [[ -n "$daemon_pid" ]] && kill "$daemon_pid" 2>/dev/null && wait "$daemon_pid" 2>/dev/null
    daemon_pid=''
}

cleanup() {
    stop_daemon
    tmux -L hdmi-resolution-test kill-server 2>/dev/null
    [[ -n "$T" ]] && rm -rf "$T"
}
trap cleanup EXIT

# Fresh config, state, mock and fake sysfs directories for one test.
sandbox() {
    stop_daemon
    [[ -n "$T" ]] && rm -rf "$T"
    T=$(mktemp -d)
    export XDG_CONFIG_HOME="$T/config" XDG_STATE_HOME="$T/state" MOCK_DIR="$T/mock"
    export HDMI_RESOLUTION_DRM_DIR="$T/drm"
    mkdir -p "$XDG_CONFIG_HOME/hdmi-resolution" "$XDG_STATE_HOME/hdmi-resolution" "$MOCK_DIR" "$T/drm"
    : > "$MOCK_DIR/calls.log"
    : > "$T/daemon.log"
    echo
    echo "== $1"
}

edid() { mkdir -p "$T/drm/card1-$1" && cp "$HERE/fixtures/$2" "$T/drm/card1-$1/edid"; }
config() { printf '%s\n' "$@" > "$XDG_CONFIG_HOME/hdmi-resolution/config"; }

events() {
    local n
    n=$(grep -c 'Display configuration changed' "$T/daemon.log" 2>/dev/null)
    echo "${n:-0}"
}

# Wait until the daemon has reacted to a change and then stayed quiet.
settle() {
    local before=$1 n last quiet=0 i
    for ((i = 0; i < 100; i++)); do
        n=$(events)
        ((n > before)) && break
        sleep 0.1
    done
    last=$n
    while ((quiet < 22)); do
        sleep 0.1
        n=$(events)
        if ((n != last)); then
            last=$n
            quiet=0
        else
            quiet=$((quiet + 1))
        fi
    done
}

set_state() {
    printf '%s\n' "$1" > "$MOCK_DIR/state.json"
    date +%s%N > "$XDG_CONFIG_HOME/kwinoutputconfig.json"
}

# Start the daemon on an initial display state.
start() {
    set_state "$1"
    "$DAEMON" run 2> "$T/daemon.log" &
    daemon_pid=$!
    settle 0
}

# Change the display state as Plasma would, and wait for the daemon.
change() {
    local before
    before=$(events)
    set_state "$1"
    settle "$before"
}

pos() { jq -r --arg n "$1" '.outputs[] | select(.name == $n) | "\(.pos.x),\(.pos.y)"' "$MOCK_DIR/state.json"; }
mode() {
    jq -r --arg n "$1" '.outputs[] | select(.name == $n) | . as $o
      | .modes[] | select(.id == $o.currentModeId) | "\(.size.width)x\(.size.height)"' "$MOCK_DIR/state.json"
}
calls() { wc -l < "$MOCK_DIR/calls.log"; }
saved_mode() { if [[ -r "$1" ]]; then tr '\t' ' ' < "$1"; else echo none; fi; }
pending() { saved_mode "$XDG_STATE_HOME/hdmi-resolution/pending-mode"; }
baseline() { saved_mode "$XDG_STATE_HOME/hdmi-resolution/baseline-mode"; }

check() {
    if [[ "$2" == "$3" ]]; then
        pass=$((pass + 1))
        echo "  ok   $1"
    else
        fail=$((fail + 1))
        echo "  FAIL $1: expected '$2', got '$3'"
    fi
}

check_log() {
    if grep -q -E -- "$2" "$T/daemon.log"; then
        pass=$((pass + 1))
        echo "  ok   $1"
    else
        fail=$((fail + 1))
        echo "  FAIL $1: no log line matching '$2'"
        sed 's/^/       | /' "$T/daemon.log"
    fi
}

check_alive() {
    if kill -0 "$daemon_pid" 2>/dev/null; then
        pass=$((pass + 1))
        echo "  ok   daemon still running"
    else
        fail=$((fail + 1))
        echo "  FAIL daemon exited"
    fi
}

USER_MODE='2560 1600 59.99399948120117'

# === Extend rule ============================================================

sandbox 'USB-C display (wider than the panel) extended to the right -> above, centred'
edid DP-3 dell-p2723de.edid
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")")"
check 'display position' '0,0' "$(pos DP-3)"
check 'panel position' '256,1440' "$(pos eDP-1)"
check 'one kscreen-doctor call' 1 "$(calls)"
check 'panel mode untouched' '2560x1600' "$(mode eDP-1)"
check 'user mode tracked' "$USER_MODE" "$(baseline)"
check_log 'display identified in the log' 'Layout changed: initial -> extend \[DP-3: DELL P2723DE, USB-C/DisplayPort\]'

sandbox 'HDMI display narrower than the panel -> display is the centred one'
start "$(state "$(panel 0 0)" "$(output HDMI-A-1 1 true 2048 0 1 1 0 1 "$FHD_MODES")")"
check 'display position' '64,0' "$(pos HDMI-A-1)"
check 'panel position' '0,1080' "$(pos eDP-1)"

sandbox '4K display at fractional scale 1.75 (logical 2194x1234)'
start "$(state "$(panel 0 0)" "$(output DP-1 1 true 2048 0 1.75 1 0 1 "$UHD_MODES")")"
check 'display position' '0,0' "$(pos DP-1)"
check 'panel position' '73,1234' "$(pos eDP-1)"

sandbox 'Portrait display (rotated left, logical 1440x2560)'
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 2 0 1 "$QHD_MODES")")"
check 'display position' '304,0' "$(pos DP-3)"
check 'panel position' '0,2560' "$(pos eDP-1)"

sandbox 'Display to the left of the panel, DVI dock -> above, centred'
start "$(state "$(panel 1920 0)" "$(output DVI-I-1 1 true 0 0 1 1 0 1 "$FHD_MODES")")"
check 'display position' '64,0' "$(pos DVI-I-1)"
check 'panel position' '0,1080' "$(pos eDP-1)"

sandbox 'Already above and centred -> nothing is applied'
start "$(state "$(panel 256 1440)" "$(output DP-3 1 true 0 0 1 1 0 1 "$QHD_MODES")")"
check 'no kscreen-doctor call' 0 "$(calls)"
check_log 'logged as already in place' 'DP-3 is already above eDP-1 and centred'

sandbox 'Extend rule switched off -> layout untouched'
config 'enabled=1' 'target_width=1920' 'target_height=1080' 'extend_top_center=0'
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")")"
check 'no kscreen-doctor call' 0 "$(calls)"
check 'display position' '2048,0' "$(pos DP-3)"

sandbox 'Two external displays -> layout untouched'
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")" "$(output HDMI-A-1 3 true 4608 0 1 1 0 1 "$FHD_MODES")")"
check 'no kscreen-doctor call' 0 "$(calls)"

sandbox 'Virtual output only -> layout untouched'
start "$(state "$(panel 0 0)" "$(output Virtual-rdp 1 true 2048 0 1 1 0 1 "$FHD_MODES")")"
check 'no kscreen-doctor call' 0 "$(calls)"

sandbox 'Second display connected but disabled -> the single enabled one is placed'
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")" "$(output HDMI-A-1 3 false 0 0 1 1 0 1 "$FHD_MODES")")"
check 'display position' '0,0' "$(pos DP-3)"
check 'panel position' '256,1440' "$(pos eDP-1)"

sandbox 'User drags the display elsewhere -> not fought; replug -> default again'
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")")"
check 'placed on start' '0,0 256,1440' "$(pos DP-3) $(pos eDP-1)"
change "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")")"
check 'manual layout kept' '2048,0 0,0' "$(pos DP-3) $(pos eDP-1)"
check 'still one kscreen-doctor call' 1 "$(calls)"
change "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 4 "$QHD_MODES")")"
check 'manual layout kept after a resolution change' '2048,0 0,0' "$(pos DP-3) $(pos eDP-1)"
change "$(state "$(panel 0 0)")"
change "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")")"
check 'placed again after replug' '0,0 256,1440' "$(pos DP-3) $(pos eDP-1)"

sandbox 'Resolution changed while still where the service put it -> re-centred'
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")")"
change "$(state "$(panel 256 1440)" "$(output DP-3 1 true 0 0 1 1 0 4 "$QHD_MODES")")"
check 'display position' '64,0' "$(pos DP-3)"
check 'panel position' '0,1080' "$(pos eDP-1)"

sandbox 'kscreen-doctor refuses the placement -> no retry loop'
touch "$MOCK_DIR/fail-apply"
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")")"
change "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")")"
check 'exactly one attempt' 1 "$(calls)"
check_log 'failure logged' 'ERROR: kscreen-doctor failed placing DP-3'
check_alive

# === Mirror rule ============================================================

sandbox 'USB-C display: extend -> mirror -> extend'
edid DP-3 dell-p2723de.edid
start "$(state "$(panel 256 1440)" "$(output DP-3 1 true 0 0 1 1 0 1 "$QHD_MODES")")"
change "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 2 1 "$QHD_MODES")")"
check 'panel switched to the target' '1920x1080' "$(mode eDP-1)"
check 'user mode saved for restore' "$USER_MODE" "$(pending)"
check 'display not moved while mirroring' '2048,0' "$(pos DP-3)"
check_log 'mirror detected for a USB-C display' 'Layout changed: extend -> mirror \[DP-3: DELL P2723DE, USB-C/DisplayPort\]'
# Plasma leaves the display beside the 1080p-sized panel when extending again.
change "$(state "$(panel 0 0 39)" "$(output DP-3 1 true 1536 0 1 1 0 1 "$QHD_MODES")")"
check 'user mode restored' '2560x1600' "$(mode eDP-1)"
check 'pending restore cleared' 'none' "$(pending)"
check 'placed using the restored panel size' '0,0 256,1440' "$(pos DP-3) $(pos eDP-1)"

sandbox 'HDMI display: mirror on connect, then unplugged'
start "$(state "$(panel 0 0)")"
change "$(state "$(panel 0 0)" "$(output HDMI-A-1 1 true 2048 0 1 1 2 1 "$FHD_MODES")")"
check 'panel switched to the target' '1920x1080' "$(mode eDP-1)"
change "$(state "$(panel 0 0 39)")"
check 'user mode restored after unplug' '2560x1600' "$(mode eDP-1)"
check 'pending restore cleared' 'none' "$(pending)"

sandbox 'Mirror reported by the panel replicating the display'
start "$(state "$(output eDP-1 2 true 0 0 1.25 1 1 32 "$PANEL_MODES")" "$(output DP-2 1 true 2048 0 1 1 0 1 "$FHD_MODES")")"
check 'panel switched to the target' '1920x1080' "$(mode eDP-1)"

sandbox 'Mirror reported only by identical positions'
start "$(state "$(panel 0 0)" "$(output DP-2 1 true 0 0 1 1 0 1 "$FHD_MODES")")"
check 'panel switched to the target' '1920x1080' "$(mode eDP-1)"

sandbox 'Other target mode (2560x1440)'
config 'enabled=1' 'target_width=2560' 'target_height=1440'
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 2 1 "$QHD_MODES")")"
check 'panel switched to the target' '2560x1440' "$(mode eDP-1)"

sandbox 'Target mode the panel does not have -> error, panel untouched'
config 'enabled=1' 'target_width=3000' 'target_height=2000'
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 2 1 "$QHD_MODES")")"
check 'panel mode untouched' '2560x1600' "$(mode eDP-1)"
check_log 'error logged' 'ERROR: eDP-1 has no 3000x2000 mode'
check_alive

sandbox 'Service restarted while mirrored -> user mode is not forgotten'
printf '2560\t1600\t59.99399948120117\n' > "$XDG_STATE_HOME/hdmi-resolution/baseline-mode"
printf '2560\t1600\t59.99399948120117\n' > "$XDG_STATE_HOME/hdmi-resolution/pending-mode"
start "$(state "$(panel 0 0 39)" "$(output DP-3 1 true 2048 0 1 1 2 1 "$QHD_MODES")")"
check 'panel stays on the target' '1920x1080' "$(mode eDP-1)"
check 'pending restore kept' "$USER_MODE" "$(pending)"
check 'baseline not overwritten by the target' "$USER_MODE" "$(baseline)"
change "$(state "$(panel 0 0 39)")"
check 'user mode restored after unplug' '2560x1600' "$(mode eDP-1)"

sandbox 'Service started in extend mode with a restore still owed'
printf '2560\t1600\t59.99399948120117\n' > "$XDG_STATE_HOME/hdmi-resolution/pending-mode"
start "$(state "$(panel 0 0 39)" "$(output DP-3 1 true 1536 0 1 1 0 1 "$QHD_MODES")")"
check 'user mode restored' '2560x1600' "$(mode eDP-1)"
check 'placed using the restored panel size' '0,0 256,1440' "$(pos DP-3) $(pos eDP-1)"

sandbox 'Mode IDs renumbered between mirroring and restoring'
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 2 1 "$QHD_MODES")")"
check 'panel switched to the target' '1920x1080' "$(mode eDP-1)"
change "$(state "$(output eDP-1 2 true 0 0 1.25 1 0 7 "$PANEL_MODES_RENUMBERED")")"
check 'user mode restored by size and refresh rate' '2560x1600' "$(mode eDP-1)"

sandbox 'Mirror rule switched off for this display only'
edid DP-3 dell-p2723de.edid
edid HDMI-A-1 no-name-lg.edid
config 'enabled=1' 'target_width=1920' 'target_height=1080' "auto_off_display=$DELL_KEY DELL P2723DE [USB-C/DisplayPort]"
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 2 1 "$QHD_MODES")")"
check 'panel mode untouched' '2560x1600' "$(mode eDP-1)"
check 'no kscreen-doctor call' 0 "$(calls)"
check_log 'logged as manual mirroring' 'Layout changed: initial -> mirror-manual'
change "$(state "$(panel 0 0)" "$(output HDMI-A-1 3 true 2048 0 1 1 2 1 "$FHD_MODES")")"
check 'another display still triggers the rule' '1920x1080' "$(mode eDP-1)"

sandbox 'Switched-off display is recognised on a different port'
edid DP-1 dell-p2723de.edid
config 'enabled=1' "auto_off_display=$DELL_KEY DELL P2723DE [USB-C/DisplayPort]"
start "$(state "$(panel 0 0)" "$(output DP-1 1 true 2048 0 1 1 2 1 "$QHD_MODES")")"
check 'panel mode untouched' '2560x1600' "$(mode eDP-1)"

sandbox 'Master switch off -> nothing applied, owed restore still honoured'
config 'enabled=0' 'target_width=1920' 'target_height=1080'
printf '2560\t1600\t59.99399948120117\n' > "$XDG_STATE_HOME/hdmi-resolution/pending-mode"
start "$(state "$(panel 0 0 39)" "$(output DP-3 1 true 2048 0 1 1 2 1 "$QHD_MODES")")"
check 'user mode restored' '2560x1600' "$(mode eDP-1)"
check 'pending restore cleared' 'none' "$(pending)"
change "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 2 1 "$QHD_MODES")")"
check 'panel left alone afterwards' '2560x1600' "$(mode eDP-1)"

sandbox 'Lid closed while mirroring (panel off) -> nothing touched'
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 2 1 "$QHD_MODES")")"
n=$(calls)
change "$(state "$(panel 0 0 39 false)" "$(output DP-3 1 true 0 0 1 1 2 1 "$QHD_MODES")")"
check 'no further kscreen-doctor call' "$n" "$(calls)"
check 'pending restore kept' "$USER_MODE" "$(pending)"
change "$(state "$(panel 0 0 39)")"
check 'user mode restored once the panel is back alone' '2560x1600' "$(mode eDP-1)"

sandbox 'kscreen-doctor refuses the restore -> pending kept, no retry loop'
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 2 1 "$QHD_MODES")")"
touch "$MOCK_DIR/fail-apply"
n=$(calls)
change "$(state "$(panel 0 0 39)")"
check 'exactly one restore attempt' $((n + 1)) "$(calls)"
check 'pending restore kept' "$USER_MODE" "$(pending)"
check 'target not recorded as the user mode' 'none' "$(baseline)"
rm "$MOCK_DIR/fail-apply"
change "$(state "$(panel 0 0 39)")"
check 'restored at the next display change' '2560x1600' "$(mode eDP-1)"

sandbox 'kscreen-doctor returns no JSON (e.g. not a Plasma session)'
touch "$MOCK_DIR/broken"
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")")"
check 'no kscreen-doctor call' 0 "$(calls)"
check_log 'error logged' 'ERROR: could not determine display layout'
check_alive
rm "$MOCK_DIR/broken"
change "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")")"
check 'recovers when Plasma answers again' '0,0 256,1440' "$(pos DP-3) $(pos eDP-1)"

sandbox 'Config from the first version (three keys) -> both rules on'
config '# Managed by hdmi-resolution-tui.' 'enabled=1' 'target_width=1920' 'target_height=1080'
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")")"
check 'extend rule active' '0,0 256,1440' "$(pos DP-3) $(pos eDP-1)"
change "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 2 1 "$QHD_MODES")")"
check 'mirror rule active' '1920x1080' "$(mode eDP-1)"

sandbox 'Config is data: shell code in it is never executed, bad lines are ignored'
edid DP-3 dell-p2723de.edid
config "enabled=0; touch $T/pwned-1" \
    "target_width=\$(touch $T/pwned-2)" \
    "\`touch $T/pwned-3\`" \
    'extend_top_center = 0' \
    'target_width=(' \
    'target_height=1080' \
    "auto_off_display=$DELL_KEY \$(touch $T/pwned-4)"
start "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")")"
check 'rejected lines leave the defaults (extend rule on)' '0,0 256,1440' "$(pos DP-3) $(pos eDP-1)"
check_log 'rejected lines are reported by number' 'WARNING: ignoring line 1 of .*/config'
change "$(state "$(panel 0 0)" "$(output DP-3 1 true 2048 0 1 1 2 1 "$QHD_MODES")")"
check 'well-formed display line still honoured' '2560x1600' "$(mode eDP-1)"
check 'nothing in the config was executed' '' "$(find "$T" -name 'pwned-*')"
check_alive

# === Display identification =================================================

sandbox 'list-displays identifies and labels every connector type'
stop_daemon
edid DP-3 dell-p2723de.edid
edid HDMI-A-1 no-name-lg.edid
edid DP-2 hostile-name.edid
mkdir -p "$T/drm/card1-x"
config 'enabled=1' 'auto_off_display=connector:VGA-1 Unidentified display [VGA]'
set_state "$(state "$(panel 0 0)" \
    "$(output DP-3 1 true 2048 0 1 1 0 1 "$QHD_MODES")" \
    "$(output DP-2 6 true 7000 0 1 1 0 1 "$FHD_MODES")" \
    "$(output x/../card1-DP-3 7 true 9000 0 1 1 0 1 "$FHD_MODES")" \
    "$(output HDMI-A-1 3 true 0 0 1 1 2 1 "$FHD_MODES")" \
    "$(output DVI-I-1 4 false 0 0 1 1 0 1 "$FHD_MODES")" \
    "$(output VGA-1 5 true 5000 0 1 1 0 1 "$FHD_MODES")")"
listing=$("$DAEMON" list-displays)
line() { grep -P "\t$1\t" <<< "$listing" | tr '\t' '|'; }
check 'USB-C display named from its EDID' "$DELL_KEY|DP-3|USB-C/DisplayPort|DELL P2723DE|extended|on" "$(line DP-3)"
hdmi=$(line HDMI-A-1)
check 'HDMI display without a name falls back to vendor and product' \
    'HDMI|LG Electronics 5B08|mirrored|on' "$(cut -d'|' -f3- <<< "${hdmi/GSM 5B08/LG Electronics 5B08}")"
check 'disabled DVI display without EDID' 'connector:DVI-I-1|DVI-I-1|DVI|Unidentified display|disabled|on' "$(line DVI-I-1)"
check 'VGA display switched off in the config' 'connector:VGA-1|VGA-1|VGA|Unidentified display|extended|off' "$(line VGA-1)"
check 'panel is not listed' '' "$(line eDP-1)"
check 'name that looks like an option is kept as plain text' "$HOSTILE_KEY|DP-2|USB-C/DisplayPort|--title PWN|extended|on" "$(line DP-2)"
check 'output name with a path in it cannot reach another EDID' \
    'connector:x/../card1-DP-3|x/../card1-DP-3|x/../card1|Unidentified display|extended|on' "$(line x/../card1-DP-3)"
check 'status runs' 0 "$("$DAEMON" status > "$T/status.txt" 2>&1; echo $?)"
check 'status shows the layout' 'Layout:       mirror' "$(grep '^Layout' "$T/status.txt")"

# === TUI ====================================================================

if command -v tmux > /dev/null && command -v whiptail > /dev/null; then
    tm() { tmux -L hdmi-resolution-test "$@"; }
    screen() { sleep 0.6; tm capture-pane -p -t tui; }
    key() { tm send-keys -t tui "$@"; sleep 0.3; }
    check_screen() {
        if grep -q -F -- "$2" <<< "$(screen)"; then
            pass=$((pass + 1))
            echo "  ok   $1"
        else
            fail=$((fail + 1))
            echo "  FAIL $1: '$2' not on screen"
            screen | sed 's/^/       | /'
        fi
    }
    start_tui() {
        tm kill-server 2>/dev/null
        tm new-session -d -s tui -x 100 -y 40 \
            "env PATH='$T/bin:$PATH' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' XDG_STATE_HOME='$XDG_STATE_HOME' MOCK_DIR='$MOCK_DIR' HDMI_RESOLUTION_KSCREEN_DOCTOR='$HDMI_RESOLUTION_KSCREEN_DOCTOR' HDMI_RESOLUTION_DRM_DIR='$HDMI_RESOLUTION_DRM_DIR' TERM=xterm '$TUI'"
    }

    sandbox 'TUI: menus, per-display switch, extend switch, save'
    stop_daemon
    edid DP-3 dell-p2723de.edid
    mkdir -p "$T/bin"
    printf '#!/bin/sh\necho "$@" >> "%s/systemctl.log"\n' "$T" > "$T/bin/systemctl"
    chmod +x "$T/bin/systemctl"
    config '# Managed by hdmi-resolution-tui.' 'enabled=1' 'target_width=1920' 'target_height=1080'
    set_state "$(state "$(panel 256 1440)" "$(output DP-3 1 true 0 0 1 1 0 1 "$QHD_MODES")")"
    start_tui
    check_screen 'main menu lists the connected display' 'DELL P2723DE [USB-C/DisplayPort] (DP-3, extended): mirror rule on'
    check_screen 'main menu shows the mirror rule' 'Mirror rule, all displays: ON'
    check_screen 'main menu shows the extend rule' 'Extend rule (above, centred): ON'
    check_screen 'main menu counts displays' 'Mirror rule per display: 1 of 1 on'
    key Down Enter
    check_screen 'display checklist labels the display' '[*] DELL P2723DE [USB-C/DisplayPort] (DP-3, extended)'
    key Space Enter
    check_screen 'display switched off' 'Mirror rule per display: 0 of 1 on'
    key Down Down Enter
    check_screen 'target menu opens' '1080p (recommended)'
    key Down Enter
    check_screen 'target changed' 'Mirrored target: 2560x1440'
    key Down Down Down Enter
    check_screen 'extend rule dialog explains itself' 'Enable the extend rule?'
    key Tab Enter
    check_screen 'extend rule switched off' 'Extend rule (above, centred): OFF'
    key Enter
    check_screen 'master switch dialog explains itself' 'Enable the mirror rule?'
    key Tab Enter
    check_screen 'master switch off' 'Mirror rule, all displays: OFF'
    key Down Down Down Down Enter
    check_screen 'restore explanation shown' 'never hardcodes the restore resolution'
    key Enter
    key Down Down Down Down Down Enter
    check_screen 'save confirmation' 'The service has been restarted.'
    key Enter
    sleep 0.5
    saved=$(grep -v '^#' "$XDG_CONFIG_HOME/hdmi-resolution/config" | tr '\n' ';')
    check 'config written' \
        "enabled=0;target_width=2560;target_height=1440;extend_top_center=0;auto_off_display=${DELL_KEY} DELL P2723DE [USB-C/DisplayPort];" "$saved"
    check 'service restarted through systemctl' '--user restart hdmi-resolution.service' "$(cat "$T/systemctl.log" 2>/dev/null)"
    check 'daemon reads the saved config' 'off' "$("$DAEMON" list-displays | cut -f6)"

    echo
    echo '== TUI: switched-off display is remembered while unplugged; cancel changes nothing'
    set_state "$(state "$(panel 0 0)")"
    before=$(md5sum < "$XDG_CONFIG_HOME/hdmi-resolution/config")
    start_tui
    check_screen 'unplugged display still listed' 'DELL P2723DE [USB-C/DisplayPort] (not connected): mirror rule off'
    key Down Enter
    check_screen 'checklist shows it unticked' '[ ] DELL P2723DE [USB-C/DisplayPort] (not connected)'
    key Space Enter
    check_screen 'switched back on' 'Mirror rule per display: 1 of 1 on'
    key Down Down Down Down Down Down Enter
    sleep 0.5
    check 'exit without saving leaves the config alone' "$before" "$(md5sum < "$XDG_CONFIG_HOME/hdmi-resolution/config")"

    echo
    echo '== TUI: junk and shell code in the config are ignored and gone after a save'
    config "enabled=0; touch $T/pwned-5" 'target_width=(' "\$(touch $T/pwned-6)" 'extend_top_center=0'
    start_tui
    check_screen 'rejected line leaves the default' 'Mirror rule, all displays: ON'
    check_screen 'valid line is honoured' 'Extend rule (above, centred): OFF'
    key Down Down Down Down Down Enter
    check_screen 'save confirmation' 'The service has been restarted.'
    key Enter
    sleep 0.5
    check 'saved config holds only known settings' \
        'enabled=1;target_width=1920;target_height=1080;extend_top_center=0;' \
        "$(grep -v '^#' "$XDG_CONFIG_HOME/hdmi-resolution/config" | tr '\n' ';')"
    check 'nothing in the config was executed' '' "$(find "$T" -name 'pwned-*')"

    echo
    echo '== TUI: display whose EDID name looks like a command-line option'
    edid DP-2 hostile-name.edid
    config 'enabled=1'
    set_state "$(state "$(panel 0 0)" "$(output DP-2 1 true 2048 0 1 1 0 1 "$FHD_MODES")")"
    start_tui
    check_screen 'main menu shows the name as text' '--title PWN [USB-C/DisplayPort] (DP-2, extended): mirror rule on'
    key Down Enter
    check_screen 'checklist shows the name as text' '[*] --title PWN [USB-C/DisplayPort] (DP-2, extended)'
    key Space Enter
    check_screen 'display switched off' 'Mirror rule per display: 0 of 1 on'
    key Down Down Down Down Down Enter
    check_screen 'save confirmation' 'The service has been restarted.'
    key Enter
    sleep 0.5
    check 'saved as one plain line' "auto_off_display=${HOSTILE_KEY} --title PWN [USB-C/DisplayPort]" \
        "$(grep '^auto_off_display' "$XDG_CONFIG_HOME/hdmi-resolution/config")"
    check 'daemon reads it back' 'off' "$("$DAEMON" list-displays | cut -f6)"

    echo
    echo '== TUI: no display connected and none remembered'
    config 'enabled=1' 'target_width=1920' 'target_height=1080'
    set_state "$(state "$(panel 0 0)")"
    start_tui
    check_screen 'main menu says so' 'No external display connected.'
    key Down Enter
    check_screen 'per-display dialog explains' 'No external display is connected'
    key Enter Escape Escape
    tm kill-server 2>/dev/null
else
    echo
    echo '== TUI tests skipped (tmux or whiptail not installed)'
fi

echo
echo "passed: $pass   failed: $fail"
((fail == 0))
