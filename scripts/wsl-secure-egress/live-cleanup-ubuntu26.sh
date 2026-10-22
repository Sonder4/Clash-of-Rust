#!/usr/bin/env bash
set -euo pipefail
BACKUP=/mnt/f/Codex/Clash-of-Rust-work/docs/wsl-secure-egress/backups/live-20261019/ubuntu-26.04
mkdir -p "$BACKUP/etc"
cp -a /etc/resolv.conf "$BACKUP/etc/resolv.conf"
printf 'nameserver 172.19.96.1\noptions timeout:2 attempts:2\n' > /etc/resolv.conf
chmod 644 /etc/resolv.conf
echo UBUNTU26_DNS_RESET