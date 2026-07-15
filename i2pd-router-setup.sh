#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

REPO_URL="https://repo.i2pd.xyz/debian"
KEY_URL="https://repo.i2pd.xyz/r4sas.gpg"
KEY_ID="66F6C87B98EBCFE2"
KEYRING="/etc/apt/keyrings/i2pd.gpg"
SOURCE_FILE="/etc/apt/sources.list.d/i2pd.list"
CONFIG_FILE="/etc/i2pd/i2pd.conf"
SERVICE="i2pd.service"
SYSTEMD_OVERRIDE="/etc/systemd/system/i2pd.service.d/20-deepwebproxy-restart.conf"
BACKUP_DIR="/var/backups/deepwebproxy-backups/i2pd/$(date -u +%Y%m%dT%H%M%SZ)-$$"
TMP_DIR=""
SERVICE_WAS_ACTIVE=false
SERVICE_WAS_ENABLED=false

ROUTER_PORT="${1:-}"
BANDWIDTH="${2:-X}"
TRANSIT_SHARE="${3:-100}"
FLOODFILL="${4:-false}"

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

get_global_option() {
  local key="$1"
  awk -v key="${key}" '
    /^[[:space:]]*\[/ {exit}
    /^[[:space:]]*[#;]/ {next}
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line=$0
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
      sub(/[[:space:]]*([#;].*)?$/, "", line)
      print line
      exit
    }
  ' "${CONFIG_FILE}"
}

set_option() {
  local section="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  awk -v section="${section}" -v key="${key}" -v value="${value}" '
    function section_name(line, name) {
      name=line
      sub(/^[[:space:]]*\[/, "", name)
      sub(/\][[:space:]]*([#;].*)?$/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      return name
    }
    function is_key(line, text) {
      text=line
      sub(/^[[:space:]]*[#;][[:space:]]*/, "", text)
      return text ~ ("^[[:space:]]*" key "[[:space:]]*=")
    }
    BEGIN {
      in_target=(section == "")
      section_seen=(section == "")
      written=0
    }
    /^[[:space:]]*\[[^]]+\]/ {
      if (in_target && !written) {
        print key " = " value
        written=1
      }
      in_target=(section_name($0) == section)
      if (in_target) section_seen=1
      print
      next
    }
    {
      if (in_target && is_key($0)) {
        if (!written) {
          print key " = " value
          written=1
        }
        next
      }
      print
    }
    END {
      if (!section_seen) {
        if (NR) print ""
        print "[" section "]"
        print key " = " value
      } else if (in_target && !written) {
        print key " = " value
      }
    }
  ' "${CONFIG_FILE}" > "${tmp}"
  install -o root -g root -m 0644 "${tmp}" "${CONFIG_FILE}"
  rm -f -- "${tmp}"
}

port_is_free() {
  local port="$1"
  ! ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|[.:])${port}$"
}

pick_port() {
  local candidate
  for _ in $(seq 1 100); do
    candidate=$((9111 + $(od -An -N2 -tu2 /dev/urandom) % 21667))
    port_is_free "${candidate}" && { printf '%s\n' "${candidate}"; return 0; }
  done
  return 1
}

has_public_ipv6() {
  local cidr address first value
  while read -r cidr; do
    address="${cidr%/*}"
    first="${address%%:*}"
    [[ ${first} =~ ^[0-9A-Fa-f]+$ ]] || continue
    value=$((16#${first}))
    (( value >= 0x2000 && value <= 0x3fff )) && return 0
  done < <(ip -6 -o address show scope global 2>/dev/null | awk '{print $4}')
  return 1
}

rollback() {
  warn "Restoring the previous i2pd configuration"
  restore i2pd.conf "${CONFIG_FILE}"
  restore systemd-override.conf "${SYSTEMD_OVERRIDE}"
  systemctl daemon-reload
  if [[ ${SERVICE_WAS_ACTIVE} == true ]]; then
    systemctl restart "${SERVICE}" || true
  else
    systemctl stop "${SERVICE}" || true
  fi
  [[ ${SERVICE_WAS_ENABLED} == true ]] || systemctl disable "${SERVICE}" >/dev/null 2>&1 || true
}

[[ ${EUID} -eq 0 ]] || die "Run this script as root: sudo bash i2pd-router-setup.sh"
[[ -r /etc/os-release ]] || die "/etc/os-release was not found"
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_CODENAME:-} == trixie ]] || \
  die "This installer is intended for Debian 13 (trixie)"

[[ -z ${ROUTER_PORT} || ${ROUTER_PORT} =~ ^[0-9]+$ ]] || die "Port must be an integer"
[[ -z ${ROUTER_PORT} ]] || (( ROUTER_PORT >= 1024 && ROUTER_PORT <= 65535 )) || \
  die "Port must be between 1024 and 65535"
[[ ${BANDWIDTH} =~ ^([LOPX]|[1-9][0-9]*)$ ]] || \
  die "Bandwidth must be L, O, P, X, or an integer in KiB/s"
[[ ${TRANSIT_SHARE} =~ ^[0-9]+$ ]] && (( TRANSIT_SHARE <= 100 )) || \
  die "Transit share must be between 0 and 100"
[[ ${FLOODFILL} == true || ${FLOODFILL} == false ]] || \
  die "Floodfill must be true or false"

systemctl is-active --quiet "${SERVICE}" && SERVICE_WAS_ACTIVE=true
systemctl is-enabled --quiet "${SERVICE}" && SERVICE_WAS_ENABLED=true
install -d -m 0700 "${BACKUP_DIR}"
backup "${SOURCE_FILE}" i2pd.list
backup "${KEYRING}" i2pd.gpg
backup "${SYSTEMD_OVERRIDE}" systemd-override.conf
[[ ! -f ${CONFIG_FILE} ]] || backup "${CONFIG_FILE}" i2pd.conf

log "Installing repository dependencies"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg iproute2 ufw
[[ -f /etc/default/ufw ]] || die "/etc/default/ufw was not found"
grep -Eq '^IPV6=yes' /etc/default/ufw || \
  die "Set IPV6=yes in /etc/default/ufw before enabling Yggdrasil access"

log "Adding the i2pd repository"
TMP_DIR="$(mktemp -d)"
install -d -m 0700 "${TMP_DIR}/gnupg"
curl -fsSL "${KEY_URL}" -o "${TMP_DIR}/key.gpg"
if ! gpg --batch --homedir "${TMP_DIR}/gnupg" --show-keys --with-colons "${TMP_DIR}/key.gpg" \
    | awk -F: '$1=="fpr" {print $10}' | grep -Eq "${KEY_ID}$"; then
  die "Unexpected i2pd repository signing key"
fi

gpg --batch --yes --homedir "${TMP_DIR}/gnupg" \
  --import-options import-export --output "${TMP_DIR}/i2pd.gpg" --import "${TMP_DIR}/key.gpg"
install -d -m 0755 "$(dirname "${KEYRING}")"
install -o root -g root -m 0644 "${TMP_DIR}/i2pd.gpg" "${KEYRING}"
printf 'deb [signed-by=%s] %s trixie main\n' "${KEYRING}" "${REPO_URL}" > "${SOURCE_FILE}"
chmod 0644 "${SOURCE_FILE}"

if ! apt-get update; then
  restore i2pd.list "${SOURCE_FILE}"
  restore i2pd.gpg "${KEYRING}"
  apt-get update || true
  die "APT could not use the i2pd repository"
fi
if ! apt-cache policy i2pd 2>/dev/null | grep -Fq "repo.i2pd.xyz"; then
  restore i2pd.list "${SOURCE_FILE}"
  restore i2pd.gpg "${KEYRING}"
  die "The i2pd repository did not provide a package candidate"
fi

log "Installing or updating i2pd"
apt-get install -y --no-install-recommends i2pd
[[ -f ${CONFIG_FILE} ]] || die "i2pd configuration was not created"
[[ -e ${BACKUP_DIR}/i2pd.conf ]] || cp -a -- "${CONFIG_FILE}" "${BACKUP_DIR}/i2pd.conf"

if [[ -z ${ROUTER_PORT} ]]; then
  EXISTING_PORT="$(get_global_option port || true)"
  if [[ ${EXISTING_PORT} =~ ^[0-9]+$ ]] && (( EXISTING_PORT >= 1024 && EXISTING_PORT <= 65535 )); then
    ROUTER_PORT="${EXISTING_PORT}"
  else
    ROUTER_PORT="$(pick_port)" || die "Could not select a free router port"
  fi
fi

CURRENT_PORT="$(get_global_option port || true)"
if ! port_is_free "${ROUTER_PORT}" && [[ ${CURRENT_PORT} != "${ROUTER_PORT}" ]]; then
  die "Port ${ROUTER_PORT} is already in use"
fi

IPV6=false
has_public_ipv6 && IPV6=true

log "Configuring i2pd"
set_option "" port "${ROUTER_PORT}"
set_option "" ipv4 true
set_option "" ipv6 "${IPV6}"
set_option "" bandwidth "${BANDWIDTH}"
set_option "" share "${TRANSIT_SHARE}"
set_option "" notransit false
set_option "" floodfill "${FLOODFILL}"
set_option ntcp2 enabled true
set_option ntcp2 published true
set_option ntcp2 port "${ROUTER_PORT}"
set_option ssu2 enabled true
set_option ssu2 published true
set_option ssu2 port "${ROUTER_PORT}"
set_option meshnets yggdrasil true
set_option http enabled true
set_option http address 127.0.0.1
set_option http port 7070
set_option http strictheaders true
set_option http hostname localhost
set_option httpproxy enabled true
set_option httpproxy address 127.0.0.1
set_option httpproxy port 4444

install -d -m 0755 "$(dirname "${SYSTEMD_OVERRIDE}")"
cat > "${SYSTEMD_OVERRIDE}" <<'DROPIN'
[Service]
Restart=on-failure
RestartSec=5s
DROPIN
chmod 0644 "${SYSTEMD_OVERRIDE}"
systemctl daemon-reload

log "Enabling and restarting i2pd"
systemctl enable "${SERVICE}" >/dev/null
if ! systemctl restart "${SERVICE}"; then
  rollback
  journalctl -u "${SERVICE}" -n 100 --no-pager >&2 || true
  die "i2pd did not start"
fi

LISTENERS_READY=false
for _ in $(seq 1 30); do
  if systemctl is-active --quiet "${SERVICE}" && \
     ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[.:])${ROUTER_PORT}$" && \
     ss -H -lun 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[.:])${ROUTER_PORT}$"; then
    LISTENERS_READY=true
    break
  fi
  sleep 1
done

if [[ ${LISTENERS_READY} != true ]]; then
  rollback
  journalctl -u "${SERVICE}" -n 100 --no-pager >&2 || true
  die "i2pd transport listeners did not appear on port ${ROUTER_PORT}"
fi

log "Adding UFW rules"
ufw allow "${ROUTER_PORT}/tcp" comment 'DeepWebProxy i2pd NTCP2 and Yggdrasil' >/dev/null
ufw allow "${ROUTER_PORT}/udp" comment 'DeepWebProxy i2pd SSU2' >/dev/null
UFW_STATUS="$(ufw status | head -n 1 | sed 's/^Status: //')"

VERSION="$(i2pd --version 2>&1 | head -n 1 || true)"
printf '\n%b%s%b\n' "$GREEN" "============================================================" "$RESET"
printf '%b i2pd installed and running.%b\n' "$GREEN" "$RESET"
printf '%b Version: %s%b\n' "$GREEN" "${VERSION:-unknown}" "$RESET"
printf '%b Transport: %s/TCP and %s/UDP%b\n' "$GREEN" "$ROUTER_PORT" "$ROUTER_PORT" "$RESET"
printf '%b Bandwidth: %s; transit share: %s%%; floodfill: %s%b\n' "$GREEN" "$BANDWIDTH" "$TRANSIT_SHARE" "$FLOODFILL" "$RESET"
printf '%b Clearnet IPv6: %s; Yggdrasil transport: enabled%b\n' "$GREEN" "$IPV6" "$RESET"
printf '%b HTTP proxy: 127.0.0.1:4444%b\n' "$GREEN" "$RESET"
printf '%b Web console: http://127.0.0.1:7070%b\n' "$GREEN" "$RESET"
printf '%b UFW: %s; rules installed%b\n' "$GREEN" "${UFW_STATUS:-unknown}" "$RESET"
printf '%b Config: %s%b\n' "$GREEN" "$CONFIG_FILE" "$RESET"
printf '%b Backup: %s%b\n' "$GREEN" "$BACKUP_DIR" "$RESET"
printf '%b SSH tunnel: ssh -L 7070:127.0.0.1:7070 USER@SERVER%b\n' "$GREEN" "$RESET"
printf '%b%s%b\n' "$GREEN" "============================================================" "$RESET"
