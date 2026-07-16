#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash tor-client-setup.sh [SOCKS_PORT]" >&2
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

if [[ -z ${VERSION_CODENAME:-} ]]; then
  echo "Debian release codename is missing from /etc/os-release." >&2
  exit 1
fi

if (( $# > 1 )); then
  echo "Usage: sudo bash tor-client-setup.sh [SOCKS_PORT]" >&2
  exit 1
fi

case "$(dpkg --print-architecture)" in
  amd64|arm64) ;;
  *)
    echo "The Tor Project repository supports amd64 and arm64." >&2
    exit 1
    ;;
esac

command -v wget >/dev/null || { echo "wget is required." >&2; exit 1; }
command -v gpg >/dev/null || { echo "gpg is required." >&2; exit 1; }
command -v ss >/dev/null || { echo "ss is required." >&2; exit 1; }

SOCKS_PORT="${1:-9050}"
if ! [[ $SOCKS_PORT =~ ^[0-9]+$ ]] || (( SOCKS_PORT < 1024 || SOCKS_PORT > 65535 )); then
  echo "SOCKS_PORT must be an integer from 1024 to 65535." >&2
  exit 1
fi

printf '\n\033[1;34m==> Installing Tor\033[0m\n'
cat > /etc/apt/sources.list.d/tor.sources <<EOF_SOURCE
Types: deb deb-src
URIs: https://deb.torproject.org/torproject.org/
Suites: $VERSION_CODENAME
Components: main
Signed-By: /usr/share/keyrings/deb.torproject.org-keyring.gpg
EOF_SOURCE

wget -qO- https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc \
  | gpg --dearmor \
  > /usr/share/keyrings/deb.torproject.org-keyring.gpg

apt-get update
apt-get install -y tor deb.torproject.org-keyring

if [[ ! -f /etc/tor/torrc ]]; then
  echo "/etc/tor/torrc was not created by the package." >&2
  exit 1
fi

BACKUP_DIR="/var/backups/deepwebproxy-backups/tor/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$BACKUP_DIR"
cp -a /etc/tor/torrc "$BACKUP_DIR/torrc"

printf '\n\033[1;34m==> Configuring Tor\033[0m\n'

# Keep the configuration installed by the package. Disable only active
# directives that conflict with the client configuration below.
sed -i '/^# BEGIN DeepWebProxy$/,/^# END DeepWebProxy$/d' /etc/tor/torrc
sed -i -E '/^[[:space:]]*(ClientOnly|ExitRelay|BridgeRelay|ORPort|DirPort|SocksPort|SocksPolicy)[[:space:]]/s/^/# /' /etc/tor/torrc

cat >> /etc/tor/torrc <<EOF_TORRC

# BEGIN DeepWebProxy
ClientOnly 1
ExitRelay 0
BridgeRelay 0
ORPort 0
DirPort 0
SocksPort 127.0.0.1:$SOCKS_PORT IsolateSOCKSAuth
SocksPolicy accept 127.0.0.1
SocksPolicy reject *
# END DeepWebProxy
EOF_TORRC

if ! tor --verify-config -f /etc/tor/torrc >/dev/null; then
  cp -a "$BACKUP_DIR/torrc" /etc/tor/torrc
  echo "The Tor configuration is invalid; the backup was restored." >&2
  exit 1
fi

systemctl enable tor@default.service >/dev/null
if ! systemctl restart tor@default.service; then
  cp -a "$BACKUP_DIR/torrc" /etc/tor/torrc
  systemctl restart tor@default.service 2>/dev/null || true
  journalctl -u tor@default.service -n 50 --no-pager >&2 || true
  echo "Tor did not start; the previous configuration was restored." >&2
  exit 1
fi

systemctl is-active --quiet tor@default.service
sleep 2

if ! ss -H -ltn | awk '{print $4}' | grep -Eq "^127\\.0\\.0\\.1:${SOCKS_PORT}$"; then
  cp -a "$BACKUP_DIR/torrc" /etc/tor/torrc
  systemctl restart tor@default.service 2>/dev/null || true
  echo "Tor did not open 127.0.0.1:$SOCKS_PORT; the previous configuration was restored." >&2
  exit 1
fi

printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m Tor installed and running.\033[0m\n'
printf '\033[1;32m Mode: client only\033[0m\n'
printf '\033[1;32m SOCKS5: 127.0.0.1:%s\033[0m\n' "$SOCKS_PORT"
printf '\033[1;32m Config: /etc/tor/torrc\033[0m\n'
printf '\033[1;32m Backup: %s\033[0m\n' "$BACKUP_DIR"
printf '\033[1;32m============================================================\033[0m\n'