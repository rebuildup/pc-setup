#!/usr/bin/env bash
# Roll back the stable herdr-t3 app to the previously selected release.
# Flips the pointers AND re-stages the previous .app into ~/Applications,
# so the next launch (Finder/Spotlight/Dock/open -a) runs the old build.
set -euo pipefail

BUNDLE_ID="com.github.rebuildup.herdr-t3"
STATE_DIR="${HERDR_T3_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/herdr-t3}"
APPS_DIR="${HERDR_T3_APPS_DIR:-$HOME/Applications}"
CURRENT_FILE="$STATE_DIR/current"
PREV_FILE="$STATE_DIR/previous"
APP_FILE="$STATE_DIR/current_app"
INSTALLED_FILE="$STATE_DIR/installed"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

log() { printf '[herdr-t3] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ -f "$PREV_FILE" ]] || die "no previous release recorded"
prev="$(cat "$PREV_FILE")"
built="$(find "$STATE_DIR/releases/$prev/release" -maxdepth 2 -name 'herdr-t3.app' -type d 2>/dev/null | head -1)"
[[ -n "$built" ]] || die "previous release $prev has no built .app"

dst="$APPS_DIR/herdr-t3.app"
if [[ -e "$dst" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$dst/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$existing_id" == "$BUNDLE_ID" ]] || die "refusing to overwrite unrelated app at $dst"
  if pgrep -f "$dst/Contents/MacOS/herdr-t3" >/dev/null 2>&1; then
    log "quitting running herdr-t3 before rollback"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 25); do
      pgrep -f "$dst/Contents/MacOS/herdr-t3" >/dev/null 2>&1 || break
      sleep 0.2
    done
    if pgrep -f "$dst/Contents/MacOS/herdr-t3" >/dev/null 2>&1; then
      pkill -f "$dst/Contents/MacOS/herdr-t3" || true
      for _ in $(seq 1 25); do
        pgrep -f "$dst/Contents/MacOS/herdr-t3" >/dev/null 2>&1 || break
        sleep 0.2
      done
    fi
    pgrep -f "$dst/Contents/MacOS/herdr-t3" >/dev/null 2>&1 && die "herdr-t3 still running; quit and retry"
  fi
fi
# Stage beside the destination and swap only after the copy verifies, so a
# failed ditto never leaves ~/Applications without the app.
staging="$dst.staging-$$"
rm -rf "$staging"
ditto "$built" "$staging" || { rm -rf "$staging"; die "ditto failed staging $built"; }
[[ -x "$staging/Contents/MacOS/herdr-t3" ]] || { rm -rf "$staging"; die "staged app has no executable: $staging"; }
rm -rf "$dst"
mv "$staging" "$dst"
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$dst" >/dev/null 2>&1 || true
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -u "$built" >/dev/null 2>&1 || true

commit="$(git -C "$STATE_DIR/releases/$prev" rev-parse HEAD)"
printf '%s\n' "$prev" > "$CURRENT_FILE"
printf '%s\n' "$dst" > "$APP_FILE"
printf '%s\n%s\n' "$prev" "$commit" > "$INSTALLED_FILE"
log "rolled back to $prev ($commit) -> $dst; relaunch the app to apply"
