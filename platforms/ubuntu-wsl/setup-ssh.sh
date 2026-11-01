#!/usr/bin/env bash
# Standard SSH for an ordinary WSL distribution, not a dedicated worker.
set -euo pipefail
if [[ $EUID -ne 0 || $# -ne 3 ]]; then
  printf 'usage (root): %s USER PORT PUBLIC_KEYS_FILE\n' "$0" >&2
  exit 2
fi
user=$1
port=$2
keys=$3
[[ "$user" =~ ^[a-z_][a-z0-9_-]*$ && "$port" =~ ^[0-9]+$ ]] || exit 2
(( port >= 1024 && port <= 65535 )) || exit 2
home_dir=$(getent passwd "$user" | cut -d: -f6)
[[ -n "$home_dir" && "$home_dir" != /root && -f "$keys" ]] || exit 2
# Accept public keys only; never accept/copy private credentials or key options.
while IFS= read -r key || [[ -n "$key" ]]; do
  [[ "$key" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+(\ .*)?$ ]] || { printf 'invalid public key\n' >&2; exit 2; }
  ssh-keygen -lf /dev/stdin <<< "$key" >/dev/null
done < "$keys"
[[ -s "$keys" ]] || exit 2
config=/etc/ssh/sshd_config.d/00-pc-setup-devices.conf
content=$(printf '# Managed by pc-setup setup-ssh.sh\nPort %s\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' "$port")
# Existing SSH port/policy changes need separate inspection; never overwrite them.
if [[ -e "$config" || -L "$config" ]]; then
  [[ ! -L "$config" && "$(cat "$config")" == "$content" ]] || { printf 'conflict: %s\n' "$config" >&2; exit 1; }
else
  if command -v sshd >/dev/null 2>&1; then
    printf 'existing sshd: inspect its configuration before adding a new port\n' >&2; exit 1
  fi
  install -d -m 755 /etc/ssh/sshd_config.d
  printf '%s\n' "$content" > "$config"
fi
if ! command -v sshd >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
fi
[[ ! -L "$home_dir/.ssh" && ! -L "$home_dir/.ssh/authorized_keys" ]] || { printf 'refusing symlinked SSH authorization\n' >&2; exit 1; }
install -d -m 700 -o "$user" -g "$(id -gn "$user")" "$home_dir/.ssh"
touch "$home_dir/.ssh/authorized_keys"
chmod 600 "$home_dir/.ssh/authorized_keys"
chown "$user:$(id -gn "$user")" "$home_dir/.ssh/authorized_keys"
while IFS= read -r key || [[ -n "$key" ]]; do
  public=$(awk '{print $2}' <<< "$key")
  if ! awk '{print $2}' "$home_dir/.ssh/authorized_keys" | grep -Fxq "$public"; then
    printf '\n%s\n' "$key" >> "$home_dir/.ssh/authorized_keys"
  fi
done < "$keys"
/usr/sbin/sshd -t
systemctl enable --now ssh
printf 'Instance: '; cat /etc/machine-id
printf 'Host key: '; cat /etc/ssh/ssh_host_ed25519_key.pub
printf 'Publish this instance and verified SSH endpoint to Infisical using dotfiles devices register.\n'
