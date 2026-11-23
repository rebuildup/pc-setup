#!/usr/bin/env bash
# Update the stable herdr-t3 install.
#
# Resolves the newest v* tag (or an explicit ref), installs it via
# install.sh into its own release dir, and flips `current` only after the
# build succeeds. The previously selected release stays on disk, so
# rollback.sh can restore it without a rebuild. A failed update leaves the
# running/selected stable version untouched.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${HERDR_T3_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/herdr-t3}"
CURRENT_FILE="$STATE_DIR/current"

if [[ -f "$CURRENT_FILE" ]]; then
  prev="$(cat "$CURRENT_FILE")"
  prev_commit="$(git -C "$STATE_DIR/releases/$prev" rev-parse HEAD 2>/dev/null || echo unknown)"
else
  prev=""; prev_commit=""
fi

"$HERE/install.sh" "${1:-}"

# Record the superseded release for rollback (only after a successful switch).
if [[ -n "$prev" && -f "$CURRENT_FILE" ]]; then
  cur="$(cat "$CURRENT_FILE")"
  if [[ "$cur" != "$prev" ]]; then
    printf '%s\n' "$prev" > "$STATE_DIR/previous"
    printf 'previous=%s (%s)\ncurrent=%s\n' "$prev" "$prev_commit" "$cur"
  fi
fi
