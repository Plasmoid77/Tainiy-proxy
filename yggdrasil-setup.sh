#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash yggdrasil-setup.sh" >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot determine the operating system." >&2
  exit 1
fi

. /etc/os-release
if [[ ${ID:-} != debian ]]; then
  echo "This script is intended for Debian." >&2
  exit 1
fi

command -v gpg >/dev/null || { echo "gpg is required." >&2; exit 1; }
command -v systemctl >/dev/null || { echo "systemd is required." >&2; exit 1; }

BACKUP_DIR="/var/backups/deepwebproxy-backups/yggdrasil/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$BACKUP_DIR"

if [[ -f /usr/local/apt-keys/yggdrasil-keyring.gpg ]]; then
  cp -a /usr/local/apt-keys/yggdrasil-keyring.gpg "$BACKUP_DIR/"
fi
if [[ -f /etc/apt/sources.list.d/yggdrasil.list ]]; then
  cp -a /etc/apt/sources.list.d/yggdrasil.list "$BACKUP_DIR/"
fi
if [[ -f /etc/systemd/system/i2pd.service.d/override.conf ]]; then
  cp -a /etc/systemd/system/i2pd.service.d/override.conf "$BACKUP_DIR/i2pd-override.conf"
fi
if [[ -f /etc/systemd/system/yggdrasil.service.d/override.conf ]]; then
  cp -a /etc/systemd/system/yggdrasil.service.d/override.conf "$BACKUP_DIR/yggdrasil-override.conf"
fi

printf '\n\033[1;34m==> Installing Yggdrasil\033[0m\n'
mkdir -p /usr/local/apt-keys
gpg --fetch-keys https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/key.txt
gpg --export 1C5162E133015D81A811239D1840CDAC6011C5EA \
  | tee /usr/local/apt-keys/yggdrasil-keyring.gpg >/dev/null

echo 'deb [signed-by=/usr/local/apt-keys/yggdrasil-keyring.gpg] https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/ debian yggdrasil' \
  > /etc/apt/sources.list.d/yggdrasil.list

apt-get update
apt-get install -y yggdrasil

if [[ ! -f /etc/yggdrasil.conf ]]; then
  echo "/etc/yggdrasil.conf was not created by the package." >&2
  exit 1
fi

printf '\n\033[1;34m==> Configuring startup order for Yggdrasil and i2pd\033[0m\n'
mkdir -p /etc/systemd/system/i2pd.service.d
cat > /etc/systemd/system/i2pd.service.d/override.conf <<'EOF_I2PD'
[Unit]
After=network.target yggdrasil.service
EOF_I2PD

mkdir -p /etc/systemd/system/yggdrasil.service.d
cat > /etc/systemd/system/yggdrasil.service.d/override.conf <<'EOF_YGGDRASIL'
[Service]
ExecStartPost=/bin/sleep 5
EOF_YGGDRASIL

systemctl daemon-reload
systemctl enable yggdrasil.service >/dev/null

if ! systemctl restart yggdrasil.service; then
  journalctl -u yggdrasil.service -n 50 --no-pager >&2 || true
  echo "Yggdrasil did not start." >&2
  exit 1
fi

systemctl is-active --quiet yggdrasil.service
yggdrasil -useconffile /etc/yggdrasil.conf -address >/dev/null

printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m Yggdrasil installed and running.\033[0m\n'
printf '\033[1;32m Address: %s\033[0m\n' "$(yggdrasil -useconffile /etc/yggdrasil.conf -address)"
printf '\033[1;32m Config: /etc/yggdrasil.conf\033[0m\n'
printf '\033[1;32m i2pd starts after Yggdrasil and a 5-second delay.\033[0m\n'
printf '\033[1;32m Backup: %s\033[0m\n' "$BACKUP_DIR"
printf '\033[1;32m============================================================\033[0m\n'