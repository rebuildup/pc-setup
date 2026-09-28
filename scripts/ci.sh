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

printf 'Checking mise TOML syntax...\n'
python3 - <<'PY'
import tomllib
from pathlib import Path

for path in (Path("mise.toml"), Path("mise.global.toml")):
    with path.open("rb") as fh:
        tomllib.load(fh)
PY

printf 'Checking continuous update train invariants...\n'
grep -Fq 'lock --global --bump' .github/workflows/update-train.yml
grep -Fq 'mise.global.lock' .github/workflows/update-train.yml
grep -Fq 'git diff --quiet -- mise.global.toml' .github/workflows/update-train.yml
grep -Fq 'headRefOid,baseRefOid' .github/workflows/update-train.yml
grep -Fq 'workflow_dispatch:' .github/workflows/ci.yml
grep -Fq 'PC_SETUP_MISE_SOURCE_LOCK_FILE' scripts/apply-global-mise.sh
grep -Fq -- '--locked' scripts/apply-global-mise.sh
grep -Fq 'PC_SETUP_MISE_SOURCE_LOCK_FILE' scripts/apply-global-mise.ps1
grep -Fq -- "'--locked'" scripts/apply-global-mise.ps1

printf 'Checking executable bits...\n'
for script in "${shell_scripts[@]}"; do
  if [[ ! -x "$script" ]]; then
    printf 'Script is not executable: %s\n' "$script" >&2
    exit 1
  fi
done

printf 'Checking parent-shell activation UX...\n'
grep -Fq 'cannot modify the parent shell PATH' bootstrap.sh
grep -Fq 'source ~/.bashrc' bootstrap.sh
grep -Fq 'bootstrap.sh | bash && source ~/.bashrc' platforms/ubuntu-wsl/README.md

printf 'All repository checks passed.\n'
