#!/usr/bin/env bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-/srv/devnode-headscale}"
marker='pc-setup:devnode-headscale:v1'
fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ "$target" = /* && "$target" != / && "$target" != */../* && "$target" != */.. ]] || fail 'Use an absolute dedicated path without ..'
# Reject symlinks in every path component, including a dangling final link.
probe="$target"
while [[ "$probe" != / ]]; do
  [[ ! -L "$probe" ]] || fail "Refusing symlink: $probe"
  probe="$(dirname -- "$probe")"
done
if [[ -e "$target" ]]; then
  [[ -d "$target" && -f "$target/.pc-setup-owned" && ! -L "$target/.pc-setup-owned" ]] || fail 'Foreign directory; refusing adoption'
  [[ "$(cat "$target/.pc-setup-owned")" = "$marker" ]] || fail 'Foreign ownership marker'
  for file in compose.yaml config.yaml policy.json; do
    [[ -f "$target/$file" && ! -L "$target/$file" ]] || fail "Missing or foreign file: $file"
    cmp -s "$source_dir/$file" "$target/$file" || fail "Changed file: $file (review upgrade manually)"
  done
  printf 'Already prepared: %s\n' "$target"
  exit 0
fi
umask 077
# mkdir fails rather than adopting a directory created concurrently.
mkdir -- "$target"
printf '%s\n' "$marker" > "$target/.pc-setup-owned"
for file in compose.yaml config.yaml policy.json; do
  cp "$source_dir/$file" "$target/$file"
  chmod 600 "$target/$file"
done
printf 'Prepared: %s\n' "$target"
