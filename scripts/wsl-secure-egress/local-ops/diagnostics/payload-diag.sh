#!/bin/bash
# Read-only inspection of the cor-egress payload install preconditions.
echo "===== /usr/local/lib/cor-egress ====="
if [ -e /usr/local/lib/cor-egress ]; then
  ls -la /usr/local/lib/cor-egress
  echo "--- receipt ---"
  cat /usr/local/lib/cor-egress/payload-receipt.json 2>/dev/null || echo "(no receipt)"
else
  echo "  MISSING"
fi

echo
echo "===== /usr/local/bin aliases ====="
ls -la /usr/local/bin/secure-egress /usr/local/bin/cor-egress-manager 2>&1

echo
echo "===== /usr/local/lib and /usr/local permissions ====="
ls -ld /usr/local /usr/local/lib /usr/local/bin 2>&1

echo
echo "===== /run/netns ====="
ls -la /run/netns 2>&1 || echo "  (absent)"

echo
echo "===== /var/lib/cor-egress ====="
ls -la /var/lib/cor-egress
echo "--- state.json ---"
cat /var/lib/cor-egress/state.json 2>/dev/null
echo

echo
echo "===== lock holders ====="
(fuser -v /var/lib/cor-egress/manager.lock 2>&1 || true)

echo
echo "===== python3 ====="
/usr/bin/python3 -V 2>&1
echo
echo "===== DONE ====="
