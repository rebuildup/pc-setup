#!/usr/bin/env bash
set -euo pipefail

if [[ ! -r /etc/os-release ]]; then
  printf 'cannot detect Linux distribution for APT preparation\n' >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

run_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
    return
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    printf 'sudo is required to prepare APT repositories\n' >&2
    exit 1
  fi

  sudo "$@"
}

enable_ubuntu_universe() {
  local deb822_source="/etc/apt/sources.list.d/ubuntu.sources"

  if [[ -f "$deb822_source" ]]; then
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN

    awk '
      /^Components:/ {
        found = 0
        for (i = 2; i <= NF; i++) {
          if ($i == "universe") {
            found = 1
            break
          }
        }
        if (!found) {
          $0 = $0 " universe"
        }
      }
      { print }
    ' "$deb822_source" > "$tmp"

    if ! cmp -s "$tmp" "$deb822_source"; then
      run_root install -m 0644 "$tmp" "$deb822_source"
    fi
    return
  fi

  # Ubuntu releases using legacy sources.list are delegated to the distro's
  # repository management helper rather than rewriting arbitrary mirror lines.
  run_root apt-get update
  if ! command -v add-apt-repository >/dev/null 2>&1; then
    printf 'installing Ubuntu repository management prerequisite\n'
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
  fi
  run_root add-apt-repository -y universe
}

case "${ID:-}" in
  ubuntu)
    printf 'ensuring Ubuntu universe repository component is enabled\n'
    enable_ubuntu_universe

    printf 'refreshing Ubuntu APT metadata\n'
    run_root apt-get update
    ;;

  debian)
    printf 'refreshing Debian APT metadata\n'
    run_root apt-get update
    ;;

  *)
    printf 'unsupported Linux bootstrap distribution for APT packages: %s\n' "${ID:-unknown}" >&2
    exit 1
    ;;
esac
