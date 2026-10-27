#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
instance="${1:?instance}" public_key="${2:?public key}" setup_hash="${3:?original setup source hash}"
[[ "$instance" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ && "$setup_hash" =~ ^[0-9a-f]{64}$ ]]
[[ "$public_key" =~ ^ssh-ed25519\ [A-Za-z0-9+/]{68}\ [A-Za-z0-9_.@-]{1,80}$ ]]
[[ "$(id -u)" = 0 && "$(uname -m)" = x86_64 ]]
root="/etc/pc-setup-wsl-ssh-$instance"
auth_root="/etc/pc-setup-wsl-authorized-$instance"
unit="pc-setup-wsl-ssh-$instance.service"
private_file() { [[ -f "$1" && ! -L "$1" && "$(stat -c '%u:%g:%a' "$1")" = '0:0:600' ]]; }
[[ ! -L "$root" && "$(stat -c '%u:%g:%a' "$root")" = '0:0:700' ]]
private_file "$root/manifest"
grep -Fxq 'owner=pc-setup/windows-worker-ssh/v1' "$root/manifest"
grep -Fxq "instance=$instance" "$root/manifest"
# The installed manifest binds the original setup, never this new verifier.
grep -Fxq "source_hash=$setup_hash" "$root/manifest"
grep -Fxq "key_hash=$(printf '%s\n' "$public_key" | sha256sum | cut -d' ' -f1)" "$root/manifest"
[[ ! -L "$auth_root" && "$(stat -c '%u:%g:%a' "$auth_root")" = '0:0:755' ]]
[[ ! -L "$auth_root/authorized_keys" && "$(stat -c '%u:%g:%a' "$auth_root/authorized_keys")" = '0:0:644' ]]
grep -Fxq "authorized_keys=$(sha256sum "$auth_root/authorized_keys" | cut -d' ' -f1)" "$root/manifest"
for name in host_ed25519.pub sshd.template runner wsl.conf.desired; do
  [[ -f "$root/$name" && ! -L "$root/$name" && "$(stat -c %u "$root/$name")" = 0 ]]
  grep -Fxq "$name=$(sha256sum "$root/$name" | cut -d' ' -f1)" "$root/manifest"
done
private_file "$root/host_ed25519"
[[ ! -L "/etc/systemd/system/$unit" && "$(stat -c '%u:%g:%a' "/etc/systemd/system/$unit")" = '0:0:644' ]]
grep -Fxq "unit=$(sha256sum "/etc/systemd/system/$unit" | cut -d' ' -f1)" "$root/manifest"
[[ -f /etc/wsl.conf && ! -L /etc/wsl.conf && "$(stat -c '%u:%g:%a' /etc/wsl.conf)" = '0:0:644' ]]
cmp -s /etc/wsl.conf "$root/wsl.conf.desired"
# Compare the reviewed desired contents too; matching two changed files is insufficient.
cmp -s /etc/wsl.conf <(printf '[boot]\nsystemd=true\n[automount]\nenabled=false\n[interop]\nenabled=false\nappendWindowsPath=false\n[user]\ndefault=worker\n')
[[ "$(id -nG worker)" = worker && "$(id -u worker)" -ge 1000 && ! -L /home/worker && "$(stat -c '%u:%g:%a' /home/worker)" = "$(id -u worker):$(id -g worker):700" ]]
if findmnt -rn -M /mnt/c >/dev/null; then exit 1; fi
if findmnt -rn -t 9p,drvfs -o TARGET | grep -Eq '^/mnt/[a-z]($|/)'; then exit 1; fi
[[ -z "$(ss -H -ltn 'sport = :22')" ]]
for ((i=0;i<30;i++)); do
  if systemctl is-active --quiet "$unit"; then break; fi
  sleep 1
done
systemctl is-active --quiet "$unit"
address="$(ip -4 -o addr show dev eth0 scope global | awk '{sub(/\/.*/,"",$4);print $4}')"
[[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
for ((i=0;i<30;i++)); do
  if [[ "$(ss -H -ltn 'sport = :22224' | awk '{print $4}')" = "$address:22224" ]]; then break; fi
  sleep 1
done
[[ "$(ss -H -ltn 'sport = :22224' | awk '{print $4}')" = "$address:22224" ]]
/usr/sbin/sshd -t -f "$root/sshd.runtime"
# WSL's binfmt registration is shared. Presence is an observation, not execution permission.
registration=absent
if [[ -e /proc/sys/fs/binfmt_misc/WSLInterop ]]; then registration=present; fi
printf 'action=VerifyV2\naddress=%s\nport=22224\nlinux_user=worker\nuid=%s\nhost_fp=%s\ninterop_config_disabled=true\nbinfmt_registration=%s\nwindows_drive_mount=false\nservice_active=true\n' "$address" "$(id -u worker)" "$(ssh-keygen -lf "$root/host_ed25519.pub" -E sha256 | awk '{print $2}')" "$registration"
