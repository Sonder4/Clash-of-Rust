# Ubuntu 26.04 workspace tools

## Authoritative installer

Use
`scripts/wsl-secure-egress/tools/install-wsl-tools.sh` as the authoritative
installer. Run it as root from the strict WSL launcher, after the current
managed generation has proven its tunnel and VPS egress.

`scripts/wsl-secure-egress/install-workspace-tools.sh` is retained only as a
compatibility entry point and must delegate to the authoritative installer.
Maintaining package versions or installation logic in both scripts is forbidden
because the two copies can drift.

The installer clears inherited proxy variables and makes no package change until
`https://ifconfig.co/ip` returns the expected German VPS IPv4. The expected
address is deployment data and is never stored in the repository: export
`EXPECTED_EGRESS_IPV4` from the operator's own record before running the
installer. A missing or malformed value exits with code 21; a failed or
unavailable probe exits with code 20. The zero-argument compatibility wrapper
preserves both exit statuses.

## Fixed versions

- Node.js `v22.23.3`.
- Claude Code CLI `2.1.302`.
- Codex CLI `0.163.0`.
- Google Chrome and the native `claude-desktop` package from their signed APT
  repositories.

## Ubuntu 26.04 specifics

This distribution targets 26.04 only; the package list uses the 64-bit time_t
names it actually publishes (`libatk1.0-0t64`, `libatk-bridge2.0-0t64`,
`libcups2t64`, `libasound2t64`, `libgtk-3-0t64`). Running it on an older release
requires those names, not a compatibility shim.

NodeSource publishes 22.23.4 as the newest 22.x line, so the install pins
`nodejs=22.23.3-1nodesource1` explicitly; an unpinned install drifts and fails
the version check.

Claude Desktop's signing key lives at
`https://downloads.claude.ai/claude-desktop/key.asc` and is already
ASCII-armored. Do not dearmor it: apt rejects an armored key that was converted
to binary as an unsupported keyring filetype.

These version strings are defaults and can be overridden explicitly for a
reviewed upgrade. The installer verifies the Node, Claude and Codex version
output before it reports success.

## Installation order

1. Use the strict launcher, not an ordinary distro shell.
2. Confirm that the private namespace exposes only the virtual links.
3. Confirm that the public IPv4 equals the VPS.
4. Confirm DNS resolution and provider reachability through the tunnel.
5. Run the root installer only after those gates pass.
6. Record the installed versions and the VPS IPv4 in the live test report.

The plain distro shell can still see `/mnt/*`. Tool installation and network
verification must therefore use the strict launcher so the application cannot
enumerate Windows interfaces, mounts or interop paths.

## Tools

The installer provides:

- Google Chrome Stable;
- Node.js and npm;
- OpenAI Codex CLI;
- Claude Code CLI;
- the native Linux `claude-desktop` package.

Do not replace the native package with an untracked Chrome wrapper. If the
distribution's GLIBC cannot run the native package, select a compatible
distribution or version rather than modifying system glibc.

## Current status

Installed on 2026-10-22 inside Ubuntu 26.04 through the VPS egress, with
`EXPECTED_EGRESS_IPV4` matching the live probe:

- Google Chrome `156.0.8078.47`
- Node.js `v22.23.3`, npm `10.9.9`
- Claude Code CLI `2.1.302`
- Codex CLI `0.163.0`
- claude-desktop `3.1623.4` (native APT package)

The installer is idempotent: a second run reports each component as already
present and re-verifies the reported versions.

Not verified: launching Chrome or Claude Desktop under a real display, and any
provider login. The exit was proven German (Frankfurt am Main, `DE`) on the same
path before installation, but application behaviour was not exercised.

The offline tool-installer regression passed 9 tests. It checks the unique
authoritative implementation, proxy clearing, the VPS gate before every
package action, fixed versions, the absence of legacy proxy/DNS logic, the
absolute wrapper path, argument forwarding and exit-code 20 propagation. These
tests do not install packages or contact a model provider.
