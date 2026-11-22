#!/usr/bin/env bash
# herdr-t3 stable install (macOS / POSIX).
#
# Installs a verified release of rebuildup/herdr-t3 into the managed state
# dir as an independent per-ref checkout, builds it once, and only then
# flips the `current` pointer. A failed install or update never disturbs
# the release that is currently selected.
#
# Usage: install.sh [ref]
#   ref: a v* tag or a full commit SHA (default: newest v* tag on origin).
#   Dev branches and unreleased release-candidate branches are never
#   selected implicitly.
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
  # Only tags and full SHAs are acceptable install targets.
  if [[ "$ref" =~ ^v[0-9] ]]; then
    git ls-remote --exit-code --tags "$REPO_URL" "refs/tags/$ref" >/dev/null \
      || die "tag $ref not found on $REPO_URL"
  elif [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    die "ref must be a v* tag or a full 40-char SHA (got: $ref)"
  fi
  printf '%s' "$ref"
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

(cd "$target" && mise install --locked >/dev/null && bun install --frozen-lockfile && bun run build) \
  || die "build failed for $name; current selection left untouched"

# Point `current` at the new release only after a successful build.
printf '%s\n' "$name" > "$CURRENT_FILE"
log "installed $name ($commit); current -> $name"
