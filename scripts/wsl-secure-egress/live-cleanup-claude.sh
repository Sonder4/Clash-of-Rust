#!/usr/bin/env bash
set -euo pipefail
BACKUP=/mnt/f/Codex/Clash-of-Rust-work/docs/wsl-secure-egress/backups/live-20261019/ubuntu-22.04
mkdir -p "$BACKUP/etc/systemd/system" "$BACKUP/etc/profile.d"
cp -a /etc/resolv.conf "$BACKUP/etc/resolv.conf"
for f in /etc/systemd/system/xuan-claude-de*.service; do
    [ -e "$f" ] && cp -a "$f" "$BACKUP/etc/systemd/system/"
done
if [ -e /etc/profile.d/xuan-claude-de.sh.disabled-by-clash-of-rust ]; then
    cp -a /etc/profile.d/xuan-claude-de.sh.disabled-by-clash-of-rust "$BACKUP/etc/profile.d/"
fi
systemctl disable --now xuan-claude-de.service xuan-claude-de-redsocks.service xuan-claude-de-doh.service xuan-claude-de-connect.service xuan-claude-de-dns.service 2>/dev/null || true
rm -f /etc/systemd/system/xuan-claude-de.service /etc/systemd/system/xuan-claude-de-redsocks.service /etc/systemd/system/xuan-claude-de-doh.service /etc/systemd/system/xuan-claude-de-connect.service /etc/systemd/system/xuan-claude-de-dns.service /etc/profile.d/xuan-claude-de.sh.disabled-by-clash-of-rust
printf 'nameserver 172.19.96.1\noptions timeout:2 attempts:2\n' > /etc/resolv.conf
chmod 644 /etc/resolv.conf
systemctl daemon-reload 2>/dev/null || true
echo CLEANUP_DONE