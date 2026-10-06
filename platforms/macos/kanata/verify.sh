#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'macOS Kanata verification must run on macOS.\n' >&2
  exit 1
fi

kanata_label="dev.rebuildup.pc-setup.kanata"
driver_label="org.pqrs.Karabiner-VirtualHIDDevice-Daemon"
config_path="/usr/local/etc/pc-setup/kanata/kanata-us.kbd"
source_ref_path="/usr/local/etc/pc-setup/kanata/SOURCE_REF"
expected_ref="583f54d196b30ca00d4c5a8142514409c9757aef"
kanata_log="/var/log/pc-setup-kanata.log"

for label in "$driver_label" "$kanata_label"; do
  output="$(sudo /bin/launchctl print "system/$label")"
  if ! grep -Fq 'state = running' <<<"$output"; then
    printf 'LaunchDaemon is not running: %s\n' "$label" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
done

if [[ ! -r "$config_path" || ! -r "$source_ref_path" ]]; then
  printf 'installed Kanata config metadata is missing.\n' >&2
  exit 1
fi

if [[ "$(cat "$source_ref_path")" != "$expected_ref" ]]; then
  printf 'unexpected key-map-kanata config ref.\n' >&2
  exit 1
fi

# DriverKit activation and virtual keyboard creation are asynchronous. The
# installer bootstraps both LaunchDaemons back-to-back, so an immediate verify
# can race Kanata's own 10-second DriverKit wait. Poll for the same evidence
# observed in the successful manual smoke test instead of failing instantly.
deadline=$((SECONDS + 20))
while (( SECONDS < deadline )); do
  recent_log="$(sudo tail -n 300 "$kanata_log" 2>/dev/null || true)"

  if grep -Fq 'keyboard grabbed, entering event processing loop' <<<"$recent_log"; then
    printf 'macOS Kanata verification passed.\n'
    exit 0
  fi

  if grep -Fq 'macOS Accessibility permission not yet granted' <<<"$recent_log"; then
    printf 'Kanata LaunchDaemon lacks effective macOS Accessibility permission.\n' >&2
    printf 'Re-add the exact installed Kanata binary to Accessibility and Input Monitoring, then kickstart the daemon.\n' >&2
    sudo tail -n 80 "$kanata_log" >&2 || true
    exit 1
  fi

  sleep 1
done

printf 'Kanata LaunchDaemon is running, but keyboard-grab evidence did not appear within 20 seconds.\n' >&2
printf 'Inspect the recent service log below.\n' >&2
sudo tail -n 120 "$kanata_log" >&2 || true
exit 1
