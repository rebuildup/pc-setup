#!/usr/bin/env bash
# Caller must validate ownership, permissions, proof and key content before invoking.
# A partial attempt is never retried or automatically rolled back.
apply_worker_key_transaction() {
  local target="$1" candidate="$2" attempt="$3" before="$4" after="$5" temporary
  [[ "$before" =~ ^[0-9a-f]{64}$ && "$after" =~ ^[0-9a-f]{64}$ && "$before" != "$after" ]] || return 1
  [[ -f "$target" && ! -L "$target" && -f "$candidate" && ! -L "$candidate" ]] || return 1
  [[ "$(sha256sum -- "$target" | cut -d' ' -f1)" = "$before" ]] || return 1
  [[ "$(sha256sum -- "$candidate" | cut -d' ' -f1)" = "$after" ]] || return 1
  temporary="${target}.new"
  [[ ! -e "$temporary" && ! -L "$temporary" ]] || return 1
  ( umask 077; mkdir -- "$attempt" ) || return 1
  printf '%s\n' "$before" > "$attempt/before.sha256" || return 1
  printf '%s\n' "$after" > "$attempt/after.sha256" || return 1
  ( set -o noclobber; cat -- "$candidate" > "$temporary" ) || return 1
  chmod 644 "$temporary" || return 1
  [[ "$(sha256sum -- "$temporary" | cut -d' ' -f1)" = "$after" ]] || return 1
  [[ -f "$target" && ! -L "$target" && "$(sha256sum -- "$target" | cut -d' ' -f1)" = "$before" ]] || return 1
  mv -f -- "$temporary" "$target" || return 1
  [[ "$(sha256sum -- "$target" | cut -d' ' -f1)" = "$after" ]] || return 1
  ( set -o noclobber; : > "$attempt/complete" ) || return 1
}
