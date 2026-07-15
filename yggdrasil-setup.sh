#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

REPO_URL="https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/"
KEY_URL="https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/key.txt"
KEY_FINGERPRINT="1C5162E133015D81A811239D1840CDAC6011C5EA"
KEYRING="/etc/apt/keyrings/yggdrasil.gpg"
SOURCE_FILE="/etc/apt/sources.list.d/yggdrasil.list"
SERVICE="yggdrasil.service"
I2PD_OVERRIDE="/etc/systemd/system/i2pd.service.d/10-deepwebproxy-yggdrasil.conf"
YGG_OVERRIDE="/etc/systemd/system/yggdrasil.service.d/10-deepwebproxy.conf"
BACKUP_DIR="/var/backups/deepwebproxy-backups/yggdrasil/$(date -u +%Y%m%dT%H%M%SZ)-$$"
TMP_DIR=""
CONFIG_FILE=""
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

find_config() {
  local path
  for path in /etc/yggdrasil/yggdrasil.conf /etc/yggdrasil.conf; do
    [[ ! -f ${path} ]] || { printf '%s\n' "${path}"; return 0; }
  done
  return 1
}

get_ygg_address() {
  local cidr address first value
  while read -r cidr; do
    address="${cidr%/*}"
    first="${address%%:*}"
    [[ ${first} =~ ^[0-9A-Fa-f]+$ ]] || continue
    value=$((16#${first}))
    if (( value >= 0x0200 && value <= 0x03ff )); then
      printf '%s\n' "${address}"
      return 0
    fi
  done < <(ip -6 -o address show scope global 2>/dev/null | awk '{print $4}')
  return 1
}

rollback() {
  warn "Restoring the previous startup configuration"
  restore i2pd-override.conf "${I2PD_OVERRIDE}"
  restore yggdrasil-override.conf "${YGG_OVERRIDE}"
  systemctl daemon-reload
  if [[ ${SERVICE_WAS_ACTIVE} == true ]]; then
    systemctl restart "${SERVICE}" || true
  else
    systemctl stop "${SERVICE}" || true
  fi
  [[ ${SERVICE_WAS_ENABLED} == true ]] || systemctl disable "${SERVICE}" >/dev/null 2>&1 || true
}

[[ ${EUID} -eq 0 ]] || die "Run this script as root: sudo bash yggdrasil-setup.sh"
[[ -r /etc/os-release ]] || die "/etc/os-release was not found"
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_CODENAME:-} == trixie ]] || \
  die "This installer is intended for Debian 13 (trixie)"

systemctl is-active --quiet "${SERVICE}" && SERVICE_WAS_ACTIVE=true
systemctl is-enabled --quiet "${SERVICE}" && SERVICE_WAS_ENABLED=true
install -d -m 0700 "${BACKUP_DIR}"
backup "${SOURCE_FILE}" yggdrasil.list
backup "${KEYRING}" yggdrasil.gpg
backup "${I2PD_OVERRIDE}" i2pd-override.conf
backup "${YGG_OVERRIDE}" yggdrasil-override.conf
CONFIG_FILE="$(find_config || true)"
[[ -z ${CONFIG_FILE} ]] || backup "${CONFIG_FILE}" yggdrasil.conf

log "Installing repository dependencies"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg iproute2

log "Adding the official Yggdrasil repository"
TMP_DIR="$(mktemp -d)"
install -d -m 0700 "${TMP_DIR}/gnupg"
curl -fsSL "${KEY_URL}" -o "${TMP_DIR}/key.asc"
FINGERPRINT="$(gpg --batch --homedir "${TMP_DIR}/gnupg" --show-keys --with-colons "${TMP_DIR}/key.asc" | awk -F: '$1=="fpr" {print $10; exit}')"
[[ ${FINGERPRINT} == "${KEY_FINGERPRINT}" ]] || \
  die "Unexpected Yggdrasil repository key fingerprint: ${FINGERPRINT:-not detected}"

install -d -m 0755 "$(dirname "${KEYRING}")"
gpg --batch --yes --homedir "${TMP_DIR}/gnupg" --dearmor \
  --output "${TMP_DIR}/yggdrasil.gpg" "${TMP_DIR}/key.asc"
install -o root -g root -m 0644 "${TMP_DIR}/yggdrasil.gpg" "${KEYRING}"
printf 'deb [signed-by=%s] %s debian yggdrasil\n' "${KEYRING}" "${REPO_URL}" > "${SOURCE_FILE}"
chmod 0644 "${SOURCE_FILE}"

if ! apt-get update; then
  restore yggdrasil.list "${SOURCE_FILE}"
  restore yggdrasil.gpg "${KEYRING}"
  apt-get update || true
  die "APT could not use the Yggdrasil repository"
fi
if ! apt-cache policy yggdrasil 2>/dev/null | grep -Fq "neilalexander.s3.dualstack.eu-west-2.amazonaws.com"; then
  restore yggdrasil.list "${SOURCE_FILE}"
  restore yggdrasil.gpg "${KEYRING}"
  die "The Yggdrasil repository did not provide a package candidate"
fi

log "Installing or updating Yggdrasil"
apt-get install -y --no-install-recommends yggdrasil
CONFIG_FILE="$(find_config)" || die "Yggdrasil configuration was not created"
[[ -e ${BACKUP_DIR}/yggdrasil.conf ]] || cp -a -- "${CONFIG_FILE}" "${BACKUP_DIR}/yggdrasil.conf"

log "Validating the Yggdrasil configuration"
yggdrasil -useconffile "${CONFIG_FILE}" -normaliseconf >/dev/null || \
  die "Yggdrasil configuration is invalid"

log "Configuring Yggdrasil-before-i2pd startup ordering"
install -d -m 0755 "$(dirname "${I2PD_OVERRIDE}")" "$(dirname "${YGG_OVERRIDE}")"
cat > "${I2PD_OVERRIDE}" <<'DROPIN'
[Unit]
After=network.target yggdrasil.service
DROPIN
cat > "${YGG_OVERRIDE}" <<'DROPIN'
[Service]
ExecStartPost=/bin/sleep 5
DROPIN
chmod 0644 "${I2PD_OVERRIDE}" "${YGG_OVERRIDE}"
systemctl daemon-reload

log "Enabling and restarting Yggdrasil"
systemctl enable "${SERVICE}" >/dev/null
if ! systemctl restart "${SERVICE}"; then
  rollback
  journalctl -u "${SERVICE}" -n 100 --no-pager >&2 || true
  die "Yggdrasil did not start"
fi

YGG_ADDRESS=""
for _ in $(seq 1 30); do
  if systemctl is-active --quiet "${SERVICE}" && YGG_ADDRESS="$(get_ygg_address)"; then
    break
  fi
  sleep 1
done

if [[ -z ${YGG_ADDRESS} ]]; then
  rollback
  journalctl -u "${SERVICE}" -n 100 --no-pager >&2 || true
  die "Yggdrasil is running, but its 0200::/7 address did not appear"
fi

VERSION="$(dpkg-query -W -f='${Version}' yggdrasil 2>/dev/null || true)"
printf '\n%b%s%b\n' "$GREEN" "============================================================" "$RESET"
printf '%b Yggdrasil installed and running.%b\n' "$GREEN" "$RESET"
printf '%b Version: %s%b\n' "$GREEN" "${VERSION:-unknown}" "$RESET"
printf '%b Address: %s%b\n' "$GREEN" "${YGG_ADDRESS}" "$RESET"
printf '%b Config: %s%b\n' "$GREEN" "${CONFIG_FILE}" "$RESET"
printf '%b i2pd ordering: after Yggdrasil plus 5-second delay%b\n' "$GREEN" "$RESET"
printf '%b Backup: %s%b\n' "$GREEN" "${BACKUP_DIR}" "$RESET"
printf '%b%s%b\n' "$GREEN" "============================================================" "$RESET"