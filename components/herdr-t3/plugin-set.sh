#!/usr/bin/env bash
# Install the pinned rebuildup/herdr-plugins set used by herdr-t3
# (pc-setup#239, rebuildup/herdr-t3#358).
#
# The six plugins and their full commit SHAs mirror the contract pins in
# rebuildup/herdr-t3 `docs/migration/contracts/plugins-boundary.md`
# @ release-0-6-0 (inbox v0.1.0, git v0.2.0, projects v0.3.0,
# checkpoints v0.4.0, automations v0.7.0, conversations v0.5.0) — the
# full set shipped by herdr-t3 v0.6.0. Each
# plugin installs independently through the official
# `herdr plugin install --ref <sha>` path; state lives under herdr's own
# plugin directories, so reinstalling never loses organize state.
#
# Idempotent: a plugin already installed at the pinned commit is skipped;
# a different commit is re-installed at the pin. `--check` only reports.
#
# Prerequisites: `herdr` on PATH (herdr >= 0.9.0) and `bun` on PATH —
# plugin manifest commands run `bun run`.
#
# Usage: plugin-set.sh [--check]
set -euo pipefail

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

log() { printf '[herdr-t3 plugins] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

command -v herdr >/dev/null 2>&1 || die "herdr not found on PATH"
command -v bun >/dev/null 2>&1 || die "bun not found on PATH (plugin commands run 'bun run')"

# name|full commit SHA — keep in sync with plugins-boundary.md.
PLUGINS=(
  "inbox|414e87dea9faa5c221fb27508e5828f086849836"
  "git|d0578307a856e53af210775f9cb95c9f593d6f87"
  "projects|2dcb2abfa57b0adcf5d1109f76087e19b3dfae07"
  "checkpoints|ae4f214c523d05128354a8c4ba493b62cd8e843f"
  "automations|6c1cfa501323772e7c1c008c3dbcd7e364feb0b3"
  "conversations|d23205af0cd2ff7dba25f72e1f3b872762a108ee"
)

# resolved_commit of one installed plugin (empty when absent/malformed).
installed_commit() {
  herdr plugin list --json | bun -e '
    const d = JSON.parse(await new Response(Bun.stdin.stream()).text());
    const plugins = d?.result?.plugins ?? [];
    const p = plugins.find((x) => x && x.plugin_id === process.argv[1]);
    process.stdout.write(p?.source?.resolved_commit ?? "");
  ' "$1"
}

rc=0
for entry in "${PLUGINS[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  sha="${rest##*|}"
  plugin_id="rebuildup.$name"
  have="$(installed_commit "$plugin_id")"
  if [[ "$have" == "$sha" ]]; then
    log "$plugin_id already at pin ${sha:0:12}"
    continue
  fi
  if [[ "$CHECK_ONLY" == "1" ]]; then
    if [[ -z "$have" ]]; then
      log "$plugin_id MISSING (pin ${sha:0:12})"
    else
      log "$plugin_id at ${have:0:12}, pin is ${sha:0:12}"
    fi
    rc=1
    continue
  fi
  log "installing $plugin_id @ ${sha:0:12}"
  herdr plugin install "rebuildup/herdr-plugins/plugins/$name" --ref "$sha" -y \
    || { log "ERROR: install failed for $plugin_id" >&2; rc=1; }
done

exit "$rc"
