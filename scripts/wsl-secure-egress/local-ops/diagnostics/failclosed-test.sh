#!/bin/bash
# Fail-closed test: with the tunnel closed, then with the WSL guard deleted.
echo "===== STATE A: closed guard present ====="
nft list tables
echo -n "  curl http://1.1.1.1        : "; curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://1.1.1.1/; echo
echo -n "  dns example.com            : "; getent hosts example.com >/dev/null 2>&1 && echo RESOLVED || echo blocked
echo -n "  ping 1.1.1.1               : "; ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1 && echo REPLY || echo blocked

echo
echo "===== deleting the WSL guard table (simulated guard failure) ====="
nft delete table inet cor_egress_guard && echo "  deleted"
nft list tables | sed 's/^/  /'

echo
echo "===== STATE B: no guard at all, endpoint rule disabled ====="
echo -n "  curl http://1.1.1.1        : "; curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://1.1.1.1/; echo
echo -n "  dns example.com            : "; getent hosts example.com >/dev/null 2>&1 && echo RESOLVED || echo blocked
echo -n "  ping 1.1.1.1               : "; ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1 && echo REPLY || echo blocked
echo -n "  curl https://api.ipify.org : "; curl -s --max-time 8 https://api.ipify.org 2>&1 | head -c 40; echo

echo
echo "===== link counters (did anything leave eth0?) ====="
ip -s link show eth0 | tail -4

echo
echo "===== DONE ====="
