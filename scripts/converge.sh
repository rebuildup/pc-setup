#!/usr/bin/env bash
# Converge this machine to the adopted state committed on origin/main (ADR-0016).
#
# Adoption (choosing new upstream versions) belongs to the GitHub Actions update
# train (ADR-0010). This script only consumes committed adopted state:
#   - it never runs `mise upgrade` or `mise lock`, and never resolves `latest`;
#   - mise is only asked to install the committed lock (`--locked`) through
#     scripts/apply-global-mise.sh, which lives in the deployment checkout.
#
# Exit codes:
#   0   every step converged
#   1   a step failed (see the status report)
#   3   converged except for steps skipped or pending (dirty checkout, PR #154)
#   75  another run holds the lock
set -euo pipefail

script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
script_dir="$(dirname -- "$script_path")"

deploy_dir="${PC_SETUP_DEPLOY_DIR:-$HOME/.local/share/pc-setup/deploy}"
deploy_repo_url="${PC_SETUP_REPO_URL:-https://github.com/rebuildup/pc-setup.git}"
dotfiles_dir="${DOTFILES_DIR:-$HOME/.dotfiles}"
state_dir="${PC_SETUP_STATE_DIR:-$HOME/.local/state/pc-setup}"
converge_dir="$state_dir/converge"
lock_dir="$state_dir/converge.lock"
steps_file="$converge_dir/steps.tsv"
run_file="$converge_dir/run.env"
log_dir="$state_dir/logs"
mise_config_path="$HOME/.config/mise/config.toml"

log_file="${PC_SETUP_CONVERGE_LOG:-$log_dir/converge-$(date -u +%Y%m%dT%H%M%SZ)-$$.log}"
deploy_ok="${PC_SETUP_CONVERGE_DEPLOY_OK:-0}"

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# record <step> <ok|skipped|error|fail|pending> <detail>
# Detail strings are authored here. Raw tool output stays in the log file.
record() {
  local step="$1" status="$2" detail="${3//$'\t'/ }"
  detail="${detail//$'\n'/ }"
  printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$step" "$status" "$detail" >>"$steps_file"
  printf '%-16s %-8s %s\n' "$step" "$status" "$detail"
}

lock_owner() {
  cat "$lock_dir/pid" 2>/dev/null || true
}

# mkdir is atomic on every platform we run on, and macOS has no flock(1).
# A lock whose owner pid is gone is stale. It is moved aside before removal so a
# concurrent reclaimer cannot delete a lock that was just re-acquired.
acquire_lock() {
  mkdir -p "$state_dir"
  local attempt owner
  for attempt in 1 2 3; do
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$$" >"$lock_dir/pid"
      return 0
    fi
    owner="$(lock_owner)"
    if [[ -z "$owner" ]]; then
      # The holder may have created the directory and not yet written its pid.
      sleep 2
      owner="$(lock_owner)"
    fi
    # exec keeps the pid, so the re-executed deployed copy finds its own lock.
    if [[ -n "$owner" && "$owner" == "$$" ]]; then
      return 0
    fi
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
      printf 'another converge run holds the lock (pid %s)\n' "$owner" >&2
      return 75
    fi
    mv "$lock_dir" "$lock_dir.stale.$$.$attempt" 2>/dev/null || true
    rm -rf "$lock_dir.stale.$$.$attempt"
  done
  printf 'could not acquire converge lock: %s\n' "$lock_dir" >&2
  return 75
}

release_lock() {
  if [[ "$(lock_owner)" == "$$" ]]; then
    rm -rf "$lock_dir"
  fi
}

# Runs on every exit, including failures, so the status report always reflects
# the last attempt. The exit code of the script is preserved.
finish_run() {
  local rc=$?
  trap - EXIT
  printf 'finished=%s\nexit=%s\n' "$(now_iso)" "$rc" >>"$run_file"
  "$script_dir/converge-status.sh" --write >>"$log_file" 2>&1 || true
  release_lock
  exit "$rc"
}

sync_deploy() {
  if [[ ! -e "$deploy_dir" ]]; then
    mkdir -p "$(dirname -- "$deploy_dir")"
    if git clone --quiet --branch main --single-branch "$deploy_repo_url" "$deploy_dir" >>"$log_file" 2>&1; then
      deploy_ok=1
      record deploy-sync ok "cloned main at $(git -C "$deploy_dir" rev-parse --short HEAD)"
    else
      record deploy-sync error "clone of $deploy_repo_url failed"
    fi
    return 0
  fi

  if [[ ! -d "$deploy_dir/.git" ]]; then
    record deploy-sync error "$deploy_dir exists and is not a git checkout"
    return 0
  fi

  local origin branch before after
  origin="$(git -C "$deploy_dir" remote get-url origin 2>/dev/null || true)"
  if [[ "$origin" != "$deploy_repo_url" ]]; then
    record deploy-sync error "origin is '$origin', expected $deploy_repo_url"
    return 0
  fi

  branch="$(git -C "$deploy_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ "$branch" != main ]]; then
    record deploy-sync error "deploy checkout is on '${branch:-detached HEAD}', expected main"
    return 0
  fi

  # Refuse rather than reset or stash: local edits in the deployment checkout
  # are someone's work, and converge must never discard them.
  if [[ -n "$(git -C "$deploy_dir" status --porcelain)" ]]; then
    record deploy-sync skipped "deploy checkout has local changes; not updated and dependent steps skipped"
    return 0
  fi

  if ! git -C "$deploy_dir" fetch --quiet origin main >>"$log_file" 2>&1; then
    record deploy-sync error "fetch of origin/main failed"
    return 0
  fi

  before="$(git -C "$deploy_dir" rev-parse HEAD)"
  if ! git -C "$deploy_dir" merge --quiet --ff-only origin/main >>"$log_file" 2>&1; then
    record deploy-sync error "main cannot fast-forward to origin/main"
    return 0
  fi
  after="$(git -C "$deploy_dir" rev-parse HEAD)"

  deploy_ok=1
  if [[ "$before" == "$after" ]]; then
    record deploy-sync ok "main at ${after:0:12}, no change"
  else
    record deploy-sync ok "main ${before:0:12} -> ${after:0:12}"
  fi
}

# Hand over to the deployed copy of this script after the sync, so a converge.sh
# that just arrived from origin/main is the one that runs the remaining steps.
# Bash reads a script incrementally; replacing the file under a running script is
# not safe. exec keeps the pid, so the lock held by this run stays valid.
reexec_deployed_copy() {
  local deployed="$deploy_dir/scripts/converge.sh"
  [[ "$deploy_ok" == 1 && -f "$deployed" ]] || return 0
  local deployed_real
  deployed_real="$(cd -- "$(dirname -- "$deployed")" && pwd -P)/converge.sh"
  if [[ "$deployed_real" == "$script_path" ]]; then
    return 0
  fi
  export PC_SETUP_CONVERGE_REEXEC=1
  export PC_SETUP_CONVERGE_DEPLOY_OK=1
  export PC_SETUP_CONVERGE_LOG="$log_file"
  exec bash "$deployed" "$@"
}

apply_mise() {
  if [[ "$deploy_ok" != 1 ]]; then
    record mise-apply skipped "deploy checkout not converged in this run"
    return 0
  fi

  local previous_target="" rc=0 lock_before="" lock_after=""
  previous_target="$(readlink "$mise_config_path" 2>/dev/null || true)"
  lock_before="$(git -C "$deploy_dir" hash-object mise.global.lock 2>/dev/null || true)"

  # apply-global-mise.sh runs one unlocked `mise install gh` before its auth check.
  # Without MISE_LOCKED=1, mise writes lock-time provenance into the linked
  # mise.global.lock (observed: ~650 added lines in the deployment checkout).
  # MISE_LOCKED=1 keeps that write from happening. The lock hash is compared
  # afterwards as a safety net; the script reports a change and never restores it.
  #
  # apply-global-mise.sh links the config into the deployment checkout and then
  # runs `mise install --locked`. A failed install is not rolled back: mise
  # installs are additive, the previous versions stay on disk, and the status
  # report lists what is missing. Rolling the link back would reintroduce the
  # dirty work checkout that this step exists to remove.
  if MISE_LOCKED=1 "$deploy_dir/scripts/apply-global-mise.sh" >>"$log_file" 2>&1; then
    if grep -Fq 'using committed mise global lock' "$log_file"; then
      record mise-apply ok "config linked to deploy checkout; locked install ok"
    else
      record mise-apply ok "config linked to deploy checkout; install ok without a committed lock"
    fi
  else
    rc=$?
    record mise-apply error "apply-global-mise.sh exited $rc; see $log_file"
  fi

  lock_after="$(git -C "$deploy_dir" hash-object mise.global.lock 2>/dev/null || true)"
  if [[ "$lock_before" != "$lock_after" ]]; then
    record adopted-lock error "apply changed the adopted mise.global.lock in the deploy checkout; not restored automatically, review with git -C $deploy_dir diff"
  fi

  # Known caveat (ADR-0016): npm:@deepseek-ai/dsh exists only in unmerged PR #154.
  if [[ -n "$previous_target" && -f "$previous_target" ]] \
    && grep -Fq 'deepseek-ai/dsh' "$previous_target" \
    && ! grep -Fq 'deepseek-ai/dsh' "$deploy_dir/mise.global.toml"; then
    record dsh-declaration pending "npm:@deepseek-ai/dsh is declared only in unmerged PR #154; dsh is no longer managed by main"
  fi
}

sync_dotfiles() {
  if [[ -d "$dotfiles_dir/.git" && -n "$(git -C "$dotfiles_dir" status --porcelain 2>/dev/null)" ]]; then
    record dotfiles-sync skipped "$dotfiles_dir has local changes; sync and link skipped"
    return 0
  fi

  if [[ "$deploy_ok" != 1 ]]; then
    record dotfiles-sync skipped "deploy checkout not converged in this run; sync and link skipped"
    return 0
  fi

  local rc=0
  if DOTFILES_DIR="$dotfiles_dir" "$deploy_dir/scripts/sync-dotfiles.sh" >>"$log_file" 2>&1; then
    record dotfiles-sync ok "synced $dotfiles_dir"
  else
    rc=$?
    record dotfiles-sync error "sync-dotfiles.sh exited $rc; see $log_file"
    return 0
  fi

  if [[ -x "$dotfiles_dir/script/link" ]]; then
    if "$dotfiles_dir/script/link" >>"$log_file" 2>&1; then
      record dotfiles-link ok "script/link is idempotent and reported success"
    else
      rc=$?
      record dotfiles-link error "script/link exited $rc; see $log_file"
    fi
  else
    record dotfiles-link error "$dotfiles_dir/script/link is missing or not executable"
  fi
}

run_verify() {
  if [[ "$deploy_ok" != 1 ]]; then
    record verify skipped "deploy checkout not converged in this run"
    return 0
  fi

  local verify_script=""
  case "$(uname -s)" in
    Darwin) verify_script="$deploy_dir/platforms/macos/verify.sh" ;;
  esac

  if [[ -z "$verify_script" || ! -f "$verify_script" ]]; then
    record verify skipped "no verify script for $(uname -s) in the deploy checkout"
    return 0
  fi

  # verify checks tools by name (rustc, cargo, ...), which only resolve inside the
  # mise environment. A bare LaunchAgent has a fixed PATH without mise shims, so
  # verify runs under `mise exec`. Missing mise is a documented skip, not a failure.
  # MISE_EXEC_AUTO_INSTALL=0 keeps verify from installing anything: a missing tool
  # shows up as a verify failure instead of a silent install.
  if ! command -v mise >/dev/null 2>&1; then
    record verify skipped "mise not found on PATH; verify not run"
    return 0
  fi

  # stdin is closed so a sudo prompt fails instead of hanging a background run.
  local rc=0
  if MISE_EXEC_AUTO_INSTALL=0 mise -C "$HOME" exec -- bash "$verify_script" </dev/null >>"$log_file" 2>&1; then
    record verify ok "verify passed (inside mise exec)"
  else
    rc=$?
    record verify fail "verify exited $rc under mise exec; see $log_file"
  fi
}

exit_code_from_steps() {
  if grep -Eq $'\t(error|fail)\t' "$steps_file"; then
    return 1
  fi
  if grep -Eq $'\t(skipped|pending)\t' "$steps_file"; then
    return 3
  fi
  return 0
}

main() {
  mkdir -p "$converge_dir" "$log_dir"
  chmod 700 "$state_dir" 2>/dev/null || true

  acquire_lock
  trap finish_run EXIT

  if [[ "${PC_SETUP_CONVERGE_REEXEC:-0}" == 1 ]]; then
    # The parent run already synced and wrote its steps; continue the same run.
    printf 'continuing run in deployed copy of converge.sh\n'
  else
    : >"$steps_file"
    printf 'started=%s\nlog=%s\nscript=%s\n' "$(now_iso)" "$log_file" "$script_path" >"$run_file"
    sync_deploy
    reexec_deployed_copy "$@"
  fi

  apply_mise
  sync_dotfiles
  run_verify

  local rc=0
  exit_code_from_steps || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    printf 'converge finished: all steps ok\n'
  else
    printf 'converge finished with exit %s; see status report\n' "$rc"
    exit "$rc"
  fi
}

main "$@"
