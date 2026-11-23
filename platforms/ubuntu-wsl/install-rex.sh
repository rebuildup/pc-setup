#!/usr/bin/env bash
set -euo pipefail

# Install Rex (https://www.superlogical.com/rex) for the current user.
#
# The official installer is used with --user so no sudo or third-party apt
# repository is required: the rex binary lands in ~/.local/bin, which is the
# only path the installer writes outside the server setup. When systemd is
# running, the installer itself also runs `rex server install`, which enables
# the rex.socket/rex.service systemd user units and lingering. This script
# repeats that step explicitly so the persistence contract does not depend on
# installer internals; `rex server install` is documented as safe to re-run.
#
# Only the preview channel is published today (stable returns 404), so the
# channel is pinned explicitly. See docs/adr/ADR-0026.md.

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'WARN  %s\n' "$*" >&2
}

if [[ ! -r /etc/os-release ]]; then
  warn "cannot detect the distribution; skipping Rex install"
  exit 0
fi

# shellcheck disable=SC1091
. /etc/os-release

case "${ID:-}" in
  ubuntu|debian)
    ;;
  *)
    printf 'skipping Rex install on unsupported distribution: %s\n' "${ID:-unknown}"
    exit 0
    ;;
esac

log "Installing Rex (preview channel, user scope)"
curl -fsSL https://pkgs.superlogical.com/rex/install.sh | sh -s -- --user --channel preview

rex_bin=""
for candidate in "$HOME/.local/bin/rex" "$(command -v rex 2>/dev/null || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    rex_bin="$candidate"
    break
  fi
done

if [[ -z "$rex_bin" ]]; then
  printf 'Rex installer finished but the rex binary was not found.\n' >&2
  printf 'Check that ~/.local/bin exists and is on PATH, then rerun.\n' >&2
  exit 1
fi

printf 'ok      rex -> %s (%s)\n' "$rex_bin" "$("$rex_bin" version | head -n 1)"

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  warn "$HOME/.local/bin is not on PATH in this shell; add it to your shell profile"
fi

# `rex server install` needs a systemd user session. Without one (for example
# WSL without systemd, or most containers) the documented fallback is a
# per-boot `rex server start`, so this stays a warning rather than a failure.
if command -v systemctl >/dev/null 2>&1 && systemctl --user list-units >/dev/null 2>&1; then
  log "Enabling the Rex server at boot (systemd user units)"
  if ! "$rex_bin" server install; then
    warn "rex server install failed; run it manually: rex server install"
  fi
else
  warn "no systemd user session detected; start the server manually with: rex server start"
fi
