#!/usr/bin/env bash
# Roll back the stable herdr-t3 app to the previously selected release.
# The old release dir is kept by update.sh, so rollback is a pointer flip —
# no rebuild. Quit and relaunch the app to run the rolled-back build.
set -euo pipefail

STATE_DIR="${HERDR_T3_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/herdr-t3}"
CURRENT_FILE="$STATE_DIR/current"
PREV_FILE="$STATE_DIR/previous"
APP_FILE="$STATE_DIR/current_app"

[[ -f "$PREV_FILE" ]] || { echo "[herdr-t3] no previous release recorded" >&2; exit 1; }
prev="$(cat "$PREV_FILE")"
prev_app="$(find "$STATE_DIR/releases/$prev/release" -maxdepth 2 -name 'herdr-t3.app' -type d 2>/dev/null | head -1)"
[[ -n "$prev_app" ]] || { echo "[herdr-t3] previous release $prev has no built .app" >&2; exit 1; }
printf '%s\n' "$prev" > "$CURRENT_FILE"
printf '%s\n' "$prev_app" > "$APP_FILE"
echo "[herdr-t3] rolled back to $prev ($prev_app); relaunch the app to apply"
