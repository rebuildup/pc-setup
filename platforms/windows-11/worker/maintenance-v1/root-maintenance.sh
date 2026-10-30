#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

action="${1:?action}" instance="${2:?instance}" nonce="${3:?nonce}"
[[ "$instance" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
[[ "$nonce" =~ ^[0-9a-f]{32}$ ]]
[[ "$action" = Inspect || "$action" = Apply ]]
[[ "$(id -u)" = 0 && "$(uname -m)" = x86_64 ]]
[[ -r /etc/os-release ]]
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" = ubuntu && "${VERSION_ID:-}" = 24.04 ]]
for command in id uname dpkg-query apt-get grep; do command -v "$command" >/dev/null; done

# Keep this list aligned with [bootstrap.packages] in mise.toml. The Windows
# controller starts only this immutable script as WSL root; no repository or
# user-writable file is interpreted inside the root process.
packages=(
  ca-certificates curl wget gnupg git git-lfs build-essential pkg-config
  libssl-dev cmake ninja-build clang lldb tree unzip zip xz-utils rsync
  python3-venv openssh-client
)
for package in "${packages[@]}"; do [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; done

missing=()
for package in "${packages[@]}"; do
  status="$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)"
  [[ "$status" = installed ]] || missing+=("$package")
done

if [[ "$action" = Apply && "${#missing[@]}" -gt 0 ]]; then
  apt-get update >/dev/null 2>&1
  install_plan="$(DEBIAN_FRONTEND=noninteractive apt-get -s --no-install-recommends --no-upgrade install "${packages[@]}" 2>/dev/null)"
  if grep -Eq '^(Inst [^[:space:]]+ \[[^]]+\] \(|Remv )' <<<"$install_plan"; then exit 21; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --no-upgrade "${packages[@]}" >/dev/null 2>&1
  missing=()
  for package in "${packages[@]}"; do
    status="$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)"
    [[ "$status" = installed ]] || missing+=("$package")
  done
fi

csv() { local IFS=,; printf '%s' "$*"; }
uid="$(id -u)"
printf 'action=%s\ninstance=%s\nnonce=%s\nuid=%s\npackages=%s\nmissing=%s\n' \
  "$action" "$instance" "$nonce" "$uid" "$(csv "${packages[@]}")" "$(csv "${missing[@]}")"
[[ "$action" != Apply || "${#missing[@]}" -eq 0 ]]
