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

gpg --fetch-keys \
  https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/key.txt

gpg --export \
  1C5162E133015D81A811239D1840CDAC6011C5EA \
  > /usr/local/apt-keys/yggdrasil-keyring.gpg

echo 'deb [signed-by=/usr/local/apt-keys/yggdrasil-keyring.gpg] https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/ debian yggdrasil' \
  > /etc/apt/sources.list.d/yggdrasil.list

apt-get update
apt-get install -y yggdrasil

systemctl enable yggdrasil.service
systemctl restart yggdrasil.service
systemctl is-active --quiet yggdrasil.service

yggdrasil \
  -useconffile /etc/yggdrasil.conf \
  -address \
  >/dev/null

printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m Yggdrasil installed and running.\033[0m\n'
printf '\033[1;32m Address: %s\033[0m\n' \
  "$(yggdrasil -useconffile /etc/yggdrasil.conf -address)"
printf '\033[1;32m Config: /etc/yggdrasil.conf\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'