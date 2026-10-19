# Ubuntu 26.04 workspace tools

`install-workspace-tools.sh` is an egress-gated installer. It refuses to install anything unless `curl -4 https://ifconfig.co/ip` returns the configured Germany VPS address (`62.84.164.122` by default). It clears inherited Windows proxy variables before running apt, Chrome download, or npm.

It installs:

- Google Chrome Stable;
- Node.js/npm;
- OpenAI Codex CLI (`@openai/codex`);
- Claude Code CLI (`@anthropic-ai/claude-code`);
- a `.desktop` launcher named `Claude Desktop (WSL Secure Egress)` that opens Claude in Chrome app mode.

The launcher is deliberately a Chrome app-mode wrapper: the Linux Claude Code CLI installer does not provide a native Claude Desktop package. The wrapper is still started inside the verified WSL environment and is subject to the same egress gate.

The script is not marked as successfully executed until the administrator tunnel is running and its final version/IP output is captured in the live test log.