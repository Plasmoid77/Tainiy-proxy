#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash yggdrasil-setup.sh" >&2
  exit 1
fi

. /etc/os-release

if [[ $ID != debian ]]; then
  echo "This script is intended for Debian." >&2
  exit 1
fi

printf '\n\033[1;34m==> Installing Yggdrasil\033[0m\n'

mkdir -p /usr/local/apt-keys
gpg --fetch-keys https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/key.txt
gpg --export 1C5162E133015D81A811239D1840CDAC6011C5EA | sudo tee /usr/local/apt-keys/yggdrasil-keyring.gpg > /dev/null

echo 'deb [signed-by=/usr/local/apt-keys/yggdrasil-keyring.gpg] http://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/ debian yggdrasil' | sudo tee /etc/apt/sources.list.d/yggdrasil.list

apt-get update
apt-get install -y yggdrasil

printf '\n\033[1;34m==> Configuring delayed i2pd startup\033[0m\n'

cat > /etc/systemd/system/i2pd.timer <<'EOF'
[Unit]
Description=i2pd service timer
After=yggdrasil.service

[Timer]
OnActiveSec=10s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl enable yggdrasil.service
systemctl restart yggdrasil.service
systemctl is-active --quiet yggdrasil.service

yggdrasil \
  -useconffile /etc/yggdrasil.conf \
  -address \
  >/dev/null

systemctl disable --now i2pd.service
systemctl enable i2pd.timer
systemctl restart i2pd.timer

printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m Yggdrasil installed and running.\033[0m\n'
printf '\033[1;32m Address: %s\033[0m\n' \
  "$(yggdrasil -useconffile /etc/yggdrasil.conf -address)"
printf '\033[1;32m Config: /etc/yggdrasil.conf\033[0m\n'
printf '\033[1;32m i2pd starts 10 seconds after Yggdrasil.\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'