#!/usr/bin/env bash
# Convergence status report for this machine (ADR-0016).
#
#   converge-status.sh --write   gather facts and write status.json atomically
#   converge-status.sh --print   print a human-readable summary of status.json
#
# The report is detect-only. Stale processes are listed and never signalled.
# It records paths, revisions, counts and step results, never environment
# values, tokens, keys, or process arguments.
set -euo pipefail

mode="${1:---print}"

deploy_dir="${PC_SETUP_DEPLOY_DIR:-$HOME/.local/share/pc-setup/deploy}"
dotfiles_dir="${DOTFILES_DIR:-$HOME/.dotfiles}"
state_dir="${PC_SETUP_STATE_DIR:-$HOME/.local/state/pc-setup}"
converge_dir="$state_dir/converge"
steps_file="$converge_dir/steps.tsv"
run_file="$converge_dir/run.env"
status_file="$state_dir/status.json"
mise_config_path="$HOME/.config/mise/config.toml"
mise_install_prefix="$HOME/.local/share/mise/installs/"

# repo_facts <prefix> <path>: writes branch, head, and dirty flag for a checkout.
repo_facts() {
  local prefix="$1" path="$2"
  if [[ ! -d "$path/.git" ]]; then
    printf '%s.present\tfalse\n' "$prefix"
    return 0
  fi
  local branch head dirty
  branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || echo detached)"
  head="$(git -C "$path" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
    dirty=true
  else
    dirty=false
  fi
  printf '%s.present\ttrue\n' "$prefix"
  printf '%s.path\t%s\n' "$prefix" "$path"
  printf '%s.branch\t%s\n' "$prefix" "$branch"
  printf '%s.head\t%s\n' "$prefix" "$head"
  printf '%s.dirty\t%s\n' "$prefix" "$dirty"
}

# stale_processes: classifies processes whose executable lives under the mise
# install tree. The tool id comes from `mise ls --json`, which lists every
# installed version with its install_path. Install directory names are never
# translated back into tool ids (npm-opencode-cli is not npm:@opencode/cli).
# Each executable is matched against the install paths, longest prefix first.
#
# Output, one line per finding:
#   process TAB stale|unresolved TAB pid TAB tool TAB binary TAB expected-or-reason
#   stale:      the executable belongs to a known install that is not the active
#               version of its tool; the reason is the active install path.
#   unresolved: the executable is under the install tree but matches no install.
# A failed `mise ls --json` is reported as a process-scan line, not as processes.
stale_processes() {
  python3 -I - "$mise_install_prefix" "$HOME" <<'PY'
import json
import subprocess
import sys

install_root = sys.argv[1]
home = sys.argv[2]


def emit(kind, pid, tool, binary, detail):
    print("\t".join(["process", kind, str(pid), tool, binary, detail]))


try:
    listing = subprocess.run(
        ["mise", "-C", home, "ls", "--json"],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=True,
    )
    tools = json.loads(listing.stdout)
except (OSError, subprocess.CalledProcessError, ValueError) as exc:
    print("process-scan\terror\tmise ls --json failed: " + type(exc).__name__)
    sys.exit(0)

# (install path with trailing slash, tool id, install path) for every known install.
installs = []
active_by_tool = {}
for tool, entries in tools.items():
    for entry in entries:
        path = entry.get("install_path")
        if not path:
            continue
        installs.append((path.rstrip("/") + "/", tool, path))
        if entry.get("active"):
            active_by_tool[tool] = path
installs.sort(key=lambda item: len(item[0]), reverse=True)

ps = subprocess.run(
    ["ps", "-axww", "-o", "pid=,args="],
    capture_output=True,
    text=True,
    check=True,
)
for line in ps.stdout.splitlines():
    fields = line.split(None, 1)
    if len(fields) != 2:
        continue
    pid, args = fields
    # Only the executable path is read; arguments are never recorded.
    exe = args.split(" ", 1)[0]
    if not exe.startswith(install_root):
        continue
    match = next((item for item in installs if exe.startswith(item[0])), None)
    if match is None:
        emit("unresolved", pid, "", exe, "no mise install matches this path")
        continue
    _, tool, matched_path = match
    current = active_by_tool.get(tool)
    if current is None:
        emit("stale", pid, tool, exe, "no active version of " + tool)
    elif matched_path != current:
        emit("stale", pid, tool, exe, current)
PY
}

facts_tmp="$(mktemp "${TMPDIR:-/tmp}/converge-facts.XXXXXX")"
trap 'rm -f "$facts_tmp"' EXIT

{
  repo_facts deploy "$deploy_dir"
  repo_facts dotfiles "$dotfiles_dir"

  if [[ -L "$mise_config_path" ]]; then
    printf 'mise.config_target\t%s\n' "$(readlink "$mise_config_path")"
  else
    printf 'mise.config_target\tnot a symlink\n'
  fi

  if outdated="$(mise -C "$HOME" outdated </dev/null 2>/dev/null)"; then
    printf 'mise.outdated_count\t%s\n' "$(printf '%s' "$outdated" | grep -c . || true)"
  else
    printf 'mise.outdated_count\t-1\n'
  fi

  stale_processes
} >"$facts_tmp"

if [[ "$mode" == --write ]]; then
  mkdir -p "$state_dir"
  python3 - "$facts_tmp" "$steps_file" "$run_file" "$status_file" <<'PY'
import datetime
import json
import os
import sys
from pathlib import Path

facts_path, steps_path, run_path, out_path = sys.argv[1:5]

facts = {}
processes = []
scan_errors = []
for line in Path(facts_path).read_text(encoding="utf-8").splitlines():
    if line.startswith("process\t"):
        _, kind, pid, tool, binary, detail = line.split("\t", 5)
        processes.append({
            "kind": kind,
            "pid": int(pid),
            "tool": tool,
            "binary": binary,
            "detail": detail,
        })
        continue
    if line.startswith("process-scan\t"):
        scan_errors.append(line.split("\t", 2)[2])
        continue
    key, _, value = line.partition("\t")
    facts[key] = value

steps = []
errors = []
verify = None
steps_path_obj = Path(steps_path)
if steps_path_obj.exists():
    for line in steps_path_obj.read_text(encoding="utf-8").splitlines():
        at, step, status, detail = (line.split("\t", 3) + ["", "", "", ""])[:4]
        steps.append({"at": at, "step": step, "status": status, "detail": detail})
        if status in ("error", "fail", "pending", "skipped"):
            errors.append(f"{step}: {detail}")
        if step == "verify":
            verify = {"status": status, "detail": detail, "at": at}

last_run = {}
run_path_obj = Path(run_path)
if run_path_obj.exists():
    for line in run_path_obj.read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition("=")
        last_run[key] = value

for message in scan_errors:
    errors.append("process-scan: " + message)
if facts.get("mise.outdated_count") == "-1":
    errors.append("mise-outdated: mise outdated failed; drift count unknown")

def repo(prefix):
    if facts.get(f"{prefix}.present") != "true":
        return {"present": False}
    return {
        "present": True,
        "path": facts.get(f"{prefix}.path", ""),
        "branch": facts.get(f"{prefix}.branch", ""),
        "head": facts.get(f"{prefix}.head", ""),
        "dirty": facts.get(f"{prefix}.dirty") == "true",
    }

stale = [p for p in processes if p["kind"] == "stale"]
unresolved = [p for p in processes if p["kind"] == "unresolved"]

report = {
    "schema": 1,
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "deploy": repo("deploy"),
    "dotfiles": repo("dotfiles"),
    "mise": {
        "config_target": facts.get("mise.config_target", ""),
        "outdated_count": int(facts.get("mise.outdated_count", "-1")),
    },
    "verify": verify,
    "last_converge": last_run,
    "steps": steps,
    "stale_processes": [
        {
            "pid": p["pid"],
            "tool": p["tool"],
            "binary": p["binary"],
            "expected_current": p["detail"],
        }
        for p in stale
    ],
    "unresolved_processes": [
        {
            "pid": p["pid"],
            "binary": p["binary"],
            "reason": p["detail"],
        }
        for p in unresolved
    ],
    "errors": errors,
}

tmp_path = out_path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, out_path)
print(f"wrote {out_path}")
PY
  exit 0
fi

if [[ "$mode" != --print ]]; then
  printf 'usage: %s [--write|--print]\n' "$0" >&2
  exit 2
fi

if [[ ! -f "$status_file" ]]; then
  printf 'no status report yet: %s\n' "$status_file" >&2
  exit 1
fi

python3 - "$status_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    r = json.load(fh)

def line(label, value):
    print(f"{label:<22} {value}")

print(f"status generated       {r['generated_at']}")
for name in ("deploy", "dotfiles"):
    info = r[name]
    if not info.get("present"):
        line(f"{name} checkout", "missing")
        continue
    state = "DIRTY" if info["dirty"] else "clean"
    line(f"{name} checkout", f"{info['branch']} @ {info['head'][:12]} ({state})")
line("mise config target", r["mise"]["config_target"])
count = r["mise"]["outdated_count"]
line("tools outdated", "unknown" if count < 0 else str(count))
verify = r["verify"]
line("verify", "not run" if verify is None else f"{verify['status']} at {verify['at']}: {verify['detail']}")
last = r["last_converge"]
if last:
    line("last converge", f"started {last.get('started', '?')}, finished {last.get('finished', 'running')}, exit {last.get('exit', '?')}")
print("steps:")
for s in r["steps"]:
    print(f"  {s['step']:<16} {s['status']:<8} {s['detail']}")
print(f"stale processes: {len(r['stale_processes'])} (detect-only; nothing was signalled)")
for p in r["stale_processes"]:
    print(f"  pid {p['pid']}  {p['tool']}  {p['binary']}  ->  current {p['expected_current']}")
print(f"unresolved processes: {len(r['unresolved_processes'])}")
for p in r["unresolved_processes"]:
    print(f"  pid {p['pid']}  {p['binary']}  (unresolved: {p['reason']})")
print(f"errors: {len(r['errors'])}")
for e in r["errors"]:
    print(f"  - {e}")
PY
