#!/usr/bin/env bash
# Verify the stable herdr-t3 install (macOS).
#
# Checks: current release + built .app exist, the app binary is present,
# and with --live the app process is running and the herdr socket exists.
set -euo pipefail

STATE_DIR="${HERDR_T3_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/herdr-t3}"
CURRENT_FILE="$STATE_DIR/current"
APP_FILE="$STATE_DIR/current_app"
LIVE=0; [[ "${1:-}" == "--live" ]] && LIVE=1

fail() { echo "[herdr-t3] FAIL: $*" >&2; exit 1; }

[[ -f "$CURRENT_FILE" ]] || fail "not installed ($CURRENT_FILE missing)"
name="$(cat "$CURRENT_FILE")"
release="$STATE_DIR/releases/$name"
[[ -d "$release/.git" ]] || fail "release dir missing: $release"
app=""
[[ -f "$APP_FILE" ]] && app="$(cat "$APP_FILE")"
[[ -n "$app" && -d "$app" ]] || app="$(find "$release/release" -maxdepth 2 -name 'herdr-t3.app' -type d 2>/dev/null | head -1)"
[[ -n "$app" ]] || fail "no herdr-t3.app built for $name"
[[ -x "$app/Contents/MacOS/herdr-t3" ]] || fail "app executable missing: $app"
commit="$(git -C "$release" rev-parse HEAD)"
echo "[herdr-t3] installed: $name @ ${commit:0:12} -> $app"

if [[ "$LIVE" == "1" ]]; then
  pgrep -f "$app/Contents/MacOS/herdr-t3" >/dev/null \
    || fail "app is not running (run launch.sh)"
  sock="${HERDR_SOCKET:-$HOME/.config/herdr/herdr.sock}"
  [[ -S "$sock" ]] || fail "herdr socket not present: $sock (is herdr running?)"
  echo "[herdr-t3] live: app running, herdr socket present: $sock"
fi
