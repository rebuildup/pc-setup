#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=platforms/windows-11/worker/ssh/verification-v2/sshd-checks.sh
source "$root/platforms/windows-11/worker/ssh/verification-v2/sshd-checks.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/pc-setup-ssh-v2-test.XXXXXXXX")"
cleanup() {
  case "$fixture" in "${TMPDIR:-/tmp}"/pc-setup-ssh-v2-test.*) ;; *) return 1;; esac
  rm -f -- "$fixture/template" "$fixture/runtime" "$fixture/key-one" "$fixture/key-one.pub" "$fixture/key-two" "$fixture/key-two.pub"
  rmdir -- "$fixture"
}
trap cleanup EXIT
printf 'ListenAddress @ADDRESS@\nHostKey @ROOT@/host_ed25519\nAuthorizedKeysFile @AUTH@/authorized_keys\nPasswordAuthentication no\n' > "$fixture/template"
printf 'ListenAddress 172.22.1.2\nHostKey /root/host_ed25519\nAuthorizedKeysFile /auth/authorized_keys\nPasswordAuthentication no\n' > "$fixture/runtime"
matches_worker_sshd_runtime "$fixture/template" "$fixture/runtime" /root /auth 172.22.1.2
if matches_worker_sshd_runtime "$fixture/template" "$fixture/runtime" /root /auth 172.22.1.3; then
  printf 'Changed address was accepted.\n' >&2; exit 1
fi
printf 'PasswordAuthentication yes\n' >> "$fixture/runtime"
if matches_worker_sshd_runtime "$fixture/template" "$fixture/runtime" /root /auth 172.22.1.2; then
  printf 'Changed runtime configuration was accepted.\n' >&2; exit 1
fi
ssh-keygen -q -t ed25519 -N '' -f "$fixture/key-one"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/key-two"
matches_worker_hostkey_pair "$fixture/key-one" "$fixture/key-one.pub"
if matches_worker_hostkey_pair "$fixture/key-one" "$fixture/key-two.pub"; then
  printf 'Different private/public host keys were accepted.\n' >&2; exit 1
fi
printf 'Worker SSH runtime and host key checks: PASS\n'
