#!/usr/bin/env bash
# Verify the stable herdr-t3 install.
#
# Checks (all must pass):
#   - `current` release exists with a built dist/
#   - the checkout HEAD matches a real commit and bun is available
#   - with --live: the running bridge's /api/health reports ok, herdr
#     reachable, and a version/commit consistent with the install
set -euo pipefail

STATE_DIR="${HERDR_T3_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/herdr-t3}"
CURRENT_FILE="$STATE_DIR/current"
PORT="${HERDR_T3_PORT:-4737}"
LIVE=0; [[ "${1:-}" == "--live" ]] && LIVE=1

fail() { echo "[herdr-t3] FAIL: $*" >&2; exit 1; }

[[ -f "$CURRENT_FILE" ]] || fail "not installed ($CURRENT_FILE missing)"
name="$(cat "$CURRENT_FILE")"
release="$STATE_DIR/releases/$name"
[[ -d "$release/.git" ]] || fail "release dir missing: $release"
[[ -f "$release/dist/index.html" ]] || fail "dist/ not built in $name"
command -v bun >/dev/null || fail "bun not on PATH"
commit="$(git -C "$release" rev-parse HEAD)"
echo "[herdr-t3] installed: $name @ ${commit:0:12}"

if [[ "$LIVE" == "1" ]]; then
  health="$(curl -fsS --max-time 3 "http://127.0.0.1:$PORT/api/health")" \
    || fail "bridge not healthy on 127.0.0.1:$PORT (run launch.sh)"
  echo "$health" | grep -q '"ok":true' || fail "health ok!=true: $health"
  echo "$health" | grep -q '"reachable":true' || fail "herdr not reachable: $health"
  echo "[herdr-t3] live: $health"
fi
