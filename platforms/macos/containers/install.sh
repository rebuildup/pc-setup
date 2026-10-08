#!/usr/bin/env bash
# Converge the macOS container runtime: Docker CLI plugins, the Colima Docker
# Context and the Colima VM itself.
#
# Rerunning is safe. An existing VM is inspected and reported, never deleted,
# re-created, resized or started behind the user's back; only a missing VM is
# created, because creating one is the only way to express its initial shape.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Colima setup must run on macOS.\n' >&2
  exit 1
fi

profile="${PC_SETUP_COLIMA_PROFILE:-default}"
plugin_dir="${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins"

log() {
  printf '==> %s\n' "$*"
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required command: $1 (run 'mise bootstrap' so the macOS packages are installed)"
  fi
}

# Desired VM shape. Override the numbers instead of editing the script; the
# defaults come from the machine this repository was set up on and stay inside
# what the host can actually offer.
desired_cpus="${PC_SETUP_COLIMA_CPUS:-4}"
desired_memory_gib="${PC_SETUP_COLIMA_MEMORY:-4}"
desired_disk_gib="${PC_SETUP_COLIMA_DISK:-60}"

for value in "$desired_cpus" "$desired_memory_gib" "$desired_disk_gib"; do
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    fail "PC_SETUP_COLIMA_CPUS / MEMORY / DISK must be positive integers, got: $value"
  fi
done

# colima names the architectures differently from uname: an Apple Silicon host
# is `arm64` to macOS and `aarch64` to the VM.
case "$(uname -m)" in
  arm64) host_arch="aarch64" ;;
  *) host_arch="$(uname -m)" ;;
esac

host_cpus="$(sysctl -n hw.ncpu 2>/dev/null || printf '1')"
host_memory_gib="$(($(sysctl -n hw.memsize 2>/dev/null || printf '0') / 1024 / 1024 / 1024))"

if [[ "$desired_cpus" -gt "$host_cpus" ]]; then
  desired_cpus="$host_cpus"
fi
# Leaving the host starved makes the VM useless rather than fast: keep at least
# half of a small machine's memory for macOS itself.
if [[ "$host_memory_gib" -ne 0 && "$host_memory_gib" -lt 8 && "$desired_memory_gib" -ge "$host_memory_gib" ]]; then
  desired_memory_gib=$((host_memory_gib / 2))
fi

require_command colima
require_command docker
require_command mise

# mise owns the package graph, so ask it where a formula lives before falling
# back to whatever is on PATH. This keeps Apple Silicon and Intel Homebrew
# prefixes on one code path instead of hard-coding either of them.
formula_root() {
  local root=""
  if root="$(mise bootstrap packages where "brew:$1" 2>/dev/null)" && [[ -n "$root" && -x "$root/bin/$2" ]]; then
    printf '%s\n' "$root/bin/$2"
    return 0
  fi
  return 1
}

resolve_binary() {
  local candidate=""
  if candidate="$(formula_root "$1" "$2")"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if candidate="$(command -v "$2" 2>/dev/null)" && [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [[ -n "${HOMEBREW_PREFIX:-}" && -x "$HOMEBREW_PREFIX/bin/$2" ]]; then
    printf '%s\n' "$HOMEBREW_PREFIX/bin/$2"
    return 0
  fi
  return 1
}

link_plugin() {
  local formula="$1"
  local name="$2"
  local source=""
  local target="$plugin_dir/$name"

  source="$(resolve_binary "$formula" "$name")" ||
    fail "cannot locate $formula ($name); install the macOS packages with 'mise bootstrap packages apply'"

  mkdir -p "$plugin_dir"

  if [[ -L "$target" ]]; then
    if [[ -x "$target" ]]; then
      log "plugin   $name already linked ($(readlink "$target"))"
      return 0
    fi
    log "plugin   $name link is broken, relinking"
    rm -f "$target"
  elif [[ -e "$target" ]]; then
    # A real file usually means another Docker distribution owns this path. It
    # works, so leave it in place rather than fighting over it.
    if [[ -x "$target" ]]; then
      log "plugin   $name already present as a file, leaving it alone"
      return 0
    fi
    fail "$target exists but is not executable; resolve it manually before rerunning"
  fi

  ln -s "$source" "$target"
  log "plugin   linked $target -> $source"
}

log "Checking Docker CLI plugins"
link_plugin docker-compose docker-compose
link_plugin docker-buildx docker-buildx

docker compose version >/dev/null || fail "docker does not recognize the compose plugin"
docker buildx version >/dev/null || fail "docker does not recognize the buildx plugin"
log "compose  $(docker compose version)"
log "buildx   $(docker buildx version)"

# Existing VM handling. Nothing below edits, restarts or removes a VM that is
# already there; a mismatch is reported so the operator decides whether it is
# worth changing.
vm_state() {
  # Prints: status cpus memory_bytes disk_bytes arch runtime, or nothing when the
  # profile has never been created.
  local row=""
  row="$(colima list 2>/dev/null | awk -v p="$profile" '$1 == p { print; exit }')"
  if [[ -z "$row" ]]; then
    return 1
  fi
  printf '%s\n' "$row" | awk '{ print $2, $4, $5, $6, $3, $7 }'
}

report_config() {
  local cpus="$1"
  local memory="$2"
  local disk="$3"
  local arch="$4"
  local runtime="$5"

  if [[ "$runtime" != "docker" || "$arch" != "$host_arch" ]]; then
    printf 'existing VM %s has runtime=%s arch=%s; docker runtime and host arch are required.\n' \
      "$profile" "$runtime" "$arch" >&2
    printf 'Changing them needs a new VM, which this script never does. Decide manually.\n' >&2
    return 1
  fi

  if [[ "$cpus" -ne "$desired_cpus" || "$memory" != "${desired_memory_gib}GiB" || "$disk" != "${desired_disk_gib}GiB" ]]; then
    log "note     VM runs with ${cpus}CPU / $memory / $disk, desired ${desired_cpus}CPU / ${desired_memory_gib}GiB / ${desired_disk_gib}GiB"
    log "note     leaving it untouched; adjust with: colima start -p $profile --cpus N --memory N --disk N"
  fi
  return 0
}

if ! vm_values="$(vm_state)"; then
  log "No Colima VM '$profile' found, creating it"
  colima start -p "$profile" \
    --runtime docker \
    --vm-type vz \
    --mount-type virtiofs \
    --cpus "$desired_cpus" \
    --memory "$desired_memory_gib" \
    --disk "$desired_disk_gib" ||
    fail "colima start failed; the VM was not created"
  vm_values="$(vm_state)" || fail "colima reported success but profile '$profile' is still missing"
  log "VM       created ($vm_values)"
else
  read -r vm_status vm_cpus vm_memory vm_disk vm_arch vm_runtime <<<"$vm_values"
  report_config "$vm_cpus" "$vm_memory" "$vm_disk" "$vm_arch" "$vm_runtime"
  if [[ "$vm_status" == "Running" ]]; then
    log "VM       $profile already running ($vm_cpus CPU / $vm_memory / $vm_disk)"
  else
    log "VM       $profile exists but is stopped; start it with: platforms/macos/containers/control.sh start"
  fi
fi

if ! docker context ls --format '{{.Name}}' 2>/dev/null | grep -Fxq "$profile"; then
  fail "docker context '$profile' is missing; 'colima start' registers it, rerun after starting the VM"
fi
log "context  '$profile' available ($(docker context ls --format '{{.Name}}' | tr '\n' ' '))"

# A Docker Desktop uninstall takes docker-credential-osxkeychain with it but
# leaves `credsStore` behind, and every `docker pull` then fails with "error
# getting credentials". Report it; installing packages is not this script's job.
docker_config="$HOME/.docker/config.json"
if [[ -f "$docker_config" ]]; then
  creds_store="$(sed -n 's/.*"credsStore"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$docker_config" | head -n 1)"
  if [[ -n "$creds_store" ]] && ! command -v "docker-credential-$creds_store" >/dev/null 2>&1; then
    log "warn     credential helper docker-credential-$creds_store is missing; 'docker pull' will fail"
    log "warn     run 'mise bootstrap packages apply' (brew:docker-credential-helper provides it)"
  fi
fi

log "Colima container runtime is set up"
