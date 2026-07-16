#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash i2pd-setup.sh [PORT]" >&2
  exit 1
fi

. /etc/os-release

if [[ $ID != debian ]]; then
  echo "This script is intended for Debian." >&2
  exit 1
fi

if (( $# > 1 )); then
  echo "Usage: sudo bash i2pd-setup.sh [PORT]" >&2
  exit 1
fi

I2PD_PORT="${1:-$(shuf -i 10000-65535 -n 1)}"

if ! [[ $I2PD_PORT =~ ^[0-9]+$ ]] ||
   (( I2PD_PORT < 1024 || I2PD_PORT > 65535 )); then
  echo "PORT must be an integer from 1024 to 65535." >&2
  exit 1
fi

PUBLIC_IFACE="$(ip -4 route show default | awk '{print $5; exit}')"

printf '\n\033[1;34m==> Installing i2pd\033[0m\n'

apt-get install -y apt-transport-https ufw

wget -q -O - \
  https://repo.i2pd.xyz/.help/add_repo \
  | bash -s -

apt-get update
apt-get install -y i2pd

printf '\n\033[1;34m==> Configuring i2pd transport port\033[0m\n'

sed -i -E \
  "0,/^[[:space:]]*#?[[:space:]]*port[[:space:]]*=/{s|^[[:space:]]*#?[[:space:]]*port[[:space:]]*=.*$|port = $I2PD_PORT|}" \
  /etc/i2pd/i2pd.conf

printf '\n\033[1;34m==> Configuring i2pd firewall rules\033[0m\n'

ufw allow in on "$PUBLIC_IFACE" \
  to any port "$I2PD_PORT" proto tcp \
  comment "i2pd NTCP2 transport"

ufw allow in on "$PUBLIC_IFACE" \
  to any port "$I2PD_PORT" proto udp \
  comment "i2pd SSU2 transport"

printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m i2pd installed.\033[0m\n'
printf '\033[1;32m Transport port: %s TCP/UDP\033[0m\n' "$I2PD_PORT"
printf '\033[1;32m Public interface: %s\033[0m\n' "$PUBLIC_IFACE"
printf '\033[1;32m Service: i2pd.service\033[0m\n'
printf '\033[1;32m Config: /etc/i2pd/i2pd.conf\033[0m\n'
printf '\033[1;32m Run i2pd-timer-setup.sh next.\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'