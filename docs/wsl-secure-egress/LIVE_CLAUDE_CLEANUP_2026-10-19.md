# Live Claude/WSL cleanup — 2026-10-19

## Scope

The cleanup targeted only the Ubuntu-22.04 WSL instance. It did not touch `C:\Users\xuan\.cc-switch` or any Windows proxy database.

## Backup

Before changes, the following files were copied to a host-local directory
(now `docs/wsl-secure-egress/backups/live-20261019/`, ignored by Git):

- `/etc/resolv.conf`
- `/etc/systemd/system/xuan-claude-de*.service`
- `/etc/profile.d/xuan-claude-de.sh.disabled-by-clash-of-rust`

These copies were removed from version control on 2026-10-22. They are
host-system backups, not reviewed source, and one of them carried a legacy
proxy credential placeholder. Keep them outside Git; the paths above still
describe what was captured.

## Changes applied

- Disabled and removed the old `xuan-claude-de*` units.
- Removed the old disabled Claude proxy profile fragment.
- Replaced the stale resolver `10.77.0.1` with the NAT gateway `172.19.96.1`.

## Validation

- No old `xuan-claude-de` units remain in `systemctl list-unit-files`.
- The WSL route remains NAT (`172.19.96.0/20`, gateway `172.19.96.1`).
- Internet access is still blocked because the Windows Hyper-V WSL VM policy is currently `DefaultOutboundAction=Block`; DNS and egress will remain unavailable until the elevated deployment enables the approved endpoint/tunnel policy.
- This is intentionally recorded as a failed live-network check, not as a pass.