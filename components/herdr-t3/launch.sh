#!/usr/bin/env bash
# Launch the stable herdr-t3 app (macOS).
#
# Idempotent: `open` activates the already-running app. The app is a normal
# macOS bundle in ~/Applications — Finder, Spotlight, `open -a herdr-t3`,
# the Dock and this script all reach the same installed copy. No bridge,
# port or browser is involved.
set -euo pipefail

STATE_DIR="${HERDR_T3_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/herdr-t3}"
APPS_DIR="${HERDR_T3_APPS_DIR:-$HOME/Applications}"
CURRENT_FILE="$STATE_DIR/current"
APP_FILE="$STATE_DIR/current_app"
BUNDLE_ID="com.github.rebuildup.herdr-t3"

log() { printf '[herdr-t3] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ -f "$CURRENT_FILE" ]] || die "no install found ($CURRENT_FILE missing); run install.sh first"
name="$(cat "$CURRENT_FILE")"
app="$APPS_DIR/herdr-t3.app"
if [[ -f "$APP_FILE" ]]; then
  recorded="$(cat "$APP_FILE")"
  [[ -d "$recorded" ]] && app="$recorded"
fi
[[ -d "$app" ]] || die "installed app missing: $app (run install.sh)"
[[ -x "$app/Contents/MacOS/herdr-t3" ]] || die "app executable missing: $app"

# Prefer the recorded installed path; fall back to Launch Services lookup.
if [[ -f "$APP_FILE" && -d "$(cat "$APP_FILE")" ]]; then
  open "$(cat "$APP_FILE")"
else
  open -a "$BUNDLE_ID" 2>/dev/null || open "$app"
fi
log "launched $name ($app)"
