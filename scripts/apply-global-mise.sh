#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_config="$repo_root/mise.global.toml"
source_lock="${PC_SETUP_MISE_SOURCE_LOCK_FILE:-$repo_root/mise.global.lock}"
target_config="${MISE_GLOBAL_CONFIG_FILE:-$HOME/.config/mise/config.toml}"
target_lock="${MISE_GLOBAL_LOCK_FILE:-${target_config%.toml}.lock}"
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

if [[ -f "$source_lock" ]]; then
  if [[ -L "$target_lock" ]]; then
    rm "$target_lock"
  elif [[ -e "$target_lock" ]]; then
    printf 'refusing to overwrite unmanaged mise global lock: %s\n' "$target_lock" >&2
    exit 1
  fi

  ln -s "$source_lock" "$target_lock"
  printf 'linked  %s -> %s\n' "$target_lock" "$source_lock"
elif [[ -L "$target_lock" && "$(readlink "$target_lock")" == "$source_lock" ]]; then
  rm "$target_lock"
  printf 'removed stale managed mise global lock link: %s\n' "$target_lock"
fi

export MISE_HTTP_TIMEOUT="${MISE_HTTP_TIMEOUT:-120s}"
export MISE_HTTP_RETRIES="${MISE_HTTP_RETRIES:-5}"

prepare_github_auth_for_mise() {
  if [[ -n "${MISE_GITHUB_TOKEN:-}" || -n "${GITHUB_API_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
    printf 'ok      mise GitHub authentication provided by environment\n'
    return
  fi

  # GitHub-backed tools may require authenticated API access for artifact
  # attestation verification. Install gh first so fresh machines can establish
  # authentication before the full mise install fan-out reaches github:* tools.
  mise -C "$HOME" install gh

  if ! mise -C "$HOME" exec gh -- gh auth status --hostname github.com >/dev/null 2>&1; then
    if [[ ! -t 0 && "${PC_SETUP_ALLOW_INTERACTIVE_AUTH:-0}" != "1" ]]; then
      printf 'GitHub authentication is required before installing GitHub-backed mise tools.\n' >&2
      printf 'Re-run interactively or set PC_SETUP_ALLOW_INTERACTIVE_AUTH=1.\n' >&2
      return 1
    fi

    local local_git_config="${PC_SETUP_GIT_LOCAL_CONFIG:-$HOME/.gitconfig.local}"
    mkdir -p "$(dirname "$local_git_config")"
    touch "$local_git_config"
    chmod 600 "$local_git_config"

    printf 'GitHub authentication is required before GitHub-backed tool installation.\n'
    GIT_CONFIG_GLOBAL="$local_git_config" \
      mise -C "$HOME" exec gh -- gh auth login --hostname github.com --git-protocol https --web
  fi

  local github_token
  github_token="$(mise -C "$HOME" exec gh -- gh auth token --hostname github.com)"
  if [[ -z "$github_token" ]]; then
    printf 'gh authentication succeeded but no GitHub token could be resolved for mise.\n' >&2
    return 1
  fi

  export MISE_GITHUB_TOKEN="$github_token"
  unset github_token
  printf 'ok      mise GitHub authentication prepared from gh\n'
}

prepare_github_auth_for_mise

install_attempts="${PC_SETUP_MISE_INSTALL_ATTEMPTS:-2}"
retry_delay_seconds="${PC_SETUP_MISE_RETRY_DELAY_SECONDS:-5}"

if ! [[ "$install_attempts" =~ ^[1-9][0-9]*$ ]]; then
  printf 'PC_SETUP_MISE_INSTALL_ATTEMPTS must be a positive integer: %s\n' "$install_attempts" >&2
  exit 2
fi

install_args=(install)
if [[ -f "$source_lock" ]]; then
  install_args+=(--locked)
  printf 'ok      using committed mise global lock\n'
fi

last_status=1
for ((attempt = 1; attempt <= install_attempts; attempt++)); do
  if mise -C "$HOME" "${install_args[@]}"; then
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
