#!/bin/bash
# Read-only diagnostic of the WSL side. Touches nothing.
#
# Usage: bash wsl-diag.sh [endpoint-ipv4] [endpoint-port]
# The endpoint is read from the root-private manager profile when not given, so
# no site-specific address is stored in this file.
ENDPOINT="${1:-}"
PORT="${2:-51820}"
if [ -z "$ENDPOINT" ] && [ -r /etc/cor-egress/profile.json ]; then
  ENDPOINT=$(python3 -c "import json;print(json.load(open('/etc/cor-egress/profile.json')).get('endpoint_ipv4',''))" 2>/dev/null)
fi
echo "===== DISTRO / KERNEL ====="
. /etc/os-release 2>/dev/null && echo "distro: $PRETTY_NAME"
uname -r
echo "netns: $(readlink /proc/self/ns/net)"

echo
echo "===== ADDRESSES ====="
ip -brief addr show 2>/dev/null || ip addr show | grep -E 'inet '

echo
echo "===== DEFAULT ROUTE ====="
ip route show default 2>/dev/null || echo "(none)"

echo
echo "===== DNS (/etc/resolv.conf) ====="
cat /etc/resolv.conf 2>/dev/null

echo
echo "===== cor-egress ARTIFACTS ====="
for p in /etc/cor-egress /var/lib/cor-egress /etc/cor-egress/profile.json \
         /var/lib/cor-egress/wireguard.key /etc/cor-egress/scope-attestation.json; do
  if [ -e "$p" ]; then
    if [ -d "$p" ]; then echo "  DIR  $p"; ls -la "$p" 2>/dev/null | head -8;
    else echo "  FILE $p ($(stat -c%s "$p" 2>/dev/null) bytes, $(stat -c%y "$p" 2>/dev/null | cut -d. -f1))"; fi
  else
    echo "  MISSING $p"
  fi
done

echo
echo "===== WIREGUARD ====="
if command -v wg >/dev/null 2>&1; then
  wg show 2>&1 | head -20 || echo "(wg show failed)"
else
  echo "  wg not installed"
fi
ip link show wg0 2>/dev/null || echo "  no wg0 interface"

echo
echo "===== NFTABLES GUARD ====="
if command -v nft >/dev/null 2>&1; then
  nft list ruleset 2>&1 | head -30 || echo "(nft failed)"
else
  echo "  nft not installed"
fi

echo
echo "===== EGRESS TEST (direct) ====="
echo -n "  direct https://api.ipify.org : "
curl -s --max-time 12 https://api.ipify.org 2>&1 | head -c 60; echo
echo -n "  direct https://ifconfig.co   : "
curl -s --max-time 12 https://ifconfig.co 2>&1 | head -c 60; echo

echo
echo "===== REACH VPS ENDPOINT ${ENDPOINT:-unset}:$PORT/udp ====="
if [ -n "$ENDPOINT" ]; then
  timeout 6 bash -c "cat < /dev/null > /dev/udp/$ENDPOINT/$PORT" 2>&1 && echo "  udp write ok (no RST expected for udp)" || echo "  udp write failed"
else
  echo "  no endpoint supplied and the manager profile is unreadable; skipped"
fi

echo
echo "===== TCP 443 to a known host ====="
timeout 8 curl -s -o /dev/null -w "  baidu: %{http_code}\n" --max-time 8 https://www.baidu.com/ 2>&1

echo
echo "===== systemd cor-egress units ====="
systemctl list-unit-files 2>/dev/null | grep -i -E 'cor-egress|clash' || echo "  none"
systemctl is-enabled cor-egress-guard.service 2>&1 | head -1
systemctl is-active cor-egress-guard.service 2>&1 | head -1

echo
echo "===== DONE ====="
