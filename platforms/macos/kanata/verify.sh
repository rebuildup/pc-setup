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
expected_ref="0c02df504029d84bdaa145a70b2ac9719f5e9956"
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
#
# Kanata 1.12.0 does not reliably emit "keyboard grabbed" to the LaunchDaemon
# log: under launchd the early startup records never reach the file, while the
# per-second "virtual_hid_keyboard_ready" poll and "Entered layer" records do.
# A layer transition is therefore accepted as grab evidence too: layers only
# change while the event loop is processing real key events.
deadline=$((SECONDS + 20))
while (( SECONDS < deadline )); do
  recent_log="$(sudo tail -n 300 "$kanata_log" 2>/dev/null || true)"

  if grep -Eq 'keyboard grabbed, entering event processing loop|Entered layer' <<<"$recent_log"; then
    printf 'macOS Kanata verification passed.\n'
    exit 0
  fi

  if grep -Eq 'Accessibility permission not yet granted|failed to open keyboard device|output backend unavailable' <<<"$recent_log"; then
    printf 'Kanata LaunchDaemon reported an input or permission failure.\n' >&2
    printf 'Re-add the exact installed Kanata binary to Accessibility and Input Monitoring, then kickstart the daemon.\n' >&2
    sudo tail -n 80 "$kanata_log" >&2 || true
    exit 1
  fi

  sleep 1
done

# No grab evidence in the log window. The startup line is not guaranteed to be
# logged under launchd, so corroborate instead: the DriverKit virtual keyboard
# must exist and the Kanata process must hold the VirtualHID client socket.
vhid_device="$(/usr/bin/hidutil list 2>/dev/null |
  /usr/bin/awk '$1 == "0x16c0" && $2 == "0x27db" { n++ } END { print n+0 }')"
kanata_pid="$(sudo /bin/launchctl print "system/$kanata_label" 2>/dev/null |
  /usr/bin/awk '/^[[:space:]]*pid =/ { print $3; exit }')"
socket_count=0
if [[ -n "$kanata_pid" ]]; then
  socket_count="$(sudo /usr/sbin/lsof -p "$kanata_pid" 2>/dev/null |
    /usr/bin/grep -c 'vhidd_client' || true)"
fi

if [[ "$vhid_device" -gt 0 && "$socket_count" -gt 0 ]]; then
  printf 'WARN: no keyboard-grab log evidence, but the Kanata virtual HID device exists and the daemon holds the VirtualHID socket.\n'
  printf 'Press a key and rerun this script if input remapping does not work.\n'
  exit 0
fi

printf 'Kanata LaunchDaemon is running, but neither grab evidence nor a live VirtualHID connection was found.\n' >&2
printf 'Inspect the recent service log below.\n' >&2
sudo tail -n 120 "$kanata_log" >&2 || true
exit 1
