#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

TOR_SOURCE_FILE="/etc/apt/sources.list.d/tor.sources"
TOR_KEYRING="/usr/share/keyrings/deb.torproject.org-keyring.gpg"
TOR_PREFERENCES_FILE="/etc/apt/preferences.d/torproject.pref"
TOR_KEY_URL="https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc"
TOR_KEY_FINGERPRINT="A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89"
TOR_REPOSITORY="https://deb.torproject.org/torproject.org/"
TORRC="/etc/tor/torrc"
TORRC_DIR="/etc/tor/torrc.d"
MANAGED_CONFIG="${TORRC_DIR}/10-vps-toolkit-client.conf"
SERVICE_NAME="tor@default.service"
SOCKS_ADDRESS="127.0.0.1"
SOCKS_PORT="${1:-9050}"
TMP_DIR=""

BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

cleanup() {
  if [[ -n ${TMP_DIR} && -d ${TMP_DIR} ]]; then
    rm -rf "${TMP_DIR}"
  fi
}

trap cleanup EXIT
trap 'printf "\n%bERROR:%b Command failed on line %s.\n" "$RED" "$RESET" "$LINENO" >&2' ERR

log() {
  printf '\n%b==>%b %s\n' "$BLUE" "$RESET" "$*"
}

warn() {
  printf '%bWARNING:%b %s\n' "$YELLOW" "$RESET" "$*" >&2
}

die() {
  printf '%bERROR:%b %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

if [[ ${EUID} -ne 0 ]]; then
  die "Run this script as root, for example: sudo bash tor-client-setup.sh"
fi

if [[ ! -r /etc/os-release ]]; then
  die "/etc/os-release was not found"
fi

# shellcheck disable=SC1091
. /etc/os-release

if [[ ${ID:-} != "debian" || ${VERSION_CODENAME:-} != "trixie" ]]; then
  die "This installer is intended for Debian 13 (trixie)"
fi

ARCHITECTURE="$(dpkg --print-architecture)"
case "${ARCHITECTURE}" in
  amd64|arm64)
    ;;
  *)
    die "The official Tor Project repository supports amd64 and arm64; detected: ${ARCHITECTURE}"
    ;;
esac

if ! [[ ${SOCKS_PORT} =~ ^[0-9]+$ ]] || (( SOCKS_PORT < 1024 || SOCKS_PORT > 65535 )); then
  die "The SOCKS port must be an integer from 1024 to 65535"
fi

port_is_available_for_tor() {
  local port="$1"

  if ! command -v ss >/dev/null 2>&1; then
    return 0
  fi

  if ! ss -H -ltn 2>/dev/null | awk '{ print $4 }' | grep -Eq "(^|[.:])${port}$"; then
    return 0
  fi

  # Re-running the installer is allowed if the existing listener belongs to Tor.
  if systemctl is-active --quiet "${SERVICE_NAME}" && \
     ss -H -ltnp 2>/dev/null | grep -Eq "127\\.0\\.0\\.1:${port}.*tor"; then
    return 0
  fi

  return 1
}

log "Installing repository dependencies"
apt-get update
apt-get install -y --no-install-recommends \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  iproute2

if ! port_is_available_for_tor "${SOCKS_PORT}"; then
  die "TCP port ${SOCKS_PORT} is already used by another service"
fi

log "Importing and verifying the Tor Project repository key"
TMP_DIR="$(mktemp -d)"
curl -fsSL "${TOR_KEY_URL}" -o "${TMP_DIR}/tor-signing-key.asc"

IMPORTED_FINGERPRINT="$(
  gpg --batch --show-keys --with-colons "${TMP_DIR}/tor-signing-key.asc" \
    | awk -F: '$1 == "fpr" { print $10; exit }'
)"

if [[ ${IMPORTED_FINGERPRINT} != "${TOR_KEY_FINGERPRINT}" ]]; then
  die "Unexpected Tor repository key fingerprint: ${IMPORTED_FINGERPRINT:-not detected}"
fi

install -d -m 0755 "$(dirname "${TOR_KEYRING}")"
gpg --batch --yes \
  --dearmor \
  --output "${TMP_DIR}/deb.torproject.org-keyring.gpg" \
  "${TMP_DIR}/tor-signing-key.asc"
install -o root -g root -m 0644 \
  "${TMP_DIR}/deb.torproject.org-keyring.gpg" \
  "${TOR_KEYRING}"

log "Adding the official Tor Project repository for Debian 13"
cat > "${TOR_SOURCE_FILE}" <<EOF_REPOSITORY
Types: deb
URIs: ${TOR_REPOSITORY}
Suites: trixie
Components: main
Signed-By: ${TOR_KEYRING}
EOF_REPOSITORY

cat > "${TOR_PREFERENCES_FILE}" <<'EOF_PREFERENCES'
Package: tor tor-geoipdb deb.torproject.org-keyring
Pin: origin "deb.torproject.org"
Pin-Priority: 700
EOF_PREFERENCES

log "Installing or updating Tor from the Tor Project repository"
apt-get update
apt-get install -y --no-install-recommends tor deb.torproject.org-keyring

[[ -f ${TORRC} ]] || die "Expected Tor configuration file ${TORRC} was not created"

BACKUP_DIR="/etc/tor/vps-toolkit-backups/$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "${BACKUP_DIR}"
cp -a "${TORRC}" "${BACKUP_DIR}/torrc"

MANAGED_CONFIG_EXISTED=false
if [[ -f ${MANAGED_CONFIG} ]]; then
  MANAGED_CONFIG_EXISTED=true
  cp -a "${MANAGED_CONFIG}" "${BACKUP_DIR}/10-vps-toolkit-client.conf"
fi

log "Configuring Tor as a standalone local SOCKS5 client"
install -d -m 0755 "${TORRC_DIR}"

if ! grep -Eq '^[[:space:]]*%include[[:space:]]+/etc/tor/torrc\.d/\*\.conf[[:space:]]*$' "${TORRC}"; then
  {
    printf '\n'
    printf '%s\n' '# Load modular Tor configuration snippets managed by VPS-toolkit.'
    printf '%s\n' '%include /etc/tor/torrc.d/*.conf'
  } >> "${TORRC}"
fi

cat > "${MANAGED_CONFIG}" <<EOF_TORRC
# Managed by VPS-toolkit.
# Tor is a client only. The SOCKS5 listener is intentionally local and is
# suitable for local applications or a later Tinyproxy upstream configuration.

ClientOnly 1
ExitRelay 0
BridgeRelay 0

/ORPort
ORPort 0
/DirPort
DirPort 0

/SocksPort
SocksPort ${SOCKS_ADDRESS}:${SOCKS_PORT} IsolateSOCKSAuth

/SocksPolicy
SocksPolicy accept ${SOCKS_ADDRESS}
SocksPolicy reject *
EOF_TORRC

chmod 0644 "${TORRC}" "${MANAGED_CONFIG}"

log "Configuring systemd ordering and automatic restart"
install -d -m 0755 "/etc/systemd/system/${SERVICE_NAME}.d"
cat > "/etc/systemd/system/${SERVICE_NAME}.d/10-vps-toolkit.conf" <<'EOF_SYSTEMD'
[Unit]
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
RestartSec=5s
EOF_SYSTEMD

systemctl daemon-reload

log "Checking UFW integration"
UFW_RESULT="not installed"
if command -v ufw >/dev/null 2>&1; then
  if UFW_STATUS="$(ufw status verbose 2>/dev/null)" && grep -q '^Status: active' <<< "${UFW_STATUS}"; then
    UFW_RESULT="active; no inbound rule required"

    # Tor client connections are outbound and use relay-defined TCP ports.
    # The common VPS-toolkit UFW policy allows outbound traffic, so no rule is
    # necessary. Do not silently weaken a deliberate deny-outgoing policy.
    if grep -Eq '^Default:.*(deny|reject) \(outgoing\)' <<< "${UFW_STATUS}"; then
      warn "UFW blocks outgoing traffic. Tor uses variable remote TCP ports, so no narrow port rule can make it reliable."
      warn "Allow the required outbound policy manually before expecting Tor to bootstrap."
      UFW_RESULT="active; outgoing traffic is blocked"
    fi
  else
    UFW_RESULT="installed but inactive; unchanged"
    warn "UFW is installed but is not active or not working; no firewall rules were changed"
  fi
fi

log "Validating the Tor configuration"
if ! tor --verify-config -f "${TORRC}" >/dev/null; then
  warn "Tor configuration validation failed; restoring the previous configuration"
  cp -a "${BACKUP_DIR}/torrc" "${TORRC}"
  if [[ ${MANAGED_CONFIG_EXISTED} == true ]]; then
    cp -a "${BACKUP_DIR}/10-vps-toolkit-client.conf" "${MANAGED_CONFIG}"
  else
    rm -f "${MANAGED_CONFIG}"
  fi
  die "Tor configuration is invalid"
fi

log "Enabling and starting Tor"
systemctl enable "${SERVICE_NAME}" >/dev/null

if ! systemctl restart "${SERVICE_NAME}"; then
  warn "Tor failed to start; restoring the previous configuration"
  cp -a "${BACKUP_DIR}/torrc" "${TORRC}"
  if [[ ${MANAGED_CONFIG_EXISTED} == true ]]; then
    cp -a "${BACKUP_DIR}/10-vps-toolkit-client.conf" "${MANAGED_CONFIG}"
  else
    rm -f "${MANAGED_CONFIG}"
  fi
  systemctl restart "${SERVICE_NAME}" || true
  journalctl -u "${SERVICE_NAME}" -n 100 --no-pager >&2 || true
  die "Tor did not start"
fi

if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
  journalctl -u "${SERVICE_NAME}" -n 100 --no-pager >&2 || true
  die "Tor is not active after restart"
fi

SOCKS_READY=false
for _ in $(seq 1 20); do
  if ss -H -ltn 2>/dev/null | awk '{ print $4 }' | grep -Eq "127\\.0\\.0\\.1:${SOCKS_PORT}$"; then
    SOCKS_READY=true
    break
  fi
  sleep 1
done

if [[ ${SOCKS_READY} != true ]]; then
  journalctl -u "${SERVICE_NAME}" -n 100 --no-pager >&2 || true
  die "Tor is running but the SOCKS5 listener did not appear on ${SOCKS_ADDRESS}:${SOCKS_PORT}"
fi

BOOTSTRAP_STATUS="in progress"
for _ in $(seq 1 30); do
  if journalctl -u "${SERVICE_NAME}" -n 200 --no-pager 2>/dev/null \
      | grep -q 'Bootstrapped 100%'; then
    BOOTSTRAP_STATUS="100% complete"
    break
  fi
  sleep 2
done

if [[ ${BOOTSTRAP_STATUS} != "100% complete" ]]; then
  warn "Tor is running and SOCKS5 is available, but bootstrap has not reached 100% yet"
fi

TOR_VERSION="$(tor --version 2>/dev/null | head -n 1 || true)"
PACKAGE_VERSION="$(dpkg-query -W -f='${Version}' tor 2>/dev/null || true)"

printf '\n%b%s%b\n' "${GREEN}" "============================================================" "${RESET}"
printf '%b Tor client installed and running.%b\n' "${GREEN}" "${RESET}"
printf '%b Binary: %s%b\n' "${GREEN}" "${TOR_VERSION:-unknown}" "${RESET}"
printf '%b Package: %s%b\n' "${GREEN}" "${PACKAGE_VERSION:-unknown}" "${RESET}"
printf '%b Repository: %s (trixie)%b\n' "${GREEN}" "${TOR_REPOSITORY}" "${RESET}"
printf '%b Mode: client only; relay and exit functions disabled%b\n' "${GREEN}" "${RESET}"
printf '%b SOCKS5: %s:%s%b\n' "${GREEN}" "${SOCKS_ADDRESS}" "${SOCKS_PORT}" "${RESET}"
printf '%b Bootstrap: %s%b\n' "${GREEN}" "${BOOTSTRAP_STATUS}" "${RESET}"
printf '%b UFW: %s%b\n' "${GREEN}" "${UFW_RESULT}" "${RESET}"
printf '%b Config: %s%b\n' "${GREEN}" "${MANAGED_CONFIG}" "${RESET}"
printf '%b Local test: curl --socks5-hostname %s:%s https://check.torproject.org/api/ip%b\n' \
  "${GREEN}" "${SOCKS_ADDRESS}" "${SOCKS_PORT}" "${RESET}"
printf '%b Remote use: ssh -L %s:%s:%s USER@SERVER%b\n' \
  "${GREEN}" "${SOCKS_PORT}" "${SOCKS_ADDRESS}" "${SOCKS_PORT}" "${RESET}"
printf '%b%s%b\n' "${GREEN}" "============================================================" "${RESET}"