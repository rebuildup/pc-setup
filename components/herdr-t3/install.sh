#!/usr/bin/env bash
# herdr-t3 stable install — native Electron app (macOS).
#
# Builds a verified release of rebuildup/herdr-t3 into the managed state
# dir, then stages the resulting .app into ~/Applications so it behaves
# like a normal macOS app: Finder, Spotlight, Launch Services, Dock.
# `current`/`previous` pointers and per-ref release dirs are unchanged;
# rollback re-stages the previous .app. A failed install or update never
# disturbs the installed stable app.
#
# Usage: install.sh [ref]
#   ref: a v* tag or a full commit SHA (default: newest v* tag on origin).
set -euo pipefail

REPO_URL="https://github.com/rebuildup/herdr-t3.git"
BUNDLE_ID="com.github.rebuildup.herdr-t3"
STATE_DIR="${HERDR_T3_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/herdr-t3}"
APPS_DIR="${HERDR_T3_APPS_DIR:-$HOME/Applications}"
RELEASES_DIR="$STATE_DIR/releases"
CURRENT_FILE="$STATE_DIR/current"
APP_FILE="$STATE_DIR/current_app"
INSTALLED_FILE="$STATE_DIR/installed"
LOG_DIR="$STATE_DIR/logs"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
mkdir -p "$RELEASES_DIR" "$LOG_DIR" "$APPS_DIR"

log() { printf '[herdr-t3] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

bundle_id_of() { # $1 = .app path -> prints CFBundleIdentifier or nothing
  /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true
}

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

# Stage a built .app into the standard apps dir. Refuses to overwrite an
# unrelated app; quits a running herdr-t3 first so the swap is clean.
stage_app() { # $1 = source .app, $2 = destination .app
  local src="$1" dst="$2"
  [[ -d "$src" ]] || die "source app missing: $src"
  if [[ -e "$dst" ]]; then
    local existing_id
    existing_id="$(bundle_id_of "$dst")"
    [[ "$existing_id" == "$BUNDLE_ID" ]] \
      || die "refusing to overwrite unrelated app at $dst (bundle id: ${existing_id:-unknown})"
    if pgrep -f "$dst/Contents/MacOS/herdr-t3" >/dev/null 2>&1; then
      log "quitting running herdr-t3 before replacing $dst"
      osascript -e 'tell application id "com.github.rebuildup.herdr-t3" to quit' >/dev/null 2>&1 || true
      for _ in $(seq 1 25); do
        pgrep -f "$dst/Contents/MacOS/herdr-t3" >/dev/null 2>&1 || break
        sleep 0.2
      done
      pgrep -f "$dst/Contents/MacOS/herdr-t3" >/dev/null 2>&1 \
        && die "herdr-t3 is still running; quit it and retry"
    fi
    rm -rf "$dst"
  fi
  ditto "$src" "$dst"
  [[ -x "$dst/Contents/MacOS/herdr-t3" ]] || die "staged app has no executable: $dst"
  # Register with Launch Services so Finder/Spotlight/`open -a` resolve it,
  # and unregister the build artifact so it can never win resolution.
  [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$dst" >/dev/null 2>&1 || true
  [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -u "$src" >/dev/null 2>&1 || true
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

(cd "$target" \
  && mise install --locked >/dev/null \
  && bun install --frozen-lockfile \
  && CSC_IDENTITY_AUTO_DISCOVERY=false bun run desktop:pack) \
  || die "build failed for $name; installed app left untouched"

built="$(find "$target/release" -maxdepth 2 -name 'herdr-t3.app' -type d 2>/dev/null | head -1)"
[[ -n "$built" ]] || die "no herdr-t3.app built under $target/release"
[[ "$(bundle_id_of "$built")" == "$BUNDLE_ID" ]] \
  || die "built app has unexpected bundle id: $(bundle_id_of "$built")"

dst="$APPS_DIR/herdr-t3.app"
stage_app "$built" "$dst"

printf '%s\n' "$name" > "$CURRENT_FILE"
printf '%s\n' "$dst" > "$APP_FILE"
printf '%s\n%s\n' "$name" "$commit" > "$INSTALLED_FILE"
log "installed $name ($commit) -> $dst"
