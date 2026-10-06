#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'setup-keyboard.sh is only supported on macOS\n' >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
label="dev.rebuildup.pc-setup.onishi"
source_apply="$script_dir/apply-onishi.sh"
source_plist="$script_dir/$label.plist"
install_dir="$HOME/.local/libexec/pc-setup"
installed_apply="$install_dir/apply-onishi.sh"
launch_agents_dir="$HOME/Library/LaunchAgents"
installed_plist="$launch_agents_dir/$label.plist"
launch_domain="gui/$(id -u)"

mkdir -p "$install_dir" "$launch_agents_dir"
install -m 0755 "$source_apply" "$installed_apply"
install -m 0644 "$source_plist" "$installed_plist"

# Reconcile the user LaunchAgent so rerunning bootstrap picks up repository changes.
launchctl bootout "$launch_domain" "$installed_plist" >/dev/null 2>&1 || true
launchctl bootstrap "$launch_domain" "$installed_plist"
launchctl enable "$launch_domain/$label" >/dev/null 2>&1 || true
launchctl kickstart -k "$launch_domain/$label"

printf 'Installed and started %s\n' "$label"
