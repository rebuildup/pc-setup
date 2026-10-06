#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'macOS verification must run on macOS.\n' >&2
  exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source_dir="$repo_root/platforms/macos/keyboard"
install_dir="$HOME/.local/libexec/pc-setup/macos-keyboard"
label="dev.rebuildup.pc-setup.onishi-keymap"
target_plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

for command in /usr/bin/hidutil /bin/launchctl; do
  if [[ ! -x "$command" ]]; then
    printf 'missing required command: %s\n' "$command" >&2
    exit 1
  fi
done

if [[ ! -x "$install_dir/apply-onishi.sh" ]]; then
  printf 'missing installed keyboard helper: %s\n' "$install_dir/apply-onishi.sh" >&2
  exit 1
fi

cmp "$source_dir/apply-onishi.sh" "$install_dir/apply-onishi.sh"
cmp "$source_dir/onishi.json" "$install_dir/onishi.json"
cmp "$source_dir/$label.plist" "$target_plist"

/bin/launchctl print "$domain/$label" >/dev/null

mapping_output="$(/usr/bin/hidutil property --get UserKeyMapping)"
for critical_value in   30064771082   30064771117   30064771128   30064771077; do
  if ! grep -Fq "$critical_value" <<<"$mapping_output"; then
    printf 'active UserKeyMapping is missing critical HID value: %s\n' "$critical_value" >&2
    exit 1
  fi
done

printf 'macOS keyboard verification passed.\n'
