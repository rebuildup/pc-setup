#!/usr/bin/env bash
# Verify the macOS container runtime without changing it.
#
# The script never starts, stops, resizes or re-creates the VM: a stopped VM is
# reported as "provisioned but stopped", which is a different outcome from
# "not provisioned" and does not fail the run. Add --smoke to also run a
# throwaway container, which needs the VM running and network access to a
# registry.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'macOS container verification must run on macOS.\n' >&2
  exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
global_config="$repo_root/mise.global.toml"
profile="${PC_SETUP_COLIMA_PROFILE:-default}"
smoke=0

for arg in "$@"; do
  case "$arg" in
    --smoke) smoke=1 ;;
    *)
      printf 'usage: %s [--smoke]\n' "$0" >&2
      exit 2
      ;;
  esac
done

failures=0
warnings=0

ok() {
  printf 'ok      %s\n' "$*"
}

warn() {
  warnings=$((warnings + 1))
  printf 'WARN    %s\n' "$*"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL    %s\n' "$*" >&2
}

skip() {
  printf 'skip    %s\n' "$*"
}

# --- mise configuration ----------------------------------------------------

if ! command -v mise >/dev/null 2>&1; then
  fail 'mise is not installed; it owns the machine-wide tool and package config'
elif ! mise -C "$HOME" config >/dev/null 2>&1; then
  fail 'mise cannot read the machine-wide configuration'
else
  ok 'mise reads the machine-wide configuration'
fi

# Every package declared in the global config must be active on this host. A
# package restricted to another OS drops out of this list, so a wrong or missing
# `os` condition shows up here instead of silently installing on every machine.
if command -v mise >/dev/null 2>&1 && [[ -f "$global_config" ]]; then
  declared="$(
    awk '
      /^\[bootstrap\.packages\]/ { in_section = 1; next }
      /^\[/ { in_section = 0 }
      in_section && /^"/ { sub(/^[^"]*"/, ""); sub(/".*/, ""); print }
    ' "$global_config"
  )"
  active="$(
    mise -C "$HOME" bootstrap packages status 2>/dev/null |
      awk 'NF >= 2 { print $1 ":" $2 }'
  )"

  if [[ -z "$declared" ]]; then
    fail 'mise.global.toml declares no [bootstrap.packages]'
  else
    missing=""
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      if ! grep -Fxq "$key" <<<"$active"; then
        missing="$missing $key"
      fi
    done <<<"$declared"

    if [[ -n "$missing" ]]; then
      fail "macOS bootstrap packages not active on this host:$missing"
    else
      ok 'declared macOS bootstrap packages are active here'
    fi
  fi

  if grep -Fq 'docker-desktop' "$global_config"; then
    fail 'mise.global.toml must not declare Docker Desktop; containers use Colima'
  else
    ok 'Docker Desktop is not part of the declared package set'
  fi
fi

# --- required commands -----------------------------------------------------

for command_name in colima docker ffmpeg; do
  if command -v "$command_name" >/dev/null 2>&1; then
    ok "$command_name found at $(command -v "$command_name")"
  else
    fail "$command_name is not installed"
  fi
done

# --- Docker CLI plugins and context (client side, no daemon needed) --------

if command -v docker >/dev/null 2>&1; then
  if compose_version="$(docker compose version 2>/dev/null)"; then
    ok "compose plugin: $compose_version"
  else
    fail 'docker does not recognize the compose plugin'
  fi

  if buildx_version="$(docker buildx version 2>/dev/null)"; then
    ok "buildx plugin: $buildx_version"
  else
    fail 'docker does not recognize the buildx plugin'
  fi

  if docker context ls --format '{{.Name}}' 2>/dev/null | grep -Fxq "$profile"; then
    ok "docker context '$profile' exists (current: $(docker context show 2>/dev/null || printf 'unknown'))"
  else
    fail "docker context '$profile' is missing"
  fi

  # A Docker Desktop uninstall removes docker-credential-osxkeychain but leaves
  # `credsStore` in ~/.docker/config.json, after which every registry pull dies
  # with "error getting credentials".
  docker_config="$HOME/.docker/config.json"
  creds_store=""
  if [[ -f "$docker_config" ]]; then
    creds_store="$(sed -n 's/.*"credsStore"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$docker_config" | head -n 1)"
  fi
  if [[ -z "$creds_store" ]]; then
    ok 'no credential helper is configured; registry pulls work without one'
  elif command -v "docker-credential-$creds_store" >/dev/null 2>&1; then
    ok "credential helper docker-credential-$creds_store is available"
  else
    fail "credential helper docker-credential-$creds_store is missing, so 'docker pull' fails (brew:docker-credential-helper provides it)"
  fi
fi

# --- Colima VM -------------------------------------------------------------

vm_status=""
vm_cpus=""
vm_memory=""
vm_disk=""
vm_arch=""
vm_runtime=""

if command -v colima >/dev/null 2>&1; then
  row="$(colima list 2>/dev/null | awk -v p="$profile" '$1 == p { print; exit }')"
  if [[ -z "$row" ]]; then
    fail "Colima VM '$profile' is not provisioned (run platforms/macos/containers/install.sh)"
  else
    # colima list columns: PROFILE STATUS ARCH CPUS MEMORY DISK RUNTIME
    read -r _ vm_status vm_arch vm_cpus vm_memory vm_disk vm_runtime <<<"$row"

    case "$(uname -m)" in
      arm64) host_arch="aarch64" ;;
      *) host_arch="$(uname -m)" ;;
    esac

    if [[ "$vm_runtime" == "docker" ]]; then
      ok "VM runtime is docker"
    else
      fail "VM runtime is '$vm_runtime', expected docker"
    fi

    if [[ "$vm_arch" == "$host_arch" ]]; then
      ok "VM architecture matches the host ($vm_arch)"
    else
      fail "VM architecture is '$vm_arch', expected '$host_arch' for this host"
    fi

    desired_cpus="${PC_SETUP_COLIMA_CPUS:-4}"
    desired_memory="${PC_SETUP_COLIMA_MEMORY:-4}GiB"
    desired_disk="${PC_SETUP_COLIMA_DISK:-60}GiB"

    if [[ "$vm_cpus" != "$desired_cpus" || "$vm_memory" != "$desired_memory" || "$vm_disk" != "$desired_disk" ]]; then
      warn "VM sizing is ${vm_cpus}CPU / $vm_memory / $vm_disk, desired ${desired_cpus}CPU / $desired_memory / $desired_disk (change only if intended: colima start --cpus N --memory N --disk N)"
    else
      ok "VM sizing matches the desired ${desired_cpus}CPU / $desired_memory / $desired_disk"
    fi

    colima_config="$HOME/.colima/$profile/colima.yaml"
    if [[ -f "$colima_config" ]]; then
      if grep -Eq '^vmType:[[:space:]]*vz[[:space:]]*$' "$colima_config" &&
        grep -Eq '^mountType:[[:space:]]*virtiofs[[:space:]]*$' "$colima_config"; then
        ok 'VM uses Apple Virtualization.framework with VirtioFS mounts'
      else
        warn "VM uses a different vmType/mountType than vz/virtiofs (see $colima_config); changing it needs a new VM"
      fi
    else
      warn "cannot read $colima_config to confirm vmType/mountType"
    fi
  fi
fi

# --- daemon-dependent checks ----------------------------------------------

if [[ "$vm_status" == "Running" ]]; then
  if docker info >/dev/null 2>&1; then
    ok 'docker daemon is reachable'
  else
    fail 'docker daemon is unreachable although the VM reports Running'
  fi

  if [[ "$smoke" -eq 1 ]]; then
    if docker run --rm hello-world >/dev/null 2>&1; then
      ok 'smoke test: hello-world container ran'
    else
      fail 'smoke test: docker run --rm hello-world failed'
    fi
  else
    skip 'container smoke test (opt in with --smoke; it pulls from Docker Hub)'
  fi
elif [[ -n "$vm_status" ]]; then
  printf 'notice  Colima VM %s is provisioned but stopped.\n' "$profile"
  printf '        The environment is built; only runtime checks are skipped.\n'
  printf '        Start it with: platforms/macos/containers/control.sh start\n'
  if [[ "$smoke" -eq 1 ]]; then
    fail '--smoke requires the VM to be running'
  else
    skip 'docker daemon and container checks (VM stopped)'
  fi
fi

# --- summary ---------------------------------------------------------------

if [[ "$failures" -gt 0 ]]; then
  printf '\nmacOS container verification failed: %s failure(s), %s warning(s).\n' \
    "$failures" "$warnings" >&2
  exit 1
fi

if [[ "$vm_status" == "Running" ]]; then
  printf '\nmacOS container verification passed (%s warning(s)).\n' "$warnings"
else
  printf '\nmacOS container verification passed with the VM stopped (%s warning(s)).\n' "$warnings"
fi
