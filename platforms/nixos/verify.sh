#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

failures=0
warnings=0

ok() {
  printf 'OK    %s\n' "$*"
}

fail() {
  printf 'FAIL  %s\n' "$*" >&2
  failures=$((failures + 1))
}

warn() {
  printf 'WARN  %s\n' "$*" >&2
  warnings=$((warnings + 1))
}

check_command() {
  local command_name="$1"

  if command -v "$command_name" >/dev/null 2>&1; then
    ok "$command_name -> $(command -v "$command_name")"
  else
    fail "$command_name is missing"
  fi
}

printf 'pc-setup NixOS verification\n\n'

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release

  if [[ "${ID:-}" == "nixos" ]]; then
    ok "NixOS detected (${PRETTY_NAME:-unknown version})"
  else
    fail "expected NixOS, detected ID=${ID:-unknown}"
  fi
else
  fail "/etc/os-release is missing"
fi

check_command nix
check_command nixos-version

commands=(
  git
  gh
  infisical
  curl
  wget
  rg
  fd
  fzf
  jq
  bat
  shellcheck
  nvim
  python3
  gcc
  clang
  lldb
  cmake
  ninja
  make
  pkg-config
  node
  pnpm
  bun
  rustc
  cargo
  rustfmt
  cargo-clippy
  rust-analyzer
  claude
  opencode
  wt
)

for command_name in "${commands[@]}"; do
  check_command "$command_name"
done

if command -v nix >/dev/null 2>&1; then
  if nix --extra-experimental-features 'nix-command flakes' flake metadata     --no-write-lock-file "$SCRIPT_DIR" >/dev/null 2>&1; then
    ok "pc-setup NixOS flake evaluates metadata"
  else
    fail "pc-setup NixOS flake metadata evaluation failed"
  fi
fi

if [[ -r "$HOME/.bashrc" ]] && grep -Fq 'wt config shell init bash' "$HOME/.bashrc"; then
  ok "Worktrunk Bash integration is present"
else
  warn "Worktrunk Bash integration was not found in ~/.bashrc; rebuild Home Manager or inspect the active shell"
fi

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "GitHub CLI authentication"
  else
    warn "GitHub CLI is not authenticated; run: gh auth login"
  fi
fi

if command -v infisical >/dev/null 2>&1; then
  if [[ -d "$HOME/.dotfiles" ]] && [[ -x "$HOME/.dotfiles/script/secrets-doctor" ]]; then
    if "$HOME/.dotfiles/script/secrets-doctor" >/dev/null 2>&1; then
      ok "Infisical dotfiles project access"
    else
      warn "Infisical dotfiles access is not ready; run ~/.dotfiles/script/bootstrap"
    fi
  else
    warn "dotfiles Infisical access is validated after ~/.dotfiles is bootstrapped"
  fi
fi

if command -v opencode >/dev/null 2>&1; then
  if opencode auth list >/dev/null 2>&1; then
    warn "Review OpenCode provider authentication with: opencode auth list"
  else
    warn "OpenCode provider auth is not configured or unreadable; run: opencode auth login"
  fi
fi

if command -v claude >/dev/null 2>&1; then
  warn "Claude Code login is interactive; run: claude and confirm the active account"
fi

if git config --get user.name >/dev/null 2>&1; then
  ok "effective Git user.name is configured"
else
  warn "effective Git user.name is not configured; dotfiles bootstrap stores it in ~/.gitconfig.local"
fi

if git config --get user.email >/dev/null 2>&1; then
  ok "effective Git user.email is configured"
else
  warn "effective Git user.email is not configured; dotfiles bootstrap stores it in ~/.gitconfig.local"
fi

printf '\nResult: %d failure(s), %d warning(s)\n' "$failures" "$warnings"

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi
