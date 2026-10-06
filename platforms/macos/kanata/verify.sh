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

for label in "$driver_label" "$kanata_label"; do
  output="$(sudo /bin/launchctl print "system/$label")"
  if ! grep -Fq 'state = running' <<<"$output"; then
    printf 'LaunchDaemon is not running: %s\n' "$label" >&2
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

if ! sudo tail -n 200 /var/log/pc-setup-kanata.log 2>/dev/null | grep -Fq 'keyboard grabbed, entering event processing loop'; then
  printf 'Kanata is running but no successful keyboard-grab evidence is present in the recent log.\n' >&2
  printf 'Inspect: sudo tail -n 200 /var/log/pc-setup-kanata.log\n' >&2
  exit 1
fi

printf 'macOS Kanata verification passed.\n'
