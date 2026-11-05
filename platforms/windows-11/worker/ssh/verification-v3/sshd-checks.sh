#!/usr/bin/env bash
# Functions are concatenated with the guest verifier and tested independently.
matches_worker_sshd_runtime() {
  local template="$1" runtime="$2" root="$3" auth_root="$4" address="$5"
  cmp -s "$runtime" <(sed -e "s|@ROOT@|$root|g" -e "s|@AUTH@|$auth_root|g" -e "s|@ADDRESS@|$address|g" "$template")
}
matches_worker_hostkey_pair() {
  local private="$1" public="$2" derived actual
  derived="$(ssh-keygen -y -f "$private")" || return 1
  derived="$(printf '%s\n' "$derived" | awk '{print $1, $2}')"
  actual="$(awk '{print $1, $2}' "$public")"
  [[ "$derived" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+=*$ && "$derived" = "$actual" ]]
}
