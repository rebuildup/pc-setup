#!/usr/bin/env bash
# Roll back the stable herdr-t3 install to the previously selected release.
# The old release dir is kept by update.sh, so rollback is a pointer flip —
# no rebuild, and the running bridge is unaffected until relaunched.
set -euo pipefail

STATE_DIR="${HERDR_T3_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/herdr-t3}"
CURRENT_FILE="$STATE_DIR/current"
PREV_FILE="$STATE_DIR/previous"

[[ -f "$PREV_FILE" ]] || { echo "[herdr-t3] no previous release recorded" >&2; exit 1; }
prev="$(cat "$PREV_FILE")"
[[ -f "$STATE_DIR/releases/$prev/dist/index.html" ]] \
  || { echo "[herdr-t3] previous release $prev is missing its build" >&2; exit 1; }
printf '%s\n' "$prev" > "$CURRENT_FILE"
echo "[herdr-t3] rolled back to $prev (restart the bridge to apply)"
