#!/usr/bin/env bash
# Install, refresh, or remove the per-user LaunchAgent that runs scripts/converge.sh
# from the deployment checkout (ADR-0016).
#
#   install-converge.sh                      install or refresh (idempotent)
#   install-converge.sh --uninstall          bootout and remove the LaunchAgent
#   install-converge.sh --converge-script P  run P instead of the deployment copy
#   install-converge.sh --interval SECONDS   StartInterval, an integer in 60..86400
#
# Every refusal happens before anything is changed: an unmanaged plist at the target
# path is left alone, and the loaded job is not booted out. This never touches the
# dev.rebuildup.pc-setup.devnode.* agents.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'install-converge.sh is macOS-only; WSL and Windows installers are separate.\n' >&2
  exit 1
fi

label="dev.rebuildup.pc-setup.converge"
marker="managed-by: rebuildup/pc-setup platforms/macos/install-converge.sh"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
template="$repo_root/platforms/macos/dev.rebuildup.pc-setup.converge.plist.in"
deploy_dir="${PC_SETUP_DEPLOY_DIR:-$HOME/.local/share/pc-setup/deploy}"
deploy_repo_url="${PC_SETUP_REPO_URL:-https://github.com/rebuildup/pc-setup.git}"
state_dir="${PC_SETUP_STATE_DIR:-$HOME/.local/state/pc-setup}"
agent_dir="$HOME/Library/LaunchAgents"
target="$agent_dir/$label.plist"
domain="gui/$(id -u)"

uninstall=0
converge_script=""
interval=3600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) uninstall=1; shift ;;
    --converge-script) converge_script="${2:?--converge-script needs a path}"; shift 2 ;;
    --interval) interval="${2:?--interval needs seconds}"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# 60..86400, the same range install-converge.ps1 enforces. The digit cap keeps
# the arithmetic safe, and 10# stops a leading zero from being read as octal.
if ! [[ "$interval" =~ ^[0-9]{1,6}$ ]] || (( 10#$interval < 60 || 10#$interval > 86400 )); then
  printf -- '--interval must be an integer in 60..86400: %s\n' "$interval" >&2
  exit 2
fi

is_managed() {
  [[ -f "$1" ]] && grep -Fq "$marker" "$1"
}

is_loaded() {
  launchctl print "$domain/$label" >/dev/null 2>&1
}

if [[ "$uninstall" == 1 ]]; then
  # Ownership is checked before bootout, so a refusal leaves the job running.
  if [[ -e "$target" ]] && ! is_managed "$target"; then
    printf 'refusing to remove unmanaged LaunchAgent: %s\n' "$target" >&2
    exit 1
  fi
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  if [[ -e "$target" ]]; then
    rm -f "$target"
    printf 'removed %s\n' "$target"
  else
    printf 'not installed: %s\n' "$target"
  fi
  exit 0
fi

# The job runs the deployment copy, so the plist does not depend on whichever
# work checkout happens to run this installer.
if [[ -z "$converge_script" ]]; then
  if [[ ! -e "$deploy_dir" ]]; then
    mkdir -p "$(dirname -- "$deploy_dir")"
    git clone --quiet --branch main --single-branch "$deploy_repo_url" "$deploy_dir"
    printf 'cloned main into %s\n' "$deploy_dir"
  fi
  converge_script="$deploy_dir/scripts/converge.sh"
fi

if [[ ! -f "$converge_script" ]]; then
  printf 'converge script not found: %s\n' "$converge_script" >&2
  printf 'until the deployment checkout contains scripts/converge.sh, pass --converge-script\n' >&2
  exit 1
fi

# launchd runs the job with cwd /, so a relative path would resolve nowhere at
# run time. Canonicalize now, while the caller's working directory is still known.
case "$converge_script" in
  /*) ;;
  *) converge_script="$(cd -- "$(dirname -- "$converge_script")" && pwd -P)/$(basename -- "$converge_script")" ;;
esac

if [[ ! -f "$template" ]]; then
  printf 'missing plist template: %s\n' "$template" >&2
  exit 1
fi

home_path="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
log_path="$state_dir/logs/launchd.log"
mkdir -p "$agent_dir" "$state_dir/logs"
chmod 700 "$state_dir" "$state_dir/logs"

rendered="$(mktemp "${TMPDIR:-/tmp}/converge-plist.XXXXXX")"
trap 'rm -f "$rendered"' EXIT

python3 - "$template" "$rendered" "$label" "$converge_script" "$interval" "$home_path" "$log_path" <<'PY'
import re
import sys
from xml.sax.saxutils import escape

template, out, label, script, interval, path, log = sys.argv[1:8]
values = {
    "__LABEL__": label,
    "__CONVERGE_SCRIPT__": script,
    "__INTERVAL__": interval,
    "__PATH__": path,
    "__LOG__": log,
}
text = open(template, encoding="utf-8").read()
for key, value in values.items():
    text = text.replace(key, escape(value))
# A placeholder the installer does not know about would ship literally.
leftover = re.findall(r"__[A-Z_]+__", text)
if leftover:
    raise SystemExit(f"unfilled placeholder(s) in the rendered plist: {sorted(set(leftover))}")
open(out, "w", encoding="utf-8").write(text)
PY

plutil -lint "$rendered" >/dev/null

if [[ -e "$target" ]] && ! is_managed "$target"; then
  printf 'refusing to overwrite unmanaged LaunchAgent: %s\n' "$target" >&2
  exit 1
fi

if cmp -s "$rendered" "$target" 2>/dev/null && is_loaded; then
  printf 'unchanged: %s is installed and loaded\n' "$label"
  exit 0
fi

# Probe the user domain before anything is booted out. If launchd cannot take a
# bootstrap here (no GUI session, for example), the running job is left alone.
if ! launchctl print "$domain" >/dev/null 2>&1; then
  printf 'launchd domain %s is not reachable from this session; nothing was changed.\n' "$domain" >&2
  printf 'run the installer from a logged-in GUI session\n' >&2
  exit 1
fi

tmp_target="$target.tmp.$$"
cp "$rendered" "$tmp_target"
chmod 644 "$tmp_target"
mv -f "$tmp_target" "$target"

# Bootout first so launchd reloads the job with the new plist. Bootstrap does not
# replace a loaded job with the same label.
#
# Failure recovery is chosen for simplicity: the new plist stays in place, because
# it is the desired state, and the job is not loaded. A failed bootstrap therefore
# exits non-zero with the exact command to run, and re-running this installer
# performs the same bootstrap. Nothing is left silently stopped.
launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
if ! launchctl bootstrap "$domain" "$target"; then
  printf 'launchctl bootstrap failed: %s is updated but the job is NOT loaded.\n' "$target" >&2
  printf 'recover with: launchctl bootstrap %s %s\n' "$domain" "$target" >&2
  printf 'or re-run this installer once the cause is fixed (see the launchctl message above).\n' >&2
  exit 1
fi

printf 'installed %s (StartInterval %ss, script %s)\n' "$target" "$interval" "$converge_script"
