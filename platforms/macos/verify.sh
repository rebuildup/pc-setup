#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'macOS verification must run on macOS.\n' >&2
  exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source_dir="$repo_root/platforms/macos/keyboard"
install_dir="/usr/local/libexec/pc-setup/macos-keyboard"
label="dev.rebuildup.pc-setup.onishi-keymap"
target_plist="/Library/LaunchDaemons/$label.plist"

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

sudo /bin/launchctl print "system/$label" >/dev/null

mapping_output="$(/usr/bin/hidutil property --get UserKeyMapping)"
for critical_value in 30064771082 30064771117 30064771128 30064771077; do
  if ! grep -Fq "$critical_value" <<<"$mapping_output"; then
    printf 'active UserKeyMapping is missing critical HID value: %s\n' "$critical_value" >&2
    exit 1
  fi
done

# The global registry entry above only proves that the mapping was written once.
# The effective per-service mapping has to be checked as well: the physical
# keyboard must carry the full mapping while the Karabiner DriverKit virtual
# keyboard must carry none, because a mapping there would double-convert
# Kanata's already converted output.
expected_entries="$(/usr/bin/awk '/HIDKeyboardModifierMappingSrc/ { n++ } END { print n+0 }' "$install_dir/onishi.json")"
physical_match='{"PrimaryUsagePage":1,"PrimaryUsage":6,"Transport":"FIFO"}'
virtual_match='{"VendorID":0x16c0,"ProductID":0x27db}'

physical_entries="$(/usr/bin/hidutil property --matching "$physical_match" --get UserKeyMapping |
  /usr/bin/awk '/HIDKeyboardModifierMappingSrc/ { n++ } END { print n+0 }')"
virtual_entries="$(/usr/bin/hidutil property --matching "$virtual_match" --get UserKeyMapping 2>/dev/null |
  /usr/bin/awk '/HIDKeyboardModifierMappingSrc/ { n++ } END { print n+0 }')"

if [[ "$physical_entries" -eq 0 ]]; then
  printf 'no physical keyboard event service was detected.\n' >&2
  exit 1
fi
if [[ "$physical_entries" -ne "$expected_entries" ]]; then
  printf 'Onishi mapping reached %s of %s expected entries on the physical keyboard.\n' \
    "$physical_entries" "$expected_entries" >&2
  printf 'run: sudo %s\n' "$install_dir/apply-onishi.sh" >&2
  exit 1
fi
if [[ "$virtual_entries" -ne 0 ]]; then
  printf 'the Kanata virtual keyboard carries %s Onishi entries; it must carry none.\n' \
    "$virtual_entries" >&2
  printf 'run: sudo %s\n' "$install_dir/apply-onishi.sh" >&2
  exit 1
fi

printf 'Onishi mapping is active on the physical keyboard (%s entries).\n' "$physical_entries"

if [[ -e "$HOME/Library/LaunchAgents/$label.plist" ]]; then
  printf 'legacy per-user LaunchAgent still exists.\n' >&2
  exit 1
fi

printf 'macOS keyboard verification passed.\n'
