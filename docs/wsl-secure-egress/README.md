# WSL Secure Egress

WSL Secure Egress is a Windows-only, opt-in management surface in this fork of
Clash of Rust. It keeps the Windows host on its existing IPv4 and IPv6 network
while placing protected WSL2 traffic on a fixed-endpoint IPv4 WireGuard path to
a dedicated German VPS workload. IPv6 egress from protected WSL traffic is
denied. A missing or unhealthy tunnel remains closed; it does not restore a
Windows or WSL direct route.

The page is available as the eleventh sidebar item. The command-line broker and
Linux helper expose the same lifecycle. All mutation commands are previews
unless `-Execute` or `--execute` is explicitly supplied, except fixed
root-owned service entry points documented in the Linux contract.

## Current status

The current host is installed but deliberately disconnected:

| Item | Current readback |
| --- | --- |
| Upstream baseline | `2615ebc` |
| Last CI-verified branch head | `efa400d` (`0` behind and `79` ahead of upstream) |
| Current worktree | UI and dependency-snapshot verification changes awaiting final commit and CI |
| Windows WireGuard profile | `MISSING` at the protected Windows target; root-only Linux copy exists |
| Windows broker | `failed_closed_requested` |
| Hyper-V endpoint exception | Present, `Enabled=False` |
| Guardian service | `Running / Automatic`; this alone does not prove a tunnel |
| Ubuntu 22.04 | Running, NAT `eth0` only; DNS and `curl` are blocked |
| Ubuntu 26.04 | Installed under `F:\WSL`; currently stopped |
| Chrome, Codex CLI, Claude Code CLI, Claude Desktop | `NOT_RUN`; not installed or not verified on this host |

The `efa400d` CI and downloaded Windows x64 artifact are verified. That artifact
cannot be deployed as a substitute for the final commit: the current UI and
dependency-snapshot verification changes have not yet passed hosted CI.

The 2026-10-18 live results are historical evidence for the exact revisions and
payloads used then. They are not evidence that the tunnel is online now.

The repository implementation and offline tests can be reviewed without
changing the local network. This is not a deployment or production acceptance
record.

The current user request is captured in three change records:

- [WSL changes](WSL_CHANGES.md): Linux data plane, boot guard and lifecycle.
- [Windows changes](WINDOWS_CHANGES.md): Hyper-V firewall, profile, guardian and
  recovery boundary.
- [Clash of Rust changes](CLASH_UI_CHANGES.md): minimal UI/controller surface and
  upstream comparison.

- Fixed-endpoint WireGuard is the only installable backend.
- The manager distribution comes from the private profile. It may be an
  existing ordinary distribution such as `Ubuntu-22.04` or `Ubuntu-26.04`.
  A specially named distribution and a downloaded rootfs are not required.
- Tailscale remains `BLOCKED` until a supported Windows-side cold-start
  boundary has been implemented and verified with real WSL/Hyper-V restart and
  fault tests.
- Docker Desktop is preserved. Its external networking is not claimed as
  functional until an independently verified adapter exists.
- Windows-wide VPN, global DNS takeover, WSL distribution deletion and CC
  Switch data changes are outside this feature.
- Actual results for CI and local checks are recorded separately in
  [TEST_STATUS.md](TEST_STATUS.md). A test that has not executed is `NOT_RUN`.
- The [2026-10-18 local usability report](LOCAL_TEST_2026-10-18.md) records
  vendor-facing VPS source verification, DNS packet sampling, and the remaining
  Desktop and launcher blockers. It does not claim complete acceptance.

## Documentation

- [Security model](SECURITY_MODEL.md) describes trust boundaries, enforcement
  layers and explicit non-goals.
- [Operating guide](OPERATIONS.md) covers prerequisites, install, connect,
  status, tests, recovery and uninstall.
- [Clash of WSL component](../../clash-of-wsl/README.md) documents the
  standalone installation and resident service.
- [Workspace tools](WORKSPACE_TOOLS.md) defines the VPS-gated Chrome, Codex CLI,
  Claude Code CLI and Claude Desktop installation. The authoritative installer
  is `scripts/wsl-secure-egress/tools/install-wsl-tools.sh`; the older
  `install-workspace-tools.sh` path is an absolute-path compatibility wrapper.
- [Deployment runbook](DEPLOY_RUNBOOK.md) records the administrator transaction
  and its evidence requirements.
- [Ubuntu 26.04 status](UBUNTU26_STATUS_2026-10-19.md) records the installed
  distribution baseline.
- [Compatibility](COMPATIBILITY.md) records supported Windows/WSL versions,
  network modes and unsupported workloads.
- [Linux helper contract](../../scripts/wsl-secure-egress/linux/CONTRACT.md)
  defines the fixed Windows-to-Linux API.
- [Implementation plan](../wsl-secure-egress-plan.md) preserves the accepted
  design and acceptance gates.
- [Local operations](../../scripts/wsl-secure-egress/local-ops/README.md) indexes
  this machine's migration, autostart and diagnostic scripts. They are local
  tools, not part of the installed product, and every network-mutating one
  requires the mandatory connectivity baseline first.

### Local run records

These files record actual runs on this machine. They are not product
acceptance evidence and do not replace [TEST_STATUS.md](TEST_STATUS.md).

- [2026-10-22 code review](CODE_REVIEW_2026-10-22.md)
- [2026-10-23 runtime diagnosis](DIAGNOSIS_2026-10-23.md)
- [2026-10-23 Ubuntu-26.04 migration](UBUNTU26-MIGRATION-2026-10-23.md)
- [2026-10-23 Ubuntu-22.04 cleanup plan](ubuntu22-cleanup-plan-2026-10-23.md)

## Trusted resources

The Windows package includes the broker, SYSTEM audit entry point, WFP helper
source, Linux runtime payload and VPS service under
`resources/wsl-secure-egress`. The desktop verifies this complete resource set
against bytes compiled into the client before invoking it. The Windows broker
stages only the five reviewed Linux runtime files into a new root-private WSL
directory, checks their SHA256 values and invokes the separate hash-pinned
payload installer.

Private WireGuard keys and endpoint profiles are supplied through stdin and
stored in root-private files. They must never be committed, pasted into logs or
included in support reports.

## Quick start

Install a reviewed Windows package from this fork, open **WSL Secure Egress**,
and run **预检** and **状态** first. The full sequence requires the ordinary WSL
distribution selected in the private profile, the dependencies listed in the
compatibility guide, a private profile and a dedicated VPS WireGuard service.
See the [operating guide](OPERATIONS.md) before any host mutation.

The mandatory Windows connectivity baseline is deliberately private and is not
part of the upstream repository. Configure it at:

```text
%LOCALAPPDATA%\ClashOfRust\WslEgress\protected-connections.json
```

It must contain a JSON array of credential-free HTTPS URLs and accepted status
codes. No network mutation starts when that baseline is absent or unhealthy.
