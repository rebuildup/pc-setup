#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
instance="${1:?instance}" operation="${2:?operation}" before="${3:?before}" after="${4:?after}" host_fp="${5:?host fingerprint}" encoded="${6:?candidate}"
[[ "$instance" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
[[ "$operation" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
[[ "$before" =~ ^[0-9a-f]{64}$ && "$after" =~ ^[0-9a-f]{64}$ && "$host_fp" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]]
[[ ${#encoded} -le 8192 && "$encoded" =~ ^[A-Za-z0-9+/=]+$ && "$(id -u)" = 0 ]]
root="/etc/pc-setup-wsl-ssh-$instance"
auth="/etc/pc-setup-wsl-authorized-$instance"
[[ ! -L "$root" && "$(stat -c '%u:%g:%a' "$root")" = '0:0:700' ]]
[[ ! -L "$auth" && "$(stat -c '%u:%g:%a' "$auth")" = '0:0:755' ]]
[[ -f "$root/manifest" && ! -L "$root/manifest" && "$(stat -c '%u:%g:%a' "$root/manifest")" = '0:0:600' ]]
grep -Fxq 'owner=pc-setup/windows-worker-ssh/v1' "$root/manifest"
grep -Fxq "instance=$instance" "$root/manifest"
[[ -f "$auth/authorized_keys" && ! -L "$auth/authorized_keys" && "$(stat -c '%u:%g:%a' "$auth/authorized_keys")" = '0:0:644' ]]
[[ "$(ssh-keygen -lf "$root/host_ed25519.pub" -E sha256 | awk '{print $2}')" = "$host_fp" ]]
stages="$root/key-stage"
if [[ ! -e "$stages" && ! -L "$stages" ]]; then mkdir -m 700 "$stages"; fi
[[ ! -L "$stages" && "$(stat -c '%u:%g:%a' "$stages")" = '0:0:700' ]]
# A single exclusive lock serializes all updates, not just this operation ID.
[[ ! -L "$stages/lock" ]]
if [[ ! -e "$stages/lock" ]]; then ( set -o noclobber; : > "$stages/lock" ); fi
[[ -f "$stages/lock" && ! -L "$stages/lock" && "$(stat -c '%u:%g:%a' "$stages/lock")" = '0:0:600' ]]
exec 9<> "$stages/lock"
flock -n 9
candidate="$stages/candidate-$operation"
[[ ! -e "$candidate" && ! -L "$candidate" && ! -e "$stages/attempt-$operation" && ! -L "$stages/attempt-$operation" ]]
( set -o noclobber; printf '%s' "$encoded" | base64 -d > "$candidate" )
[[ "$(sha256sum "$candidate" | cut -d' ' -f1)" = "$after" ]]
count=0
while IFS= read -r line; do
  [[ "$line" =~ ^ssh-ed25519\ [A-Za-z0-9+/]{68}\ [A-Za-z0-9_.@-]{1,80}$ ]]
  ((count+=1)); [[ "$count" -le 32 ]]
done < "$candidate"
[[ "$count" -ge 1 && "$(tail -c 1 "$candidate" | od -An -tu1 | tr -d ' ')" = 10 ]]
[[ "$(awk '{print $2}' "$candidate" | sort -u | wc -l)" -eq "$count" ]]
ssh-keygen -lf "$candidate" >/dev/null
apply_worker_key_transaction "$auth/authorized_keys" "$candidate" "$stages/attempt-$operation" "$before" "$after"
printf 'action=UpdateKeyStage\ninstance=%s\noperation=%s\nauthorization_hash=%s\nhost_fp=%s\n' "$instance" "$operation" "$after" "$host_fp"
