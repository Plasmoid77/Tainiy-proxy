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

# Drop our own source first: a partial earlier run can leave this file behind
# pointing at a missing/invalid keyring, which would make the apt-get update
# below fail before the key is rewritten. It is recreated further down.
rm -f /etc/apt/sources.list.d/yggdrasil.list

apt-get update
apt-get install -y ca-certificates wget gnupg

mkdir -p /usr/local/apt-keys

YGGDRASIL_KEY_FINGERPRINT='1C5162E133015D81A811239D1840CDAC6011C5EA'

# --dearmor rather than gpg --fetch-keys into a keyring: --fetch-keys needs a
# gpg homedir plus a running dirmngr, and writes the keybox format, which APT's
# sqv verifier cannot parse -- apt-get update then fails with
# "Failed to parse keyring ... EOF". Dearmoring is stateless, touches no
# trustdb, and emits the classic OpenPGP binary format APT expects.
wget -qO- \
  https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/key.txt \
  | gpg --dearmor \
  > /usr/local/apt-keys/yggdrasil-keyring.gpg

# Pin the expected signing key, so a substituted upstream key fails loudly here
# instead of silently authorising a different repository.
gpg --show-keys --with-colons /usr/local/apt-keys/yggdrasil-keyring.gpg |
  awk -F: '$1 == "fpr" { print $10 }' |
  grep -qx "$YGGDRASIL_KEY_FINGERPRINT" || {
    echo "Unexpected Yggdrasil signing key; expected $YGGDRASIL_KEY_FINGERPRINT." >&2
    rm -f /usr/local/apt-keys/yggdrasil-keyring.gpg
    exit 1
  }

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

# A fresh install ships "Peers: []". The node then has an address but no path
# into the network: on a VPS there are no multicast neighbours to discover
# either, so it stays isolated until peers are added by hand.
if grep -Eq '^[[:space:]]*Peers:[[:space:]]*\[\][[:space:]]*$' /etc/yggdrasil/yggdrasil.conf; then
  printf '\n\033[1;33m%s\n%s\n%s\n%s\n%s\033[0m\n' \
    'WARNING: no peers are configured, so this node is isolated from the' \
    'Yggdrasil network. Pick current peers from' \
    'https://github.com/yggdrasil-network/public-peers, add them to the' \
    'Peers: [] list in /etc/yggdrasil/yggdrasil.conf, then run:' \
    '  systemctl restart yggdrasil'
fi

printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m Yggdrasil installed and running.\033[0m\n'
printf '\033[1;32m Address: %s\033[0m\n' "$YGG_ADDRESS"
printf '\033[1;32m Config: /etc/yggdrasil/yggdrasil.conf\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'