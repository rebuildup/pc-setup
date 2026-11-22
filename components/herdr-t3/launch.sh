#!/usr/bin/env bash
# Launch the stable herdr-t3 desktop app (macOS).
#
# Idempotent: `open` activates the already-running app instead of starting a
# second instance. No bridge, port or browser is involved — the app embeds
# the bridge in its Main process and connects to herdr directly.
set -euo pipefail

STATE_DIR="${HERDR_T3_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/herdr-t3}"
CURRENT_FILE="$STATE_DIR/current"
APP_FILE="$STATE_DIR/current_app"

log() { printf '[herdr-t3] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ -f "$CURRENT_FILE" ]] || die "no install found ($CURRENT_FILE missing); run install.sh first"
name="$(cat "$CURRENT_FILE")"
release="$STATE_DIR/releases/$name"
app=""
if [[ -f "$APP_FILE" ]]; then app="$(cat "$APP_FILE")"; fi
if [[ -z "$app" || ! -d "$app" ]]; then
  app="$(find "$release/release" -maxdepth 2 -name 'herdr-t3.app' -type d 2>/dev/null | head -1)"
fi
[[ -n "$app" && -d "$app" ]] || die "release $name has no built .app; reinstall"
[[ -x "$app/Contents/MacOS/herdr-t3" ]] || die "app executable missing: $app"

open "$app"
log "launched $name ($app)"
