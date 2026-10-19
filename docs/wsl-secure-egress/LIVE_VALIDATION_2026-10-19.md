# Live validation — 2026-10-19

## Authoritative host state

- `.wslconfig` is explicitly `networkingMode=nat`, `localhostForwarding=false`, `dnsTunneling=false`, `autoProxy=false`, and `firewall=true`.
- `Ubuntu-26.04` is WSL2 with registry `BasePath=F:\WSL`.
- The SYSTEM guardian service `ClashOfRust.WslEgress` is running.
- Hyper-V WSL VM policy remains `DefaultOutboundAction=Block` and the managed WireGuard endpoint rule remains disabled.

## Live WSL results

- Ubuntu-22.04 and Ubuntu-26.04 both use the NAT route `172.19.96.1`.
- Old Claude proxy units and stale `10.77.0.1` resolver files were backed up and removed/reset.
- Direct DNS and TCP egress fail while the host Hyper-V policy is default-deny. This is recorded as a failed live-network check.
- No live WireGuard interface or Linux egress namespace is present yet.

## UAC attempt

The Windows `sudo.exe --new-window` path was used because `Start-Process -Verb RunAs` launched medium-integrity children in this session. The UAC request was cancelled before the administrator job ran. No Windows firewall, endpoint, route, or VPS changes were made by that cancelled attempt.

## Tests executed

- Clash of WSL self-test: 18/18 assertions passed; live tunnel checks remain not run.
- PowerShell parser checks for the admin job and WSL installers: passed.
- Main Rust library: 41 tests passed; one GUI isolation test failed because the desktop application was already running.

No provider egress IP, Claude Code, OpenAI, Anthropic, IPv6, or DNS-through-tunnel result is claimed until the administrator deployment completes.
## Hot restart after cleanup

- `wsl.exe --shutdown` returned exit code `0`.
- Ubuntu-26.04 restarted with the same NAT address `172.19.104.128/20` and gateway `172.19.96.1`.
- The cleaned resolver persisted as `172.19.96.1`.
- DNS lookup still failed because Hyper-V outbound default-deny remains active.

## Egress-gated workspace installer

The new Ubuntu 26.04 workspace installer was syntax-checked with `bash -n` and executed once while the tunnel was absent. It correctly refused with exit code `20` after `ifconfig.co` DNS failed; it did not install packages. This proves the installer cannot accidentally install or launch Claude/Codex outside the approved VPS egress.
