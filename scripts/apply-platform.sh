#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

case "$(uname -s)" in
  Darwin)
    bash "$repo_root/platforms/macos/install-keyboard.sh"
    bash "$repo_root/platforms/macos/kanata/install-kanata.sh"
    bash "$repo_root/platforms/macos/containers/install.sh"
    bash "$repo_root/platforms/macos/install-rex.sh"
    ;;
  Linux)
    bash "$repo_root/platforms/ubuntu-wsl/install-rex.sh"
    ;;
  *)
    ;;
esac
