#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_config="$repo_root/mise.global.toml"
target_config="${MISE_GLOBAL_CONFIG_FILE:-$HOME/.config/mise/config.toml}"
managed_marker="# Managed by rebuildup/pc-setup."

if [[ ! -f "$source_config" ]]; then
  printf 'missing global mise source: %s\n' "$source_config" >&2
  exit 1
fi

mkdir -p "$(dirname "$target_config")"

if [[ -L "$target_config" ]]; then
  rm "$target_config"
elif [[ -e "$target_config" ]]; then
  if ! head -n 1 "$target_config" | grep -Fxq "$managed_marker"; then
    printf 'refusing to overwrite unmanaged mise global config: %s\n' "$target_config" >&2
    exit 1
  fi
  rm "$target_config"
fi

ln -s "$source_config" "$target_config"
printf 'linked  %s -> %s\n' "$target_config" "$source_config"

mise -C "$HOME" install
