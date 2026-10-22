# Ubuntu 26.04 live status — 2026-10-19 (superseded; see below)

- Distribution: Ubuntu 26.04.1 LTS (Resolute Raccoon)
- Registered WSL version: 2
- Root filesystem: `F:\WSL\ext4.vhdx`
- Current network mode: WSL NAT (`172.19.104.128/20`, gateway `172.19.96.1`)
- WireGuard tools: installed (`wg` available)
- nftables: installed (`nft` available)
- Tailscale: not installed
- Chrome, Codex CLI, Claude Code CLI/Desktop: not installed
- Previous resolver `10.77.0.1` was backed up and replaced with `172.19.96.1`.
- External DNS and package installation remain blocked while the Windows Hyper-V WSL VM policy has `DefaultOutboundAction=Block`.
- The ordinary shell still exposes `/mnt/c`, `/mnt/d`, `/mnt/e` and `/mnt/f`.
  Interop is disabled, but strict launcher launch and hidden mount checks remain
  `NOT_RUN`.

The Windows administrator deployment must complete before installing network-dependent packages or claiming provider egress tests.

## Update, 2026-10-22

The status above is superseded. On this date the managed WireGuard generation was
opened and closed again, and the workspace toolchain was installed.

- Network: egress through the German VPS, `62.84.164.122`, IPv6 refused. The
  probe reported Frankfurt am Main, `DE`, on the same path used for the
  Anthropic endpoint.
- Resolver: `10.77.0.1` through the tunnel, `options timeout:2 attempts:1`.
- `systemd-resolved` is disabled and masked so it cannot replace the static
  `/etc/resolv.conf` that the manager owns.
- Guard: only `inet cor_egress_guard` in the ruleset. The
  `cor_egress_boot_emergency` table that a 26.04 sibling used to install on every
  boot no longer appears; the classification defect behind it is fixed in
  `f0e0cd9` and `434367d`.
- Installed: Chrome `156.0.8078.47`, Node `v22.23.3`, Claude Code CLI `2.1.302`,
  Codex CLI `0.163.0`, claude-desktop `3.1623.4`. WSL-internal sudo password was
  set for the `xuan` account as the user specified.
- The managed namespace launcher still has not been exercised for the strict
  visibility and interop checks; those remain `NOT_RUN`.

Evidence for the tunnel and the fail-closed state lives in
`TEST_STATUS.md` under "2026-10-22 shared-guard repair".
