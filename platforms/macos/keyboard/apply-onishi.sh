#!/usr/bin/env bash
set -euo pipefail

# Applies the Onishi base layout to the physical keyboard and keeps the Karabiner
# DriverKit virtual keyboard free of it.
#
# Ownership boundary: hidutil owns the base layout at the lowest layer so that a
# working layout survives Kanata being absent and is available before user login.
# Kanata owns the stateful customization above it. That split only holds if exactly
# one conversion runs per keystroke, and a mapping on the virtual keyboard is a
# second conversion of Kanata's already converted output.
#
# Two independent mechanisms keep that from happening.
#
# The apply is scoped to the physical keyboard. A global `hidutil property --set`
# writes the mapping onto every keyboard event service that exists at that moment,
# and the Karabiner DriverKit virtual keyboard registers tens of seconds into boot
# under a fresh registry entry.
#
# The helper then stays alive and re-checks forever. The virtual keyboard restores
# the mapping every time it registers, and it registers again on every Kanata
# restart, not only on boot, so a helper that exits once leaves nothing to correct
# that. A drift repair rather than a boot-time convergence is what makes the layout
# correct in every state.
#
# `hidutil property --set` appends a registry entry rather than replacing the
# existing one, so the apply runs only when the physical keyboard is not already
# carrying the mapping. Verification counts mapping entries per keyboard event
# service; counting registry entries globally reports a false failure on any machine
# that has run a global apply.
#
# Device-level services such as AppleUserHIDDevice or AppleHIDTransportHIDDevice are
# parents and never carry UserKeyMapping, so verification only counts keyboard event
# services.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
mapping_file="${ONISHI_MAPPING_FILE:-$script_dir/onishi.json}"
retry_interval="${ONISHI_RETRY_INTERVAL:-2}"
max_attempts="${ONISHI_MAX_ATTEMPTS:-30}"
watch_interval="${ONISHI_WATCH_INTERVAL:-5}"
virtual_keyboard_match="${ONISHI_VIRTUAL_KEYBOARD_MATCH:-{\"VendorID\":0x16c0,\"ProductID\":0x27db}}"
# Matches that resolve to the physical keyboard only.
#
# macOS ships bash 3.2, whose glob expansion mangles a `[{"` sequence inside a
# quoted assignment into `[[{`. An unrecognised match then resolves to nothing and
# the helper silently reports an empty mapping, so the match strings must avoid a
# bracketed array literal. Each entry below is a single dictionary.
#
# The Karabiner DriverKit virtual keyboard registers with a null transport while the
# built-in keyboard uses FIFO, so matching on transport keeps them apart without an
# array. Matching on the usage page alone does not separate them: the virtual
# keyboard registers as a keyboard too, and a wildcard apply would put the mapping on
# it every time it registers.
#
# External keyboards need their own entry once one is actually present.
physical_keyboard_matches=(
  '{"PrimaryUsagePage":1,"PrimaryUsage":6,"Transport":"FIFO"}'
)

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

# Mapping entries reported for the physical keyboard. Sums every physical match, so
# adding an external keyboard entry does not change the call sites.
physical_keyboard_entries() {
  local match total=0 entries
  for match in "${physical_keyboard_matches[@]}"; do
    entries="$(
      /usr/bin/hidutil property --matching "$match" --get UserKeyMapping 2>/dev/null |
        /usr/bin/awk '/HIDKeyboardModifierMappingSrc/ { n++ } END { print n+0 }'
    )"
    total=$((total + entries))
  done
  printf '%s' "$total"
}

# Mapping entries reported for the Karabiner DriverKit virtual keyboard.
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

# A correct end state is exactly one conversion per keystroke: the physical
# keyboard reports one copy of the mapping and the Kanata virtual keyboard reports
# none.
verify_state() {
  local physical
  physical="$(physical_keyboard_entries)"

  if [[ "$physical" -eq 0 ]]; then
    log "no keyboard event service is present yet"
    return 1
  fi

  if [[ "$physical" -ne "$expected_entries" ]]; then
    log "physical keyboard carries $physical of $expected_entries expected entries"
    return 1
  fi

  if ! clear_virtual_keyboard; then
    return 1
  fi

  if [[ "$(virtual_keyboard_entries)" -ne 0 ]]; then
    log "the Kanata virtual keyboard still carries the Onishi mapping"
    return 1
  fi

  return 0
}

apply_physical_keyboard() {
  local attempt="$1" match applied=0
  # Scoped to the physical keyboard. A wildcard set would also write the mapping onto
  # the virtual keyboard every time it registers.
  for match in "${physical_keyboard_matches[@]}"; do
    if /usr/bin/hidutil property --matching "$match" --set "$mapping_body" >/dev/null; then
      applied=$((applied + 1))
    else
      log "attempt $attempt: hidutil property --set failed"
    fi
  done
  log "attempt $attempt: set physical keyboard UserKeyMapping on $applied match(es) ($expected_entries entries each)"
}

converge() {
  local attempt=1
  while [[ "$attempt" -le "$max_attempts" ]]; do
    clear_virtual_keyboard || true

    # A registry write is not visible to a following read immediately, so verification
    # must not run in the same breath as the set. Verifying right after the set reads
    # an empty mapping and re-applies on every attempt, which is how the mapping
    # accumulated in the first place.
    if [[ "$(physical_keyboard_entries)" -ne "$expected_entries" ]]; then
      log "attempt $attempt: physical keyboard reports $(physical_keyboard_entries) entries, applying"
      apply_physical_keyboard "$attempt"
      /bin/sleep "$retry_interval"
    fi

    if verify_state; then
      log "attempt $attempt: applied Onishi mapping to the physical keyboard, $expected_entries entries, Kanata virtual keyboard clear"
      return 0
    fi

    log "attempt $attempt: coverage incomplete, retrying"
    attempt=$((attempt + 1))
  done

  log "gave up after $max_attempts attempts; Onishi mapping is not fully applied"
  return 1
}

# The Karabiner DriverKit virtual keyboard restores the mapping every time it
# registers, and it registers again on every Kanata restart, not only on boot. A
# helper that exits after the layout converges leaves nothing to correct that, so the
# convergence loop runs for the life of the job instead of exiting.
#
# Keeping the job alive means the LaunchDaemon must not restart it on success.
converge || exit 1

while true; do
  /bin/sleep "$watch_interval"

  if ! verify_state; then
    log "drift detected, re-converging"
    converge || true
  fi
done