#!/usr/bin/env bash
set -euo pipefail

EXPECTED_EGRESS_IPV4="${EXPECTED_EGRESS_IPV4:-62.84.164.122}"
if [ "$(id -u)" -ne 0 ]; then
  echo "run as root" >&2
  exit 2
fi

export http_proxy= https_proxy= all_proxy= HTTP_PROXY= HTTPS_PROXY= ALL_PROXY=
actual="$(curl -4fsS --connect-timeout 12 https://ifconfig.co/ip | tr -d '\r\n' || true)"
if [ -z "$actual" ] || [ "$actual" != "$EXPECTED_EGRESS_IPV4" ]; then
  echo "refusing tool installation: egress=$actual expected=$EXPECTED_EGRESS_IPV4" >&2
  exit 20
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl wget gnupg python3 python3-pip nodejs npm

chrome_deb=/tmp/google-chrome-stable_current_amd64.deb
curl -fL --retry 3 -o "$chrome_deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
dpkg -i "$chrome_deb" || apt-get -f install -y
rm -f "$chrome_deb"

npm install --global @openai/codex @anthropic-ai/claude-code

# Linux does not receive a native Claude Desktop package from the CLI installers.
# Provide a desktop entry that uses Chrome app mode and inherits the verified
# WSL network namespace/environment.
install -d -m 0755 /usr/local/share/applications
cat > /usr/local/share/applications/claude-desktop-wsl.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Claude Desktop (WSL Secure Egress)
Comment=Claude web app through Clash of WSL
Exec=/usr/bin/google-chrome --app=https://claude.ai/
Terminal=false
Categories=Development;Network;
DESKTOP
chmod 0644 /usr/local/share/applications/claude-desktop-wsl.desktop

printf 'egress_ipv4=%s\n' "$actual"
node --version
npm --version
/usr/bin/google-chrome --version || true
codex --version || true
claude --version || true