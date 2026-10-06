#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Skipping macOS keyboard setup on non-macOS host.\n'
  exit 0
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source_dir="$repo_root/platforms/macos/keyboard"
install_dir="$HOME/.local/libexec/pc-setup/macos-keyboard"
launch_agents_dir="$HOME/Library/LaunchAgents"
label="dev.rebuildup.pc-setup.onishi-keymap"
plist_name="$label.plist"
target_plist="$launch_agents_dir/$plist_name"
domain="gui/$(id -u)"

mkdir -p "$install_dir" "$launch_agents_dir"
install -m 0755 "$source_dir/apply-onishi.sh" "$install_dir/apply-onishi.sh"
install -m 0644 "$source_dir/onishi.json" "$install_dir/onishi.json"
install -m 0644 "$source_dir/$plist_name" "$target_plist"

/bin/launchctl bootout "$domain" "$target_plist" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "$domain" "$target_plist"
"$install_dir/apply-onishi.sh"

printf 'Installed macOS Onishi keyboard LaunchAgent: %s\n' "$target_plist"
