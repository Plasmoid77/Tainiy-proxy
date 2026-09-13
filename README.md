# Tainiy-proxy

Four independent Bash installers for anonymity-network tooling on a Debian VPS: a Tor client, an i2pd router, a Yggdrasil mesh node, and a systemd timer that sequences i2pd's startup after Yggdrasil's.

These scripts install and start each service on its own. They do not chain traffic between the services — i2pd is not bound to Yggdrasil's interface, and Tor is not routed through either of them — and they do not provide a single "secret proxy" pipeline. Combine them yourself only after understanding the trade-offs documented below.

## Requirements

- Debian with systemd
- root access
- an existing UFW setup if you want the firewall rules of `i2pd-setup.sh` and `yggdrasil-setup.sh` to actually take effect (see [VPS-toolkit](https://github.com/Plasmoid77/VPS-toolkit)'s `ufw-basic-setup.sh`); `yggdrasil-setup.sh` needs `ufw prepend`, i.e. UFW 0.36.1+ (Debian 12 and later)

Before piping a remote script into root Bash, inspect it if the server or repository is not under your control.

## Script index

| Script | Purpose |
|---|---|
| `tor-client-setup.sh` | Install Tor as a client-only SOCKS5 proxy on `127.0.0.1:9050` |
| `i2pd-setup.sh` | Install i2pd and open its NTCP2/SSU2 transport port in UFW |
| `i2pd-timer-setup.sh` | Delay i2pd's start by 10s after `yggdrasil.service` via a systemd timer |
| `yggdrasil-setup.sh` | Install and start a Yggdrasil mesh node on `ygg0` (or the `--iface` name), with peers, identity and trusted addresses given at deploy time |

## Deploying on a server

Run these on the server as root. Each script is independent; take only the ones you want.

```bash
curl -fsSL https://raw.githubusercontent.com/Plasmoid77/Tainiy-proxy/main/tor-client-setup.sh | bash
```

```bash
curl -fsSL https://raw.githubusercontent.com/Plasmoid77/Tainiy-proxy/main/i2pd-setup.sh | bash
```

`i2pd-setup.sh` takes an optional transport port; without one it picks a random port in `10000-65535`. Pass it after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/Plasmoid77/Tainiy-proxy/main/i2pd-setup.sh | bash -s -- 59699
```

`yggdrasil-setup.sh` takes its peers and the Yggdrasil addresses allowed in through UFW as options, in the same way (all are optional; see [Yggdrasil](#yggdrasil)):

```bash
curl -fsSL https://raw.githubusercontent.com/Plasmoid77/Tainiy-proxy/main/yggdrasil-setup.sh | bash -s -- \
  --peer tls://<PEER_HOST>:<PORT> \
  --peer tcp://<PEER_HOST>:<PORT> \
  --trusted <YOUR_YGG_ADDRESS>
```

`i2pd-timer-setup.sh` expects both i2pd and Yggdrasil to be installed already, so run it last:

```bash
curl -fsSL https://raw.githubusercontent.com/Plasmoid77/Tainiy-proxy/main/i2pd-timer-setup.sh | bash
```

Everything at once, in dependency order:

```bash
for s in tor-client-setup i2pd-setup yggdrasil-setup i2pd-timer-setup; do
  curl -fsSL "https://raw.githubusercontent.com/Plasmoid77/Tainiy-proxy/main/$s.sh" | bash || break
done
```

(add the `yggdrasil-setup.sh` options after `bash -s --` in that loop if you want peers configured in the same pass.)

To inspect a script before running it as root — advisable for anything piped from the network:

```bash
curl -fsSL https://raw.githubusercontent.com/Plasmoid77/Tainiy-proxy/main/i2pd-setup.sh -o /tmp/i2pd-setup.sh
less /tmp/i2pd-setup.sh
bash /tmp/i2pd-setup.sh
```

### Checking the result

```bash
systemctl is-active tor@default yggdrasil i2pd i2pd.timer
grep '^port' /etc/i2pd/i2pd.conf    # configured i2pd transport port
ss -ltnp | grep i2pd                # what i2pd actually listens on -- must match
ip -6 addr show ygg0                # Yggdrasil address
yggdrasilctl getPeers               # every peer should read Up
curl -s --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip
```

The last command should answer `{"IsTor":true,...}` with an IP other than the server's own.

## Tor

Client-only mode (`ClientOnly 1`), no relaying of others' traffic. SOCKS5 proxy at `127.0.0.1:9050` with `IsolateSOCKSAuth`. No firewall rule is needed or added — the proxy only listens on loopback.

## i2pd

**Runs as a full I2P router by default, not just a client** — i2pd relays other users' encrypted traffic and consumes host bandwidth unless you explicitly restrict it (`share`/bandwidth limits in `i2pd.conf`). Decide whether that is acceptable on your host before deploying.

The script picks a random port (10000–65535) unless you pass one, writes it into `i2pd.conf`'s global `port` setting, restarts i2pd, verifies the daemon is actually bound to that port, and only then opens matching TCP/UDP UFW rules. It keeps a one-time backup of the original config at `i2pd.conf.orig` before editing.

The UFW rules are not scoped to a network interface. An I2P router's transport port has to be reachable from the internet anyway, so restricting it to one interface buys little, while depending on an interface name means the rule silently stops matching if the host's NIC is ever renamed.

The repo-add step (`repo.i2pd.xyz/.help/add_repo`) is i2pd's own official installer, piped into root Bash with no checksum pinning — it adds a permanent apt source and signing key, not a one-off action. Review it if that domain is not already trusted.

## Yggdrasil

The script pins the TUN interface name to `ygg0` (the package default is `IfName: auto`, which lands on `tun0` — or `tun1` if something claimed the name first). A stable name means firewall rules and resolver configuration can refer to the interface without breaking when the numbering shifts. `--iface NAME` picks a different name (15 characters at most; letters, digits, `-`, `_`, `.`). The text below says `ygg0` for the default; with `--iface` read it as the name you gave.

The same script serves a VPS and a client machine; what differs is the options given at deploy time. Every edit is made on a copy of `/etc/yggdrasil/yggdrasil.conf` that Yggdrasil must parse successfully before it replaces the live file, so a bad key or peer list leaves the running configuration untouched. Re-running the script is safe: unchanged options are no-ops, given options replace what is there.

| Option | Effect |
|---|---|
| `--peer URI` (repeatable) | Write these into `Peers`, replacing the current list. Schemes `tls tcp quic ws wss socks sockstls`. |
| `--peers-file FILE` | Same, read from a file: one URI per line, `#` comments allowed. |
| `--trusted ADDR` (repeatable) | Allow that Yggdrasil address through the `ygg0` deny rule the script always adds — it may then reach every port on this host, over `ygg0` only. |
| `--private-key-file FILE` | Restore an existing identity (128 hex characters, nothing else) so the node keeps its address. Also accepted in the `YGG_PRIVATE_KEY` environment variable. |
| `--iface NAME` | TUN interface name instead of `ygg0`. The UFW rules are bound to the name, so changing it on a re-run leaves the rules written for the old name in place — remove those by hand (`ufw status numbered`, `ufw delete N`). |

**Peers.** Yggdrasil does not listen for incoming peer connections by default (`Listen` is empty out of the box) — it only makes outbound connections to the peers you configure, plus local discovery via multicast. Without `--peer` the node gets its address and the service runs, but on a VPS there are no multicast neighbours to discover, so it stays isolated until peers are given — the script prints a warning when `Peers` is still empty. Pick current entries from [public-peers](https://github.com/yggdrasil-network/public-peers) and confirm afterwards with `yggdrasilctl getPeers`. No port is opened for Yggdrasil itself; if you want the node to accept incoming peerings from the public network, add a `Listen` entry to the config yourself and open the matching port in UFW.

**Firewall.** The script always closes the mesh side of the host: `ufw prepend deny in on ygg0` drops everything arriving on `ygg0`, ahead of every rule that already exists — so a port allowed globally with `ufw allow <port>` stops answering over the mesh and keeps answering on the public side. Each `--trusted` address is then prepended as `ufw allow in on ygg0 from ADDR`, which puts it above the deny: that address — typically one of your own machines — reaches every port on this host, but only when the packet arrives on `ygg0`; the public interface is not widened. This is how a server becomes reachable from your clients, or a client from your server, over the mesh alone; without `--trusted`, nothing does (ICMPv6 echo excepted — UFW's `before6.rules` admit that first). Adding a trusted address later is a re-run with the new `--trusted`, or the same `ufw prepend allow ...` by hand; both land above the deny. The script installs UFW if it is missing but never enables it: turning a firewall on without an SSH rule locks a remote session out. If UFW is inactive the rules are stored, a warning says so, and `ygg0` stays fully open until you allow SSH and run `ufw enable` (VPS-toolkit's `ufw-basic-setup.sh` does that part).

**Identity.** The node's address is derived from `PrivateKey` in `/etc/yggdrasil/yggdrasil.conf`. To move an identity to a new host — or to keep the address across a reinstall — take that value from the old config and hand it to the script in a mode-600 file:

```bash
awk '/^ *PrivateKey: /{print $2}' /etc/yggdrasil/yggdrasil.conf > ygg.key   # on the old host
bash yggdrasil-setup.sh --private-key-file ygg.key --peer ...                # on the new one
```

The key is deliberately never taken as an argument value: `/proc/<pid>/cmdline` is world readable and arguments end up in shell history. `YGG_PRIVATE_KEY` works as well, but with `curl | bash` it has to be exported in the shell beforehand (a `VAR=... curl ...` prefix reaches only `curl`, not `bash`), and `sudo` drops it unless told otherwise — the file is the simpler path.

### Reaching the server over Yggdrasil

Once the node has peers, the server is reachable at its Yggdrasil address from any other Yggdrasil node, and ordinary services answer there as they would on any IPv6 address:

```bash
ssh -p <SSH_PORT> root@<SERVER_YGG_ADDRESS>
```

This needs no inbound port on the underlay, because the two layers are separate. Peering happens over outbound TCP connections to the peers listed in `Peers`, which is why `Listen` can stay empty. Traffic addressed to the node's `200::/7` address travels inside those already-open connections and surfaces on the server's `ygg0` interface as a normal IPv6 packet — from the kernel's point of view it is simply IPv6 arriving on an interface, so it goes through `INPUT` and UFW decides.

That means UFW governs which services answer over the mesh, and after this script the answer is "only what `--trusted` allows": the prepended `deny in on ygg0` sits above the rest of the ruleset, so a plain `ufw allow <port>/tcp` — which is not bound to a source or an interface and would otherwise permit both the public path and the Yggdrasil one — no longer reaches over `ygg0`. To make a service reachable *only* over the mesh, keep `--trusted` for your own addresses and drop the public rule:

```bash
ufw delete allow <SSH_PORT>/tcp
```

To open a port to every Yggdrasil node instead of a trusted few, prepend an interface-scoped rule so it lands above the deny: `ufw prepend allow in on ygg0 to any port <PORT> proto tcp comment '...'`.

Weigh that carefully for SSH: it removes the server from internet-wide brute-force attempts, but it also makes Yggdrasil the only way in. If every configured peer goes down, `yggdrasil.service` fails to start after an upgrade, or `/etc/yggdrasil/yggdrasil.conf` is lost, so is your access. The node's address is derived from the private key in that file, so a lost key means a different address. Keep provider console access available, configure several peers, and back up that file before relying on this path alone.

## i2pd-timer-setup.sh

`Wants=`/`After=yggdrasil.service` in the generated `i2pd.timer` only order when systemd *attempts* to start `i2pd.timer` relative to `yggdrasil.service` — they do not wait for Yggdrasil to be fully operational. This works out in practice because Yggdrasil derives its address from its own keys and assigns it immediately on start, well inside the 10-second delay. The timer only sequences startup order; it does not bind i2pd to Yggdrasil's interface or route i2pd's traffic through it.

## Validation

Every push and pull request runs `.github/workflows/shellcheck.yml`, which checks all scripts with `bash -n` and ShellCheck.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
