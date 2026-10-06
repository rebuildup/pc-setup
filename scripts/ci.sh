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

printf 'Checking macOS keyboard contract...\n'
python3 - <<'PY'
import json
import plistlib
from pathlib import Path

usage = 0x700000000
expected = {
    usage + 0x2D: usage + 0x38,  # physical - -> /
    usage + 0x1A: usage + 0x0F,  # W -> L
    usage + 0x08: usage + 0x18,  # E -> U
    usage + 0x15: usage + 0x36,  # R -> ,
    usage + 0x17: usage + 0x37,  # T -> .
    usage + 0x1C: usage + 0x09,  # Y -> F
    usage + 0x18: usage + 0x1A,  # U -> W
    usage + 0x0C: usage + 0x15,  # I -> R
    usage + 0x12: usage + 0x1C,  # O -> Y
    usage + 0x04: usage + 0x08,  # A -> E
    usage + 0x16: usage + 0x0C,  # S -> I
    usage + 0x07: usage + 0x04,  # D -> A
    usage + 0x09: usage + 0x12,  # F -> O
    usage + 0x0A: usage + 0x2D,  # G -> -
    usage + 0x0B: usage + 0x0E,  # H -> K
    usage + 0x0D: usage + 0x17,  # J -> T
    usage + 0x0E: usage + 0x11,  # K -> N
    usage + 0x0F: usage + 0x16,  # L -> S
    usage + 0x33: usage + 0x0B,  # ; -> H
    usage + 0x05: usage + 0x33,  # B -> ;
    usage + 0x11: usage + 0x0A,  # N -> G
    usage + 0x10: usage + 0x07,  # M -> D
    usage + 0x36: usage + 0x10,  # , -> M
    usage + 0x37: usage + 0x0D,  # . -> J
    usage + 0x38: usage + 0x05,  # / -> B
}

mapping_path = Path("platforms/macos/keyboard/onishi.json")
with mapping_path.open(encoding="utf-8") as fh:
    entries = json.load(fh)["UserKeyMapping"]

mapping = {
    entry["HIDKeyboardModifierMappingSrc"]: entry["HIDKeyboardModifierMappingDst"]
    for entry in entries
}

assert len(mapping) == len(entries), "duplicate source HID usage in Onishi mapping"
assert mapping == expected, (mapping, expected)
assert usage + 0x35 not in mapping, "backtick must not map to slash"

plist_path = Path("platforms/macos/keyboard/dev.rebuildup.pc-setup.onishi-keymap.plist")
with plist_path.open("rb") as fh:
    plist = plistlib.load(fh)

assert plist["Label"] == "dev.rebuildup.pc-setup.onishi-keymap"
assert plist["RunAtLoad"] is True
assert plist["UserName"] == "root"
assert plist["ProgramArguments"] == ["/usr/local/libexec/pc-setup/macos-keyboard/apply-onishi.sh"]
PY

grep -Fq 'bash scripts/apply-platform.sh' mise.toml

printf 'Checking macOS Kanata service contract...\n'
python3 - <<'PY'
import plistlib
from pathlib import Path

driver_path = Path("platforms/macos/kanata/org.pqrs.Karabiner-VirtualHIDDevice-Daemon.plist")
with driver_path.open("rb") as fh:
    driver = plistlib.load(fh)
assert driver["Label"] == "org.pqrs.Karabiner-VirtualHIDDevice-Daemon"
assert driver["UserName"] == "root"
assert driver["RunAtLoad"] is True
assert driver["KeepAlive"] is True

kanata_path = Path("platforms/macos/kanata/dev.rebuildup.pc-setup.kanata.plist.in")
with kanata_path.open("rb") as fh:
    kanata = plistlib.load(fh)
assert kanata["Label"] == "dev.rebuildup.pc-setup.kanata"
assert kanata["UserName"] == "root"
assert kanata["RunAtLoad"] is True
assert kanata["ProgramArguments"][0] == "__KANATA_BIN__"
assert kanata["ProgramArguments"][2] == "__KANATA_CONFIG__"
PY

grep -Fq 'kanata_version="1.12.0"' platforms/macos/kanata/install-kanata.sh
grep -Fq 'driver_version="6.2.0"' platforms/macos/kanata/install-kanata.sh
grep -Fq 'config_ref="583f54d196b30ca00d4c5a8142514409c9757aef"' platforms/macos/kanata/install-kanata.sh
grep -Fq '"brew:kanata" = { os = "macos" }' mise.toml
grep -Fq 'platforms/macos/kanata/install-kanata.sh' scripts/apply-platform.sh


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
