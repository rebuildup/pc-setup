#!/usr/bin/env bash
set -euo pipefail

repo_url="${PC_SETUP_REPO_URL:-https://github.com/rebuildup/pc-setup.git}"
repo_ref="${PC_SETUP_REF:-main}"
target_dir="${PC_SETUP_DIR:-$HOME/src/pc-setup}"

log() {
  printf '\n==> %s\n' "$*"
}

install_git_if_needed() {
  if git --version >/dev/null 2>&1; then
    return
  fi

  case "$(uname -s)" in
    Linux)
      if [[ ! -r /etc/os-release ]]; then
        printf 'cannot detect Linux distribution; install Git manually and rerun\n' >&2
        exit 1
      fi

      # shellcheck disable=SC1091
      . /etc/os-release
      case "${ID:-}" in
        ubuntu|debian)
          log "Installing minimal bootstrap dependencies"
          sudo apt-get update
          sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git curl ca-certificates
          ;;
        *)
          printf 'unsupported Linux bootstrap distribution: %s\n' "${ID:-unknown}" >&2
          printf 'install Git and mise, then run: mise bootstrap --from %s\n' "$repo_url" >&2
          exit 1
          ;;
      esac
      ;;
    Darwin)
      log "Git requires Apple Command Line Tools"
      xcode-select --install >/dev/null 2>&1 || true
      printf 'finish the Command Line Tools installation, then rerun this command\n' >&2
      exit 1
      ;;
    *)
      printf 'bootstrap.sh supports Linux/macOS; use bootstrap.ps1 on Windows\n' >&2
      exit 1
      ;;
  esac
}

install_mise_if_needed() {
  if command -v mise >/dev/null 2>&1; then
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    printf 'curl is required to install mise\n' >&2
    exit 1
  fi

  local shell_name
  shell_name="$(basename "${SHELL:-/bin/bash}")"
  case "$shell_name" in
    bash|zsh|fish)
      ;;
    *)
      shell_name="bash"
      ;;
  esac

  log "Installing mise"
  curl -fsSL "https://mise.run/$shell_name" | sh
  export PATH="$HOME/.local/bin:$PATH"
}

install_git_if_needed
install_mise_if_needed

mise_bin="$(command -v mise 2>/dev/null || true)"
if [[ -z "$mise_bin" && -x "$HOME/.local/bin/mise" ]]; then
  mise_bin="$HOME/.local/bin/mise"
fi

if [[ -z "$mise_bin" ]]; then
  printf 'mise installation completed but the executable was not found\n' >&2
  exit 1
fi

run_mise_bootstrap() {
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    exec "$mise_bin" bootstrap --yes </dev/tty
  fi

  exec "$mise_bin" bootstrap --yes
}

script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fi

if [[ -n "$script_dir" && -f "$script_dir/mise.toml" && -d "$script_dir/.git" ]]; then
  log "Applying pc-setup from current checkout"
  cd "$script_dir"
  run_mise_bootstrap
fi

log "Preparing pc-setup checkout ($repo_ref)"
mkdir -p "$(dirname "$target_dir")"

if [[ ! -e "$target_dir" ]]; then
  git clone --branch "$repo_ref" --single-branch "$repo_url" "$target_dir"
elif [[ ! -d "$target_dir/.git" ]]; then
  printf 'refusing to overwrite non-git path: %s\n' "$target_dir" >&2
  exit 1
else
  current_origin="$(git -C "$target_dir" remote get-url origin 2>/dev/null || true)"
  if [[ "$current_origin" != "$repo_url" ]]; then
    printf 'existing checkout has unexpected origin: %s\n' "$current_origin" >&2
    exit 1
  fi

  log "Updating existing pc-setup checkout to $repo_ref"
  git -C "$target_dir" fetch origin "$repo_ref"
  git -C "$target_dir" switch "$repo_ref"
  git -C "$target_dir" merge --ff-only "origin/$repo_ref"
fi

cd "$target_dir"
run_mise_bootstrap
