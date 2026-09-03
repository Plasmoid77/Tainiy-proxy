#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash yggdrasil-setup.sh" >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

if [[ $ID != debian ]]; then
  echo "This script is intended for Debian." >&2
  exit 1
fi

printf '\n\033[1;34m==> Installing Yggdrasil\033[0m\n'

mkdir -p /usr/local/apt-keys

# Fetched straight into a dedicated keyring file (--no-default-keyring), not
# root's default GPG trustdb, so apt's signed-by key stays isolated from any
# other GPG use on this host.
gpg --no-default-keyring \
  --keyring /usr/local/apt-keys/yggdrasil-keyring.gpg \
  --fetch-keys \
  https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/key.txt

echo 'deb [signed-by=/usr/local/apt-keys/yggdrasil-keyring.gpg] https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/ debian yggdrasil' \
  > /etc/apt/sources.list.d/yggdrasil.list

apt-get update
apt-get install -y yggdrasil

systemctl enable yggdrasil.service
systemctl restart yggdrasil.service
systemctl is-active --quiet yggdrasil.service

# Single call: doubles as a startup check (set -e aborts if it fails) and the
# value printed below, instead of running the binary twice.
YGG_ADDRESS="$(yggdrasil -useconffile /etc/yggdrasil/yggdrasil.conf -address)"

# No UFW rule is opened here: Yggdrasil's "Listen" is empty by default, so it
# only makes outbound peer connections plus local multicast discovery, and
# accepts no incoming connections. Add a Listen entry in yggdrasil.conf and
# open the matching port yourself if you want to accept incoming peerings.

printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m Yggdrasil installed and running.\033[0m\n'
printf '\033[1;32m Address: %s\033[0m\n' "$YGG_ADDRESS"
printf '\033[1;32m Config: /etc/yggdrasil/yggdrasil.conf\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'