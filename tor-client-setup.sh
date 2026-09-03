#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash tor-client-setup.sh" >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

if [[ $ID != debian ]]; then
  echo "This script is intended for Debian." >&2
  exit 1
fi

printf '\n\033[1;34m==> Installing Tor\033[0m\n'

apt-get update
apt-get install -y ca-certificates wget gnupg

wget -qO- \
  https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc \
  | gpg --dearmor \
  > /usr/share/keyrings/deb.torproject.org-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/deb.torproject.org-keyring.gpg] https://deb.torproject.org/torproject.org $VERSION_CODENAME main" \
  > /etc/apt/sources.list.d/tor.list

apt-get update
apt-get install -y tor deb.torproject.org-keyring

printf '\n\033[1;34m==> Configuring Tor\033[0m\n'

cat > /etc/tor/torrc <<'EOF'
ClientOnly 1
SocksPort 127.0.0.1:9050 IsolateSOCKSAuth
EOF

tor --verify-config -f /etc/tor/torrc >/dev/null

# No `systemctl enable` here: tor@default.service ships without an [Install]
# section on Debian. It is instead wired to tor.service (already enabled by
# the package) at boot time by /usr/lib/systemd/system-generators/tor-generator,
# which links it in automatically because /etc/tor/torrc exists. An explicit
# enable is a no-op that only prints a "no installation config" warning.
systemctl restart tor@default.service
systemctl is-active --quiet tor@default.service

printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m Tor installed and running.\033[0m\n'
printf '\033[1;32m Mode: client only\033[0m\n'
printf '\033[1;32m SOCKS5: 127.0.0.1:9050\033[0m\n'
printf '\033[1;32m Config: /etc/tor/torrc\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'