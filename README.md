# TainiyProxy

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

## Usage

```bash
sudo bash tor-client-setup.sh
sudo bash i2pd-setup.sh [PORT]
sudo bash yggdrasil-setup.sh
sudo bash i2pd-timer-setup.sh
```

## Tor

Client-only mode (`ClientOnly 1`), no relaying of others' traffic. SOCKS5 proxy at `127.0.0.1:9050` with `IsolateSOCKSAuth`. No firewall rule is needed or added — the proxy only listens on loopback.

## i2pd

**Runs as a full I2P router by default, not just a client** — i2pd relays other users' encrypted traffic and consumes host bandwidth unless you explicitly restrict it (`share`/bandwidth limits in `i2pd.conf`). Decide whether that is acceptable on your host before deploying.

The script picks a random port (10000–65535) unless you pass one, writes it into `i2pd.conf`'s global `port` setting, and opens matching TCP/UDP UFW rules on the detected default-route interface. It keeps a one-time backup of the original config at `i2pd.conf.orig` before editing.

The repo-add step (`repo.i2pd.xyz/.help/add_repo`) is i2pd's own official installer, piped into root Bash with no checksum pinning — it adds a permanent apt source and signing key, not a one-off action. Review it if that domain is not already trusted.

## Yggdrasil

Yggdrasil does not listen for incoming peer connections by default (`Listen` is empty out of the box) — it only makes outbound connections to the peers you configure, plus local discovery via multicast. No UFW rule is opened by this script because none is needed for that default, outbound-only mode. If you want your node to accept incoming peerings from the public network, add a `Listen` entry to `/etc/yggdrasil/yggdrasil.conf` yourself and open the matching port in UFW.

## i2pd-timer-setup.sh

`Wants=`/`After=yggdrasil.service` in the generated `i2pd.timer` only order when systemd *attempts* to start `i2pd.timer` relative to `yggdrasil.service` — they do not wait for Yggdrasil to be fully operational. This works out in practice because Yggdrasil derives its address from its own keys and assigns it immediately on start, well inside the 10-second delay. The timer only sequences startup order; it does not bind i2pd to Yggdrasil's interface or route i2pd's traffic through it.

## Validation

Every push and pull request runs `.github/workflows/shellcheck.yml`, which checks all scripts with `bash -n` and ShellCheck.
