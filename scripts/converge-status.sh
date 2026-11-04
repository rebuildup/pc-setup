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

# stale_processes: one line per process whose executable lives under the mise
# install tree but is not the version `mise where` reports as current.
# Output: <stale|unresolved> TAB pid TAB binary TAB expected-or-reason
stale_processes() {
  local pid exe _rest rel tool after_tool ver root expected
  ps -axww -o pid=,args= | while read -r pid exe _rest; do
    case "$exe" in
      "$mise_install_prefix"*) ;;
      *) continue ;;
    esac
    rel="${exe#"$mise_install_prefix"}"
    tool="${rel%%/*}"
    after_tool="${rel#*/}"
    ver="${after_tool%%/*}"
    root="$mise_install_prefix$tool/$ver"
    expected="$(mise -C "$HOME" where "$tool" </dev/null 2>/dev/null || true)"
    if [[ -z "$expected" ]]; then
      printf 'unresolved\t%s\t%s\tmise where could not resolve %s\n' "$pid" "$exe" "$tool"
    elif [[ "$expected" != "$root" ]]; then
      printf 'stale\t%s\t%s\t%s\n' "$pid" "$exe" "$expected"
    fi
  done
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

  stale_processes | sed 's/^/process\t/'
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
for line in Path(facts_path).read_text(encoding="utf-8").splitlines():
    if line.startswith("process\t"):
        _, kind, pid, binary, detail = line.split("\t", 4)
        processes.append({"kind": kind, "pid": int(pid), "binary": binary, "detail": detail})
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
        {"pid": p["pid"], "binary": p["binary"], "expected_current": p["detail"]} for p in stale
    ],
    "unresolved_processes": [
        {"pid": p["pid"], "binary": p["binary"], "reason": p["detail"]} for p in unresolved
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
    print(f"  pid {p['pid']}  {p['binary']}  ->  current {p['expected_current']}")
for p in r["unresolved_processes"]:
    print(f"  pid {p['pid']}  {p['binary']}  (unresolved: {p['reason']})")
print(f"errors: {len(r['errors'])}")
for e in r["errors"]:
    print(f"  - {e}")
PY
