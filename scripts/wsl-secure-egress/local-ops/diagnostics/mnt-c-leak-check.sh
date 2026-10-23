#!/bin/bash
# Is the host address recoverable through the /mnt/c filesystem?
PREFIXES=("$@")

echo "===== /mnt/c mount options ====="
mount | grep -E ' /mnt/c ' | sed 's/^/  /'

echo
echo "===== registry hives visible? ====="
for h in SYSTEM SOFTWARE; do
  f="/mnt/c/Windows/System32/config/$h"
  if [ -r "$f" ]; then
    echo "  readable: $f ($(stat -c%s "$f" 2>/dev/null) bytes)"
  else
    echo "  not readable: $f"
  fi
done

echo
echo "===== grep the SYSTEM hive for the host prefixes (binary-safe) ====="
HIVE=/mnt/c/Windows/System32/config/SYSTEM
if [ -r "$HIVE" ]; then
  for p in "${PREFIXES[@]}"; do
    echo -n "  $p : "
    if grep -a -c -- "$p" "$HIVE" 2>/dev/null | grep -qv '^0$'; then
      echo "FOUND"
    else
      echo "not found"
    fi
  done
else
  echo "  SYSTEM hive not readable"
fi

echo
echo "===== grep the SOFTWARE hive for the host prefixes ====="
SOFT=/mnt/c/Windows/System32/config/SOFTWARE
if [ -r "$SOFT" ]; then
  for p in "${PREFIXES[@]}"; do
    echo -n "  $p : "
    if grep -a -c -- "$p" "$SOFT" 2>/dev/null | grep -qv '^0$'; then
      echo "FOUND"
    else
      echo "not found"
    fi
  done
else
  echo "  SOFTWARE hive not readable"
fi

echo
echo "===== a broader but bounded scan of small user files ====="
for p in "${PREFIXES[@]}"; do
  echo "  prefix $p in /mnt/c/Users/xuan (files < 1 MiB, first 200 hits)"
  timeout 120 grep -rIl --binary-files=without-match -m1 -- "$p" /mnt/c/Users/xuan 2>/dev/null | head -5 | sed 's/^/    LEAK: /'
done

echo
echo "===== DONE ====="
