#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

SNAPSHOT=0

usage() {
  cat <<'EOF'
Usage: ./platforms/ubuntu-wsl/verify.sh [--snapshot]

Options:
  --snapshot   Print a stable version inventory suitable for snapshots/.
  -h, --help   Show this help.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --snapshot)
      SNAPSHOT=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

first_line() {
  "$@" 2>&1 | sed -n '1p'
}

snapshot() {
  printf 'generated_at_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf 'kernel=%s\n' "$(uname -r)"
  printf 'git=%s\n' "$(first_line git --version)"
  printf 'gh=%s\n' "$(first_line gh --version)"
  printf 'rg=%s\n' "$(first_line rg --version)"
  printf 'fd=%s\n' "$(first_line fd --version)"
  printf 'fzf=%s\n' "$(first_line fzf --version)"
  printf 'jq=%s\n' "$(first_line jq --version)"
  printf 'bat=%s\n' "$(first_line bat --version)"
  printf 'bun=%s\n' "$(first_line bun --version)"
  printf 'rustc=%s\n' "$(first_line rustc --version)"
  printf 'cargo=%s\n' "$(first_line cargo --version)"
  printf 'worktrunk=%s\n' "$(first_line wt --version)"
  printf 'claude=%s\n' "$(first_line claude --version)"
  printf 'opencode=%s\n' "$(first_line opencode --version)"
  printf 'shellcheck=%s\n' "$(first_line shellcheck --version)"
  printf 'python=%s\n' "$(first_line python3 --version)"
  printf 'cmake=%s\n' "$(first_line cmake --version)"
  printf 'clang=%s\n' "$(first_line clang --version)"
}

if [[ "$SNAPSHOT" -eq 1 ]]; then
  required=(git gh rg fd fzf jq bat bun rustc cargo wt claude opencode shellcheck python3 cmake clang)
  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf 'Cannot create complete snapshot: missing command %s\n' "$cmd" >&2
      exit 1
    fi
  done
  snapshot
  exit 0
fi

failures=0
warnings=0

ok() {
  printf 'OK    %s\n' "$*"
}

fail() {
  printf 'FAIL  %s\n' "$*"
  failures=$((failures + 1))
}

warn() {
  printf 'WARN  %s\n' "$*"
  warnings=$((warnings + 1))
}

check_command() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd -> $(command -v "$cmd")"
  else
    fail "$cmd is missing"
  fi
}

printf 'pc-setup Ubuntu/WSL verification\n\n'

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" == "ubuntu" ]]; then
    ok "Ubuntu detected (${PRETTY_NAME:-unknown version})"
  else
    fail "Expected Ubuntu, detected ID=${ID:-unknown}"
  fi
else
  fail "/etc/os-release is missing"
fi

if [[ -n "${WSL_INTEROP:-}" ]] || grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null; then
  ok "WSL detected"
else
  warn "WSL was not detected"
fi

case "$REPO_ROOT" in
  /mnt/*)
    warn "repository is on a Windows-mounted filesystem: $REPO_ROOT"
    ;;
  *)
    ok "repository is on the Linux filesystem: $REPO_ROOT"
    ;;
esac

if [[ -d "$HOME/src" ]]; then
  ok "workspace exists: $HOME/src"
else
  fail "workspace is missing: $HOME/src"
fi

commands=(
  git
  gh
  rg
  fd
  fzf
  jq
  bat
  bun
  rustc
  cargo
  wt
  herdr
  pnpm
  gcloud
  aws
  supabase
  vercel
  npkill
  ocr
  cargo-clean-all
  claude
  opencode
  shellcheck
  python3
  cmake
  clang
)

for cmd in "${commands[@]}"; do
  check_command "$cmd"
done

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "GitHub CLI authentication"
  else
    warn "GitHub CLI is not authenticated; run: gh auth login"
  fi
fi

if command -v opencode >/dev/null 2>&1; then
  if opencode auth list >/dev/null 2>&1; then
    warn "Review OpenCode provider authentication manually with: opencode auth list"
  else
    warn "OpenCode provider auth is not configured or unreadable; run: opencode auth login"
  fi
fi

if command -v claude >/dev/null 2>&1; then
  warn "Claude Code login is interactive; run: claude and confirm the active account"
fi

if git config --global --get user.name >/dev/null 2>&1; then
  ok "global Git user.name is configured"
else
  warn "global Git user.name is not configured"
fi

if git config --global --get user.email >/dev/null 2>&1; then
  ok "global Git user.email is configured"
else
  warn "global Git user.email is not configured"
fi

printf '\nResult: %d failure(s), %d warning(s)\n' "$failures" "$warnings"

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi
