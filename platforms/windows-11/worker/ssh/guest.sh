#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
action="${1:?action}" instance="${2:?instance}" public_key="${3:?public key}" source_hash="${4:?source hash}" baseline="${5:-absent}"
[[ "$instance" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
[[ "$source_hash" =~ ^[0-9a-f]{64}$ ]]
[[ "$public_key" =~ ^ssh-ed25519\ [A-Za-z0-9+/]{68}\ [A-Za-z0-9_.@-]{1,80}$ ]]
[[ "$(id -u)" = 0 && "$(uname -m)" = x86_64 ]]
for command in ip ss findmnt stat sha256sum awk systemctl dpkg-query apt-get getent; do command -v "$command" >/dev/null; done
root="/etc/pc-setup-wsl-ssh-$instance"
auth_root="/etc/pc-setup-wsl-authorized-$instance"
unit="pc-setup-wsl-ssh-$instance.service"
key_hash="$(printf '%s\n' "$public_key" | sha256sum | cut -d' ' -f1)"
conf_hash=absent
if [[ -e /etc/wsl.conf ]]; then
  [[ ! -L /etc/wsl.conf && -f /etc/wsl.conf && "$(stat -c %u /etc/wsl.conf)" = 0 ]]
  conf_hash="$(sha256sum /etc/wsl.conf | cut -d' ' -f1)"
fi
installed=false
if [[ "$(dpkg-query -W -f='${Status}' openssh-server 2>/dev/null || true)" = 'install ok installed' ]]; then installed=true; fi
if [[ "$action" = Inspect ]]; then
  user_exists=false policy_exists=false owned_root=false home_exists=false group_exists=false auth_exists=false unit_exists=false
  if getent passwd worker >/dev/null; then user_exists=true; fi
  if [[ -e /usr/sbin/policy-rc.d || -L /usr/sbin/policy-rc.d ]]; then policy_exists=true; fi
  if [[ -e "$root" || -L "$root" ]]; then owned_root=true; fi
  if [[ -e /home/worker || -L /home/worker ]]; then home_exists=true; fi
  if getent group worker >/dev/null; then group_exists=true; fi
  if [[ -e "$auth_root" || -L "$auth_root" ]]; then auth_exists=true; fi
  if [[ -e "/etc/systemd/system/$unit" || -L "/etc/systemd/system/$unit" ]]; then unit_exists=true; fi
  printf 'action=Inspect\nwsl_conf_hash=%s\nserver_installed=%s\nuser_exists=%s\npolicy_exists=%s\nstage_exists=%s\nhome_exists=%s\ngroup_exists=%s\nauth_exists=%s\nunit_exists=%s\n' "$conf_hash" "$installed" "$user_exists" "$policy_exists" "$owned_root" "$home_exists" "$group_exists" "$auth_exists" "$unit_exists"
  exit 0
fi
private_file() {
  [[ -f "$1" && ! -L "$1" && "$(stat -c '%u:%g:%a' "$1")" = '0:0:600' ]]
}
if [[ "$action" = Configure ]]; then
  # No adoption of a foreign/partial Linux resource or an existing user/server.
  [[ ! -e "$root" && ! -L "$root" && ! -e "$auth_root" && ! -L "$auth_root" && ! -e "/etc/systemd/system/$unit" && ! -L "/etc/systemd/system/$unit" ]]
  [[ "$installed" = false && "$conf_hash" = "$baseline" ]]
  if getent passwd worker >/dev/null; then exit 1; fi
  if getent group worker >/dev/null; then exit 1; fi
  [[ ! -e /home/worker && ! -L /home/worker && ! -L /home ]]
  [[ ! -e /usr/sbin/policy-rc.d && ! -L /usr/sbin/policy-rc.d ]]
  [[ -z "$(ss -H -ltn 'sport = :22')" && -z "$(ss -H -ltn 'sport = :22224')" ]]
  mkdir -m 700 "$root"
  printf 'owner=pc-setup/windows-worker-ssh/v1\ninstance=%s\nsource_hash=%s\nkey_hash=%s\n' "$instance" "$source_hash" "$key_hash" > "$root/manifest.partial"
  if [[ "$conf_hash" != absent ]]; then cp /etc/wsl.conf "$root/wsl.conf.before"; chmod 600 "$root/wsl.conf.before"; fi
  # Prevent package post-install hooks from briefly exposing the vendor port 22.
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
  chmod 755 /usr/sbin/policy-rc.d
  policy_hash="$(sha256sum /usr/sbin/policy-rc.d | cut -d' ' -f1)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update > "$root/apt.log" 2>&1
  apt-get install -y --no-install-recommends openssh-server >> "$root/apt.log" 2>&1
  [[ "$(sha256sum /usr/sbin/policy-rc.d | cut -d' ' -f1)" = "$policy_hash" ]]
  systemctl --root=/ disable ssh.service ssh.socket > "$root/vendor-disable.log" 2>&1
  [[ -z "$(ss -H -ltn 'sport = :22')" ]]
  # Only remove the exact temporary policy file created in this stage.
  rm -- /usr/sbin/policy-rc.d
  useradd --create-home --user-group --shell /bin/bash worker
  [[ "$(id -nG worker)" = worker && "$(id -u worker)" -ge 1000 ]]
  chmod 700 /home/worker
  # sshd opens AuthorizedKeysFile as the target user. Public data must be readable,
  # while only root may change it. Keep private host keys in the separate 0700 root.
  mkdir -m 755 "$auth_root"
  printf '%s\n' "$public_key" > "$auth_root/authorized_keys"
  chmod 644 "$auth_root/authorized_keys"
  ssh-keygen -q -t ed25519 -N '' -C "wsl-$instance" -f "$root/host_ed25519"
  chmod 600 "$root/host_ed25519.pub"
  cat > "$root/sshd.template" <<'CONFIG'
AddressFamily inet
Port 22224
ListenAddress @ADDRESS@
HostKey @ROOT@/host_ed25519
AuthorizedKeysFile @AUTH@/authorized_keys
PidFile @ROOT@/sshd.pid
AllowUsers worker
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
UsePAM yes
StrictModes yes
DisableForwarding yes
AllowTcpForwarding no
AllowStreamLocalForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no
PermitUserRC no
LoginGraceTime 30
MaxAuthTries 3
MaxStartups 3:30:10
LogLevel VERBOSE
CONFIG
  cat > "$root/runner" <<'RUNNER'
#!/bin/bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
root="${0%/*}"
auth_root="${root/pc-setup-wsl-ssh-/pc-setup-wsl-authorized-}"
[[ "$(stat -c '%u:%g:%a' "$root")" = '0:0:700' && ! -L "$root" ]]
address=''
for ((i=0;i<30;i++)); do
  address="$(ip -4 -o addr show dev eth0 scope global | awk '{sub(/\/.*/,"",$4);print $4}')"
  if [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then break; fi
  sleep 1
done
[[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
[[ ! -L /run/sshd ]]
mkdir -p -m 755 /run/sshd
[[ "$(stat -c '%u:%g:%a' /run/sshd)" = '0:0:755' ]]
sed -e "s|@ROOT@|$root|g" -e "s|@AUTH@|$auth_root|g" -e "s|@ADDRESS@|$address|g" "$root/sshd.template" > "$root/sshd.runtime.new"
chmod 600 "$root/sshd.runtime.new"
mv -f -- "$root/sshd.runtime.new" "$root/sshd.runtime"
/usr/sbin/sshd -t -f "$root/sshd.runtime"
exec /usr/sbin/sshd -D -f "$root/sshd.runtime" -E "$root/sshd.log"
RUNNER
  chmod 700 "$root/runner"
  cat > "/etc/systemd/system/$unit" <<UNIT
[Unit]
Description=Owned WSL SSH $instance
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=3
[Service]
Type=simple
ExecStart=$root/runner
Environment=PATH=/usr/sbin:/usr/bin:/sbin:/bin
UMask=0077
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 "/etc/systemd/system/$unit"
  cat > "$root/wsl.conf.desired" <<'WSLCONF'
[boot]
systemd=true
[automount]
enabled=false
[interop]
enabled=false
appendWindowsPath=false
[user]
default=worker
WSLCONF
  # The previous exact hash was explicitly supplied by the owner after Inspect.
  cp "$root/wsl.conf.desired" /etc/wsl.conf
  chmod 644 /etc/wsl.conf
  systemctl --root=/ enable "$unit" > "$root/unit-enable.log" 2>&1
  printf 'authorized_keys=%s\n' "$(sha256sum "$auth_root/authorized_keys" | cut -d' ' -f1)" >> "$root/manifest.partial"
  for name in host_ed25519.pub sshd.template runner wsl.conf.desired; do
    printf '%s=%s\n' "$name" "$(sha256sum "$root/$name" | cut -d' ' -f1)" >> "$root/manifest.partial"
  done
  printf 'unit=%s\n' "$(sha256sum "/etc/systemd/system/$unit" | cut -d' ' -f1)" >> "$root/manifest.partial"
  mv -- "$root/manifest.partial" "$root/manifest"
  printf 'action=Configure\nhost_fp=%s\nrestart_required=true\n' "$(ssh-keygen -lf "$root/host_ed25519.pub" -E sha256 | awk '{print $2}')"
  exit 0
fi
[[ "$action" = Verify ]]
[[ ! -L "$root" && "$(stat -c '%u:%g:%a' "$root")" = '0:0:700' ]]
private_file "$root/manifest"
grep -Fxq 'owner=pc-setup/windows-worker-ssh/v1' "$root/manifest"
grep -Fxq "instance=$instance" "$root/manifest"
grep -Fxq "source_hash=$source_hash" "$root/manifest"
grep -Fxq "key_hash=$key_hash" "$root/manifest"
[[ ! -L "$auth_root" && "$(stat -c '%u:%g:%a' "$auth_root")" = '0:0:755' ]]
[[ ! -L "$auth_root/authorized_keys" && "$(stat -c '%u:%g:%a' "$auth_root/authorized_keys")" = '0:0:644' ]]
grep -Fxq "authorized_keys=$(sha256sum "$auth_root/authorized_keys" | cut -d' ' -f1)" "$root/manifest"
for name in host_ed25519.pub sshd.template runner wsl.conf.desired; do
  [[ ! -L "$root/$name" && "$(stat -c %u "$root/$name")" = 0 ]]
  grep -Fxq "$name=$(sha256sum "$root/$name" | cut -d' ' -f1)" "$root/manifest"
done
private_file "$root/host_ed25519"
[[ ! -L "/etc/systemd/system/$unit" && "$(stat -c '%u:%g:%a' "/etc/systemd/system/$unit")" = '0:0:644' ]]
grep -Fxq "unit=$(sha256sum "/etc/systemd/system/$unit" | cut -d' ' -f1)" "$root/manifest"
cmp -s /etc/wsl.conf "$root/wsl.conf.desired"
[[ "$(id -nG worker)" = worker && "$(id -u worker)" -ge 1000 && "$(stat -c %a /home/worker)" = 700 ]]
[[ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ]]
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
printf 'action=Verify\naddress=%s\nport=22224\nlinux_user=worker\nuid=%s\nhost_fp=%s\ninterop=false\nwindows_drive_mount=false\nservice_active=true\n' "$address" "$(id -u worker)" "$(ssh-keygen -lf "$root/host_ed25519.pub" -E sha256 | awk '{print $2}')"
