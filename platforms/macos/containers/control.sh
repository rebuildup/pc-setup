#!/usr/bin/env bash
# Day-to-day Colima operations for people and coding agents.
#
#   control.sh start     start the VM with its stored configuration
#   control.sh stop      stop the VM (containers and data stay on disk)
#   control.sh status    VM state, Docker context and whether docker works
#
# The VM is not meant to run permanently; starting and stopping it on demand is
# the normal workflow. No LaunchDaemon is created for it.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Colima control must run on macOS.\n' >&2
  exit 1
fi

profile="${PC_SETUP_COLIMA_PROFILE:-default}"

log() {
  printf '==> %s\n' "$*"
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

if ! command -v colima >/dev/null 2>&1; then
  fail "colima is not installed; run 'mise bootstrap packages apply' first"
fi

vm_exists() {
  colima list 2>/dev/null | awk -v p="$profile" '$1 == p { found = 1 } END { exit !found }'
}

require_vm() {
  if ! vm_exists; then
    fail "no Colima VM '$profile'; create it with: platforms/macos/containers/install.sh"
  fi
}

case "${1:-status}" in
  start)
    require_vm
    log "Starting Colima VM '$profile'"
    colima start -p "$profile" ||
      fail "colima start failed; see 'colima status -p $profile'"
    docker info >/dev/null 2>&1 ||
      fail "colima started but docker cannot reach the daemon; check 'colima status -p $profile'"
    log "Docker is reachable through context '$(docker context show)'"
    ;;
  stop)
    require_vm
    log "Stopping Colima VM '$profile'"
    colima stop -p "$profile" ||
      fail "colima stop failed; see 'colima status -p $profile'"
    log "VM stopped; stored images and volumes are kept on disk"
    ;;
  status)
    if ! vm_exists; then
      printf 'colima VM %s: not provisioned (run platforms/macos/containers/install.sh)\n' "$profile"
      exit 1
    fi
    colima status -p "$profile" || true
    printf 'docker context: %s\n' "$(docker context show 2>/dev/null || printf 'none')"
    if docker info >/dev/null 2>&1; then
      printf 'docker daemon: reachable\n'
      docker version --format 'client {{.Client.Version}} / server {{.Server.Version}}' 2>/dev/null || true
      if docker compose version >/dev/null 2>&1; then
        printf 'compose: available\n'
      else
        printf 'compose: plugin missing\n'
      fi
      if docker buildx version >/dev/null 2>&1; then
        printf 'buildx: available\n'
      else
        printf 'buildx: plugin missing\n'
      fi
    else
      printf 'docker daemon: unreachable (VM is stopped)\n'
      printf 'start it with: platforms/macos/containers/control.sh start\n'
    fi
    ;;
  *)
    printf 'usage: %s start|stop|status\n' "$0" >&2
    exit 2
    ;;
esac
