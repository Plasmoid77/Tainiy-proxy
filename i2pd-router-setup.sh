#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

I2PD_REPOSITORY="https://repo.i2pd.xyz/debian"
I2PD_KEY_URL="https://repo.i2pd.xyz/r4sas.gpg"
I2PD_KEY_ID="66F6C87B98EBCFE2"
I2PD_KEYRING="/etc/apt/keyrings/i2pd.gpg"
I2PD_SOURCE_FILE="/etc/apt/sources.list.d/i2pd.list"
I2PD_PREFERENCES_FILE="/etc/apt/preferences.d/i2pd.pref"
CONFIG_FILE="/etc/i2pd/i2pd.conf"
SERVICE_NAME="i2pd.service"
YGG_SERVICE="yggdrasil.service"
STATE_DIR="/var/lib/tainiyproxy"
STATE_FILE="${STATE_DIR}/i2pd.env"
BACKUP_ROOT="/var/backups/deepwebproxy-backups/i2pd"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
TMP_DIR=""

ROUTER_PORT="${1:-}"
BANDWIDTH="${2:-X}"
TRANSIT_SHARE="${3:-100}"
FLOODFILL="${4:-false}"

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

set_global_option() {
  local key="$1"
  local value="$2"
  local tmp=""

  tmp="$(mktemp)"
  awk -v key="${key}" -v value="${value}" '
    BEGIN { done = 0; in_global = 1 }
    {
      if (in_global) {
        testline = $0
        sub(/^[[:space:]]*#[[:space:]]*/, "", testline)

        if (testline ~ "^[[:space:]]*" key "[[:space:]]*=") {
          if (!done) {
            print key " = " value
            done = 1
          }
          next
        }

        if ($0 ~ "^[[:space:]]*\\[") {
          if (!done) {
            print key " = " value
            print ""
            done = 1
          }
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

set_section_option() {
  local section="$1"
  local key="$2"
  local value="$3"
  local tmp=""

  tmp="$(mktemp)"
  awk -v wanted_section="${section}" -v key="${key}" -v value="${value}" '
    function normalized_section(line, result) {
      result = line
      sub(/^[[:space:]]*\[/, "", result)
      sub(/\][[:space:]]*(#.*)?$/, "", result)
      gsub(/[[:space:]]/, "", result)
      return tolower(result)
    }

    BEGIN {
      in_section = 0
      section_found = 0
      done = 0
      wanted = tolower(wanted_section)
    }

    /^[[:space:]]*\[[^]]+\]/ {
      if (in_section && !done) {
        print key " = " value
        done = 1
      }

      current = normalized_section($0)
      in_section = (current == wanted)
      if (in_section) {
        section_found = 1
      }
      print
      next
    }

    {
      if (in_section) {
        testline = $0
        sub(/^[[:space:]]*#[[:space:]]*/, "", testline)
        if (testline ~ "^[[:space:]]*" key "[[:space:]]*=") {
          if (!done) {
            print key " = " value
            done = 1
          }
          next
        }
      }
      print
    }

    END {
      if (!section_found) {
        print ""
        print "[" wanted_section "]"
        print key " = " value
      }
      else if (in_section && !done) {
        print key " = " value
      }
    }
  ' "${CONFIG_FILE}" > "${tmp}"

  install -o root -g root -m 0644 "${tmp}" "${CONFIG_FILE}"
  rm -f "${tmp}"
}

port_is_free() {
  local port="$1"
  ! ss -H -lntu 2>/dev/null | awk '{ print $4 }' | grep -Eq "(^|[.:])${port}$"
}

pick_random_port() {
  local candidate=""

  for _ in $(seq 1 100); do
    candidate="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"
    candidate=$((20000 + candidate % 40001))
    if port_is_free "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

configure_yggdrasil_ordering() {
  local helper_dir="/usr/local/libexec"
  local wait_helper="${helper_dir}/tainiyproxy-wait-yggdrasil"
  local restart_helper="${helper_dir}/tainiyproxy-restart-i2pd-after-yggdrasil"
  local ygg_dropin_dir="/etc/systemd/system/${YGG_SERVICE}.d"
  local i2pd_dropin_dir="/etc/systemd/system/${SERVICE_NAME}.d"

  if ! unit_exists "${YGG_SERVICE}"; then
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
Before=${SERVICE_NAME}

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
}

ufw_active() {
  command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'
}

ufw_rule_exists() {
  local port="$1"
  local proto="$2"
  local comment="$3"

  ufw status 2>/dev/null \
    | grep -F "${port}/${proto}" \
    | grep -Fq "${comment}"
}

delete_managed_ufw_rule() {
  local port="$1"
  local proto="$2"
  local comment="$3"
  local numbers=()
  local number=""

  mapfile -t numbers < <(
    ufw status numbered 2>/dev/null \
      | awk -v port="${port}" -v proto="${proto}" -v comment="${comment}" '
          index($0, port "/" proto) && index($0, comment) {
            if (match($0, /\[[[:space:]]*[0-9]+\]/)) {
              n = substr($0, RSTART + 1, RLENGTH - 2)
              gsub(/[[:space:]]/, "", n)
              print n
            }
          }
        ' \
      | sort -rn
  )

  for number in "${numbers[@]}"; do
    yes | ufw delete "${number}" >/dev/null
  done
}

delete_all_ufw_rules_by_comment() {
  local comment="$1"
  local numbers=()
  local number=""

  mapfile -t numbers < <(
    ufw status numbered 2>/dev/null \
      | awk -v comment="${comment}" '
          {
            hash = index($0, "#")
            if (!hash) next
            actual = substr($0, hash + 1)
            sub(/^[[:space:]]+/, "", actual)
            sub(/[[:space:]]+$/, "", actual)
            if (actual != comment) next

            if (match($0, /\[[[:space:]]*[0-9]+\]/)) {
              n = substr($0, RSTART + 1, RLENGTH - 2)
              gsub(/[[:space:]]/, "", n)
              print n
            }
          }
        ' \
      | sort -rn
  )

  for number in "${numbers[@]}"; do
    yes | ufw delete "${number}" >/dev/null
  done
}

delete_stale_managed_ufw_rules() {
  local current_port="$1"
  local proto="$2"
  local comment="$3"
  local numbers=()
  local number=""

  mapfile -t numbers < <(
    ufw status numbered 2>/dev/null \
      | awk -v current="${current_port}" -v proto="${proto}" -v comment="${comment}" '
          index($0, comment) && !index($0, current "/" proto) {
            if (match($0, /\[[[:space:]]*[0-9]+\]/)) {
              n = substr($0, RSTART + 1, RLENGTH - 2)
              gsub(/[[:space:]]/, "", n)
              print n
            }
          }
        ' \
      | sort -rn
  )

  for number in "${numbers[@]}"; do
    yes | ufw delete "${number}" >/dev/null
  done
}

configure_ufw() {
  local tcp_comment="TainiyProxy i2pd NTCP2 and Yggdrasil"
  local udp_comment="TainiyProxy i2pd SSU2"
  local added_tcp=false
  local added_udp=false

  UFW_RESULT="not installed"
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi

  if ! ufw_active; then
    UFW_RESULT="installed but inactive; unchanged"
    warn "UFW is installed but inactive; no firewall rules were changed"
    return 0
  fi

  log "Opening the i2pd transport port in UFW"

  if ! ufw_rule_exists "${ROUTER_PORT}" tcp "${tcp_comment}"; then
    if ! ufw allow "${ROUTER_PORT}/tcp" comment "${tcp_comment}" >/dev/null; then
      return 1
    fi
    added_tcp=true
  fi

  if ! ufw_rule_exists "${ROUTER_PORT}" udp "${udp_comment}"; then
    if ! ufw allow "${ROUTER_PORT}/udp" comment "${udp_comment}" >/dev/null; then
      if [[ ${added_tcp} == true ]]; then
        delete_managed_ufw_rule "${ROUTER_PORT}" tcp "${tcp_comment}"
      fi
      return 1
    fi
    added_udp=true
  fi

  if ! delete_stale_managed_ufw_rules "${ROUTER_PORT}" tcp "${tcp_comment}"; then
    warn "Could not remove one or more stale managed TCP rules"
  fi
  if ! delete_stale_managed_ufw_rules "${ROUTER_PORT}" udp "${udp_comment}"; then
    warn "Could not remove one or more stale managed UDP rules"
  fi

  # Remove rules left by older versions of these installers. Only rules with
  # the exact legacy comments are touched.
  delete_all_ufw_rules_by_comment "i2pd NTCP2" || warn "Could not remove legacy i2pd NTCP2 rules"
  delete_all_ufw_rules_by_comment "i2pd SSU2" || warn "Could not remove legacy i2pd SSU2 rules"
  delete_all_ufw_rules_by_comment "i2pd NTCP2 and Yggdrasil transport" || warn "Could not remove legacy i2pd transport rules"
  delete_all_ufw_rules_by_comment "i2pd SSU2 transport" || warn "Could not remove legacy i2pd SSU2 transport rules"

  if [[ -r /etc/default/ufw ]] && ! grep -Eq '^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*yes[[:space:]]*$' /etc/default/ufw; then
    warn "UFW IPv6 support is disabled; UFW is not managing access through Yggdrasil IPv6"
    UFW_RESULT="active; transport rules added, but UFW IPv6 support is disabled"
  else
    UFW_RESULT="active; TCP and UDP transport rules added"
  fi

  local ufw_status=""
  ufw_status="$(ufw status verbose 2>/dev/null || true)"
  if grep -Eq '^Default:.*(deny|reject) \(outgoing\)' <<< "${ufw_status}"; then
    warn "UFW blocks outgoing traffic; i2pd uses variable remote ports and may not reseed or connect reliably"
    UFW_RESULT="${UFW_RESULT}; outgoing traffic is blocked"
  fi

  # Keep these assignments visible to shellcheck and document that successful
  # additions are intentionally retained after the installation completes.
  : "${added_tcp}" "${added_udp}"
}

rollback_configuration() {
  warn "Restoring the previous i2pd configuration"
  restore_or_remove "i2pd.conf" "${CONFIG_FILE}"
  restore_or_remove "i2pd.service.d" "/etc/systemd/system/${SERVICE_NAME}.d"
  restore_or_remove "yggdrasil.service.d" "/etc/systemd/system/${YGG_SERVICE}.d"
  restore_or_remove "tainiyproxy-wait-yggdrasil" "/usr/local/libexec/tainiyproxy-wait-yggdrasil"
  restore_or_remove "tainiyproxy-restart-i2pd-after-yggdrasil" "/usr/local/libexec/tainiyproxy-restart-i2pd-after-yggdrasil"
  systemctl daemon-reload
  systemctl restart "${SERVICE_NAME}" || true
}

if [[ ${EUID} -ne 0 ]]; then
  die "Run this script as root, for example: sudo bash i2pd-router-setup.sh"
fi

[[ -r /etc/os-release ]] || die "/etc/os-release was not found"
# shellcheck disable=SC1091
. /etc/os-release

if [[ ${ID:-} != "debian" || ${VERSION_CODENAME:-} != "trixie" ]]; then
  die "This installer is intended for Debian 13 (trixie)"
fi

if [[ -n ${ROUTER_PORT} ]]; then
  if ! [[ ${ROUTER_PORT} =~ ^[0-9]+$ ]] || (( ROUTER_PORT < 1024 || ROUTER_PORT > 65535 )); then
    die "The port must be an integer from 1024 to 65535"
  fi
fi

if ! [[ ${BANDWIDTH} =~ ^([LOPX]|[1-9][0-9]*)$ ]]; then
  die "Bandwidth must be L, O, P, X, or an integer in KiB/s"
fi

if ! [[ ${TRANSIT_SHARE} =~ ^[0-9]+$ ]] || (( TRANSIT_SHARE < 0 || TRANSIT_SHARE > 100 )); then
  die "Transit share must be an integer from 0 to 100"
fi

case ${FLOODFILL,,} in
  true|yes|1)
    FLOODFILL=true
    ;;
  false|no|0)
    FLOODFILL=false
    ;;
  *)
    die "Floodfill mode must be true or false"
    ;;
esac

install -d -m 0700 "/var/backups/deepwebproxy-backups" "${BACKUP_ROOT}" "${BACKUP_DIR}"
backup_if_exists "${CONFIG_FILE}" "i2pd.conf"
backup_if_exists "${I2PD_SOURCE_FILE}" "i2pd.list"
backup_if_exists "${I2PD_KEYRING}" "i2pd.gpg"
backup_if_exists "${I2PD_PREFERENCES_FILE}" "i2pd.pref"
backup_if_exists "/etc/systemd/system/${SERVICE_NAME}.d" "i2pd.service.d"
backup_if_exists "/etc/systemd/system/${YGG_SERVICE}.d" "yggdrasil.service.d"
backup_if_exists "/usr/local/libexec/tainiyproxy-wait-yggdrasil" "tainiyproxy-wait-yggdrasil"
backup_if_exists "/usr/local/libexec/tainiyproxy-restart-i2pd-after-yggdrasil" "tainiyproxy-restart-i2pd-after-yggdrasil"
backup_if_exists "${STATE_FILE}" "i2pd.env"

log "Installing repository dependencies"
apt-get update
apt-get install -y --no-install-recommends apt-transport-https ca-certificates curl gnupg iproute2

log "Importing and verifying the i2pd repository key"
TMP_DIR="$(mktemp -d)"
install -d -m 0700 "${TMP_DIR}/gnupg"
curl -fsSL "${I2PD_KEY_URL}" -o "${TMP_DIR}/i2pd-key.gpg"

IMPORTED_FINGERPRINT="$(
  gpg --batch --homedir "${TMP_DIR}/gnupg" --show-keys --with-colons "${TMP_DIR}/i2pd-key.gpg" \
    | awk -F: '$1 == "fpr" { print $10; exit }'
)"

if [[ ${IMPORTED_FINGERPRINT: -16} != "${I2PD_KEY_ID}" ]]; then
  die "Unexpected i2pd repository key fingerprint: ${IMPORTED_FINGERPRINT:-not detected}"
fi

install -d -m 0755 "$(dirname "${I2PD_KEYRING}")"
gpg --batch --yes --homedir "${TMP_DIR}/gnupg" --import-options import-export \
  --import "${TMP_DIR}/i2pd-key.gpg" > "${TMP_DIR}/i2pd.gpg"

if [[ ! -s ${TMP_DIR}/i2pd.gpg ]]; then
  die "Failed to create the i2pd APT keyring"
fi

install -o root -g root -m 0644 "${TMP_DIR}/i2pd.gpg" "${I2PD_KEYRING}"

log "Adding the i2pd repository from the official installation guide"
printf '%s\n' \
  "deb [signed-by=${I2PD_KEYRING}] ${I2PD_REPOSITORY} trixie main" \
  > "${I2PD_SOURCE_FILE}"
chmod 0644 "${I2PD_SOURCE_FILE}"

cat > "${I2PD_PREFERENCES_FILE}" <<'EOF_PREFERENCES'
Package: i2pd
Pin: origin "repo.i2pd.xyz"
Pin-Priority: 700
EOF_PREFERENCES
chmod 0644 "${I2PD_PREFERENCES_FILE}"

log "Installing or updating i2pd"
if ! apt-get update; then
  restore_or_remove "i2pd.list" "${I2PD_SOURCE_FILE}"
  restore_or_remove "i2pd.gpg" "${I2PD_KEYRING}"
  restore_or_remove "i2pd.pref" "${I2PD_PREFERENCES_FILE}"
  apt-get update || true
  die "APT could not use the i2pd repository; repository files were restored"
fi

I2PD_APT_POLICY="$(apt-cache policy i2pd 2>/dev/null || true)"
if ! grep -Fq 'repo.i2pd.xyz' <<< "${I2PD_APT_POLICY}"; then
  restore_or_remove "i2pd.list" "${I2PD_SOURCE_FILE}"
  restore_or_remove "i2pd.gpg" "${I2PD_KEYRING}"
  restore_or_remove "i2pd.pref" "${I2PD_PREFERENCES_FILE}"
  die "The i2pd repository did not provide a package candidate for Debian 13"
fi

apt-get install -y --no-install-recommends i2pd

[[ -f ${CONFIG_FILE} ]] || die "Expected configuration file ${CONFIG_FILE} was not created"

if [[ ! -e ${BACKUP_DIR}/i2pd.conf ]]; then
  cp -a "${CONFIG_FILE}" "${BACKUP_DIR}/i2pd.conf"
fi

CURRENT_PORT="$(get_global_option port || true)"

if [[ -z ${ROUTER_PORT} ]]; then
  if [[ ${CURRENT_PORT:-} =~ ^[0-9]+$ ]] && (( CURRENT_PORT >= 1024 && CURRENT_PORT <= 65535 )); then
    ROUTER_PORT="${CURRENT_PORT}"
  else
    ROUTER_PORT="$(pick_random_port)" || die "Could not select a free router port"
  fi
fi

if ! port_is_free "${ROUTER_PORT}" && [[ ${CURRENT_PORT:-} != "${ROUTER_PORT}" ]]; then
  die "Port ${ROUTER_PORT} is already used by another service"
fi

has_clearnet_ipv6() {
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

    # Clearnet global unicast is 2000::/3. Yggdrasil uses 0200::/7 and is
    # configured separately through meshnets.yggdrasil.
    if (( value >= 0x2000 && value <= 0x3fff )); then
      return 0
    fi
  done < <(ip -6 -o address show scope global 2>/dev/null | awk '{ print $4 }')

  return 1
}

ENABLE_IPV6=false
if has_clearnet_ipv6; then
  ENABLE_IPV6=true
fi

log "Configuring i2pd as an Internet and Yggdrasil transit router"
set_global_option port "${ROUTER_PORT}"
set_global_option ipv4 true
set_global_option ipv6 "${ENABLE_IPV6}"
set_global_option bandwidth "${BANDWIDTH}"
set_global_option share "${TRANSIT_SHARE}"
set_global_option notransit false
set_global_option floodfill "${FLOODFILL}"

set_section_option ntcp2 enabled true
set_section_option ntcp2 published true
set_section_option ntcp2 port "${ROUTER_PORT}"
set_section_option ssu2 enabled true
set_section_option ssu2 published true
set_section_option ssu2 port "${ROUTER_PORT}"
set_section_option meshnets yggdrasil true

set_section_option http enabled true
set_section_option http address 127.0.0.1
set_section_option http port 7070
set_section_option http strictheaders true
set_section_option http hostname localhost

log "Configuring systemd automatic restart"
install -d -m 0755 "/etc/systemd/system/${SERVICE_NAME}.d"
cat > "/etc/systemd/system/${SERVICE_NAME}.d/10-tainiyproxy.conf" <<'EOF_SYSTEMD'
[Unit]
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
RestartSec=5s
EOF_SYSTEMD

configure_yggdrasil_ordering
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null

log "Starting i2pd"
if ! systemctl restart "${SERVICE_NAME}"; then
  rollback_configuration
  journalctl -u "${SERVICE_NAME}" -n 100 --no-pager >&2 || true
  die "i2pd did not start"
fi

if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
  rollback_configuration
  journalctl -u "${SERVICE_NAME}" -n 100 --no-pager >&2 || true
  die "i2pd is not active after restart"
fi

TCP_READY=false
UDP_READY=false
for _ in $(seq 1 20); do
  if ss -H -ltn 2>/dev/null | awk '{ print $4 }' | grep -Eq "(^|[.:])${ROUTER_PORT}$"; then
    TCP_READY=true
  fi
  if ss -H -lun 2>/dev/null | awk '{ print $4 }' | grep -Eq "(^|[.:])${ROUTER_PORT}$"; then
    UDP_READY=true
  fi
  if [[ ${TCP_READY} == true && ${UDP_READY} == true ]]; then
    break
  fi
  sleep 1
done

if [[ ${TCP_READY} != true || ${UDP_READY} != true ]]; then
  rollback_configuration
  journalctl -u "${SERVICE_NAME}" -n 100 --no-pager >&2 || true
  die "i2pd is running but both TCP and UDP listeners did not appear on port ${ROUTER_PORT}"
fi

UFW_RESULT="not installed"
if ! configure_ufw; then
  rollback_configuration
  die "UFW is active, but the required i2pd rules could not be installed safely"
fi

install -d -m 0755 "${STATE_DIR}"
printf 'I2PD_PORT=%q\n' "${ROUTER_PORT}" > "${STATE_FILE}"
chmod 0644 "${STATE_FILE}"

CLOCK_STATUS="unknown"
if command -v timedatectl >/dev/null 2>&1; then
  CLOCK_STATUS="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [[ ${CLOCK_STATUS} != "yes" ]]; then
    warn "The system clock is not reported as synchronized; accurate time is important for i2pd"
  fi
fi

I2PD_VERSION="$(i2pd --version 2>&1 | head -n 1 || true)"
PACKAGE_VERSION="$(dpkg-query -W -f='${Version}' i2pd 2>/dev/null || true)"
YGG_INTEGRATION="enabled in i2pd config"
if unit_exists "${YGG_SERVICE}"; then
  YGG_INTEGRATION="enabled; systemd waits for Yggdrasil readiness"
fi

printf '\n%b%s%b\n' "${GREEN}" "============================================================" "${RESET}"
printf '%b i2pd router installed and running.%b\n' "${GREEN}" "${RESET}"
printf '%b Binary: %s%b\n' "${GREEN}" "${I2PD_VERSION:-unknown}" "${RESET}"
printf '%b Package: %s%b\n' "${GREEN}" "${PACKAGE_VERSION:-unknown}" "${RESET}"
printf '%b Repository: %s (trixie)%b\n' "${GREEN}" "${I2PD_REPOSITORY}" "${RESET}"
printf '%b Transport: %s/TCP and %s/UDP%b\n' "${GREEN}" "${ROUTER_PORT}" "${ROUTER_PORT}" "${RESET}"
printf '%b Bandwidth: %s; transit share: %s%%%b\n' "${GREEN}" "${BANDWIDTH}" "${TRANSIT_SHARE}" "${RESET}"
printf '%b Floodfill role: %s; bandwidth class defaults to X%b\n' "${GREEN}" "${FLOODFILL}" "${RESET}"
printf '%b Clearnet IPv6: %s%b\n' "${GREEN}" "${ENABLE_IPV6}" "${RESET}"
printf '%b Yggdrasil: %s%b\n' "${GREEN}" "${YGG_INTEGRATION}" "${RESET}"
printf '%b Web console: http://127.0.0.1:7070%b\n' "${GREEN}" "${RESET}"
printf '%b UFW: %s%b\n' "${GREEN}" "${UFW_RESULT}" "${RESET}"
printf '%b Config: %s%b\n' "${GREEN}" "${CONFIG_FILE}" "${RESET}"
printf '%b Backup: %s%b\n' "${GREEN}" "${BACKUP_DIR}" "${RESET}"
printf '%b SSH tunnel: ssh -L 7070:127.0.0.1:7070 USER@SERVER%b\n' "${GREEN}" "${RESET}"
printf '%b%s%b\n' "${GREEN}" "============================================================" "${RESET}"
