#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Skipping macOS keyboard setup on non-macOS host.\n'
  exit 0
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source_dir="$repo_root/platforms/macos/keyboard"
install_dir="/usr/local/libexec/pc-setup/macos-keyboard"
launch_daemons_dir="/Library/LaunchDaemons"
label="dev.rebuildup.pc-setup.onishi-keymap"
plist_name="$label.plist"
target_plist="$launch_daemons_dir/$plist_name"

# Remove the old per-user LaunchAgent from the first macOS implementation.
old_user_plist="$HOME/Library/LaunchAgents/$plist_name"
old_user_dir="$HOME/.local/libexec/pc-setup/macos-keyboard"
/bin/launchctl bootout "gui/$(id -u)" "$old_user_plist" >/dev/null 2>&1 || true
rm -f "$old_user_plist"
rm -rf "$old_user_dir"

sudo mkdir -p "$install_dir" "$launch_daemons_dir"
sudo install -o root -g wheel -m 0755 "$source_dir/apply-onishi.sh" "$install_dir/apply-onishi.sh"
sudo install -o root -g wheel -m 0644 "$source_dir/onishi.json" "$install_dir/onishi.json"
sudo install -o root -g wheel -m 0644 "$source_dir/$plist_name" "$target_plist"

sudo /bin/launchctl bootout "system/$label" >/dev/null 2>&1 || true
sudo /bin/launchctl bootstrap system "$target_plist"
sudo "$install_dir/apply-onishi.sh"

printf 'Installed macOS Onishi keyboard LaunchDaemon: %s\n' "$target_plist"
