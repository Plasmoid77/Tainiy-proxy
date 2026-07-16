#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash i2pd-router-setup.sh [PORT]" >&2
  exit 1
fi

. /etc/os-release
if [[ ${ID:-} != debian || ${VERSION_CODENAME:-} != trixie ]]; then
  echo "This script is intended for Debian 13 (trixie)." >&2
  exit 1
fi

if (( $# > 1 )); then
  echo "Usage: sudo bash i2pd-router-setup.sh [PORT]" >&2
  exit 1
fi

command -v wget >/dev/null || { echo "wget is required." >&2; exit 1; }
command -v ip >/dev/null || { echo "ip is required." >&2; exit 1; }
command -v ufw >/dev/null || { echo "ufw is required." >&2; exit 1; }

printf '\n\033[1;34m==> Installing i2pd\033[0m\n'
wget -q -O - https://repo.i2pd.xyz/.help/add_repo | bash -s -
apt-get update
apt-get install -y i2pd

if [[ ! -f /etc/i2pd/i2pd.conf ]]; then
  echo "/etc/i2pd/i2pd.conf was not created by the package." >&2
  exit 1
fi

BACKUP_DIR="/var/backups/deepwebproxy-backups/i2pd/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$BACKUP_DIR"
cp -a /etc/i2pd/i2pd.conf "$BACKUP_DIR/i2pd.conf"

if [[ -n ${1:-} ]]; then
  PORT="$1"
elif grep -Eq '^[[:space:]]*port[[:space:]]*=[[:space:]]*[0-9]+' /etc/i2pd/i2pd.conf; then
  PORT="$(sed -nE 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' /etc/i2pd/i2pd.conf | head -n 1)"
else
  PORT="$(shuf -i 9111-30777 -n 1)"
fi

if ! [[ $PORT =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
  echo "PORT must be an integer from 1024 to 65535." >&2
  exit 1
fi

if ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
  IPV6=true
else
  IPV6=false
fi

printf '\n\033[1;34m==> Configuring i2pd\033[0m\n'

# Keep the configuration installed by the package and change only the required settings .
sed -i -E "0,/^[[:space:]#]*port[[:space:]]*=/{s/^[[:space:]#]*port[[:space:]]*=.*$/port = $PORT/}" /etc/i2pd/i2pd.conf
sed -i -E "s/^[[:space:]#]*ipv6[[:space:]]*=.*$/ipv6 = $IPV6/" /etc/i2pd/i2pd.conf
sed -i -E 's/^[[:space:]#]*bandwidth[[:space:]]*=.*$/bandwidth = X/' /etc/i2pd/i2pd.conf

if grep -q '^\[meshnets\]' /etc/i2pd/i2pd.conf; then
  sed -i -E '/^\[meshnets\]/,/^\[/{s/^[[:space:]#]*yggdrasil[[:space:]]*=.*$/yggdrasil = true/}' /etc/i2pd/i2pd.conf
else
  printf '\n[meshnets]\nyggdrasil = true\n' >> /etc/i2pd/i2pd.conf
fi

if ! grep -Eq "^[[:space:]]*port[[:space:]]*=[[:space:]]*$PORT([[:space:]]*)$" /etc/i2pd/i2pd.conf \
  || ! grep -Eq "^[[:space:]]*ipv6[[:space:]]*=[[:space:]]*$IPV6([[:space:]]*)$" /etc/i2pd/i2pd.conf \
  || ! grep -Eq '^[[:space:]]*bandwidth[[:space:]]*=[[:space:]]*X([[:space:]]*)$' /etc/i2pd/i2pd.conf \
  || ! grep -Eq '^[[:space:]]*yggdrasil[[:space:]]*=[[:space:]]*true([[:space:]]*)$' /etc/i2pd/i2pd.conf; then
  cp -a "$BACKUP_DIR/i2pd.conf" /etc/i2pd/i2pd.conf
  echo "The installed i2pd.conf has an unexpected format; the backup was restored." >&2
  exit 1
fi

systemctl enable i2pd.service >/dev/null
if ! systemctl restart i2pd.service; then
  cp -a "$BACKUP_DIR/i2pd.conf" /etc/i2pd/i2pd.conf
  systemctl restart i2pd.service 2>/dev/null || true
  journalctl -u i2pd.service -n 50 --no-pager >&2 || true
  echo "i2pd did not start; the previous configuration was restored." >&2
  exit 1
fi

systemctl is-active --quiet i2pd.service

if [[ -f /etc/default/ufw ]] && ! grep -q '^IPV6=yes' /etc/default/ufw; then
  echo "Warning: UFW IPv6 support is disabled; the rule will not cover Yggdrasil." >&2
fi

printf '\n\033[1;34m==> Adding UFW rules\033[0m\n'
ufw allow "$PORT/tcp" comment 'i2pd NTCP2' >/dev/null
ufw allow "$PORT/udp" comment 'i2pd SSU2' >/dev/null

printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m i2pd installed and running.\033[0m\n'
printf '\033[1;32m Transport port: %s/TCP and %s/UDP\033[0m\n' "$PORT" "$PORT"
printf '\033[1;32m Bandwidth: X; transit share: default 100%%\033[0m\n'
printf '\033[1;32m Clearnet IPv6: %s; Yggdrasil: enabled\033[0m\n' "$IPV6"
printf '\033[1;32m HTTP proxy: 127.0.0.1:4444\033[0m\n'
printf '\033[1;32m Web console: http://127.0.0.1:7070\033[0m\n'
printf '\033[1;32m Config: /etc/i2pd/i2pd.conf\033[0m\n'
printf '\033[1;32m Backup: %s\033[0m\n' "$BACKUP_DIR"
printf '\033[1;32m============================================================\033[0m\n'
