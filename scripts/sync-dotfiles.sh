#!/usr/bin/env bash
set -euo pipefail

repo_url="${DOTFILES_REPO_URL:-https://github.com/rebuildup/dotfiles.git}"
repo_ref="${DOTFILES_REF:-main}"
target_dir="${DOTFILES_DIR:-$HOME/.dotfiles}"

if [[ ! -e "$target_dir" ]]; then
  printf 'cloning dotfiles (%s) -> %s\n' "$repo_ref" "$target_dir"
  mkdir -p "$(dirname "$target_dir")"
  git clone --branch "$repo_ref" --single-branch "$repo_url" "$target_dir"
  exit 0
fi

if [[ ! -d "$target_dir/.git" ]]; then
  printf 'refusing to overwrite non-git dotfiles path: %s\n' "$target_dir" >&2
  exit 1
fi

current_origin="$(git -C "$target_dir" remote get-url origin 2>/dev/null || true)"
if [[ "$current_origin" != "$repo_url" ]]; then
  printf 'existing dotfiles checkout has unexpected origin: %s\n' "$current_origin" >&2
  exit 1
fi

if [[ -n "$(git -C "$target_dir" status --porcelain)" ]]; then
  printf 'existing dotfiles checkout has local changes; refusing automatic update: %s\n' "$target_dir" >&2
  git -C "$target_dir" status --short >&2
  exit 1
fi

printf 'updating existing dotfiles checkout to %s\n' "$repo_ref"

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

if [[ ! -x "$target_dir/script/bootstrap" ]]; then
  printf 'dotfiles bootstrap is unavailable after sync: %s\n' "$target_dir/script/bootstrap" >&2
  exit 1
fi
