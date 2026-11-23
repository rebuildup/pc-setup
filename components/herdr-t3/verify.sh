#!/usr/bin/env bash
# Verify the stable herdr-t3 install (macOS).
#
# Checks: installed app in ~/Applications, bundle id, recorded release
# commit vs the release checkout, the actual launch target, Launch
# Services / Spotlight discovery, and with --live the running process.
set -euo pipefail

BUNDLE_ID="com.github.rebuildup.herdr-t3"
STATE_DIR="${HERDR_T3_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/herdr-t3}"
APPS_DIR="${HERDR_T3_APPS_DIR:-$HOME/Applications}"
CURRENT_FILE="$STATE_DIR/current"
APP_FILE="$STATE_DIR/current_app"
INSTALLED_FILE="$STATE_DIR/installed"
LIVE=0; [[ "${1:-}" == "--live" ]] && LIVE=1

fail() { echo "[herdr-t3] FAIL: $*" >&2; exit 1; }

[[ -f "$CURRENT_FILE" ]] || fail "not installed ($CURRENT_FILE missing)"
name="$(cat "$CURRENT_FILE")"
release="$STATE_DIR/releases/$name"
[[ -d "$release/.git" ]] || fail "release dir missing: $release"

app="$APPS_DIR/herdr-t3.app"
[[ -f "$APP_FILE" ]] && [[ -d "$(cat "$APP_FILE")" ]] && app="$(cat "$APP_FILE")"
[[ -d "$app" ]] || fail "installed app missing: $app"
[[ -x "$app/Contents/MacOS/herdr-t3" ]] || fail "app executable missing: $app"
bid="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
[[ "$bid" == "$BUNDLE_ID" ]] || fail "bundle id mismatch: ${bid:-none} != $BUNDLE_ID"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo unknown)"

commit="$(git -C "$release" rev-parse HEAD)"
if [[ -f "$INSTALLED_FILE" ]]; then
  recorded_commit="$(sed -n 2p "$INSTALLED_FILE")"
  [[ "$recorded_commit" == "$commit" ]] || fail "installed commit $recorded_commit != release HEAD $commit"
fi
echo "[herdr-t3] installed: $name @ ${commit:0:12} -> $app (v$version, $bid)"

# Launch Services / Spotlight discovery (not just file existence).
mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | grep -Fqx "$app" \
  || fail "Spotlight/Launch Services does not resolve $BUNDLE_ID to $app"
echo "[herdr-t3] launch services: $app"

if [[ "$LIVE" == "1" ]]; then
  # Layer 1: the installed app process is actually running.
  pgrep -f "$app/Contents/MacOS/herdr-t3" >/dev/null \
    || fail "app is not running (run launch.sh)"
  echo "[herdr-t3] live: app process running ($app)"
  # Layer 2: the herdr endpoint the app will use exists.
  sock="${HERDR_SOCKET:-$HOME/.config/herdr/herdr.sock}"
  [[ -S "$sock" ]] || fail "herdr socket not present: $sock (is herdr running?)"
  echo "[herdr-t3] live: herdr socket present: $sock"
  # Layer 3: the running app's Main process reports a live herdr snapshot
  # via <userData>/bridge-status.json — proof the GUI bridge reached herdr,
  # not just that a process and a socket exist.
  status="$HOME/Library/Application Support/herdr-t3/bridge-status.json"
  [[ -f "$status" ]] || fail "no bridge-status.json at $status (app too old or never connected)"
  python3 - "$status" <<'PYEOF' || fail "bridge-status.json reports failure or is stale: $(cat "$status" 2>/dev/null)"
import json, sys, time, calendar
d = json.load(open(sys.argv[1]))
age = time.time() - calendar.timegm(time.strptime(d["at"][:19], "%Y-%m-%dT%H:%M:%S"))
assert d.get("ok") is True, d.get("detail")
assert age < 300, f"status is {int(age)}s old"
print(f"[herdr-t3] live: bridge reports '{d['detail']}' via {d['herdr']}")
PYEOF
fi
