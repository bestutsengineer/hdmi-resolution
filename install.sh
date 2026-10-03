#!/usr/bin/env bash
# Install hdmi-resolution for the current user. No root needed.
#
# Usage: bash install.sh [--no-restart]
#   --no-restart  install and enable, but leave a running service alone
#                 (it picks up the new version at the next login or restart)
set -eu

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bin_dir="$HOME/.local/bin"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
unit_dir="$config_home/systemd/user"
config_dir="$config_home/hdmi-resolution"

missing=()
for tool in kscreen-doctor jq whiptail md5sum od timeout systemctl; do
    command -v "$tool" > /dev/null || missing+=("$tool")
done
if ((${#missing[@]})); then
    echo "Missing required tools: ${missing[*]}" >&2
    exit 1
fi

install -d "$bin_dir" "$unit_dir" "$config_dir"
install -m 755 "$here/bin/hdmi-resolution" "$here/bin/hdmi-resolution-tui" "$bin_dir/"
install -m 644 "$here/systemd/hdmi-resolution.service" "$unit_dir/"
# Existing settings are kept.
[[ -e "$config_dir/config" ]] || install -m 644 "$here/config.example" "$config_dir/config"

systemctl --user daemon-reload
systemctl --user enable hdmi-resolution.service
if [[ "${1:-}" == --no-restart ]]; then
    echo 'Installed. The new version starts at the next login, or now with:'
    echo '  systemctl --user restart hdmi-resolution.service'
else
    systemctl --user restart hdmi-resolution.service
    echo 'Installed and running. Settings menu: hdmi-resolution-tui'
fi

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "Note: $bin_dir is not in your PATH." ;;
esac
