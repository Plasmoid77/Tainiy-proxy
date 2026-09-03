#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash i2pd-timer-setup.sh" >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

if [[ $ID != debian ]]; then
  echo "This script is intended for Debian." >&2
  exit 1
fi

printf '\n\033[1;34m==> Configuring delayed i2pd startup\033[0m\n'

cat > /etc/systemd/system/i2pd.timer <<'EOF'
[Unit]
# Wants=/After= only order unit *start attempts*; they do not wait for
# Yggdrasil to be fully operational. This is fine here because Yggdrasil
# derives its address from its own keys and assigns it immediately on start,
# well inside the 10s OnActiveSec delay below. This timer only sequences
# startup order — it does not bind i2pd to Yggdrasil's interface or route
# i2pd traffic through it.
Description=Start i2pd 10 seconds after Yggdrasil
Wants=yggdrasil.service
After=yggdrasil.service

[Timer]
OnActiveSec=10s
AccuracySec=1s
Unit=i2pd.service

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl disable --now i2pd.service
systemctl enable i2pd.timer
systemctl restart i2pd.timer
systemctl is-active --quiet i2pd.timer

printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m i2pd delayed startup configured.\033[0m\n'
printf '\033[1;32m Timer: i2pd.timer\033[0m\n'
printf '\033[1;32m Delay: 10 seconds after Yggdrasil\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'