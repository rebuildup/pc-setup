#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

if [[ ! -x "$repo_root/bootstrap.sh" ]]; then
  printf 'missing root bootstrap: %s/bootstrap.sh\n' "$repo_root" >&2
  exit 1
fi

exec "$repo_root/bootstrap.sh" "$@"
