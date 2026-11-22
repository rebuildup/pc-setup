#!/usr/bin/env bash
# herdr-t3 stable install — native Electron app (macOS).
#
# Installs a verified release of rebuildup/herdr-t3 into the managed state
# dir as an independent per-ref checkout, builds the .app once with
# electron-builder, and only then flips the `current` pointer. A failed
# install or update never disturbs the app that is currently selected.
#
# Usage: install.sh [ref]
#   ref: a v* tag or a full commit SHA (default: newest v* tag on origin).
set -euo pipefail

REPO_URL="https://github.com/rebuildup/herdr-t3.git"
STATE_DIR="${HERDR_T3_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/herdr-t3}"
RELEASES_DIR="$STATE_DIR/releases"
CURRENT_FILE="$STATE_DIR/current"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$RELEASES_DIR" "$LOG_DIR"

log() { printf '[herdr-t3] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

resolve_ref() {
  local ref="${1:-}"
  if [[ -z "$ref" ]]; then
    ref="$(git ls-remote --tags "$REPO_URL" 'refs/tags/v*' \
      | awk -F/ '{print $3}' | grep -v '\^' | sort -V | tail -1)"
    [[ -n "$ref" ]] || die "no v* tag found on $REPO_URL"
  fi
  if [[ "$ref" =~ ^v[0-9] ]]; then
    git ls-remote --exit-code --tags "$REPO_URL" "refs/tags/$ref" >/dev/null \
      || die "tag $ref not found on $REPO_URL"
  elif [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    die "ref must be a v* tag or a full 40-char SHA (got: $ref)"
  fi
  printf '%s' "$ref"
}

app_path() { # $1 = release dir -> prints the built .app path
  local rel="$1"
  local app
  app="$(find "$rel/release" -maxdepth 2 -name 'herdr-t3.app' -type d 2>/dev/null | head -1)"
  [[ -n "$app" ]] || die "no herdr-t3.app built under $rel/release"
  printf '%s' "$app"
}

ref="$(resolve_ref "${1:-}")"
name="$(printf '%s' "$ref" | tr '/:' '__')"
target="$RELEASES_DIR/$name"

if [[ ! -d "$target/.git" ]]; then
  log "cloning $ref into $target"
  git clone --quiet "$REPO_URL" "$target"
else
  git -C "$target" fetch --quiet --tags origin
fi

git -C "$target" checkout --quiet "$ref"
commit="$(git -C "$target" rev-parse HEAD)"
log "building $name ($commit)"

# Build at install time only; launch never rebuilds. electron-builder
# produces an unsigned .app (dir target) — Gatekeeper quarantine does not
# apply to locally built apps.
(cd "$target" \
  && mise install --locked >/dev/null \
  && bun install --frozen-lockfile \
  && CSC_IDENTITY_AUTO_DISCOVERY=false bun run desktop:pack) \
  || die "build failed for $name; current selection left untouched"

app="$(app_path "$target")"
[[ -x "$app/Contents/MacOS/herdr-t3" ]] || die "built app missing executable: $app"

printf '%s\n' "$name" > "$CURRENT_FILE"
printf '%s\n' "$app" > "$STATE_DIR/current_app"
log "installed $name ($commit); current -> $name ($app)"
