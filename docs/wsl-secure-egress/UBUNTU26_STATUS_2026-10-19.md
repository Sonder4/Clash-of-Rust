# Ubuntu 26.04 live status — 2026-10-19

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
