#!/bin/bash
# Does WSL expose the Windows host's campus address?
#
# Usage inside the distro (run as root for the nft section):
#   bash exposure-check.sh [host-address ...]
# Example (placeholders -- use the host's current addresses):
#   bash exposure-check.sh 192.0.2.10 198.51.100.20
#
# Read-only. The addresses are supplied by the caller so no site-specific
# address is stored in this file.
PREFIXES=("$@")

echo "===== IPv4 ADDRESSES ====="
ip -4 -brief addr show

echo
echo "===== IPv6 ADDRESSES ====="
ip -6 -brief addr show
echo "--- IPv6 routes ---"
ip -6 route show 2>/dev/null | head -5

echo
echo "===== HOST PREFIXES PRESENT IN WSL? ====="
if [ "${#PREFIXES[@]}" -eq 0 ]; then
  echo "  no prefixes supplied; skipping"
else
  found=0
  for p in "${PREFIXES[@]}"; do
    if ip -4 addr show | grep -q -- "$p"; then
      echo "  !! FOUND host address $p configured inside WSL"
      found=1
    else
      echo "  absent: $p"
    fi
  done
  [ "$found" -eq 0 ] && echo "  none of the host addresses are configured inside WSL"
fi

echo
echo "===== NFT GUARD: what may leave ====="
nft list ruleset | grep -E 'policy (drop|accept)|meta nfproto ipv6|oifname "cor-eb0"|iifname "cor-et0" oifname "eth0"' | head -12

echo
echo "===== DNS PATH ====="
cat /etc/resolv.conf

echo
echo "===== IPv4 EGRESS (three services) ====="
for u in https://api.ipify.org https://ifconfig.co https://api.myip.com; do
  printf '  %-28s ' "$u"
  curl -s --max-time 15 "$u" 2>&1 | head -c 80
  echo
done

echo
echo "===== IPv6 EGRESS ATTEMPT (must fail closed) ====="
printf '  curl -6 ifconfig.co : '
curl -6 -s --max-time 12 https://ifconfig.co 2>&1 | head -c 80
echo
printf '  curl -6 ipify       : '
curl -6 -s --max-time 12 https://api64.ipify.org 2>&1 | head -c 80
echo

echo
echo "===== DONE ====="
