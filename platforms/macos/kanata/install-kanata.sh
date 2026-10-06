#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Skipping macOS Kanata setup on non-macOS host.\n'
  exit 0
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
source_dir="$repo_root/platforms/macos/kanata"

kanata_version="1.12.0"
driver_version="6.2.0"
config_ref="7e127ecdf20b1589d636589a1b0e6f00c7fa2876"
config_url="https://raw.githubusercontent.com/rebuildup/key-map-kanata/$config_ref/mac/kanata-us.kbd"
layout_url="https://raw.githubusercontent.com/rebuildup/key-map-kanata/$config_ref/mac/layout.html"

driver_manager="/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager"
driver_daemon="/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon"
driver_pkg_url="https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v$driver_version/Karabiner-DriverKit-VirtualHIDDevice-$driver_version.pkg"

config_dir="/usr/local/etc/pc-setup/kanata"
config_path="$config_dir/kanata-us.kbd"
layout_path="$config_dir/layout.html"
source_ref_path="$config_dir/SOURCE_REF"

driver_label="org.pqrs.Karabiner-VirtualHIDDevice-Daemon"
driver_plist="/Library/LaunchDaemons/$driver_label.plist"
kanata_label="dev.rebuildup.pc-setup.kanata"
kanata_plist="/Library/LaunchDaemons/$kanata_label.plist"

find_kanata() {
  if [[ -n "${PC_SETUP_KANATA_BIN:-}" && -x "$PC_SETUP_KANATA_BIN" ]]; then
    printf '%s\n' "$PC_SETUP_KANATA_BIN"
    return
  fi

  if command -v kanata >/dev/null 2>&1; then
    command -v kanata
    return
  fi

  for candidate in     /opt/homebrew/opt/kanata/bin/kanata     /usr/local/opt/kanata/bin/kanata; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  return 1
}

kanata_bin="$(find_kanata || true)"
if [[ -z "$kanata_bin" ]]; then
  printf 'Kanata is not installed. Expected brew:kanata from mise bootstrap packages.\n' >&2
  exit 1
fi

kanata_bin="$(python3 - "$kanata_bin" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
)"

if ! "$kanata_bin" --version 2>&1 | grep -Fq "$kanata_version"; then
  printf 'Kanata/DriverKit pair is pinned: expected Kanata %s at %s.\n' "$kanata_version" "$kanata_bin" >&2
  "$kanata_bin" --version >&2 || true
  exit 1
fi

if [[ ! -x "$driver_manager" || ! -x "$driver_daemon" ]]; then
  pkg="$(mktemp -t karabiner-vhid).pkg"
  trap 'rm -f "$pkg"' EXIT
  printf 'Installing Karabiner DriverKit VirtualHIDDevice %s...\n' "$driver_version"
  curl -fsSL "$driver_pkg_url" -o "$pkg"
  sudo /usr/sbin/installer -pkg "$pkg" -target /
fi

if [[ ! -x "$driver_manager" || ! -x "$driver_daemon" ]]; then
  printf 'Karabiner VirtualHIDDevice installation is incomplete.\n' >&2
  exit 1
fi

installed_driver_version="$(defaults read "/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Info.plist" CFBundleVersion 2>/dev/null || true)"
if [[ -n "$installed_driver_version" && "$installed_driver_version" != "$driver_version" ]]; then
  printf 'Expected DriverKit %s, found %s. Refusing an unverified Kanata/driver pair.\n' "$driver_version" "$installed_driver_version" >&2
  exit 1
fi

# Activation can require a one-time approval under
# System Settings > General > Login Items & Extensions > Driver Extensions.
sudo "$driver_manager" forceActivate || true

tmp_config="$(mktemp -t pc-setup-kanata-config)"
tmp_layout="$(mktemp -t pc-setup-kanata-layout)"
tmp_plist="$(mktemp -t pc-setup-kanata-plist)"
trap 'rm -f "$tmp_config" "$tmp_layout" "$tmp_plist"' EXIT
curl -fsSL "$config_url" -o "$tmp_config"
curl -fsSL "$layout_url" -o "$tmp_layout"

printf 'Validating pinned Kanata config before install...\n'
"$kanata_bin" --check --cfg "$tmp_config"

sudo mkdir -p "$config_dir"
sudo install -o root -g wheel -m 0644 "$tmp_config" "$config_path"
sudo install -o root -g wheel -m 0644 "$tmp_layout" "$layout_path"
printf '%s\n' "$config_ref" | sudo tee "$source_ref_path" >/dev/null
sudo chown root:wheel "$source_ref_path"
sudo chmod 0644 "$source_ref_path"

python3 - "$source_dir/dev.rebuildup.pc-setup.kanata.plist.in" "$tmp_plist" "$kanata_bin" "$config_path" <<'PY'
from pathlib import Path
import sys

template = Path(sys.argv[1]).read_text(encoding="utf-8")
rendered = template.replace("__KANATA_BIN__", sys.argv[3]).replace("__KANATA_CONFIG__", sys.argv[4])
if "__KANATA_" in rendered:
    raise SystemExit("unexpanded Kanata plist placeholder")
Path(sys.argv[2]).write_text(rendered, encoding="utf-8")
PY

sudo install -o root -g wheel -m 0644   "$source_dir/org.pqrs.Karabiner-VirtualHIDDevice-Daemon.plist"   "$driver_plist"
sudo install -o root -g wheel -m 0644 "$tmp_plist" "$kanata_plist"

sudo /bin/launchctl bootout "system/$driver_label" >/dev/null 2>&1 || true
sudo /bin/launchctl bootstrap system "$driver_plist"

sudo /bin/launchctl bootout "system/$kanata_label" >/dev/null 2>&1 || true
sudo /bin/launchctl bootstrap system "$kanata_plist"

printf 'Installed persistent macOS keyboard services.\n'
printf '  Kanata: %s\n' "$kanata_bin"
printf '  Config: %s @ %s\n' "$config_path" "$config_ref"
printf '  Layout: %s\n' "$layout_path"
printf '  DriverKit: %s\n' "$driver_version"
printf '\n'
printf 'The exact Kanata binary above must remain enabled in both:\n'
printf '  System Settings > Privacy & Security > Accessibility\n'
printf '  System Settings > Privacy & Security > Input Monitoring\n'
printf 'Then rerun this installer or kickstart system/%s.\n' "$kanata_label"
printf '\n'
printf 'Open the keyboard cheat sheet with:\n'
printf '  open "%s"\n' "$layout_path"
