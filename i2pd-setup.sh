#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash i2pd-setup.sh [PORT]" >&2
  exit 1
fi

# shellcheck disable=SC1091
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

# Falls back through the IPv6 default route, then an explicit override, so
# hosts without an IPv4 default route -- IPv6-only, or reachable only via a
# meshnet transport such as Yggdrasil -- still get a scoped UFW rule instead
# of a silently empty interface (which would otherwise make `ufw allow in on
# ""` behave unpredictably).
find_default_iface() {
  awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

PUBLIC_IFACE="${PUBLIC_IFACE:-}"
[ -n "$PUBLIC_IFACE" ] || PUBLIC_IFACE="$(ip -4 route show default | find_default_iface)"
[ -n "$PUBLIC_IFACE" ] || PUBLIC_IFACE="$(ip -6 route show default | find_default_iface)"

if [ -z "$PUBLIC_IFACE" ]; then
  echo "Could not detect a default route interface (IPv4 or IPv6)." >&2
  echo "Set PUBLIC_IFACE=<iface> and re-run." >&2
  exit 1
fi

printf '\n\033[1;34m==> Installing i2pd\033[0m\n'

apt-get install -y apt-transport-https ufw

# i2pd's official repo-add script: fetched over HTTPS and run as root, no
# checksum pinning (trust-on-first-use). It adds a permanent apt source and
# signing key, not a one-off action — review it if this domain is not already
# trusted: https://repo.i2pd.xyz/.help/add_repo
wget -q -O - \
  https://repo.i2pd.xyz/.help/add_repo \
  | bash -s -

apt-get update
apt-get install -y i2pd

printf '\n\033[1;34m==> Configuring i2pd transport port\033[0m\n'

# One-time backup of the pristine config, kept across re-runs, so a bad edit
# below can be diffed or restored by hand.
[ -e /etc/i2pd/i2pd.conf.orig ] || cp -a /etc/i2pd/i2pd.conf /etc/i2pd/i2pd.conf.orig

# Replaces the first "port =" line in the file: in the default i2pd.conf this
# is the global NTCP2/SSU2 transport port, defined before any [section].
# Fragile if upstream reorders the file — verify with `sshd -T`-style checks
# after upgrades, i.e. confirm the running i2pd actually uses this port.
sed -i -E \
  "0,/^[[:space:]]*#?[[:space:]]*port[[:space:]]*=/{s|^[[:space:]]*#?[[:space:]]*port[[:space:]]*=.*$|port = $I2PD_PORT|}" \
  /etc/i2pd/i2pd.conf

# The package's postinst already started i2pd.service with the pristine
# (port-unset, randomly-chosen-port) config before this script ever ran, so
# the edit above has no effect on the running daemon until it is restarted.
# Verify the new port actually took before opening the firewall for it --
# otherwise UFW would open a port nothing listens on, leaving the real
# transport port unreachable behind the default-deny policy.
systemctl restart i2pd

for _ in {1..30}; do
  ss -H -tln "sport = :$I2PD_PORT" | grep -q . && break
  sleep 1
done

ss -H -tln "sport = :$I2PD_PORT" | grep -q . || {
  echo "i2pd is not listening on TCP port $I2PD_PORT after restart." >&2
  echo "Check: systemctl status i2pd ; journalctl -u i2pd -n 50" >&2
  exit 1
}

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
printf '\033[1;32m============================================================\033[0m\n'