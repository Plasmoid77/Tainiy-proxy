#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

YGG_REPO_URL="https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/"
YGG_KEY_URL="https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/key.txt"
YGG_KEY_FINGERPRINT="1C5162E133015D81A811239D1840CDAC6011C5EA"
YGG_KEYRING="/etc/apt/keyrings/yggdrasil.gpg"
YGG_SOURCE_FILE="/etc/apt/sources.list.d/yggdrasil.list"
YGG_CONFIG_CURRENT="/etc/yggdrasil/yggdrasil.conf"
YGG_CONFIG_LEGACY="/etc/yggdrasil.conf"
YGG_CONFIG=""
YGG_SERVICE="yggdrasil.service"
I2PD_SERVICE="i2pd.service"
BACKUP_ROOT="/var/backups/deepwebproxy-backups/yggdrasil"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
TMP_DIR=""

DEFAULT_PEERS=(
  "tls://ygg-msk-1.averyan.ru:8362"
  "tls://ru2.cert.dev:7041"
  "tls://yg-vvo.magicum.net:29331"
)

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

backup_if_exists() {
  local path="$1"
  local name="${2:-$(basename "$path")}"

  if [[ -e ${path} || -L ${path} ]]; then
    cp -a "${path}" "${BACKUP_DIR}/${name}"
  fi
}

restore_or_remove() {
  local backup_name="$1"
  local destination="$2"

  if [[ -e ${BACKUP_DIR}/${backup_name} || -L ${BACKUP_DIR}/${backup_name} ]]; then
    rm -rf "${destination}"
    cp -a "${BACKUP_DIR}/${backup_name}" "${destination}"
  else
    rm -rf "${destination}"
  fi
}

unit_exists() {
  local load_state=""
  load_state="$(systemctl show -p LoadState --value "$1" 2>/dev/null || true)"
  [[ -n ${load_state} && ${load_state} != "not-found" ]]
}

get_yggdrasil_address() {
  local cidr=""
  local address=""
  local first_hextet=""
  local value=""

  while read -r cidr; do
    [[ -n ${cidr} ]] || continue
    address="${cidr%/*}"
    first_hextet="${address%%:*}"
    [[ ${first_hextet} =~ ^[0-9A-Fa-f]+$ ]] || continue
    value=$((16#${first_hextet}))
    if (( value >= 0x0200 && value <= 0x03ff )); then
      printf '%s\n' "${address}"
      return 0
    fi
  done < <(ip -6 -o address show scope global 2>/dev/null | awk '{ print $4 }')

  return 1
}

has_yggdrasil_address() {
  get_yggdrasil_address >/dev/null
}

wait_for_yggdrasil() {
  local attempts="${1:-60}"

  for (( i = 1; i <= attempts; i++ )); do
    if systemctl is-active --quiet "${YGG_SERVICE}" && \
       yggdrasilctl getSelf >/dev/null 2>&1 && \
       has_yggdrasil_address; then
      return 0
    fi
    sleep 1
  done

  return 1
}

has_configured_peers() {
  awk '
    /^[[:space:]]*Peers:[[:space:]]*\[/ { in_peers = 1 }
    in_peers && /(tls|tcp|quic|ws|wss):\/\// { found = 1; exit }
    in_peers && /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/ { exit }
    END { exit !found }
  ' "${YGG_CONFIG}"
}

ensure_default_peers() {
  local tmp=""

  if has_configured_peers; then
    return 0
  fi

  tmp="$(mktemp)"

  if grep -Eq '^[[:space:]]*Peers:[[:space:]]*\[\][[:space:]]*,?[[:space:]]*$' "${YGG_CONFIG}"; then
    awk -v p1="${DEFAULT_PEERS[0]}" -v p2="${DEFAULT_PEERS[1]}" -v p3="${DEFAULT_PEERS[2]}" '
      /^[[:space:]]*Peers:[[:space:]]*\[\][[:space:]]*,?[[:space:]]*$/ {
        print "Peers: ["
        print "  " p1
        print "  " p2
        print "  " p3
        print "]"
        next
      }
      { print }
    ' "${YGG_CONFIG}" > "${tmp}"
  elif awk '
      /^[[:space:]]*Peers:[[:space:]]*\[[[:space:]]*$/ { found = 1; in_peers = 1; next }
      in_peers && /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/ { empty = 1; exit }
      in_peers && $0 !~ /^[[:space:]]*(#.*)?$/ { exit }
      END { exit !(found && empty) }
    ' "${YGG_CONFIG}"; then
    awk -v p1="${DEFAULT_PEERS[0]}" -v p2="${DEFAULT_PEERS[1]}" -v p3="${DEFAULT_PEERS[2]}" '
      BEGIN { in_peers = 0; inserted = 0 }
      /^[[:space:]]*Peers:[[:space:]]*\[[[:space:]]*$/ {
        in_peers = 1
        print
        next
      }
      in_peers && !inserted && /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/ {
        print "  " p1
        print "  " p2
        print "  " p3
        inserted = 1
        in_peers = 0
        print
        next
      }
      { print }
    ' "${YGG_CONFIG}" > "${tmp}"
  else
    rm -f "${tmp}"
    die "No configured peers were found and the Peers section could not be updated safely"
  fi

  install -o root -g root -m 0600 "${tmp}" "${YGG_CONFIG}"
  rm -f "${tmp}"
}

configure_i2pd_ordering() {
  local helper_dir="/usr/local/libexec"
  local wait_helper="${helper_dir}/tainiyproxy-wait-yggdrasil"
  local restart_helper="${helper_dir}/tainiyproxy-restart-i2pd-after-yggdrasil"
  local ygg_dropin_dir="/etc/systemd/system/${YGG_SERVICE}.d"
  local i2pd_dropin_dir="/etc/systemd/system/${I2PD_SERVICE}.d"

  if ! unit_exists "${I2PD_SERVICE}"; then
    return 0
  fi

  log "Configuring Yggdrasil-before-i2pd startup ordering"
  install -d -m 0755 "${helper_dir}" "${ygg_dropin_dir}" "${i2pd_dropin_dir}"

  cat > "${wait_helper}" <<'EOF_WAIT'
#!/usr/bin/env bash
set -Eeuo pipefail

load_state="$(systemctl show -p LoadState --value yggdrasil.service 2>/dev/null || true)"
if [[ -z ${load_state} || ${load_state} == "not-found" ]]; then
  exit 0
fi

has_yggdrasil_address() {
  local cidr=""
  local address=""
  local first_hextet=""
  local value=""

  while read -r cidr; do
    [[ -n ${cidr} ]] || continue
    address="${cidr%/*}"
    first_hextet="${address%%:*}"
    [[ ${first_hextet} =~ ^[0-9A-Fa-f]+$ ]] || continue
    value=$((16#${first_hextet}))
    if (( value >= 0x0200 && value <= 0x03ff )); then
      return 0
    fi
  done < <(ip -6 -o address show scope global 2>/dev/null | awk '{ print $4 }')

  return 1
}

for _ in $(seq 1 60); do
  if systemctl is-active --quiet yggdrasil.service && \
     has_yggdrasil_address; then
    exit 0
  fi
  sleep 1
done

echo "Yggdrasil did not become ready within 60 seconds" >&2
exit 1
EOF_WAIT
  chmod 0755 "${wait_helper}"

  cat > "${restart_helper}" <<'EOF_RESTART'
#!/usr/bin/env bash
set -Eeuo pipefail

if systemctl is-active --quiet i2pd.service; then
  systemctl --no-block try-restart i2pd.service
fi
EOF_RESTART
  chmod 0755 "${restart_helper}"

  cat > "${ygg_dropin_dir}/20-tainiyproxy-i2pd-ordering.conf" <<EOF_YGG_DROPIN
[Unit]
Before=${I2PD_SERVICE}

[Service]
ExecStartPost=${wait_helper}
ExecStartPost=${restart_helper}
EOF_YGG_DROPIN

  cat > "${i2pd_dropin_dir}/20-tainiyproxy-yggdrasil-ordering.conf" <<EOF_I2PD_DROPIN
[Unit]
Wants=${YGG_SERVICE}
After=${YGG_SERVICE}

[Service]
ExecStartPre=${wait_helper}
EOF_I2PD_DROPIN

  systemctl daemon-reload
}


rollback_configuration() {
  warn "Restoring the previous Yggdrasil configuration"
  if [[ -n ${YGG_CONFIG} ]]; then
    restore_or_remove "active-yggdrasil.conf" "${YGG_CONFIG}"
  fi
  restore_or_remove "yggdrasil.service.d" "/etc/systemd/system/${YGG_SERVICE}.d"
  restore_or_remove "i2pd.service.d" "/etc/systemd/system/${I2PD_SERVICE}.d"
  restore_or_remove "tainiyproxy-wait-yggdrasil" "/usr/local/libexec/tainiyproxy-wait-yggdrasil"
  restore_or_remove "tainiyproxy-restart-i2pd-after-yggdrasil" "/usr/local/libexec/tainiyproxy-restart-i2pd-after-yggdrasil"
  systemctl daemon-reload
  systemctl restart "${YGG_SERVICE}" || true
}

if [[ ${EUID} -ne 0 ]]; then
  die "Run this script as root, for example: sudo bash yggdrasil-setup.sh"
fi

[[ -r /etc/os-release ]] || die "/etc/os-release was not found"
# shellcheck disable=SC1091
. /etc/os-release

if [[ ${ID:-} != "debian" || ${VERSION_CODENAME:-} != "trixie" ]]; then
  die "This installer is intended for Debian 13 (trixie)"
fi

command -v apt-get >/dev/null 2>&1 || die "apt-get was not found"
command -v systemctl >/dev/null 2>&1 || die "systemctl was not found"

install -d -m 0700 "/var/backups/deepwebproxy-backups" "${BACKUP_ROOT}" "${BACKUP_DIR}"
backup_if_exists "${YGG_CONFIG_CURRENT}" "yggdrasil.conf.current"
backup_if_exists "${YGG_CONFIG_LEGACY}" "yggdrasil.conf.legacy"
backup_if_exists "${YGG_SOURCE_FILE}" "yggdrasil.list"
backup_if_exists "${YGG_KEYRING}" "yggdrasil.gpg"
backup_if_exists "/etc/systemd/system/${YGG_SERVICE}.d" "yggdrasil.service.d"
backup_if_exists "/etc/systemd/system/${I2PD_SERVICE}.d" "i2pd.service.d"
backup_if_exists "/usr/local/libexec/tainiyproxy-wait-yggdrasil" "tainiyproxy-wait-yggdrasil"
backup_if_exists "/usr/local/libexec/tainiyproxy-restart-i2pd-after-yggdrasil" "tainiyproxy-restart-i2pd-after-yggdrasil"

log "Installing repository dependencies"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg iproute2

log "Importing and verifying the Yggdrasil repository key"
TMP_DIR="$(mktemp -d)"
install -d -m 0700 "${TMP_DIR}/gnupg"
curl -fsSL "${YGG_KEY_URL}" -o "${TMP_DIR}/yggdrasil-key.asc"

IMPORTED_FINGERPRINT="$(
  gpg --batch --homedir "${TMP_DIR}/gnupg" --show-keys --with-colons "${TMP_DIR}/yggdrasil-key.asc" \
    | awk -F: '$1 == "fpr" { print $10; exit }'
)"

if [[ ${IMPORTED_FINGERPRINT} != "${YGG_KEY_FINGERPRINT}" ]]; then
  die "Unexpected Yggdrasil repository key fingerprint: ${IMPORTED_FINGERPRINT:-not detected}"
fi

install -d -m 0755 "$(dirname "${YGG_KEYRING}")"
gpg --batch --yes --homedir "${TMP_DIR}/gnupg" --import-options import-export \
  --import "${TMP_DIR}/yggdrasil-key.asc" > "${TMP_DIR}/yggdrasil.gpg"

if [[ ! -s ${TMP_DIR}/yggdrasil.gpg ]]; then
  die "Failed to create the Yggdrasil APT keyring"
fi

install -o root -g root -m 0644 "${TMP_DIR}/yggdrasil.gpg" "${YGG_KEYRING}"

log "Adding the official Yggdrasil APT repository"
printf '%s\n' \
  "deb [signed-by=${YGG_KEYRING}] ${YGG_REPO_URL} debian yggdrasil" \
  > "${YGG_SOURCE_FILE}"
chmod 0644 "${YGG_SOURCE_FILE}"

log "Installing or updating Yggdrasil"
if ! apt-get update; then
  restore_or_remove "yggdrasil.list" "${YGG_SOURCE_FILE}"
  restore_or_remove "yggdrasil.gpg" "${YGG_KEYRING}"
  apt-get update || true
  die "APT could not use the Yggdrasil repository; repository files were restored"
fi
apt-get install -y --no-install-recommends yggdrasil

if [[ -s ${YGG_CONFIG_CURRENT} ]]; then
  YGG_CONFIG="${YGG_CONFIG_CURRENT}"
elif [[ -s ${YGG_CONFIG_LEGACY} ]]; then
  YGG_CONFIG="${YGG_CONFIG_LEGACY}"
else
  YGG_CONFIG="${YGG_CONFIG_CURRENT}"
  log "Generating a new Yggdrasil configuration"
  install -d -m 0750 "$(dirname "${YGG_CONFIG}")"
  if yggdrasil -genconf > "${YGG_CONFIG}" 2>/dev/null; then
    :
  elif yggdrasil -generateconf > "${YGG_CONFIG}" 2>/dev/null; then
    :
  else
    rm -f "${YGG_CONFIG}"
    die "Could not generate a Yggdrasil configuration"
  fi
fi

cp -a "${YGG_CONFIG}" "${BACKUP_DIR}/active-yggdrasil.conf"

log "Ensuring a small set of public peers is configured"
ensure_default_peers

if getent group yggdrasil >/dev/null 2>&1; then
  chown root:yggdrasil "${YGG_CONFIG}"
  chmod 0640 "${YGG_CONFIG}"
else
  chown root:root "${YGG_CONFIG}"
  chmod 0600 "${YGG_CONFIG}"
fi

log "Validating the Yggdrasil configuration"
if yggdrasil -useconffile "${YGG_CONFIG}" -normaliseconf >/dev/null 2>&1; then
  :
elif yggdrasil -normaliseconf -useconffile "${YGG_CONFIG}" >/dev/null 2>&1; then
  :
elif yggdrasil -useconf -normaliseconf < "${YGG_CONFIG}" >/dev/null 2>&1; then
  :
else
  rollback_configuration
  die "The Yggdrasil configuration is invalid"
fi

log "Configuring systemd automatic restart"
install -d -m 0755 "/etc/systemd/system/${YGG_SERVICE}.d"
cat > "/etc/systemd/system/${YGG_SERVICE}.d/10-tainiyproxy.conf" <<'EOF_SYSTEMD'
[Unit]
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
RestartSec=5s
EOF_SYSTEMD

configure_i2pd_ordering
systemctl daemon-reload
systemctl enable "${YGG_SERVICE}" >/dev/null

log "Starting Yggdrasil"
if ! systemctl restart "${YGG_SERVICE}"; then
  rollback_configuration
  journalctl -u "${YGG_SERVICE}" -n 100 --no-pager >&2 || true
  die "Yggdrasil did not start"
fi

if ! wait_for_yggdrasil 60; then
  rollback_configuration
  journalctl -u "${YGG_SERVICE}" -n 100 --no-pager >&2 || true
  die "Yggdrasil is running but its control socket or IPv6 address did not become ready"
fi

PEER_STATUS="no active peer yet"
for _ in $(seq 1 60); do
  if yggdrasilctl getPeers 2>/dev/null | grep -Eq '(^|[[:space:]])Up([[:space:]]|$)'; then
    PEER_STATUS="connected"
    break
  fi
  sleep 1
done

if [[ ${PEER_STATUS} != "connected" ]]; then
  warn "Yggdrasil has an address but no peer is Up yet; check DNS, outbound access and yggdrasilctl getPeers"
fi

YGG_ADDRESS="$(get_yggdrasil_address || true)"
INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' yggdrasil 2>/dev/null || true)"

UFW_RESULT="not installed"
if command -v ufw >/dev/null 2>&1; then
  if UFW_STATUS="$(ufw status verbose 2>/dev/null)" && grep -q '^Status: active' <<< "${UFW_STATUS}"; then
    UFW_RESULT="active; no inbound rule required"
    if grep -Eq '^Default:.*(deny|reject) \(outgoing\)' <<< "${UFW_STATUS}"; then
      warn "UFW blocks outgoing traffic; Yggdrasil may be unable to reach its public peers"
      UFW_RESULT="active; no inbound rule required, but outgoing traffic is blocked"
    fi
  else
    UFW_RESULT="installed but inactive; unchanged"
  fi
fi

printf '\n%b%s%b\n' "${GREEN}" "============================================================" "${RESET}"
printf '%b Yggdrasil installed and running.%b\n' "${GREEN}" "${RESET}"
printf '%b Package: %s%b\n' "${GREEN}" "${INSTALLED_VERSION:-unknown}" "${RESET}"
printf '%b Address: %s%b\n' "${GREEN}" "${YGG_ADDRESS:-unknown}" "${RESET}"
printf '%b Peers: %s%b\n' "${GREEN}" "${PEER_STATUS}" "${RESET}"
printf '%b Config: %s%b\n' "${GREEN}" "${YGG_CONFIG}" "${RESET}"
printf '%b UFW: %s%b\n' "${GREEN}" "${UFW_RESULT}" "${RESET}"
printf '%b Backup: %s%b\n' "${GREEN}" "${BACKUP_DIR}" "${RESET}"
printf '%b Check peers: sudo yggdrasilctl getPeers%b\n' "${GREEN}" "${RESET}"
printf '%b%s%b\n' "${GREEN}" "============================================================" "${RESET}"