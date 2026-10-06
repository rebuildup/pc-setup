#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

case "$(uname -s)" in
  Darwin)
    bash "$repo_root/platforms/macos/install-keyboard.sh"
    bash "$repo_root/platforms/macos/kanata/install-kanata.sh"
    ;;
  Linux)
    ;;
  *)
    ;;
esac
