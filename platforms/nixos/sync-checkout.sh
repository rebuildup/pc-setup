#!/usr/bin/env bash
set -euo pipefail

repo_url="${1:?repository URL is required}"
repo_ref="${2:?repository ref is required}"
target_dir="${3:?target directory is required}"

if [[ ! -e "$target_dir" ]]; then
  printf 'cloning pc-setup (%s) -> %s\n' "$repo_ref" "$target_dir"
  mkdir -p "$(dirname "$target_dir")"
  git clone --branch "$repo_ref" --single-branch "$repo_url" "$target_dir"
  exit 0
fi

if [[ ! -d "$target_dir/.git" ]]; then
  printf 'refusing to overwrite non-git path: %s\n' "$target_dir" >&2
  exit 1
fi

current_origin="$(git -C "$target_dir" remote get-url origin)"
if [[ "$current_origin" != "$repo_url" ]]; then
  printf 'existing checkout has unexpected origin: %s\n' "$current_origin" >&2
  exit 1
fi

printf 'updating existing pc-setup checkout to %s\n' "$repo_ref"

remote_tracking_ref="refs/remotes/origin/$repo_ref"
fetch_refspec="+refs/heads/$repo_ref:$remote_tracking_ref"

if ! git -C "$target_dir" config --get-all remote.origin.fetch | grep -Fxq "$fetch_refspec"; then
  git -C "$target_dir" config --add remote.origin.fetch "$fetch_refspec"
fi

git -C "$target_dir" fetch origin "$fetch_refspec"

if git -C "$target_dir" show-ref --verify --quiet "refs/heads/$repo_ref"; then
  git -C "$target_dir" switch "$repo_ref"
else
  git -C "$target_dir" switch --track -c "$repo_ref" "origin/$repo_ref"
fi

git -C "$target_dir" merge --ff-only "origin/$repo_ref"
