#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

case "$(uname -s)" in
  Darwin)
    bash "$repo_root/platforms/macos/bootstrap.sh"
    ;;
  *)
    # Other platforms keep their existing platform-specific bootstrap paths.
    ;;
esac
