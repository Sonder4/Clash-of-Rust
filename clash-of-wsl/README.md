# Clash of WSL

The WSL half of Clash of Rust. It is a standalone system component: it installs
itself, configures the managed WSL network, keeps the tunnel fail-closed, and can
be removed again. The Clash of Rust desktop client drives it, but nothing in the
desktop client is required for it to run.

    Clash of Rust (Windows UI)
              |  Invoke-WslEgressOperation  (JSON in, JSON out)
              v
    Clash of WSL  ---->  WSL2 NAT + Hyper-V Firewall default deny
       (Program Files)           |
                                 v
                  Linux network namespace + nftables guard
                                 |
                                 v
                     Fixed WireGuard endpoint
                                 |
                                 v
                            Germany VPS

## What it guarantees

Every WSL workload leaves through the Germany VPS. DNS and IPv6 are handled
inside the tunnel, so neither can bypass it. If the tunnel drops, the host policy
and the Linux guard both default to drop, and there is no fallback to the Windows
uplink.

| Escape route | Blocked by |
| --- | --- |
| A direct WSL packet to a LAN or internet host | Hyper-V default deny on the WSL creator, plus the Linux `cor_egress_guard` default-drop chains |
| DNS to the Windows resolver | Namespace-local resolver, and `dnsTunneling=false` in `.wslconfig` |
| IPv6 | The Linux guard drops all IPv6 output; the VPS profile is IPv4-only |
| `ipconfig.exe` and other Windows interop | `interop.enabled=false` and `appendWindowsPath=false` in the managed distro |
| A second unmanaged distro reusing the WSL VM | The shared guard table, installed by the boot guard in every managed distro |
| Reading the real network interfaces | The workload runs in a private namespace that only contains the virtual links |

## Layout

| Path | Purpose |
| --- | --- |
| `ClashOfWsl.ps1` | The elevated entry point: Install, Configure, Start, Stop, Status, Test, Uninstall, Rollback |
| `Install-ClashOfWsl.ps1` | Installs or removes the component in Program Files; requests one UAC consent |
| `ClashOfWsl-Daemon.ps1` | Resident SYSTEM service; verifies the payload against its receipt and keeps the directory protected. Never opens the tunnel |
| `Test-ClashOfWsl.ps1` | Offline self-test: structure and syntax only, live checks reported as `NOT_RUN` |
| `linux/clash-of-wsl-daemon.py` | Resident in-distro guard that records guard health |
| `linux/clash-of-wsl-guard.service` | systemd unit for that guard |
| `linux/install-guard.sh` | Installs the guard inside the managed distribution |

The reviewed egress logic lives in `scripts/wsl-secure-egress/WslSecureEgress.psm1`
and `scripts/wsl-secure-egress/linux/manager.py`. This component is the packaging
and lifecycle shell around them.

## Install

Run these from the repository root in an ordinary terminal. The install and the
tunnel actions each need one UAC consent.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File clash-of-wsl/Install-ClashOfWsl.ps1 -Execute
```

Then open the tunnel:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File clash-of-wsl/ClashOfWsl.ps1 -Action Start -Execute `
  -ProfilePath "$env:LOCALAPPDATA\ClashOfRust\WslEgress\profile.json"
```

Read state, and run the acceptance checks:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File clash-of-wsl/ClashOfWsl.ps1 -Action Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File clash-of-wsl/ClashOfWsl.ps1 -Action Test
```

Install the resident guard inside the managed distribution:

```
wsl.exe -d Ubuntu-22.04 -u root --exec clash-of-wsl/linux/install-guard.sh
```

Remove everything and restore the prior network configuration:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File clash-of-wsl/Install-ClashOfWsl.ps1 -Uninstall -Execute `
  -RestoreOriginalNetwork
```

## Result contract

Every action prints one JSON object. `outcome` is `succeeded`, `blocked`,
`failed` or `not_run`. A preview that was never executed reports `not_run`, so a
result can never be mistaken for a change that happened.

```json
{"schema_version":1,"component":"clash-of-wsl","action":"Status",
 "outcome":"succeeded","executed":false,"backend":"WireGuard",
 "phase":"failed_closed_requested"}
```

## Self-test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File clash-of-wsl/Test-ClashOfWsl.ps1
```

18 assertions cover file presence, PowerShell parsing, the action set, the
fail-closed guards and the UAC path. Live tunnel, VPS egress and uninstall are
reported as `NOT_RUN`, because they need an elevated host.

## What this component does not do

It does not touch the CC Switch data directory, it does not handle Windows system
proxy or TUN for Windows applications, and it does not start a second desktop
client. Those remain Clash of Rust core.