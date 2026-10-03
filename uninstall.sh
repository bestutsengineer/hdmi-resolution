#!/usr/bin/env bash
# Remove hdmi-resolution for the current user. Settings and state are kept.
#
# Usage: bash uninstall.sh
set -eu

bin_dir="$HOME/.local/bin"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/hdmi-resolution"

systemctl --user disable --now hdmi-resolution.service 2> /dev/null || true
rm -f "$bin_dir/hdmi-resolution" "$bin_dir/hdmi-resolution-tui" \
    "$config_home/systemd/user/hdmi-resolution.service"
systemctl --user daemon-reload

echo 'Removed. Settings and state were kept; delete them with:'
echo "  rm -r '$config_home/hdmi-resolution' '$state_dir'"
if [[ -e "$state_dir/pending-mode" ]]; then
    echo 'The laptop screen is still at the mirror resolution.'
    echo 'Set it back under System Settings > Display & Monitor.'
fi
