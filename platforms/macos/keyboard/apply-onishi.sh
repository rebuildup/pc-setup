#!/usr/bin/env bash
set -euo pipefail

# Applies the Onishi base layout as a global hidutil UserKeyMapping and then
# verifies that the mapping actually reached every keyboard event service.
#
# A single unverified apply is not sufficient. On boot the Karabiner DriverKit
# virtual keyboard registers tens of seconds after launchd starts this job, and a
# hidutil write that predates the registration leaves that keyboard on the raw US
# ANSI layout until the next reboot. The failure is silent because the global
# registry entry still reports the full mapping.
#
# This script therefore re-applies and re-checks until every keyboard event
# service present on the machine reports the full mapping, and keeps watching for
# a short window so a keyboard that registers late is still covered.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
mapping_file="${ONISHI_MAPPING_FILE:-$script_dir/onishi.json}"
retry_interval="${ONISHI_RETRY_INTERVAL:-2}"
max_attempts="${ONISHI_MAX_ATTEMPTS:-30}"
settle_seconds="${ONISHI_SETTLE_SECONDS:-8}"

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

# Keyboard event services are the services that actually deliver key events to
# the window server. Device-level services such as AppleUserHIDDevice or
# AppleHIDTransportHIDDevice are parents and never carry UserKeyMapping.
keyboard_service_count() {
  /usr/bin/hidutil list |
    /usr/bin/awk 'NR > 1 && $4 == 1 && $5 == 6 && $8 ~ /Event(Driver|Service)/ { n++ } END { print n+0 }'
}

# `--matching keyboard --get` reports the effective mapping of every matching
# keyboard event service, so a keyboard that missed the apply contributes fewer
# entries and lowers the total. Counting the reported rows is not sufficient
# because an unmapped service still answers with an empty mapping.
applied_entry_count() {
  /usr/bin/hidutil property --matching keyboard --get UserKeyMapping 2>/dev/null |
    /usr/bin/awk '/HIDKeyboardModifierMappingSrc/ { n++ } END { print n+0 }'
}

verify_coverage() {
  local keyboard_services applied_entries
  keyboard_services="$(keyboard_service_count)"
  applied_entries="$(applied_entry_count)"

  if [[ "$keyboard_services" -eq 0 ]]; then
    log "no keyboard event service is present yet"
    return 1
  fi
  if [[ "$applied_entries" -ne $((keyboard_services * expected_entries)) ]]; then
    log "mapping reached $applied_entries of $((keyboard_services * expected_entries)) expected entries across $keyboard_services keyboard event service(s)"
    return 1
  fi

  KEYBOARD_SERVICES="$keyboard_services"
  return 0
}

# Waits until the coverage stops changing, because a keyboard service that
# registers during the window needs a fresh apply. Polling instead of a single
# sleep keeps a late service from costing the whole settle window.
watch_settle_window() {
  local elapsed=0
  while [[ "$elapsed" -lt "$settle_seconds" ]]; do
    /bin/sleep "$retry_interval"
    elapsed=$((elapsed + retry_interval))
    if ! verify_coverage; then
      return 1
    fi
  done
  return 0
}

attempt=1
while [[ "$attempt" -le "$max_attempts" ]]; do
  if /usr/bin/hidutil property --set "$mapping_body" >/dev/null; then
    log "attempt $attempt: set global UserKeyMapping ($expected_entries entries)"
  else
    log "attempt $attempt: hidutil property --set failed"
  fi

  if verify_coverage && watch_settle_window; then
    log "applied Onishi mapping to $KEYBOARD_SERVICES keyboard event service(s), $expected_entries entries each"
    exit 0
  fi

  log "coverage incomplete, retrying"
  attempt=$((attempt + 1))
done

log "gave up after $max_attempts attempts; Onishi mapping is not fully applied"
exit 1