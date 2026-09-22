#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
APT_PACKAGES_FILE="$SCRIPT_DIR/apt-packages.txt"
SHELL_ENV_SOURCE="$REPO_ROOT/config/shell/env.sh"

SKIP_AGENTS=0

usage() {
  cat <<'EOF'
Usage: ./platforms/ubuntu-wsl/bootstrap.sh [--skip-agents]

Options:
  --skip-agents  Skip Claude Code and OpenCode installation.
  -h, --help     Show this help.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --skip-agents)
      SKIP_AGENTS=1
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

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

require_ubuntu() {
  if [[ ! -r /etc/os-release ]]; then
    printf 'Cannot detect Linux distribution: /etc/os-release is missing.\n' >&2
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    printf 'This bootstrap targets Ubuntu. Detected ID=%s.\n' "${ID:-unknown}" >&2
    exit 1
  fi

  if [[ -z "${WSL_INTEROP:-}" ]] && ! grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null; then
    warn "WSL was not detected. The script can install Ubuntu tools, but WSL-specific assumptions are unverified."
  fi

  case "$REPO_ROOT" in
    /mnt/*)
      warn "pc-setup is running from a Windows-mounted path ($REPO_ROOT). Clone development repositories under ~/src instead."
      ;;
  esac
}

install_apt_packages() {
  log "Installing Ubuntu base packages"

  mapfile -t packages < <(
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$APT_PACKAGES_FILE"
  )

  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

install_github_cli() {
  log "Configuring the official GitHub CLI APT repository"

  sudo install -d -m 0755 /etc/apt/keyrings
  local keyring="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
  local source_list="/etc/apt/sources.list.d/github-cli.list"
  local tmp_key

  tmp_key="$(mktemp)"
  trap 'rm -f "$tmp_key"' RETURN

  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$tmp_key"
  sudo install -m 0644 "$tmp_key" "$keyring"

  printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' \
    "$(dpkg --print-architecture)" "$keyring" \
    | sudo tee "$source_list" >/dev/null

  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh

  rm -f "$tmp_key"
  trap - RETURN
}

install_shell_environment() {
  log "Installing user-local shell environment"

  mkdir -p "$HOME/.local/bin" "$HOME/.config/pc-setup" "$HOME/src"
  install -m 0644 "$SHELL_ENV_SOURCE" "$HOME/.config/pc-setup/env.sh"

  if command -v fdfind >/dev/null 2>&1; then
    ln -sfn "$(command -v fdfind)" "$HOME/.local/bin/fd"
  fi

  if command -v batcat >/dev/null 2>&1; then
    ln -sfn "$(command -v batcat)" "$HOME/.local/bin/bat"
  fi

  local bashrc="$HOME/.bashrc"
  local marker='# >>> pc-setup >>>'

  touch "$bashrc"

  if ! grep -Fq "$marker" "$bashrc"; then
    cat >>"$bashrc" <<'EOF'

# >>> pc-setup >>>
if [ -f "$HOME/.config/pc-setup/env.sh" ]; then
  . "$HOME/.config/pc-setup/env.sh"
fi
# <<< pc-setup <<<
EOF
  fi

  # Make the paths available to the remainder of this process as well.
  # shellcheck disable=SC1091
  . "$HOME/.config/pc-setup/env.sh"
}

install_rust() {
  log "Installing Rust stable with rustup"

  if ! command -v rustup >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile default --default-toolchain stable
  fi

  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
  rustup toolchain install stable
  rustup default stable
}

install_worktrunk() {
  log "Installing Worktrunk"

  if ! command -v wt >/dev/null 2>&1; then
    cargo install worktrunk
  fi

  wt config shell install
}

install_bun() {
  log "Installing Bun"

  if ! command -v bun >/dev/null 2>&1; then
    curl -fsSL https://bun.sh/install | bash
  fi

  export PATH="$HOME/.bun/bin:$PATH"
}

install_agent_tools() {
  if [[ "$SKIP_AGENTS" -eq 1 ]]; then
    log "Skipping Claude Code and OpenCode (--skip-agents)"
    return
  fi

  log "Installing Claude Code"
  if ! command -v claude >/dev/null 2>&1; then
    curl -fsSL https://claude.ai/install.sh | bash
  fi
  export PATH="$HOME/.local/bin:$PATH"

  log "Installing OpenCode"
  if ! command -v opencode >/dev/null 2>&1; then
    curl -fsSL https://opencode.ai/install | bash
  fi
}

print_next_steps() {
  cat <<'EOF'

Bootstrap finished.

Open a fresh shell (or run: exec bash), then verify:

  ./platforms/ubuntu-wsl/verify.sh

Manual authentication intentionally remains:

  gh auth login
  gh auth setup-git

  claude

  opencode auth login
  opencode auth list

Also configure personal Git identity if this distribution does not have it yet:

  git config --global user.name  "<name>"
  git config --global user.email "<email>"

Development repositories should live under:

  ~/src
EOF
}

require_ubuntu
install_apt_packages
install_github_cli
install_shell_environment
install_rust
install_worktrunk
install_bun
install_agent_tools
print_next_steps
