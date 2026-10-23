#!/bin/bash
# Can any WSL-side command reveal the Windows host's campus address?
# Prefixes are passed as arguments so the values are not stored in the script.
PREFIXES=("$@")

echo "===== 1. address / route / neighbour ====="
ip -4 addr show | sed 's/^/  /'
ip -4 route show | sed 's/^/  /'
ip neigh show 2>/dev/null | sed 's/^/  /'
echo -n "  hostname -I: "; hostname -I

echo
echo "===== 2. resolver / hosts ====="
sed 's/^/  /' /etc/resolv.conf
grep -v '^#' /etc/hosts | sed 's/^/  /'

echo
echo "===== 3. proxy environment ====="
env | grep -i -E 'proxy|http_|https_' | sed 's/^/  /' || echo "  none"

echo
echo "===== 4. /proc network views ====="
cat /proc/net/route | sed 's/^/  /'
grep -i -E 'inet |172\.19|169\.254' /proc/net/fib_trie 2>/dev/null | head -10 | sed 's/^/  /'

echo
echo "===== 5. wsl metadata mounts ====="
ls -la /mnt/wsl 2>/dev/null | sed 's/^/  /'
cat /mnt/wsl/resolv.conf 2>/dev/null | sed 's/^/  /' || true

echo
echo "===== 6. interop attempt (must fail) ====="
if [ -x /mnt/c/Windows/System32/ipconfig.exe ]; then
  echo "  ipconfig.exe has the executable bit; trying to run it"
  /mnt/c/Windows/System32/ipconfig.exe 2>&1 | head -5 | sed 's/^/  /'
else
  echo "  ipconfig.exe not executable from WSL (interop disabled / noexec)"
fi

echo
echo "===== 7. grep system paths for the host prefixes ====="
for p in "${PREFIXES[@]}"; do
  echo "  searching prefix $p in /etc /run /var/log (bounded)"
  if grep -rIl -- "$p" /etc /run /var/log 2>/dev/null | head -5 | tee /tmp/leakhits | grep -q .; then
    sed 's/^/    LEAK FILE: /' /tmp/leakhits
  else
    echo "    no plain-text hit"
  fi
done

echo
echo "===== 8. /mnt/c sample files that commonly carry the host address ====="
for f in \
  "/mnt/c/Users/xuan/AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt" \
  "/mnt/c/Windows/System32/drivers/etc/hosts" \
  "/mnt/c/ProgramData/ClashOfRust/WslEgress/state.json"
do
  if [ -r "$f" ]; then
    echo "  readable: $f"
    for p in "${PREFIXES[@]}"; do
      if grep -q -- "$p" "$f" 2>/dev/null; then echo "    !! LEAK: file contains $p"; fi
    done
  else
    echo "  not readable: $f"
  fi
done

echo
echo "===== DONE ====="
