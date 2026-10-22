#!/bin/sh
# Clash of WSL resident guard installer for the managed distribution.
set -eu

PREFIX=/usr/local/lib/clash-of-wsl
UNIT=/etc/systemd/system/clash-of-wsl-guard.service

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root inside the managed distribution" >&2
    exit 1
fi

install -d -m 0755 "$PREFIX"
install -m 0755 "$(dirname "$0")/clash-of-wsl-daemon.py" "$PREFIX/clash-of-wsl-daemon.py"
install -m 0644 "$(dirname "$0")/clash-of-wsl-guard.service" "$UNIT"

systemctl daemon-reload
systemctl enable clash-of-wsl-guard.service >/dev/null 2>&1 || true
systemctl restart clash-of-wsl-guard.service

echo "clash-of-wsl resident guard installed"
