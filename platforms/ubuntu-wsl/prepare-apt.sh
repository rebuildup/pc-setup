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

case "${ID:-}" in
  ubuntu)
    printf 'refreshing Ubuntu APT metadata\n'
    run_root apt-get update

    if ! command -v add-apt-repository >/dev/null 2>&1; then
      printf 'installing Ubuntu repository management prerequisite\n'
      run_root env DEBIAN_FRONTEND=noninteractive         apt-get install -y software-properties-common
    fi

    printf 'ensuring Ubuntu universe repository component is enabled\n'
    run_root add-apt-repository -y universe

    # Keep the package index boundary explicit. Some minimal images start with
    # only main enabled, while mise's declared host baseline includes packages
    # such as clang/lldb from universe.
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
