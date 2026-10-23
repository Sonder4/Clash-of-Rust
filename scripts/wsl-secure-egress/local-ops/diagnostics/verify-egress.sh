#!/bin/bash
# Read-only runtime verification of the WSL Secure Egress transport.
#
# Run inside the manager distribution after the product's Start:
#   wsl.exe -d Ubuntu-26.04 -u root -- bash verify-egress.sh [endpoint-ipv4]
#
# It changes nothing. wg0 lives in cor-egress-gw (its UDP socket stays bound in
# cor-egress-transport), so the tunnel state is read from the gateway namespace.
#
# The endpoint is passed as an argument or read from the root-private manager
# profile; it is never stored in this file.
ENDPOINT="${1:-}"
if [ -z "$ENDPOINT" ] && [ -r /etc/cor-egress/profile.json ]; then
  ENDPOINT=$(python3 -c "import json;print(json.load(open('/etc/cor-egress/profile.json')).get('endpoint_ipv4',''))" 2>/dev/null)
fi

echo "===== NETNS ====="
readlink /proc/self/ns/net
ip netns list 2>/dev/null || echo "(ip netns list failed)"

echo
echo "===== ADDRESSES (root ns) ====="
ip -brief addr show

echo
echo "===== ROUTES (root ns) ====="
ip route show

echo
echo "===== DNS ====="
cat /etc/resolv.conf

echo
echo "===== TUNNEL: gateway namespace ====="
ip netns exec cor-egress-gw wg show 2>&1 || echo "(wg show failed)"
echo "--- gateway routes ---"
ip netns exec cor-egress-gw ip route show 2>&1
echo "--- gateway links ---"
ip netns exec cor-egress-gw ip -brief link show 2>&1
echo "--- transport links (outer socket namespace) ---"
ip netns exec cor-egress-transport ip -brief link show 2>&1

echo
echo "===== NFT TABLES ====="
nft list tables 2>&1

echo
echo "===== EGRESS IP (three independent services) ====="
echo -n "  api.ipify.org      : "; curl -s --max-time 20 https://api.ipify.org 2>&1 | head -c 40; echo
echo -n "  ifconfig.co        : "; curl -s --max-time 20 https://ifconfig.co 2>&1 | head -c 40; echo
echo -n "  api.myip.com       : "; curl -s --max-time 20 https://api.myip.com 2>&1 | head -c 120; echo

echo
echo "===== IPv6 EGRESS (must fail closed) ====="
echo -n "  curl -6 ifconfig.co: "; curl -6 -s --max-time 10 https://ifconfig.co 2>&1 | head -c 60; echo
echo -n "  global IPv6 addrs  : "; ip -6 -brief addr show scope global 2>/dev/null | grep -c . || true

echo
echo "===== DNS + TLS + HTTP ====="
echo -n "  getent api.ipify.org: "; getent hosts api.ipify.org 2>&1 | head -2
echo -n "  example.com status : "; curl -s -o /dev/null -w '%{http_code}' --max-time 20 https://example.com/ 2>&1; echo

echo
echo "===== ROUTE CHOSEN FOR THE VPS ENDPOINT ====="
if [ -n "$ENDPOINT" ]; then
  ip route get "$ENDPOINT" 2>&1
else
  echo "  no endpoint supplied and the manager profile is unreadable; skipped"
fi

echo
echo "===== DONE ====="
