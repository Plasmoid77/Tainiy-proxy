#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

REPO_URL="https://deb.torproject.org/torproject.org/"
KEY_URL="https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc"
KEY_FINGERPRINT="A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89"
KEYRING="/usr/share/keyrings/deb.torproject.org-keyring.gpg"
SOURCE_FILE="/etc/apt/sources.list.d/tor.sources"
TORRC="/etc/tor/torrc"
SERVICE="tor@default.service"
SYSTEMD_OVERRIDE="/etc/systemd/system/tor@default.service.d/10-deepwebproxy.conf"
BACKUP_DIR="/var/backups/deepwebproxy-backups/tor/$(date -u +%Y%m%dT%H%M%SZ)-$$"
SOCKS_PORT="${1:-9050}"
TMP_DIR=""
SERVICE_WAS_ACTIVE=false
SERVICE_WAS_ENABLED=false

BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

log()  { printf '\n%b==>%b %s\n' "$BLUE" "$RESET" "$*"; }
warn() { printf '%bWARNING:%b %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%bERROR:%b %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

cleanup() {
  [[ -z ${TMP_DIR} || ! -d ${TMP_DIR} ]] || rm -rf -- "${TMP_DIR}"
}
trap cleanup EXIT
trap 'printf "\n%bERROR:%b Command failed on line %s.\n" "$RED" "$RESET" "$LINENO" >&2' ERR

backup() {
  local path="$1" name="$2"
  [[ ! -e ${path} && ! -L ${path} ]] || cp -a -- "${path}" "${BACKUP_DIR}/${name}"
}

restore() {
  local name="$1" path="$2"
  rm -rf -- "${path}"
  [[ ! -e ${BACKUP_DIR}/${name} && ! -L ${BACKUP_DIR}/${name} ]] || \
    cp -a -- "${BACKUP_DIR}/${name}" "${path}"
}

port_is_available() {
  if ! ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[.:])${SOCKS_PORT}$"; then
    return 0
  fi
  systemctl is-active --quiet "${SERVICE}" && \
    ss -H -ltnp 2>/dev/null | grep -Eq "127\\.0\\.0\\.1:${SOCKS_PORT}.*tor"
}

rollback() {
  warn "Restoring the previous Tor configuration"
  restore torrc "${TORRC}"
  restore systemd-override.conf "${SYSTEMD_OVERRIDE}"
  systemctl daemon-reload
  if [[ ${SERVICE_WAS_ACTIVE} == true ]]; then
    systemctl restart "${SERVICE}" || true
  else
    systemctl stop "${SERVICE}" || true
  fi
  [[ ${SERVICE_WAS_ENABLED} == true ]] || systemctl disable "${SERVICE}" >/dev/null 2>&1 || true
}

[[ ${EUID} -eq 0 ]] || die "Run this script as root: sudo bash tor-client-setup.sh"
[[ -r /etc/os-release ]] || die "/etc/os-release was not found"
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_CODENAME:-} == trixie ]] || \
  die "This installer is intended for Debian 13 (trixie)"

ARCH="$(dpkg --print-architecture)"
[[ ${ARCH} == amd64 || ${ARCH} == arm64 ]] || \
  die "The Tor Project repository supports amd64 and arm64; detected: ${ARCH}"
[[ ${SOCKS_PORT} =~ ^[0-9]+$ ]] && (( SOCKS_PORT >= 1024 && SOCKS_PORT <= 65535 )) || \
  die "SOCKS port must be between 1024 and 65535"

systemctl is-active --quiet "${SERVICE}" && SERVICE_WAS_ACTIVE=true
systemctl is-enabled --quiet "${SERVICE}" && SERVICE_WAS_ENABLED=true
install -d -m 0700 "${BACKUP_DIR}"
backup "${SOURCE_FILE}" tor.sources
backup "${KEYRING}" tor-keyring.gpg
backup "${SYSTEMD_OVERRIDE}" systemd-override.conf
[[ ! -f ${TORRC} ]] || backup "${TORRC}" torrc

log "Installing repository dependencies"
apt-get update
apt-get install -y --no-install-recommends apt-transport-https ca-certificates curl gnupg iproute2
port_is_available || die "TCP port ${SOCKS_PORT} is already used by another service"

log "Adding the official Tor Project repository"
TMP_DIR="$(mktemp -d)"
install -d -m 0700 "${TMP_DIR}/gnupg"
curl -fsSL "${KEY_URL}" -o "${TMP_DIR}/key.asc"
FINGERPRINT="$(gpg --batch --homedir "${TMP_DIR}/gnupg" --show-keys --with-colons "${TMP_DIR}/key.asc" | awk -F: '$1=="fpr" {print $10; exit}')"
[[ ${FINGERPRINT} == "${KEY_FINGERPRINT}" ]] || \
  die "Unexpected Tor repository key fingerprint: ${FINGERPRINT:-not detected}"

gpg --batch --yes --homedir "${TMP_DIR}/gnupg" --dearmor \
  --output "${TMP_DIR}/tor.gpg" "${TMP_DIR}/key.asc"
install -d -m 0755 "$(dirname "${KEYRING}")"
install -o root -g root -m 0644 "${TMP_DIR}/tor.gpg" "${KEYRING}"
cat > "${SOURCE_FILE}" <<EOF_SOURCE
Types: deb
URIs: ${REPO_URL}
Suites: trixie
Components: main
Signed-By: ${KEYRING}
EOF_SOURCE
chmod 0644 "${SOURCE_FILE}"

if ! apt-get update; then
  restore tor.sources "${SOURCE_FILE}"
  restore tor-keyring.gpg "${KEYRING}"
  apt-get update || true
  die "APT could not use the Tor Project repository"
fi
if ! apt-cache policy tor 2>/dev/null | grep -Fq "deb.torproject.org"; then
  restore tor.sources "${SOURCE_FILE}"
  restore tor-keyring.gpg "${KEYRING}"
  die "The Tor Project repository did not provide a package candidate"
fi

log "Installing or updating Tor"
apt-get install -y --no-install-recommends tor deb.torproject.org-keyring
[[ -f ${TORRC} ]] || die "Tor configuration was not created"
[[ -e ${BACKUP_DIR}/torrc ]] || cp -a -- "${TORRC}" "${BACKUP_DIR}/torrc"

log "Configuring Tor as a local client"
cat > "${TORRC}" <<EOF_TORRC
# Managed by DeepWebProxy. This instance is a client only.
ClientOnly 1
ExitRelay 0
BridgeRelay 0
ORPort 0
DirPort 0
SocksPort 127.0.0.1:${SOCKS_PORT} IsolateSOCKSAuth
SocksPolicy accept 127.0.0.1
SocksPolicy reject *
Log notice syslog
EOF_TORRC
chmod 0644 "${TORRC}"

install -d -m 0755 "$(dirname "${SYSTEMD_OVERRIDE}")"
cat > "${SYSTEMD_OVERRIDE}" <<'DROPIN'
[Service]
Restart=on-failure
RestartSec=5s
DROPIN
chmod 0644 "${SYSTEMD_OVERRIDE}"
systemctl daemon-reload

log "Validating the Tor configuration"
tor --verify-config -f "${TORRC}" >/dev/null || { rollback; die "Tor configuration is invalid"; }

log "Enabling and restarting Tor"
systemctl enable "${SERVICE}" >/dev/null
if ! systemctl restart "${SERVICE}"; then
  rollback
  journalctl -u "${SERVICE}" -n 100 --no-pager >&2 || true
  die "Tor did not start"
fi

SOCKS_READY=false
for _ in $(seq 1 30); do
  if systemctl is-active --quiet "${SERVICE}" && \
     ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "127\\.0\\.0\\.1:${SOCKS_PORT}$"; then
    SOCKS_READY=true
    break
  fi
  sleep 1
done

if [[ ${SOCKS_READY} != true ]]; then
  rollback
  journalctl -u "${SERVICE}" -n 100 --no-pager >&2 || true
  die "Tor SOCKS5 listener did not appear on 127.0.0.1:${SOCKS_PORT}"
fi

BOOTSTRAP="in progress"
for _ in $(seq 1 30); do
  if journalctl -u "${SERVICE}" -n 250 --no-pager 2>/dev/null | grep -q 'Bootstrapped 100%'; then
    BOOTSTRAP="100% complete"
    break
  fi
  sleep 2
done
[[ ${BOOTSTRAP} == "100% complete" ]] || warn "Tor is running, but bootstrap has not reached 100% yet"

VERSION="$(tor --version 2>/dev/null | head -n 1 || true)"
printf '\n%b%s%b\n' "$GREEN" "============================================================" "$RESET"
printf '%b Tor client installed and running.%b\n' "$GREEN" "$RESET"
printf '%b Version: %s%b\n' "$GREEN" "${VERSION:-unknown}" "$RESET"
printf '%b Mode: client only; relay, bridge and exit disabled%b\n' "$GREEN" "$RESET"
printf '%b SOCKS5: 127.0.0.1:%s%b\n' "$GREEN" "$SOCKS_PORT" "$RESET"
printf '%b Bootstrap: %s%b\n' "$GREEN" "$BOOTSTRAP" "$RESET"
printf '%b Config: %s%b\n' "$GREEN" "$TORRC" "$RESET"
printf '%b Backup: %s%b\n' "$GREEN" "$BACKUP_DIR" "$RESET"
printf '%b Test: curl --socks5-hostname 127.0.0.1:%s https://check.torproject.org/api/ip%b\n' "$GREEN" "$SOCKS_PORT" "$RESET"
printf '%b%s%b\n' "$GREEN" "============================================================" "$RESET"