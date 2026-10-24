#!/usr/bin/env bash
set -euo pipefail
operation="${1:-}"
target="${2:-/srv/devnode-headscale}"
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
case "$operation" in validate|apply|verify|stop) ;; *) printf 'Usage: %s validate|apply|verify|stop [directory]\n' "$0" >&2; exit 1 ;; esac
# All operations require reviewed source and unchanged, owned host files.
bash "$source_dir/prepare.sh" "$target"
compose=(docker compose --project-name devnode-headscale --project-directory "$target" -f "$target/compose.yaml")
"${compose[@]}" config --quiet
# Named Docker resources may predate Compose. Never adopt foreign resources.
for kind_name in volume:devnode-headscale_state network:devnode-headscale_default container:devnode-headscale-headscale-1; do
  kind="${kind_name%%:*}"
  name="${kind_name#*:}"
  if docker "$kind" inspect "$name" >/dev/null 2>&1; then
    if [[ "$kind" = container ]]; then
      label="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$name")"
    else
      label="$(docker "$kind" inspect --format '{{index .Labels "com.docker.compose.project"}}' "$name")"
    fi
    [[ "$label" = devnode-headscale ]] || { printf 'Foreign Docker resource: %s\n' "$name" >&2; exit 1; }
  fi
done
docker info >/dev/null
case "$operation" in
  validate)
    # Separate ephemeral state: configtest constructs a server and may write DB/keys.
    docker run --rm --network bridge --tmpfs /var/lib/headscale \
      --mount "type=bind,source=$target/config.yaml,target=/etc/headscale/config.yaml,readonly" \
      --mount "type=bind,source=$target/policy.json,target=/etc/headscale/policy.json,readonly" \
      ghcr.io/juanfont/headscale:0.29.6 configtest
    ;;
  apply) "${compose[@]}" up -d --wait --wait-timeout 180 ;;
  verify)
    "${compose[@]}" exec -T headscale health
    "${compose[@]}" exec -T headscale policy check --file /etc/headscale/policy.json
    curl --fail --silent --show-error https://headscale.rebuildup.dev/health
    ;;
  stop) "${compose[@]}" stop ;;
esac
