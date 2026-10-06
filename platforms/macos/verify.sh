#!/usr/bin/env bash
set -euo pipefail

label="dev.rebuildup.pc-setup.onishi"
launch_domain="gui/$(id -u)"
installed_apply="$HOME/.local/libexec/pc-setup/apply-onishi.sh"
installed_plist="$HOME/Library/LaunchAgents/$label.plist"

failures=0

ok() {
  printf 'OK    %s\n' "$*"
}

fail() {
  printf 'FAIL  %s\n' "$*"
  failures=$((failures + 1))
}

printf 'pc-setup macOS verification\n\n'

if [[ "$(uname -s)" == "Darwin" ]]; then
  ok "macOS detected ($(sw_vers -productVersion))"
else
  fail "Expected macOS"
fi

if [[ -x "$installed_apply" ]]; then
  ok "installed Onishi apply script"
else
  fail "Onishi apply script is missing: $installed_apply"
fi

if [[ -f "$installed_plist" ]]; then
  ok "Onishi LaunchAgent plist"
else
  fail "Onishi LaunchAgent plist is missing: $installed_plist"
fi

if launchctl print "$launch_domain/$label" >/dev/null 2>&1; then
  ok "Onishi LaunchAgent is loaded"
else
  fail "Onishi LaunchAgent is not loaded"
fi

mapping_output="$(/usr/bin/hidutil property --get UserKeyMapping 2>/dev/null || true)"
if [[ -n "$mapping_output" && "$mapping_output" != *"(null)"* ]]; then
  ok "hidutil UserKeyMapping is active"
else
  fail "hidutil UserKeyMapping is not active"
fi

printf '\nResult: %d failure(s)\n' "$failures"

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi
