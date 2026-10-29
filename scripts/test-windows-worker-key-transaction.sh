#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=platforms/windows-11/worker/ssh/key-stage/transaction.sh
source "$root/platforms/windows-11/worker/ssh/key-stage/transaction.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/pc-setup-key-stage-test.XXXXXXXX")"
cleanup() {
  case "$fixture" in "${TMPDIR:-/tmp}"/pc-setup-key-stage-test.*) ;; *) return 1;; esac
  rm -f -- "$fixture/auth/authorized_keys" "$fixture/auth/authorized_keys.new" "$fixture/candidate" "$fixture/attempt/before.sha256" "$fixture/attempt/after.sha256" "$fixture/attempt/complete" "$fixture/interrupted/before.sha256" "$fixture/interrupted/after.sha256" "$fixture/interrupted/complete"
  if [[ -d "$fixture/attempt" ]]; then rmdir -- "$fixture/attempt"; fi
  if [[ -d "$fixture/interrupted" ]]; then rmdir -- "$fixture/interrupted"; fi
  rmdir -- "$fixture/auth" "$fixture"
}
trap cleanup EXIT
mkdir "$fixture/auth"
printf 'old-key\n' > "$fixture/auth/authorized_keys"
printf 'old-key\nnew-key\n' > "$fixture/candidate"
before="$(sha256sum "$fixture/auth/authorized_keys" | cut -d' ' -f1)"
after="$(sha256sum "$fixture/candidate" | cut -d' ' -f1)"
apply_worker_key_transaction "$fixture/auth/authorized_keys" "$fixture/candidate" "$fixture/attempt" "$before" "$after"
cmp -s "$fixture/auth/authorized_keys" "$fixture/candidate"
[[ "$(cat "$fixture/attempt/before.sha256")" = "$before" && "$(cat "$fixture/attempt/after.sha256")" = "$after" && -f "$fixture/attempt/complete" ]]
printf 'old-key\n' > "$fixture/auth/authorized_keys"
if apply_worker_key_transaction "$fixture/auth/authorized_keys" "$fixture/candidate" "$fixture/attempt" "$before" "$after" 2>/dev/null; then
  printf 'Existing attempt was reused.\n' >&2; exit 1
fi
[[ "$(sha256sum "$fixture/auth/authorized_keys" | cut -d' ' -f1)" = "$before" ]]
printf 'modified-key\n' > "$fixture/candidate"
if apply_worker_key_transaction "$fixture/auth/authorized_keys" "$fixture/candidate" "$fixture/unused" "$before" "$after"; then
  printf 'Modified candidate was accepted.\n' >&2; exit 1
fi
[[ ! -e "$fixture/unused" && "$(sha256sum "$fixture/auth/authorized_keys" | cut -d' ' -f1)" = "$before" ]]
printf 'old-key\nnew-key\n' > "$fixture/candidate"
mv() { command mv "$@"; return 1; }
if apply_worker_key_transaction "$fixture/auth/authorized_keys" "$fixture/candidate" "$fixture/interrupted" "$before" "$after"; then
  printf 'Interrupted commit was reported as successful.\n' >&2; exit 1
fi
unset -f mv
[[ "$(sha256sum "$fixture/auth/authorized_keys" | cut -d' ' -f1)" = "$after" && ! -e "$fixture/interrupted/complete" ]]
printf 'Worker SSH key transaction: PASS\n'
