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

printf 'Checking machine-wide mise package scope...\n'
python3 - <<'PY'
import tomllib
from pathlib import Path

with Path("mise.global.toml").open("rb") as fh:
    global_config = tomllib.load(fh)

packages = global_config.get("bootstrap", {}).get("packages", {})

# mise.global.toml is the machine-wide config on every OS. A package without an
# `os` condition would be applied by Windows and Linux bootstraps too, so the
# macOS-only scope is part of the contract rather than a local preference.
if not packages:
    raise SystemExit("mise.global.toml declares no [bootstrap.packages]")

for name, spec in packages.items():
    manager = name.split(":", 1)[0]
    if manager not in {"brew", "brew-cask"}:
        raise SystemExit(f"unexpected manager for {name}: {manager}")
    if not isinstance(spec, dict) or "os" not in spec:
        raise SystemExit(f"{name} must declare an explicit os condition")
    os_value = spec["os"]
    declared = {os_value} if isinstance(os_value, str) else set(os_value)
    if declared != {"macos"}:
        raise SystemExit(f"{name} must apply to macOS only, got {sorted(declared)}")

if any("docker-desktop" in name for name in packages):
    raise SystemExit(
        "Docker Desktop must stay out of the package set; containers use Colima"
    )

# Colima, Docker, Compose, Buildx and FFmpeg are system packages. As portable
# tools they would lose their os condition and land on every OS.
for name in global_config.get("tools", {}):
    if name in {"colima", "docker", "docker-compose", "docker-buildx", "ffmpeg"}:
        raise SystemExit(
            f"{name} belongs to [bootstrap.packages] with an os condition, not [tools]"
        )
PY

printf 'Checking macOS container runtime contract...\n'
grep -Fq "bash \"\$repo_root/platforms/macos/containers/install.sh\"" scripts/apply-platform.sh
grep -Fq "mise -C \"\$HOME\" bootstrap packages apply" scripts/apply-global-mise.sh
grep -Fq 'provisioned but stopped' platforms/macos/containers/verify.sh

# Homebrew lives under different prefixes on Apple Silicon and Intel, so the
# scripts resolve formulae through mise instead of assuming one of them.
if grep -Eq '/opt/homebrew' platforms/macos/containers/*.sh; then
  printf 'container scripts must not hard-code a Homebrew prefix\n' >&2
  exit 1
fi

# The VM holds every image and volume, and a pinned DOCKER_HOST would leak the
# container daemon into unrelated sessions. Neither is acceptable here.
if grep -Eq 'colima (delete|reset)|export DOCKER_HOST|docker context use' platforms/macos/containers/*.sh; then
  printf 'container scripts must not destroy VM data, pin DOCKER_HOST or switch contexts\n' >&2
  exit 1
fi

# Verification reports a stopped VM as provisioned; starting it is the operator's
# decision, not a side effect of running a check.
if grep -Eq '^[[:space:]]*colima start' platforms/macos/containers/verify.sh; then
  printf 'verify must not start the Colima VM\n' >&2
  exit 1
fi

# mise resolves [bootstrap.packages] itself. Prove on this host that the resolved
# set equals the set declared for this OS, which is what keeps a macOS-only entry
# from reaching Windows and Linux.
if command -v mise >/dev/null 2>&1; then
  printf 'Checking bootstrap package OS filtering through mise...\n'
  mise_scope_dir="$(mktemp -d)"
  trap 'rm -rf "$mise_scope_dir"' EXIT
  mkdir -p "$mise_scope_dir/config" "$mise_scope_dir/work"
  cp mise.global.toml "$mise_scope_dir/config/config.toml"
  MISE_CONFIG_DIR="$mise_scope_dir/config" \
    mise -C "$mise_scope_dir/work" bootstrap status --json >"$mise_scope_dir/status.json"

  python3 - "$mise_scope_dir/status.json" <<'PY'
import json
import sys
import tomllib
from pathlib import Path

host = {"darwin": "macos", "linux": "linux", "win32": "windows"}[sys.platform]

with Path("mise.global.toml").open("rb") as fh:
    packages = tomllib.load(fh).get("bootstrap", {}).get("packages", {})

expected = set()
for name, spec in packages.items():
    os_value = spec.get("os") if isinstance(spec, dict) else None
    declared = (
        set()
        if os_value is None
        else ({os_value} if isinstance(os_value, str) else set(os_value))
    )
    if not declared or host in declared:
        expected.add(name)

status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
actual = {
    f"{manager}:{entry['package']}"
    for manager, group in status.get("packages", {}).items()
    for entry in group.get("packages", [])
}

if actual != expected:
    raise SystemExit(
        f"on {host} expected {sorted(expected)} but mise resolved {sorted(actual)}"
    )
print(f"ok      mise resolved {len(expected)} bootstrap package(s) on {host}")
PY
fi

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
# The helper runs for the life of the job to repair drift, so launchd must not
# restart it after a successful exit.
assert plist["KeepAlive"] == {"SuccessfulExit": False}
assert plist["ThrottleInterval"] == 30
# The Karabiner DriverKit virtual keyboard restores the mapping on every Kanata
# restart, not only on boot, so the poll interval is the repair latency.
watch_interval = int(plist["EnvironmentVariables"]["ONISHI_WATCH_INTERVAL"])
assert 1 <= watch_interval <= 60, "ONISHI_WATCH_INTERVAL must stay responsive"

# An apply that is not verified per keyboard event service silently leaves the
# machine on the raw US ANSI layout after boot, so the verification path is part
# of the contract rather than an implementation detail.
#
# `hidutil property --set` appends a registry entry instead of replacing one, so an
# apply that does not clear first converts every keystroke once per historical run.
# A second conversion of Kanata's already converted output arrives through the
# Karabiner DriverKit virtual keyboard, so the mapping must stay off that service
# while remaining on the physical keyboards.
helper_path = Path("platforms/macos/keyboard/apply-onishi.sh")
helper = helper_path.read_text(encoding="utf-8")

for required in (
    "--matching",
    "HIDKeyboardModifierMappingSrc",
    "verify_state",
    "clear_virtual_keyboard",
    "virtual_keyboard_entries",
    "physical_keyboard_entries",
):
    assert required in helper, f"apply-onishi.sh lost required verification: {required}"

# A global `hidutil property --set` writes the mapping onto every keyboard event
# service that exists at that moment, including the Karabiner DriverKit virtual
# keyboard once it registers. Scoping the apply to the physical keyboard is what
# keeps a later Kanata restart from reintroducing a second conversion, so the
# apply must never be issued without a match.
assert "physical_keyboard_matches" in helper, (
    "apply-onishi.sh must scope the apply to the physical keyboard"
)
apply_line = next(
    line for line in helper.splitlines() if '--set "$mapping_body"' in line
)
assert "--matching" in apply_line, (
    "the UserKeyMapping apply must be scoped with --matching"
)

# macOS ships bash 3.2, whose glob expansion turns a quoted `[{"` into `[[{`. The
# resulting match resolves to nothing and the helper reports an empty mapping, which
# `bash -n` cannot detect. A bracketed array literal in a match would be silently
# wrong for that reason.
match_block = helper.split("physical_keyboard_matches=(")[1].split("\n)")[0]
assert '[{"' not in match_block, (
    "physical keyboard matches must not use a bracketed array literal: bash 3.2 "
    "mangles `[{\"` into `[[{` and the match then resolves to nothing"
)

# A registry write is not visible to a following read, so verifying in the same
# breath as the set reads an empty mapping and re-applies on every attempt. That
# accumulation is what produced the historical duplicate mapping entries.
assert "physical_keyboard_entries" in helper
set_index = helper.index('--set "$mapping_body"')
assert "/bin/sleep" in helper[set_index : helper.index("if verify_state", set_index)], (
    "apply-onishi.sh must wait for the registry write to become visible"
)

# Re-applying on every attempt is what accumulates mapping entries, so the apply
# must be conditional on the physical keyboard not already carrying the mapping.
assert (
    'if [[ "$(physical_keyboard_entries)" -ne "$expected_entries" ]]' in helper
), "apply-onishi.sh must skip the apply when the mapping is already present"

# The virtual keyboard restores the mapping on every Kanata restart, so the helper
# has to keep checking for drift instead of exiting once the layout converges.
assert "while true" in helper, (
    "apply-onishi.sh must keep checking for drift after convergence"
)
assert "drift detected" in helper, (
    "apply-onishi.sh must report and repair drift"
)
assert "exit 0" not in helper.split("while true")[1], (
    "apply-onishi.sh must not exit after convergence; it has to survive Kanata "
    "restarts"
)

assert "ONISHI_VIRTUAL_KEYBOARD_MATCH" in helper, (
    "apply-onishi.sh must define the Kanata virtual keyboard match"
)
assert '{"UserKeyMapping":[]}' in helper, (
    "apply-onishi.sh must clear the Kanata virtual keyboard mapping"
)
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
grep -Fq 'config_ref="0c02df504029d84bdaa145a70b2ac9719f5e9956"' platforms/macos/kanata/install-kanata.sh
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
