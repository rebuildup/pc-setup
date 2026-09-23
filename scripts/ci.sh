#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

mapfile -t shell_scripts < <(
  {
    find platforms scripts -type f -name '*.sh' -print
    printf '%s\n' bootstrap.sh
  } | sort
)

if [[ "${#shell_scripts[@]}" -eq 0 ]]; then
  printf 'No shell scripts found.\n' >&2
  exit 1
fi

printf 'Checking bash syntax...\n'
for script in "${shell_scripts[@]}"; do
  bash -n "$script"
done

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'shellcheck is required for repository validation.\n' >&2
  exit 1
fi

printf 'Running ShellCheck...\n'
shellcheck "${shell_scripts[@]}"

printf 'Checking mise.toml syntax...\n'
python3 - <<'PY'
import tomllib
from pathlib import Path

with Path("mise.toml").open("rb") as fh:
    tomllib.load(fh)
PY

printf 'Checking executable bits...\n'
for script in "${shell_scripts[@]}"; do
  if [[ ! -x "$script" ]]; then
    printf 'Script is not executable: %s\n' "$script" >&2
    exit 1
  fi
done

printf 'All repository checks passed.\n'
