#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash i2pd-setup.sh" >&2
  exit 1
fi

. /etc/os-release

if [[ $ID != debian ]]; then
  echo "This script is intended for Debian." >&2
  exit 1
fi

printf '\n\033[1;34m==> Installing i2pd\033[0m\n'

apt-get install -y apt-transport-https

wget -q -O - \
  https://repo.i2pd.xyz/.help/add_repo \
  | bash -s -

apt-get update
apt-get install -y i2pd

printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m i2pd installed.\033[0m\n'
printf '\033[1;32m Service: i2pd.service\033[0m\n'
printf '\033[1;32m Config: /etc/i2pd/i2pd.conf\033[0m\n'
printf '\033[1;32m Run i2pd-timer-setup.sh next.\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'