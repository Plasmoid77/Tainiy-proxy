#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

YGGDRASIL_KEY_FINGERPRINT='1C5162E133015D81A811239D1840CDAC6011C5EA'
YGGDRASIL_IFNAME='ygg0'
YGGDRASIL_CONF='/etc/yggdrasil/yggdrasil.conf'

PEERS=''
TRUSTED=''
PRIVATE_KEY_FILE=''
CONFIG_KEY=''
CONFIG_KEY_SRC=''
SUPPLIED_KEY=''

die() { echo "$*" >&2; exit 1; }

usage() {
  cat >&2 <<USAGE
Usage: bash yggdrasil-setup.sh [options]

Every setting can come from the command line, from one settings file, or both:
  --config FILE         Read settings from FILE (format below). Repeatable.
                        Options are applied in the order given: a later
                        --iface wins, peers and trusted addresses accumulate.

Peers (without any, the node has an address but no path into the network):
  --peer URI            Public peer to configure. Repeatable. Replaces the
                        current Peers list. Schemes: tls tcp quic ws wss
                        socks sockstls
  --peers-file FILE     Read peers from FILE, one URI per line (# = comment).

Node identity:
  --private-key-file F  Restore an existing Yggdrasil identity from file F,
                        keeping its node address. F holds the 128 hex character
                        private key and nothing else. The key may also be passed
                        in the YGG_PRIVATE_KEY environment variable. It is never
                        accepted as an argument value: /proc/<pid>/cmdline is
                        world readable. Without either, the key the package
                        generated on install is kept.

Trusted remote access ($YGGDRASIL_IFNAME is closed by a UFW deny rule):
  --trusted ADDR        Yggdrasil /128 allowed to reach every port on this host
                        over $YGGDRASIL_IFNAME. Repeatable. Without any, nothing
                        reaches this host over the mesh.

Interface:
  --iface NAME          TUN interface name (default: $YGGDRASIL_IFNAME). Up to
                        15 characters: letters, digits, '-' '_' '.'. The UFW
                        rules are bound to this name: on a rename the ones this
                        script wrote for the old name are deleted and written
                        again for the new one.

  -h, --help            This text

Settings file: one value per line under a [section] header, # starts a
comment, blank lines are ignored. Unknown sections are an error. Sections:
  [peers]         one peer URI per line          (as --peer)
  [trusted]       one Yggdrasil /128 per line    (as --trusted)
  [private-key]   the 128 hex character key      (as --private-key-file)
  [iface]         the interface name             (as --iface)
Keep the file mode 600 when it holds the key.
USAGE
}

add_peer() {
  case "$1" in
    tls://*|tcp://*|quic://*|ws://*|wss://*|socks://*|sockstls://*) : ;;
    *) die "Unsupported peer URI (bad scheme): $1" ;;
  esac
  # The URI is written into yggdrasil.conf as a quoted HJSON string, so the
  # two characters that would need escaping there are refused instead.
  case "$1" in
    *[[:space:]\"\\]*) die "Peer URI contains whitespace, a quote or a backslash: $1" ;;
  esac
  PEERS="${PEERS}${PEERS:+$'\n'}$1"
}

set_iface() {
  # Kernel limit is IFNAMSIZ-1 = 15 bytes; the character set is kept to what
  # both UFW and the yggdrasil.conf sed below pass through unchanged.
  case "$1" in
    ''|*[!A-Za-z0-9_.-]*) die "Interface name may only contain letters, digits, '-', '_' and '.': $1" ;;
    .|..) die "Interface name may not be '.' or '..'" ;;
  esac
  [[ ${#1} -le 15 ]] || die "Interface name is ${#1} characters, the kernel allows 15: $1"
  YGGDRASIL_IFNAME="$1"
}

add_trusted() {
  case "$1" in
    */*) die "Trusted address must be a bare /128 address, no prefix length: $1" ;;
    2??:*|3??:*) : ;;
    *) die "Trusted address does not look like a Yggdrasil 200::/7 address: $1" ;;
  esac
  TRUSTED="${TRUSTED}${TRUSTED:+$'\n'}$1"
}

read_config() {
  local file="$1" section='' line mode
  [[ -r $file ]] || die "Cannot read config file: $file"
  mode="$(stat -c %a "$file")"
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n $line ]] || continue
    case "$line" in
      \[*\])
        section="${line:1:${#line}-2}"
        case "$section" in
          peers|trusted|private-key|iface) ;;
          *) die "Unknown section [$section] in $file (expected [peers] [trusted] [private-key] [iface])" ;;
        esac
        continue ;;
    esac
    case "$section" in
      peers)   add_peer "$line" ;;
      trusted) add_trusted "$line" ;;
      iface)   set_iface "$line" ;;
      private-key)
        [[ -z $CONFIG_KEY ]] || die "[private-key] holds more than one line, or was given twice: $file"
        CONFIG_KEY="$line"
        CONFIG_KEY_SRC="[private-key] in $file"
        [[ $mode == ?00 ]] \
          || echo "WARNING: config file holds the private key but is readable beyond its owner (mode $mode): $file" >&2 ;;
      '') die "Value before any [section] header in $file: $line" ;;
    esac
  done < "$file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)     [[ $# -ge 2 ]] || die "--config needs a value"; read_config "$2"; shift 2 ;;
    --peer)       [[ $# -ge 2 ]] || die "--peer needs a value"; add_peer "$2"; shift 2 ;;
    --peers-file)
      [[ $# -ge 2 ]] || die "--peers-file needs a value"
      [[ -r $2 ]] || die "Cannot read peers file: $2"
      while IFS= read -r line || [[ -n $line ]]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -n $line ]] && add_peer "$line"
      done < "$2"
      shift 2 ;;
    --trusted)    [[ $# -ge 2 ]] || die "--trusted needs a value"; add_trusted "$2"; shift 2 ;;
    --private-key-file)
      [[ $# -ge 2 ]] || die "--private-key-file needs a value"; PRIVATE_KEY_FILE="$2"; shift 2 ;;
    --iface)      [[ $# -ge 2 ]] || die "--iface needs a value"; set_iface "$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage; die "Unknown argument: $1" ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash yggdrasil-setup.sh" >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

if [[ $ID != debian ]]; then
  echo "This script is intended for Debian." >&2
  exit 1
fi

# The private key is the node identity: supplying the old one is the only way
# to keep an existing Yggdrasil address when redeploying or moving to new
# hardware. It is deliberately not accepted as a command-line value --
# /proc/<pid>/cmdline is world readable, so an argument would expose the key to
# every process on the host for the length of the run, and leave it in the
# shell history of whoever typed it. A file (its own, or a [private-key]
# section of --config) or the environment keeps it out of argv. Loaded before
# anything is installed, so a bad key fails the run before it has changed the
# system.
env_key="${YGG_PRIVATE_KEY-}"
unset YGG_PRIVATE_KEY
if [[ -n $PRIVATE_KEY_FILE ]]; then
  [[ -r $PRIVATE_KEY_FILE ]] || die "Cannot read private key file: $PRIVATE_KEY_FILE"
  mode="$(stat -c %a "$PRIVATE_KEY_FILE")"
  [[ $mode == ?00 ]] \
    || echo "WARNING: key file is readable beyond its owner (mode $mode): $PRIVATE_KEY_FILE" >&2
  SUPPLIED_KEY="$(tr -d ' \t\r\n' < "$PRIVATE_KEY_FILE")"
  key_src="$PRIVATE_KEY_FILE"
elif [[ -n $CONFIG_KEY ]]; then
  SUPPLIED_KEY="$CONFIG_KEY"
  key_src="$CONFIG_KEY_SRC"
elif [[ -n $env_key ]]; then
  SUPPLIED_KEY="$(printf '%s' "$env_key" | tr -d ' \t\r\n')"
  key_src='the YGG_PRIVATE_KEY environment variable'
fi
unset env_key
if [[ -n $SUPPLIED_KEY ]]; then
  # Never echo the value itself, not even in an error.
  [[ ${#SUPPLIED_KEY} -eq 128 ]] \
    || die "Private key from $key_src is ${#SUPPLIED_KEY} characters, expected 128 hex."
  [[ $SUPPLIED_KEY != *[!0-9a-fA-F]* ]] \
    || die "Private key from $key_src contains non-hex characters."
fi

printf '\n\033[1;34m==> Installing Yggdrasil\033[0m\n'

# Drop our own source first: a partial earlier run can leave this file behind
# pointing at a missing/invalid keyring, which would make the apt-get update
# below fail before the key is rewritten. It is recreated further down.
rm -f /etc/apt/sources.list.d/yggdrasil.list

apt-get update
apt-get install -y ca-certificates wget gnupg ufw

mkdir -p /usr/local/apt-keys

# --dearmor rather than gpg --fetch-keys into a keyring: --fetch-keys needs a
# gpg homedir plus a running dirmngr, and writes the keybox format, which APT's
# sqv verifier cannot parse -- apt-get update then fails with
# "Failed to parse keyring ... EOF". Dearmoring is stateless, touches no
# trustdb, and emits the classic OpenPGP binary format APT expects.
# --timeout/--tries (per address, so a dual-stack host can take a few minutes
# to give up): without them a TLS handshake that stalls -- seen on an LTE
# uplink where this host is filtered -- leaves wget waiting forever instead of
# failing the run.
wget -qO- --timeout=20 --tries=2 \
  https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/key.txt \
  | gpg --dearmor \
  > /usr/local/apt-keys/yggdrasil-keyring.gpg \
  || { rm -f /usr/local/apt-keys/yggdrasil-keyring.gpg
       die "Cannot download the Yggdrasil signing key: the upstream repository host is unreachable from here."; }

# Pin the expected signing key, so a substituted upstream key fails loudly here
# instead of silently authorising a different repository.
gpg --show-keys --with-colons /usr/local/apt-keys/yggdrasil-keyring.gpg |
  awk -F: '$1 == "fpr" { print $10 }' |
  grep -qx "$YGGDRASIL_KEY_FINGERPRINT" || {
    echo "Unexpected Yggdrasil signing key; expected $YGGDRASIL_KEY_FINGERPRINT." >&2
    rm -f /usr/local/apt-keys/yggdrasil-keyring.gpg
    exit 1
  }

echo 'deb [signed-by=/usr/local/apt-keys/yggdrasil-keyring.gpg] https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/ debian yggdrasil' \
  > /etc/apt/sources.list.d/yggdrasil.list

apt-get update
apt-get install -y yggdrasil

printf '\n\033[1;34m==> Configuring Yggdrasil\033[0m\n'

# Every edit below goes to a copy; the live file is only replaced once
# Yggdrasil itself has parsed the result, so a bad key or peer list cannot
# leave the node with a config it refuses to start on.
conf_new="$(mktemp "$YGGDRASIL_CONF.XXXXXX")"
trap 'rm -f "$conf_new"' EXIT
cat "$YGGDRASIL_CONF" > "$conf_new"

# The interface a previous run pinned, read before it is overwritten: the UFW
# rules below are bound to that name, so a rename has to retire them too.
old_ifname="$(sed -nE 's/^[[:space:]]*IfName:[[:space:]]*([^[:space:]]+).*$/\1/p' "$YGGDRASIL_CONF" | head -n1)"

# The package ships IfName: auto, which lands on tun0 -- or tun1, or tun2, if
# something else claimed the name first. Pin it (ygg0 unless --iface says
# otherwise) so firewall rules and DNS configuration can refer to the interface
# by name without breaking when the numbering shifts.
sed -i -E "s|^([[:space:]]*)IfName:.*$|\1IfName: $YGGDRASIL_IFNAME|" "$conf_new"

if [[ -n $SUPPLIED_KEY ]]; then
  # Anchored on "PrivateKey:" followed by a blank, so PrivateKeyPath is left alone.
  sed -i -E "s|^([[:space:]]*)PrivateKey:[[:space:]].*$|\1PrivateKey: $SUPPLIED_KEY|" "$conf_new"
  grep -qF "PrivateKey: $SUPPLIED_KEY" "$conf_new" \
    || die "No PrivateKey line found in $YGGDRASIL_CONF to replace."
fi

if [[ -n $PEERS ]]; then
  # Replace the whole Peers block -- the one-line "Peers: []" of a fresh
  # install, or the multi-line list a previous run wrote -- and leave every
  # other line, comments included, exactly as it was.
  # umask: the intermediate file carries the private key too.
  (umask 077; awk -v peers="$PEERS" '
    BEGIN { n = split(peers, p, "\n") }
    skip && /^[[:space:]]*\]/ { skip = 0; next }
    skip { next }
    /^[[:space:]]*Peers:[[:space:]]*\[/ {
      match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
      printf "%sPeers: [\n", ind
      for (i = 1; i <= n; i++) printf "%s  \"%s\"\n", ind, p[i]
      printf "%s]\n", ind
      if ($0 !~ /\]/) skip = 1
      next
    }
    { print }
  ' "$conf_new" > "$conf_new.awk")
  cat "$conf_new.awk" > "$conf_new"
  rm -f "$conf_new.awk"
fi

# Doubles as the parse check for everything edited above and as the value
# printed at the end. A malformed key or list fails here, before the live
# config is touched.
YGG_ADDRESS="$(yggdrasil -useconffile "$conf_new" -address)" \
  || die "Yggdrasil rejected the edited configuration; $YGGDRASIL_CONF was left unchanged."

cat "$conf_new" > "$YGGDRASIL_CONF"

systemctl enable yggdrasil.service
systemctl restart yggdrasil.service
systemctl is-active --quiet yggdrasil.service

# systemd reports the unit active as soon as the process starts, which is
# before the TUN device exists, so wait for the interface rather than assume it.
for _ in {1..15}; do
  ip link show "$YGGDRASIL_IFNAME" >/dev/null 2>&1 && break
  sleep 1
done

ip link show "$YGGDRASIL_IFNAME" >/dev/null 2>&1 || {
  echo "Yggdrasil is running but did not create interface $YGGDRASIL_IFNAME." >&2
  echo "Check: ip -6 addr ; journalctl -u yggdrasil -n 50" >&2
  exit 1
}

printf '\n\033[1;34m==> Configuring Yggdrasil firewall rules\033[0m\n'

# No port is opened for Yggdrasil itself: "Listen" is empty by default, so the
# node only makes outbound peer connections plus local multicast discovery, and
# accepts no incoming peerings. Add a Listen entry in yggdrasil.conf and open
# the matching port yourself if you want to accept them.
#
# Traffic addressed to this node arrives inside those outbound connections and
# surfaces on the TUN interface as ordinary IPv6, so UFW rules decide what
# answers there. UFW evaluates rules in order and a plain "ufw allow <port>" is
# not bound to an interface, so on its own it would answer over the mesh too.
# The deny is therefore prepended -- ahead of every existing rule -- and closes
# the interface to everything; the trusted addresses are prepended after it, which lands them
# above it, and a trusted address added on a later run still ends up on top.
# ufw refuses to add a rule that already exists, so re-running is a no-op.
# A rename leaves the rules written for the old name behind: a deny on an
# interface that no longer exists is dead weight, and an allow there would
# quietly spring back to life if anything ever took that name. "ufw show added"
# prints every user rule as the command that created it, so the ones this
# script wrote for the old name -- recognised by the interface and the exact
# comments used here -- are deleted by the same spec. Each trusted address found
# there joins this run's list, so the rename moves the access rather than
# silently dropping hosts that were not repeated on the command line.
if [[ -n $old_ifname && $old_ifname != auto && $old_ifname != "$YGGDRASIL_IFNAME" ]]; then
  while IFS= read -r rule; do
    case "$rule" in
      "ufw deny in on $old_ifname comment 'Yggdrasil: closed unless trusted'")
        ufw delete deny in on "$old_ifname" comment 'Yggdrasil: closed unless trusted' ;;
      "ufw allow in on $old_ifname from "*" comment 'Yggdrasil trusted host'")
        addr="${rule#ufw allow in on "$old_ifname" from }"
        addr="${addr%% *}"
        ufw delete allow in on "$old_ifname" from "$addr" comment 'Yggdrasil trusted host'
        grep -qxF "$addr" <<< "$TRUSTED" || TRUSTED="${TRUSTED}${TRUSTED:+$'\n'}$addr" ;;
    esac
  done < <(ufw show added)
fi

ufw prepend deny in on "$YGGDRASIL_IFNAME" comment 'Yggdrasil: closed unless trusted'

if [[ -n $TRUSTED ]]; then
  while IFS= read -r addr; do
    ufw prepend allow in on "$YGGDRASIL_IFNAME" from "$addr" comment 'Yggdrasil trusted host'
  done <<< "$TRUSTED"
fi

# Not enabled here: turning a firewall on without an SSH rule locks a remote
# session out, and which port that is belongs to the host's own setup.
ufw status | grep -q '^Status: active' || printf '\n\033[1;33m%s\n%s\033[0m\n' \
  'WARNING: UFW is installed but inactive, so the rules above are stored but' \
  "not enforced and $YGGDRASIL_IFNAME is fully open. Allow SSH, then: ufw enable"

# A fresh install ships "Peers: []". The node then has an address but no path
# into the network: on a VPS there are no multicast neighbours to discover
# either, so it stays isolated until peers are added.
if grep -Eq '^[[:space:]]*Peers:[[:space:]]*\[\][[:space:]]*$' "$YGGDRASIL_CONF"; then
  printf '\n\033[1;33m%s\n%s\n%s\n%s\033[0m\n' \
    'WARNING: no peers are configured, so this node is isolated from the' \
    'Yggdrasil network. Pick current peers from' \
    'https://github.com/yggdrasil-network/public-peers and rerun with' \
    '  --peer URI [--peer URI ...]'
fi

# The summary describes the node as it now is -- read back from the live
# config and from UFW -- not the options of this particular run, so a re-run
# without arguments reports the same picture as the run that configured it.
node_peers="$(awk '
  /^[[:space:]]*Peers:[[:space:]]*\[/ { if ($0 ~ /\]/) exit; f = 1; next }
  f && /^[[:space:]]*\]/ { exit }
  f { gsub(/^[[:space:]]*"|"[[:space:]]*$/, ""); if ($0 != "") print }
' "$YGGDRASIL_CONF")"
node_trusted=''
while IFS= read -r rule; do
  case "$rule" in
    "ufw allow in on $YGGDRASIL_IFNAME from "*" comment 'Yggdrasil trusted host'")
      addr="${rule#ufw allow in on "$YGGDRASIL_IFNAME" from }"
      node_trusted="${node_trusted}${node_trusted:+$'\n'}${addr%% *}" ;;
  esac
done < <(ufw show added)
ufw_state="$(ufw status verbose 2>/dev/null)"
fw_inactive=0
case "$ufw_state" in
  *'Status: active'*)
    case "$ufw_state" in
      *'Default: allow (incoming)'*) node_fw="active, default allow incoming -- only $YGGDRASIL_IFNAME is filtered" ;;
      *)                             node_fw="active, default deny incoming" ;;
    esac ;;
  *) node_fw='INACTIVE -- the rules below are stored but not enforced'; fw_inactive=1 ;;
esac
# Peers connect a moment after the restart; this is the count at this instant,
# and LAN multicast neighbours are counted too.
links_up="$(yggdrasilctl -json getPeers 2>/dev/null | grep -c '"up": *true' || true)"

G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[0m'
printf '\n%s============================================================%s\n' "$G" "$R"
printf '%s Yggdrasil installed and running.%s\n' "$G" "$R"
printf '%s Node address : %s%s\n' "$G" "$YGG_ADDRESS" "$R"
printf '%s Interface    : %s%s\n' "$G" "$YGGDRASIL_IFNAME" "$R"
printf '%s Config       : %s%s\n' "$G" "$YGGDRASIL_CONF" "$R"
# The one line that calls for action is the one line in yellow.
if [[ $fw_inactive -eq 1 ]]; then
  printf '%s Firewall     : %s%s\n' "$Y" "$node_fw" "$R"
else
  printf '%s Firewall     : %s%s\n' "$G" "$node_fw" "$R"
fi
if [[ -n $node_peers ]]; then
  printf '%s Peers        : %s configured, %s link(s) up right now (public + LAN multicast)%s\n' "$G" "$(wc -l <<< "$node_peers")" "${links_up:-0}" "$R"
  while IFS= read -r p; do printf '%s     %s%s\n' "$G" "$p" "$R"; done <<< "$node_peers"
else
  printf '%s Peers        : none -- isolated until --peer is given%s\n' "$G" "$R"
fi
if [[ -n $node_trusted ]]; then
  printf '%s Trusted      : %s host(s) may reach every port over %s%s\n' "$G" "$(wc -l <<< "$node_trusted")" "$YGGDRASIL_IFNAME" "$R"
  while IFS= read -r t; do printf '%s     %s%s\n' "$G" "$t" "$R"; done <<< "$node_trusted"
else
  printf '%s Trusted      : none -- nothing reaches this host over %s%s\n' "$G" "$YGGDRASIL_IFNAME" "$R"
fi
printf '%s Check        : yggdrasilctl getPeers ; ufw status%s\n' "$G" "$R"
printf '%s============================================================%s\n' "$G" "$R"
