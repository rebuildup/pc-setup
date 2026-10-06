#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
mapping_file="${ONISHI_MAPPING_FILE:-$script_dir/onishi.json}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Onishi hidutil mapping is only supported on macOS.\n' >&2
  exit 1
fi

if [[ ! -r "$mapping_file" ]]; then
  printf 'Onishi mapping file is missing: %s\n' "$mapping_file" >&2
  exit 1
fi

/usr/bin/hidutil property --set "$(/bin/cat "$mapping_file")" >/dev/null
printf 'Applied Onishi keyboard mapping with hidutil.\n'
