#!/usr/bin/env bash
set -euo pipefail

# Install the Rex macOS app (https://www.superlogical.com/rex).
#
# Rex has no Homebrew cask or pkg installer during the beta; the official
# distribution is a notarized DMG. The preview channel's latest.dmg alias is
# the public download URL used by testers. The installer downloads the DMG,
# mounts it read-only at a private mountpoint, and copies the app bundle. It
# re-runs cleanly: when the installed bundle already carries the same version
# and build, the copy is skipped. See docs/adr/ADR-0026.md.

dmg_url="https://blob.superlogical.com/download/rex-app/preview/latest.dmg"

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'WARN  %s\n' "$*" >&2
}

fail() {
  printf 'FAIL  %s\n' "$*" >&2
  exit 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Rex app install is macOS-only; skipping.\n'
  exit 0
fi

bundle_value() {
  # bundle_value <app path> <Info.plist key>; prints nothing when absent.
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true
}

installed_app=""
for candidate in /Applications/Rex*.app "$HOME/Applications/Rex"*.app; do
  if [[ -d "$candidate" ]]; then
    installed_app="$candidate"
    break
  fi
done

work_dir="$(mktemp -d)"
mount_point="$work_dir/mnt"
mkdir -p "$mount_point"
cleanup() {
  hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

log "Downloading Rex preview DMG"
curl -fL --retry 3 -o "$work_dir/Rex.dmg" "$dmg_url"

log "Mounting DMG"
if ! hdiutil attach -nobrowse -readonly -mountpoint "$mount_point" "$work_dir/Rex.dmg" >/dev/null; then
  fail "could not mount $work_dir/Rex.dmg"
fi

source_app=""
for candidate in "$mount_point"/Rex*.app; do
  if [[ -d "$candidate" ]]; then
    source_app="$candidate"
    break
  fi
done

if [[ -z "$source_app" ]]; then
  fail "no Rex*.app found in the mounted DMG"
fi

source_version="$(bundle_value "$source_app" CFBundleShortVersionString)"
source_build="$(bundle_value "$source_app" CFBundleVersion)"

if [[ -n "$installed_app" ]]; then
  installed_version="$(bundle_value "$installed_app" CFBundleShortVersionString)"
  installed_build="$(bundle_value "$installed_app" CFBundleVersion)"
  if [[ -n "$source_version" && "$installed_version" == "$source_version" && "$installed_build" == "$source_build" ]]; then
    printf 'ok      Rex %s (%s) already installed at %s\n' \
      "$installed_version" "$installed_build" "$installed_app"
    exit 0
  fi
  printf 'updating Rex %s (%s) -> %s (%s)\n' \
    "${installed_version:-unknown}" "${installed_build:-unknown}" \
    "${source_version:-unknown}" "${source_build:-unknown}"
fi

# Prefer /Applications (the conventional location, writable by admin users
# without sudo); fall back to a per-user Applications folder.
target_dir="/Applications"
if [[ ! -w "$target_dir" ]]; then
  target_dir="$HOME/Applications"
  mkdir -p "$target_dir"
fi

target_app="$target_dir/$(basename "$source_app")"

# A bundle already at the target may live in the other Applications folder;
# remove stale copies so only the managed location remains.
for stale in /Applications/Rex*.app "$HOME/Applications/Rex"*.app; do
  if [[ -d "$stale" && "$stale" != "$target_app" ]]; then
    warn "removing stale Rex app copy: $stale"
    rm -rf "$stale"
  fi
done

log "Installing Rex to $target_app"
if [[ -d "$target_app" ]]; then
  rm -rf "$target_app"
fi
ditto "$source_app" "$target_app"

# Sanity check: warn when the bundle does not contain this Mac's architecture.
main_executable="$(bundle_value "$target_app" CFBundleExecutable)"
if [[ -n "$main_executable" && -f "$target_app/Contents/MacOS/$main_executable" ]]; then
  if ! lipo -info "$target_app/Contents/MacOS/$main_executable" 2>/dev/null | grep -q "$(uname -m)"; then
    warn "installed Rex executable may not support $(uname -m); check: lipo -info \"$target_app/Contents/MacOS/$main_executable\""
  fi
fi

printf 'ok      Rex %s (%s) installed at %s\n' \
  "${source_version:-unknown}" "${source_build:-unknown}" "$target_app"
printf 'note    launch Rex once, then run "rex skill setup" inside it to install agent skills\n'
