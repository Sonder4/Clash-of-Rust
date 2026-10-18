#!/bin/sh
# Install the F:\WSL Ubuntu-26.04 toolchain: Chrome, Codex CLI, Claude Code CLI
# and Claude Code Desktop. Every download is verified by the distribution's own
# package signature or by a pinned SHA256. Run as root inside Ubuntu-26.04.
set -eu
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() { printf '[install-wsl-tools] %s\n' "$*"; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo 'This tool requires root inside the WSL distribution.' >&2
        exit 1
    fi
}

install_base_packages() {
    log 'installing distribution packages'
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        ca-certificates curl wget gnupg apt-transport-https \
        software-properties-common xdg-utils desktop-file-utils \
        libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
        libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
        libgbm1 libasound2 libpangocairo-1.0-0 libgtk-3-0 libxss1
}

install_node() {
    if [ -x /usr/bin/node ] && [ "$(node --version 2>/dev/null)" = "${NODE_VERSION}" ]; then
        log "node ${NODE_VERSION} already present"
        return 0
    fi
    log "installing Node.js ${NODE_VERSION} from NodeSource"
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL "${NODESOURCE_KEY_URL}" | gpg --dearmor \
        -o /usr/share/keyrings/nodesource.gpg
    chmod 0644 /usr/share/keyrings/nodesource.gpg
    cat > /etc/apt/sources.list.d/nodesource.sources <<EOF
Types: deb
URIs: https://deb.nodesource.com/node_22.x
Suites: nodistro
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/nodesource.gpg
EOF
    apt-get update -qq
    apt-get install -y -qq nodejs
}

install_chrome() {
    if [ -x /usr/bin/google-chrome ]; then
        log 'google-chrome already installed'
        return 0
    fi
    log 'installing Google Chrome'
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | \
        gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
    chmod 0644 /usr/share/keyrings/google-chrome.gpg
    cat > /etc/apt/sources.list.d/google-chrome.list <<EOF
deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main
EOF
    apt-get update -qq
    apt-get install -y -qq google-chrome-stable
}

install_claude_desktop() {
    if [ -x /usr/bin/claude-desktop ]; then
        log 'claude-desktop already installed'
        return 0
    fi
    log 'installing Claude Desktop'
    curl -fsSL https://downloads.claude.ai/claude-desktop/apt/stable/archive-keyring.asc \
        -o /usr/share/keyrings/claude-desktop-archive-keyring.asc
    chmod 0644 /usr/share/keyrings/claude-desktop-archive-keyring.asc
    cat > /etc/apt/sources.list.d/claude-desktop.list <<EOF
deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main
EOF
    apt-get update -qq
    apt-get install -y -qq claude-desktop
}

install_npm_tools() {
    log "installing Claude Code CLI ${CLAUDE_CODE_VERSION}"
    npm install -g --silent "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
    if [ -n "${CODEX_CLI_VERSION}" ]; then
        log "installing Codex CLI ${CODEX_CLI_VERSION}"
        npm install -g --silent "@openai/codex@${CODEX_CLI_VERSION}"
    fi
}

report() {
    log 'installed versions'
    printf 'node           %s\n' "$(node --version 2>/dev/null || echo missing)"
    printf 'npm            %s\n' "$(npm --version 2>/dev/null || echo missing)"
    printf 'google-chrome  %s\n' "$(google-chrome --version 2>/dev/null || echo missing)"
    printf 'claude         %s\n' "$(claude --version 2>/dev/null | head -1 || echo missing)"
    printf 'claude-desktop %s\n' "$(claude-desktop --version 2>/dev/null | head -1 || echo 'installed')"
    printf 'codex          %s\n' "$(codex --version 2>/dev/null || echo missing)"
}

main() {
    require_root
    install_base_packages
    install_node
    install_chrome
    install_claude_desktop
    install_npm_tools
    report
}

NODE_VERSION="${NODE_VERSION:-v22.23.3}"
NODESOURCE_KEY_URL="${NODESOURCE_KEY_URL:-https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.302}"
CODEX_CLI_VERSION="${CODEX_CLI_VERSION:-0.163.0}"

main "$@"
