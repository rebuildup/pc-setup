#!/usr/bin/env bash
# Convergence status report for this machine (ADR-0016).
#
#   converge-status.sh --write   gather facts and write status.json atomically
#   converge-status.sh --print   print a human-readable summary of status.json
#
# The report is detect-only. Stale processes are listed and never signalled.
# It records paths, revisions, counts and step results, never environment
# values, tokens, keys, or process arguments.
#
# The status.json schema is shared with platforms/windows-11/converge.ps1. Both
# writers emit: schema, platform, generated_at, deploy, dotfiles, mise, verify,
# last_converge (exit as an integer), steps, stale_processes, unresolved_processes,
# errors. Platform ids match the platforms/ directory names: macos, ubuntu-wsl,
# linux (a non-WSL Linux host), windows-11.
set -euo pipefail

mode="${1:---print}"

# Validate the mode before anything else. Facts are gathered only for --write.
case "$mode" in
  --write|--print) ;;
  *) printf 'usage: %s [--write|--print]\n' "$0" >&2; exit 2 ;;
esac

deploy_dir="${PC_SETUP_DEPLOY_DIR:-$HOME/.local/share/pc-setup/deploy}"
dotfiles_dir="${DOTFILES_DIR:-$HOME/.dotfiles}"
state_dir="${PC_SETUP_STATE_DIR:-$HOME/.local/state/pc-setup}"
converge_dir="$state_dir/converge"
steps_file="$converge_dir/steps.tsv"
run_file="$converge_dir/run.env"
status_file="$state_dir/status.json"
mise_config_path="$HOME/.config/mise/config.toml"
mise_install_prefix="$HOME/.local/share/mise/installs/"

# platform_id: the same ids the platform directories use. WSL is detected with the
# same test as converge.sh and verify.sh, so a non-WSL Linux host is reported as linux.
platform_id() {
  case "$(uname -s)" in
    Darwin) printf 'macos\n' ;;
    Linux)
      if [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] \
        || grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null; then
        printf 'ubuntu-wsl\n'
      else
        printf 'linux\n'
      fi
      ;;
    *) uname -s | tr '[:upper:]' '[:lower:]' ;;
  esac
}

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
# installed version with its install_path, so install directory names are never
# translated into tool ids (npm-opencode-cli is not npm:@opencode/cli).
#
# Finding the executable of a process:
#   - Linux: /proc/<pid>/exe, the kernel's real path. argv[0] is not used.
#   - macOS: there is no /proc. argv[0] is used only when it is absolute and the
#     install root appears in the command line. Otherwise (a bare name such as
#     `node server.js`, or a path with spaces) `lsof -p <pid> -d txt` gives the real
#     image path. A process that still cannot be resolved is counted and reported
#     as a process-scan note. It is never silently treated as clean.
#   - Kernel threads, shown as [name], have no executable and are skipped.
#
# Output, one line per finding:
#   process TAB stale|unresolved TAB pid TAB tool TAB binary TAB expected-or-reason
#   process-scan TAB error|note TAB message
#   stale:      the executable belongs to a known install that is not the active
#               version of its tool; the reason is the active install path.
#   unresolved: the executable is under the install tree but matches no install.
stale_processes() {
  python3 -I - "$mise_install_prefix" "$HOME" <<'PY'
import ctypes
import json
import os
import subprocess
import sys

install_root = sys.argv[1]
home = sys.argv[2]
# How the ps call below appears in its own output (argv joined by spaces).
PS_SELF_ARGS = "ps -axww -o pid=,args="


def emit(kind, pid, tool, binary, detail):
    print("\t".join(["process", kind, str(pid), tool, binary, detail]))


def scan_error(message):
    print("process-scan\terror\t" + message)


PROC_PIDPATHINFO_MAXSIZE = 4096
_libproc = None


def image_path(pid):
    """Real executable path of a process, or None when it cannot be determined."""
    if os.path.isdir("/proc/self"):
        try:
            return os.readlink(f"/proc/{pid}/exe")
        except OSError:
            return None
    # macOS: proc_pidpath(3) returns the kernel's executable path, the equivalent of
    # /proc/<pid>/exe. The first txt mapping of lsof is not guaranteed to be the image.
    global _libproc
    try:
        if _libproc is None:
            _libproc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            _libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
            _libproc.proc_pidpath.restype = ctypes.c_int
        buf = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
        length = _libproc.proc_pidpath(int(pid), buf, PROC_PIDPATHINFO_MAXSIZE)
    except (OSError, ValueError, AttributeError):
        return None
    if length <= 0:
        return None
    return buf.value.decode("utf-8", "replace")


try:
    listing = subprocess.run(
        ["mise", "-C", home, "ls", "--json"],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=True,
    )
    tools = json.loads(listing.stdout.decode("utf-8", "replace"))
except (OSError, subprocess.CalledProcessError, ValueError) as exc:
    scan_error("mise ls --json failed: " + type(exc).__name__)
    sys.exit(0)

try:
    ps = subprocess.run(
        ["ps", "-axww", "-o", "pid=,args="],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=True,
    )
except (OSError, subprocess.CalledProcessError) as exc:
    scan_error("ps failed: " + type(exc).__name__)
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

has_proc = os.path.isdir("/proc/self")
unresolved_candidates = []
try:
    for raw in ps.stdout.decode("utf-8", "replace").splitlines():
        fields = raw.strip().split(None, 1)
        if len(fields) != 2:
            continue
        pid, args = fields
        if args == PS_SELF_ARGS:
            continue  # this scan's own ps child: it is in its own snapshot
        argv0 = args.split(" ", 1)[0]
        if argv0.startswith("["):
            continue  # kernel thread: no executable image
        absolute = argv0.startswith("/")
        if absolute and install_root not in args and not has_proc:
            continue  # macOS: an absolute argv0 that does not mention the install tree
        exe = image_path(pid)
        if exe is None:
            # Linux: an absolute argv0 with no install root in it is not a candidate.
            if has_proc and absolute and install_root not in args:
                continue
            unresolved_candidates.append((pid, argv0))
            continue
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
except Exception as exc:  # the report must still be written
    scan_error("process scan aborted: " + type(exc).__name__)
    sys.exit(0)

if unresolved_candidates:
    # Only pid and argv[0] are recorded, never the arguments.
    first_pid, first_argv0 = unresolved_candidates[0]
    print(
        "process-scan\tnote\t"
        f"{len(unresolved_candidates)} process(es) could not be resolved to an executable path "
        f"(first: pid {first_pid}, argv0 {first_argv0!r}); their stale status is unknown"
    )
PY
}

# gather_facts: prints the fact lines consumed by the --write step below.
gather_facts() {
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

  # A failed scan becomes a process-scan error line. It never stops the report.
  stale_processes || printf 'process-scan\terror\tprocess scan did not run\n'
}

if [[ "$mode" == --write ]]; then
  mkdir -p "$state_dir"
  facts_tmp="$(mktemp "${TMPDIR:-/tmp}/converge-facts.XXXXXX")"
  trap 'rm -f "$facts_tmp"' EXIT
  gather_facts >"$facts_tmp"
  platform="$(platform_id)"

  # The report is written through a unique temp file in the same directory and
  # then renamed. Concurrent writers can never publish mixed JSON.
  python3 - "$facts_tmp" "$steps_file" "$run_file" "$status_file" "$platform" <<'PY'
import datetime
import json
import os
import re
import sys
import tempfile
from pathlib import Path

facts_path, steps_path, run_path, out_path, platform = sys.argv[1:6]

URL_USERINFO = re.compile(r"([A-Za-z][A-Za-z0-9+.-]*://)[^/@\s]+@")


def redact(text):
    return URL_USERINFO.sub(r"\1***@", text)


facts = {}
processes = []
scan_messages = []
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
        scan_messages.append(line.split("\t", 2)[2])
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
        steps.append({"at": at, "step": step, "status": status, "detail": redact(detail)})
        if status in ("error", "fail", "pending", "skipped"):
            errors.append(f"{step}: {redact(detail)}")
        if step == "verify":
            verify = {"status": status, "detail": redact(detail), "at": at}

last_run = {}
run_path_obj = Path(run_path)
if run_path_obj.exists():
    for line in run_path_obj.read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition("=")
        if key == "exit" and re.fullmatch(r"-?\d+", value):
            last_run[key] = int(value)
        else:
            last_run[key] = redact(value)

for message in scan_messages:
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
    "platform": platform,
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

out_dir = os.path.dirname(out_path) or "."
fd, tmp_path = tempfile.mkstemp(dir=out_dir, prefix=".status.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, out_path)
except BaseException:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
    raise
print(f"wrote {out_path}")
PY
  exit 0
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
line("platform", r.get("platform", "unknown"))
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
