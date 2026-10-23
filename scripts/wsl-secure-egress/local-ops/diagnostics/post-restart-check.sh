#!/bin/bash
# Post-restart inspection: what did the boot guard restore by itself?
echo "===== DISTRO / KERNEL ====="
. /etc/os-release 2>/dev/null && echo "distro: $PRETTY_NAME"
echo "netns: $(readlink /proc/self/ns/net)"

echo
echo "===== NFT TABLES ====="
nft list tables

echo
echo "===== GUARD (summary) ====="
nft list ruleset | grep -E 'policy (drop|accept)|counter packets|iifname "cor-et0"' | head -12

echo
echo "===== MANAGER JOURNAL ====="
python3 -c "
import json
try:
    s=json.load(open('/var/lib/cor-egress/state.json'))
    print('role=',s.get('role'),'phase=',s.get('phase'),'boot_id=',s.get('boot_id'))
    print('namespaces=',s.get('namespaces'))
except Exception as e:
    print('no journal:', type(e).__name__)
"

echo
echo "===== NAMESPACES / LINKS ====="
ip netns list 2>/dev/null || true
ip -brief addr show | head -8

echo
echo "===== BOOT HOOK ====="
cat /etc/wsl.conf 2>/dev/null

echo
echo "===== EGRESS ATTEMPT ====="
echo -n "  ipify: "; curl -s --max-time 12 https://api.ipify.org 2>&1 | head -c 60; echo
echo -n "  dns example.com: "; getent hosts example.com 2>&1 | head -1; echo

echo
echo "===== DONE ====="
