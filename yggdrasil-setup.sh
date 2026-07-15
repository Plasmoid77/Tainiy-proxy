#!/usr/bin/env bash
set -Eeuo pipefail

# Официальный APT-репозиторий Yggdrasil
YGG_REPO_URL="https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/"
YGG_KEY_URL="https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/key.txt"
YGG_KEY_FINGERPRINT="1C5162E133015D81A811239D1840CDAC6011C5EA"
YGG_KEYRING="/etc/apt/keyrings/yggdrasil.gpg"
YGG_SOURCE_LIST="/etc/apt/sources.list.d/yggdrasil.list"

BLUE='\033[1;34m'
GREEN='\033[1;32m'
RED='\033[1;31m'
RESET='\033[0m'

step() {
  printf '\n%b%s%b\n' "$BLUE" "===== $1 =====" "$RESET"
}

fail() {
  printf '%bError:%b %s\n' "$RED" "$RESET" "$1" >&2
  exit 1
}

# Поддерживаем запуск как от root, так и через sudo
if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
elif command -v sudo >/dev/null 2>&1; then
  SUDO=(sudo)
else
  fail "Run this script as root or install sudo."
fi

command -v apt-get >/dev/null 2>&1 || fail "apt-get was not found. This script is intended for Debian-based systems."
command -v systemctl >/dev/null 2>&1 || fail "systemctl was not found. Yggdrasil packages require a systemd-based system."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

step "1. Installing repository dependencies"
"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y ca-certificates gnupg dirmngr

step "2. Importing and verifying the Yggdrasil repository key"
install -m 0700 -d "$TMP_DIR/gnupg"

gpg \
  --batch \
  --homedir "$TMP_DIR/gnupg" \
  --fetch-keys "$YGG_KEY_URL"

IMPORTED_FINGERPRINT="$(
  gpg \
    --batch \
    --homedir "$TMP_DIR/gnupg" \
    --with-colons \
    --fingerprint "$YGG_KEY_FINGERPRINT" \
  | awk -F: '$1 == "fpr" { print $10; exit }'
)"

[[ "$IMPORTED_FINGERPRINT" == "$YGG_KEY_FINGERPRINT" ]] \
  || fail "Unexpected repository key fingerprint: ${IMPORTED_FINGERPRINT:-not found}"

"${SUDO[@]}" install -m 0755 -d /etc/apt/keyrings
gpg \
  --batch \
  --homedir "$TMP_DIR/gnupg" \
  --export "$YGG_KEY_FINGERPRINT" \
  | "${SUDO[@]}" tee "$YGG_KEYRING" >/dev/null
"${SUDO[@]}" chmod 0644 "$YGG_KEYRING"

step "3. Adding the official Yggdrasil APT repository"
printf '%s\n' \
  "deb [signed-by=$YGG_KEYRING] $YGG_REPO_URL debian yggdrasil" \
  | "${SUDO[@]}" tee "$YGG_SOURCE_LIST" >/dev/null

step "4. Installing or updating Yggdrasil"
"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y yggdrasil

step "5. Enabling and restarting Yggdrasil"
"${SUDO[@]}" systemctl enable yggdrasil
"${SUDO[@]}" systemctl restart yggdrasil

if ! "${SUDO[@]}" systemctl is-active --quiet yggdrasil; then
  "${SUDO[@]}" systemctl status yggdrasil --no-pager || true
  fail "The Yggdrasil service is not active."
fi

INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' yggdrasil)"

echo
printf '%b%s%b\n' "$GREEN" "============================================================" "$RESET"
printf '%b%s%b\n' "$GREEN" " Yggdrasil ${INSTALLED_VERSION} installed and running." "$RESET"
printf '%b%s%b\n' "$GREEN" " Config: /etc/yggdrasil.conf" "$RESET"
printf '%b%s%b\n' "$GREEN" " Check peers: sudo yggdrasilctl getPeers" "$RESET"
printf '%b%s%b\n' "$GREEN" "============================================================" "$RESET"
