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

export MISE_HTTP_TIMEOUT="${MISE_HTTP_TIMEOUT:-120s}"
export MISE_HTTP_RETRIES="${MISE_HTTP_RETRIES:-5}"

install_attempts="${PC_SETUP_MISE_INSTALL_ATTEMPTS:-2}"
retry_delay_seconds="${PC_SETUP_MISE_RETRY_DELAY_SECONDS:-5}"

if ! [[ "$install_attempts" =~ ^[1-9][0-9]*$ ]]; then
  printf 'PC_SETUP_MISE_INSTALL_ATTEMPTS must be a positive integer: %s\n' "$install_attempts" >&2
  exit 2
fi

last_status=1
for ((attempt = 1; attempt <= install_attempts; attempt++)); do
  if mise -C "$HOME" install; then
    exit 0
  else
    last_status=$?
  fi

  if ((attempt == install_attempts)); then
    break
  fi

  printf 'mise install failed (attempt %d/%d, exit %d); retrying in %ss with existing install state\n' \
    "$attempt" "$install_attempts" "$last_status" "$retry_delay_seconds" >&2
  sleep "$retry_delay_seconds"
done

printf 'mise install failed after %d attempt(s)\n' "$install_attempts" >&2
exit "$last_status"
