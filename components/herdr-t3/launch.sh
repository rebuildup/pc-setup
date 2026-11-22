#!/usr/bin/env bash
# Launch the stable herdr-t3 bridge and open the GUI.
#
# Idempotent: if /api/health already answers on 127.0.0.1:4737 the bridge is
# left alone and the browser just opens. Otherwise the bridge is started
# detached from the `current` release; a port already owned by something
# else is reported instead of being hijacked.
set -euo pipefail

STATE_DIR="${HERDR_T3_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/herdr-t3}"
CURRENT_FILE="$STATE_DIR/current"
PORT="${HERDR_T3_PORT:-4737}"
URL="http://127.0.0.1:$PORT/"
HEALTH="http://127.0.0.1:$PORT/api/health"

log() { printf '[herdr-t3] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

healthy() { curl -fsS --max-time 2 "$HEALTH" >/dev/null 2>&1; }

if healthy; then
  log "bridge already healthy on $URL"
else
  [[ -f "$CURRENT_FILE" ]] || die "no install found ($CURRENT_FILE missing); run install.sh first"
  name="$(cat "$CURRENT_FILE")"
  release="$STATE_DIR/releases/$name"
  [[ -f "$release/dist/index.html" ]] || die "release $name has no built dist/; reinstall"
  command -v bun >/dev/null || die "bun not on PATH (mise install --locked in the release dir first)"

  # Refuse to start if the port is owned by a process that is not our bridge.
  if command -v lsof >/dev/null && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "port $PORT is already listening but /api/health did not answer; not hijacking it"
  fi

  mkdir -p "$STATE_DIR/run" "$STATE_DIR/logs"
  log "starting bridge from $name on $URL"
  (cd "$release" && PORT="$PORT" HOST=127.0.0.1 nohup bun run server \
      >>"$STATE_DIR/logs/bridge.log" 2>&1 & echo $! > "$STATE_DIR/run/bridge.pid")

  for _ in $(seq 1 50); do
    healthy && break
    sleep 0.2
  done
  healthy || die "bridge did not become healthy; see $STATE_DIR/logs/bridge.log"
fi

if command -v open >/dev/null; then
  open "$URL"
else
  log "open $URL in your browser"
fi
