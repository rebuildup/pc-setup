#!/usr/bin/env bash
set -euo pipefail

# Applies the Onishi base layout to the physical keyboard event services only.
#
# Ownership boundary: hidutil owns the base layout at the lowest layer so that a
# working layout survives Kanata being absent and is available before user
# login. Kanata owns stateful customization above it. That split only holds if
# exactly one conversion runs per keystroke, so this script must never let the
# mapping reach the Karabiner DriverKit virtual keyboard that Kanata injects
# through. A mapping on that service is a second conversion of Kanata's already
# converted output, which scrambles every layer it drives.
#
# `hidutil property --set` appends a registry entry rather than replacing the
# existing one, so repeated applies accumulate entries across the whole HID event
# system. Those leftovers sit on non-keyboard services such as AppleSMCKeysEndpoint
# and never reach the window server, so verification counts mapping entries per
# keyboard event service instead of registry entries globally. Counting globally
# reports a false failure on any machine that has run the helper more than once.
#
# The Karabiner DriverKit virtual keyboard registers tens of seconds after
# launchd starts this job, so a clear issued at boot alone is undone once that
# service appears. The script keeps clearing it across a settle window.
#
# Device-level services such as AppleUserHIDDevice or AppleHIDTransportHIDDevice
# are parents and never carry UserKeyMapping, so verification only counts
# keyboard event services.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
mapping_file="${ONISHI_MAPPING_FILE:-$script_dir/onishi.json}"
retry_interval="${ONISHI_RETRY_INTERVAL:-2}"
max_attempts="${ONISHI_MAX_ATTEMPTS:-30}"
settle_seconds="${ONISHI_SETTLE_SECONDS:-90}"
virtual_keyboard_match="${ONISHI_VIRTUAL_KEYBOARD_MATCH:-{\"VendorID\":0x16c0,\"ProductID\":0x27db}}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Onishi hidutil mapping is only supported on macOS.\n' >&2
  exit 1
fi

if [[ ! -r "$mapping_file" ]]; then
  printf 'Onishi mapping file is missing: %s\n' "$mapping_file" >&2
  exit 1
fi

log() {
  printf '%s %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

mapping_body="$(/bin/cat "$mapping_file")"
expected_entries="$(/usr/bin/awk '/HIDKeyboardModifierMappingSrc/ { n++ } END { print n+0 }' "$mapping_file")"

if [[ "$expected_entries" -eq 0 ]]; then
  log "mapping file declares no mapping entries: $mapping_file"
  exit 1
fi

# Keyboard event services that must carry the mapping.
#
# Two exclusions. AppleUserHIDEventService is the Karabiner DriverKit virtual
# keyboard, which is verified separately as carrying no mapping at all; counting
# it here would make the expected total unreachable. AppleUserHIDDevice is a device
# level parent and never carries UserKeyMapping. AppleHIDTransportHIDDevice is
# also a parent. The remaining AppleHIDKeyboardEventDriverV2 is the physical
# keyboard driver.
keyboard_service_count() {
  /usr/bin/hidutil list |
    /usr/bin/awk 'NR > 1 && $4 == 1 && $5 == 6 && $8 ~ /EventDriver/ { n++ } END { print n+0 }'
}

# `--matching keyboard --get` reports the effective mapping of every matching
# keyboard event service, so a keyboard that missed the apply contributes fewer
# entries and lowers the total. Counting the reported rows is not sufficient
# because an unmapped service still answers with an empty mapping.
applied_entry_count() {
  /usr/bin/hidutil property --matching keyboard --get UserKeyMapping 2>/dev/null |
    /usr/bin/awk '/HIDKeyboardModifierMappingSrc/ { n++ } END { print n+0 }'
}

virtual_keyboard_entries() {
  /usr/bin/hidutil property --matching "$virtual_keyboard_match" --get UserKeyMapping 2>/dev/null |
    /usr/bin/awk '/HIDKeyboardModifierMappingSrc/ { n++ } END { print n+0 }'
}

# The virtual keyboard only exists once DriverKit has registered it. Treating an
# absent service as a failure would report the clear as incomplete during the
# first seconds of boot, so this reports success while there is nothing to clear.
clear_virtual_keyboard() {
  local entries
  entries="$(virtual_keyboard_entries)"
  if [[ "$entries" -eq 0 ]]; then
    return 0
  fi

  if /usr/bin/hidutil property --matching "$virtual_keyboard_match" \
    --set '{"UserKeyMapping":[]}' >/dev/null 2>&1; then
    log "cleared $entries Onishi entries from the Kanata virtual keyboard"
  else
    log "failed to clear the Onishi mapping from the Kanata virtual keyboard"
    return 1
  fi
}

# A correct end state is exactly one conversion per keystroke: every keyboard
# event service reports one copy of the mapping and the Kanata virtual keyboard
# reports none.
verify_state() {
  local services applied
  services="$(keyboard_service_count)"
  applied="$(applied_entry_count)"

  if [[ "$services" -eq 0 ]]; then
    log "no keyboard event service is present yet"
    return 1
  fi

  if [[ "$applied" -ne $((services * expected_entries)) ]]; then
    log "mapping reached $applied of $((services * expected_entries)) expected entries across $services keyboard event service(s)"
    return 1
  fi

  if ! clear_virtual_keyboard; then
    return 1
  fi

  if [[ "$(virtual_keyboard_entries)" -ne 0 ]]; then
    log "the Kanata virtual keyboard still carries the Onishi mapping"
    return 1
  fi

  KEYBOARD_SERVICES="$services"
  return 0
}

# Keeps clearing the virtual keyboard across the whole window. DriverKit can
# register, disappear and re-register while the machine settles, and every
# re-registration restores the mapping that the boot-time apply just cleared.
watch_settle_window() {
  local elapsed=0
  while [[ "$elapsed" -lt "$settle_seconds" ]]; do
    /bin/sleep "$retry_interval"
    elapsed=$((elapsed + retry_interval))
    clear_virtual_keyboard || return 1
  done
  return 0
}

attempt=1
while [[ "$attempt" -le "$max_attempts" ]]; do
  # The Karabiner DriverKit virtual keyboard is absent right after launchd starts
  # this job and registers later, so it is cleared once here and then repeatedly
  # across the settle window.
  clear_virtual_keyboard || true

  if /usr/bin/hidutil property --set "$mapping_body" >/dev/null; then
    log "attempt $attempt: set global UserKeyMapping ($expected_entries entries)"
  else
    log "attempt $attempt: hidutil property --set failed"
  fi

  if verify_state && watch_settle_window; then
    log "applied Onishi mapping to $KEYBOARD_SERVICES keyboard event service(s), $expected_entries entries each, Kanata virtual keyboard clear"
    exit 0
  fi

  log "coverage incomplete, retrying"
  attempt=$((attempt + 1))
done

log "gave up after $max_attempts attempts; Onishi mapping is not fully applied"
exit 1