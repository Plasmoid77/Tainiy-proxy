#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "\n[ERROR] Command failed on line %s.\n" "$LINENO" >&2' ERR

CONFIG_FILE="/etc/i2pd/i2pd.conf"
SERVICE_NAME="i2pd.service"

log() {
  printf '\033[1;34m==>\033[0m %s\n' "$*"
}

die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

if [[ ${EUID} -ne 0 ]]; then
  die "Run this script as root, for example: sudo bash i2pd-router-setup.sh"
fi

if [[ ! -r /etc/os-release ]]; then
  die "/etc/os-release was not found"
fi

# shellcheck disable=SC1091
. /etc/os-release

if [[ ${ID:-} != "debian" || ${VERSION_CODENAME:-} != "trixie" ]]; then
  die "This installer is intended for Debian 13 (trixie)"
fi

ROUTER_PORT="${1:-}"
BANDWIDTH="${2:-P}"
TRANSIT_SHARE="${3:-100}"

if [[ -n ${ROUTER_PORT} ]]; then
  if ! [[ ${ROUTER_PORT} =~ ^[0-9]+$ ]]; then
    die "The port must be an integer from 1024 to 65535"
  fi
  if (( ROUTER_PORT < 1024 || ROUTER_PORT > 65535 )); then
    die "The port must be an integer from 1024 to 65535"
  fi
fi

if ! [[ ${BANDWIDTH} =~ ^([LOPX]|[1-9][0-9]*)$ ]]; then
  die "Bandwidth must be L, O, P, X, or an integer in KiB/s"
fi

if ! [[ ${TRANSIT_SHARE} =~ ^[0-9]+$ ]] || (( TRANSIT_SHARE < 0 || TRANSIT_SHARE > 100 )); then
  die "Transit share must be an integer from 0 to 100"
fi

log "Installing i2pd from the Debian 13 repository"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends i2pd ca-certificates iproute2

[[ -f ${CONFIG_FILE} ]] || die "Expected configuration file ${CONFIG_FILE} was not created"

get_global_option() {
  local key="$1"
  awk -v key="${key}" '
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
        sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
        sub(/[[:space:]]*(#.*)?$/, "", line)
        print line
        exit
      }
    }
  ' "${CONFIG_FILE}"
}

port_is_free() {
  local port="$1"
  ! ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|[.:])${port}$"
}

pick_random_port() {
  local candidate
  for _ in $(seq 1 100); do
    candidate=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
    candidate=$((20000 + candidate % 40001))
    if port_is_free "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

if [[ -z ${ROUTER_PORT} ]]; then
  EXISTING_PORT=$(get_global_option port || true)
  if [[ ${EXISTING_PORT:-} =~ ^[0-9]+$ ]] && \
     (( EXISTING_PORT >= 1024 && EXISTING_PORT <= 65535 )); then
    ROUTER_PORT="${EXISTING_PORT}"
  else
    ROUTER_PORT=$(pick_random_port) || die "Could not select a free router port"
  fi
fi

if ! port_is_free "${ROUTER_PORT}"; then
  # It may already belong to a currently running i2pd instance, which is fine.
  CURRENT_PORT=$(get_global_option port || true)
  if [[ ${CURRENT_PORT:-} != "${ROUTER_PORT}" ]]; then
    die "Port ${ROUTER_PORT} is already in use"
  fi
fi

if command -v ip >/dev/null 2>&1 && ip -6 address show scope global | grep -q 'inet6 '; then
  ENABLE_IPV6=true
else
  ENABLE_IPV6=false
fi

BACKUP_FILE="${CONFIG_FILE}.vps-toolkit.$(date -u +%Y%m%dT%H%M%SZ).bak"
cp -a "${CONFIG_FILE}" "${BACKUP_FILE}"
log "Configuration backup: ${BACKUP_FILE}"

set_global_option() {
  local key="$1"
  local value="$2"
  local tmp
  tmp=$(mktemp)

  awk -v key="${key}" -v value="${value}" '
    BEGIN { done = 0; in_global = 1 }
    {
      if (in_global && !done) {
        testline = $0
        sub(/^[[:space:]]*#[[:space:]]*/, "", testline)

        if (testline ~ "^[[:space:]]*" key "[[:space:]]*=") {
          print key " = " value
          done = 1
          next
        }

        if ($0 ~ "^[[:space:]]*\\[") {
          print key " = " value
          print ""
          done = 1
          in_global = 0
        }
      }
      print
    }
    END {
      if (!done) {
        print ""
        print key " = " value
      }
    }
  ' "${CONFIG_FILE}" > "${tmp}"

  install -o root -g root -m 0644 "${tmp}" "${CONFIG_FILE}"
  rm -f "${tmp}"
}

log "Configuring i2pd as a transit router"
set_global_option port "${ROUTER_PORT}"
set_global_option ipv4 true
set_global_option ipv6 "${ENABLE_IPV6}"
set_global_option bandwidth "${BANDWIDTH}"
set_global_option share "${TRANSIT_SHARE}"
set_global_option notransit false
set_global_option floodfill false

install -d -m 0755 /etc/systemd/system/i2pd.service.d
cat > /etc/systemd/system/i2pd.service.d/10-vps-toolkit.conf <<'OVERRIDE'
[Service]
Restart=on-failure
RestartSec=5s
OVERRIDE

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null
systemctl restart "${SERVICE_NAME}"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  log "Opening i2pd transport port in UFW"
  ufw allow "${ROUTER_PORT}/tcp" comment 'i2pd NTCP2' >/dev/null
  ufw allow "${ROUTER_PORT}/udp" comment 'i2pd SSU2' >/dev/null
fi

if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
  journalctl -u "${SERVICE_NAME}" -n 80 --no-pager >&2 || true
  die "i2pd did not start"
fi

I2PD_VERSION=$(i2pd --version 2>&1 | head -n 1 || true)

echo
printf '\033[1;32m%s\033[0m\n' "============================================================"
printf '\033[1;32m i2pd router installed and running.\033[0m\n'
printf ' Version: %s\n' "${I2PD_VERSION:-unknown}"
printf ' Transport port: %s/TCP and %s/UDP\n' "${ROUTER_PORT}" "${ROUTER_PORT}"
printf ' Bandwidth class/limit: %s\n' "${BANDWIDTH}"
printf ' Transit share: %s%%\n' "${TRANSIT_SHARE}"
printf ' IPv6 enabled: %s\n' "${ENABLE_IPV6}"
printf ' Web console: http://127.0.0.1:7070\n'
printf '\033[1;32m%s\033[0m\n' "============================================================"
echo
printf 'To reach the console remotely, use an SSH tunnel:\n'
printf '  ssh -L 7070:127.0.0.1:7070 USER@SERVER\n'
