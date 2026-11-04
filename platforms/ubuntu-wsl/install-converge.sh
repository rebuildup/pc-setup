#!/usr/bin/env bash
# Install, refresh, or remove the systemd USER timer that runs scripts/converge.sh
# from the deployment checkout (ADR-0016). Same interface as
# platforms/macos/install-converge.sh.
#
#   install-converge.sh                      install or refresh (idempotent)
#   install-converge.sh --uninstall          disable and remove the units
#   install-converge.sh --converge-script P  run P instead of the deployment copy
#   install-converge.sh --interval SECONDS   OnUnitActiveSec (default 3600)
#
# Lingering is NOT enabled by this script. Enabling it needs privileges, so it is
# a manual step (see the message printed at install time). Without linger the
# timer runs only while the systemd user manager is running, which on WSL2 means
# while a distro session is open.
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  printf 'platforms/ubuntu-wsl/install-converge.sh is for Linux (WSL2) only.\n' >&2
  exit 1
fi

marker="managed-by: rebuildup/pc-setup platforms/ubuntu-wsl/install-converge.sh"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
template_dir="$repo_root/platforms/ubuntu-wsl"
deploy_dir="${PC_SETUP_DEPLOY_DIR:-$HOME/.local/share/pc-setup/deploy}"
deploy_repo_url="${PC_SETUP_REPO_URL:-https://github.com/rebuildup/pc-setup.git}"
state_dir="${PC_SETUP_STATE_DIR:-$HOME/.local/state/pc-setup}"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
service_name="pc-setup-converge.service"
timer_name="pc-setup-converge.timer"

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

if ! [[ "$interval" =~ ^[1-9][0-9]*$ ]]; then
  printf '--interval must be a positive integer: %s\n' "$interval" >&2
  exit 2
fi

if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
  printf 'systemd user manager is not reachable. On WSL2 enable [boot] systemd=true in /etc/wsl.conf and restart WSL.\n' >&2
  exit 1
fi

is_managed() {
  [[ -f "$1" ]] && grep -Fq "$marker" "$1"
}

if [[ "$uninstall" == 1 ]]; then
  systemctl --user disable --now "$timer_name" >/dev/null 2>&1 || true
  for name in "$service_name" "$timer_name"; do
    target="$unit_dir/$name"
    if [[ -e "$target" ]]; then
      if ! is_managed "$target"; then
        printf 'refusing to remove unmanaged unit: %s\n' "$target" >&2
        exit 1
      fi
      rm -f "$target"
      printf 'removed %s\n' "$target"
    fi
  done
  systemctl --user daemon-reload
  exit 0
fi

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

# systemd quotes values inside double quotes; reject characters that would break
# the quoting rather than trying to escape them.
case "$converge_script" in
  *'"'*|*\\*|*$'\n'*) printf 'converge script path contains a quote, backslash, or newline: %s\n' "$converge_script" >&2; exit 1 ;;
esac

path_value="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$unit_dir" "$state_dir/logs"
chmod 700 "$state_dir" "$state_dir/logs"

render() {
  # render <template> <output>
  python3 - "$1" "$2" "$converge_script" "$path_value" "$interval" <<'PY'
import sys

template, out, script, path, interval = sys.argv[1:6]
text = open(template, encoding="utf-8").read()
for key, value in {
    "__CONVERGE_SCRIPT__": script,
    "__PATH__": path,
    "__INTERVAL__": interval,
}.items():
    text = text.replace(key, value)
open(out, "w", encoding="utf-8").write(text)
PY
}

rendered_dir="$(mktemp -d "${TMPDIR:-/tmp}/converge-units.XXXXXX")"
trap 'rm -rf "$rendered_dir"' EXIT
render "$template_dir/pc-setup-converge.service.in" "$rendered_dir/$service_name"
render "$template_dir/pc-setup-converge.timer.in" "$rendered_dir/$timer_name"

for name in "$service_name" "$timer_name"; do
  if [[ -e "$unit_dir/$name" ]] && ! is_managed "$unit_dir/$name"; then
    printf 'refusing to overwrite unmanaged unit: %s\n' "$unit_dir/$name" >&2
    exit 1
  fi
done

changed=0
for name in "$service_name" "$timer_name"; do
  if ! cmp -s "$rendered_dir/$name" "$unit_dir/$name" 2>/dev/null; then
    cp "$rendered_dir/$name" "$unit_dir/$name.tmp.$$"
    chmod 644 "$unit_dir/$name.tmp.$$"
    mv -f "$unit_dir/$name.tmp.$$" "$unit_dir/$name"
    changed=1
  fi
done

systemctl --user daemon-reload
if systemctl --user is-enabled "$timer_name" >/dev/null 2>&1; then
  if [[ "$changed" == 1 ]]; then
    systemctl --user restart "$timer_name"
    printf 'refreshed %s\n' "$timer_name"
  else
    printf 'unchanged: %s is installed and enabled\n' "$timer_name"
  fi
else
  systemctl --user enable --now "$timer_name"
  printf 'enabled %s\n' "$timer_name"
fi

printf 'installed %s and %s in %s (interval %ss, script %s)\n' \
  "$service_name" "$timer_name" "$unit_dir" "$interval" "$converge_script"
printf 'linger: not enabled by this script. To run while no session is open, a privileged user runs:\n'
printf '  sudo loginctl enable-linger %s\n' "$USER"
