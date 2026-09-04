# Tainiy-proxy

Four independent Bash installers for anonymity-network tooling on a Debian VPS: a Tor client, an i2pd router, a Yggdrasil mesh node, and a systemd timer that sequences i2pd's startup after Yggdrasil's.

These scripts install and start each service on its own. They do not chain traffic between the services — i2pd is not bound to Yggdrasil's interface, and Tor is not routed through either of them — and they do not provide a single "secret proxy" pipeline. Combine them yourself only after understanding the trade-offs documented below.

## Requirements

- Debian with systemd
- root access
- an existing UFW setup if you want `i2pd-setup.sh`'s firewall rules to actually take effect (see [VPS-toolkit](https://github.com/Plasmoid77/VPS-toolkit)'s `ufw-basic-setup.sh`)

Before piping a remote script into root Bash, inspect it if the server or repository is not under your control.

## Script index

| Script | Purpose |
|---|---|
| `tor-client-setup.sh` | Install Tor as a client-only SOCKS5 proxy on `127.0.0.1:9050` |
| `i2pd-setup.sh` | Install i2pd and open its NTCP2/SSU2 transport port in UFW |
| `i2pd-timer-setup.sh` | Delay i2pd's start by 10s after `yggdrasil.service` via a systemd timer |
| `yggdrasil-setup.sh` | Install and start a Yggdrasil mesh node |

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

```bash
curl -fsSL https://raw.githubusercontent.com/Plasmoid77/Tainiy-proxy/main/yggdrasil-setup.sh | bash
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

The script pins the TUN interface name to `ygg0` (the package default is `IfName: auto`, which lands on `tun0` — or `tun1` if something claimed the name first). A stable name means firewall rules and resolver configuration can refer to the interface without breaking when the numbering shifts.

Yggdrasil does not listen for incoming peer connections by default (`Listen` is empty out of the box) — it only makes outbound connections to the peers you configure, plus local discovery via multicast. No UFW rule is opened by this script because none is needed for that default, outbound-only mode. If you want your node to accept incoming peerings from the public network, add a `Listen` entry to `/etc/yggdrasil/yggdrasil.conf` yourself and open the matching port in UFW.

**The script does not configure any peers, and `Peers` is empty in a fresh install.** The node gets its address and the service runs, but on a VPS there are no multicast neighbours to discover either, so it stays isolated from the network until you add peers yourself — the script prints a warning when it detects this. Pick current entries from [public-peers](https://github.com/yggdrasil-network/public-peers), add them to `Peers: []` in `/etc/yggdrasil/yggdrasil.conf`, then `systemctl restart yggdrasil` and confirm with `yggdrasilctl getPeers`.

### Reaching the server over Yggdrasil

Once the node has peers, the server is reachable at its Yggdrasil address from any other Yggdrasil node, and ordinary services answer there as they would on any IPv6 address:

```bash
ssh -p <SSH_PORT> root@<SERVER_YGG_ADDRESS>
```

This needs no inbound port on the underlay, because the two layers are separate. Peering happens over outbound TCP connections to the peers listed in `Peers`, which is why `Listen` can stay empty. Traffic addressed to the node's `200::/7` address travels inside those already-open connections and surfaces on the server's `ygg0` interface as a normal IPv6 packet — from the kernel's point of view it is simply IPv6 arriving on an interface, so it goes through `INPUT` and UFW decides.

That means UFW still governs which services answer over the mesh. A plain `ufw allow <port>/tcp` rule is not bound to a source or an interface, so it permits both the public path and the Yggdrasil one. To make a service reachable *only* over the mesh, scope the rule to the interface and drop the public one:

```bash
ufw allow in on ygg0 to any port <SSH_PORT> proto tcp comment 'SSH over Yggdrasil'
ufw delete allow <SSH_PORT>/tcp
```

Weigh that carefully for SSH: it removes the server from internet-wide brute-force attempts, but it also makes Yggdrasil the only way in. If every configured peer goes down, `yggdrasil.service` fails to start after an upgrade, or `/etc/yggdrasil/yggdrasil.conf` is lost, so is your access. The node's address is derived from the private key in that file, so a lost key means a different address. Keep provider console access available, configure several peers, and back up that file before relying on this path alone.

## i2pd-timer-setup.sh

`Wants=`/`After=yggdrasil.service` in the generated `i2pd.timer` only order when systemd *attempts* to start `i2pd.timer` relative to `yggdrasil.service` — they do not wait for Yggdrasil to be fully operational. This works out in practice because Yggdrasil derives its address from its own keys and assigns it immediately on start, well inside the 10-second delay. The timer only sequences startup order; it does not bind i2pd to Yggdrasil's interface or route i2pd's traffic through it.

## Validation

Every push and pull request runs `.github/workflows/shellcheck.yml`, which checks all scripts with `bash -n` and ShellCheck.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
