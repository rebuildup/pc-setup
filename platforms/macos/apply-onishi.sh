#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'apply-onishi.sh is only supported on macOS\n' >&2
  exit 1
fi

readonly HIDUTIL="/usr/bin/hidutil"

readonly mapping='{
  "UserKeyMapping": [
    {"HIDKeyboardModifierMappingSrc":0x70000002D,"HIDKeyboardModifierMappingDst":0x700000038},
    {"HIDKeyboardModifierMappingSrc":0x70000001A,"HIDKeyboardModifierMappingDst":0x70000000F},
    {"HIDKeyboardModifierMappingSrc":0x700000008,"HIDKeyboardModifierMappingDst":0x700000018},
    {"HIDKeyboardModifierMappingSrc":0x700000015,"HIDKeyboardModifierMappingDst":0x700000036},
    {"HIDKeyboardModifierMappingSrc":0x700000017,"HIDKeyboardModifierMappingDst":0x700000037},
    {"HIDKeyboardModifierMappingSrc":0x70000001C,"HIDKeyboardModifierMappingDst":0x700000009},
    {"HIDKeyboardModifierMappingSrc":0x700000018,"HIDKeyboardModifierMappingDst":0x70000001A},
    {"HIDKeyboardModifierMappingSrc":0x70000000C,"HIDKeyboardModifierMappingDst":0x700000015},
    {"HIDKeyboardModifierMappingSrc":0x700000012,"HIDKeyboardModifierMappingDst":0x70000001C},
    {"HIDKeyboardModifierMappingSrc":0x700000004,"HIDKeyboardModifierMappingDst":0x700000008},
    {"HIDKeyboardModifierMappingSrc":0x700000016,"HIDKeyboardModifierMappingDst":0x70000000C},
    {"HIDKeyboardModifierMappingSrc":0x700000007,"HIDKeyboardModifierMappingDst":0x700000004},
    {"HIDKeyboardModifierMappingSrc":0x700000009,"HIDKeyboardModifierMappingDst":0x700000012},
    {"HIDKeyboardModifierMappingSrc":0x70000000A,"HIDKeyboardModifierMappingDst":0x70000002D},
    {"HIDKeyboardModifierMappingSrc":0x70000000B,"HIDKeyboardModifierMappingDst":0x70000000E},
    {"HIDKeyboardModifierMappingSrc":0x70000000D,"HIDKeyboardModifierMappingDst":0x700000017},
    {"HIDKeyboardModifierMappingSrc":0x70000000E,"HIDKeyboardModifierMappingDst":0x700000011},
    {"HIDKeyboardModifierMappingSrc":0x70000000F,"HIDKeyboardModifierMappingDst":0x700000016},
    {"HIDKeyboardModifierMappingSrc":0x700000033,"HIDKeyboardModifierMappingDst":0x70000000B},
    {"HIDKeyboardModifierMappingSrc":0x700000005,"HIDKeyboardModifierMappingDst":0x700000033},
    {"HIDKeyboardModifierMappingSrc":0x700000011,"HIDKeyboardModifierMappingDst":0x70000000A},
    {"HIDKeyboardModifierMappingSrc":0x700000010,"HIDKeyboardModifierMappingDst":0x700000007},
    {"HIDKeyboardModifierMappingSrc":0x700000036,"HIDKeyboardModifierMappingDst":0x700000010},
    {"HIDKeyboardModifierMappingSrc":0x700000037,"HIDKeyboardModifierMappingDst":0x70000000D},
    {"HIDKeyboardModifierMappingSrc":0x700000038,"HIDKeyboardModifierMappingDst":0x700000005}
  ]
}'

"$HIDUTIL" property --set "$mapping" >/dev/null
printf 'Applied Onishi layout with hidutil.\n'
