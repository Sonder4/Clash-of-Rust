# Windows Changes

The Windows side is the outer enforcement and orchestration boundary. The
desktop UI remains a controller; privileged mutations are performed by the
installed broker and guardian resources.

## WSL and Hyper-V

- `.wslconfig` is merged to `networkingMode=nat`, with `localhostForwarding`,
  `dnsTunneling` and `autoProxy` disabled and the supported WSL firewall path
  enabled. Existing unrelated keys are preserved. The current host readback is
  `nat`, `false`, `false`, `false`, `true`, respectively.
- Hyper-V Firewall records the immediate persistent settings, then applies
  default inbound/outbound block, disables host-policy merge and loopback, and
  creates only the exact fixed endpoint UDP exception.
- Endpoint enablement occurs only after Linux preparation and an effective
  Windows audit. Disconnect closes the exception before stopping Linux.
- The guardian service is a fixed SYSTEM audit boundary. It is adopted only
  from the two canonical Program Files package locations and never from a
  user-writable path.

## Docker containment

The WFP helper records Docker backend identities and applies executable-scoped
containment. Docker data and registrations are preserved. The project reports
Docker connectivity as unsupported until an independent host-backend path is
validated.

## Current host boundary

The current host is disconnected by policy. The Windows WireGuard profile is
absent from the protected target, the broker journal reports
`failed_closed_requested`, and the matching endpoint rule exists with
`Enabled=False`. Hyper-V WSL policy is default-deny on inbound and outbound.

The guardian service is `Running / Automatic`, and the executable used by the
service is present. This proves only that the resident monitor is running. It
does not prove that the current broker payload matches the newest code, that a
WireGuard handshake exists, or that WSL has Internet access.

## Elevation and fail-closed behavior

The normal UI is non-administrative. Explicit mutating actions use the fixed
installed broker and UAC. Preflight, Status and Test do not change the
protection state. Preflight and Status also do not elevate or start stopped
distributions.
The broker sends private profile data through stdin and never puts keys in
argv, logs or reports.

The journal writes markers before each host mutation:
`settings_write_started`, `docker_guard_write_started`,
`linux_manager_install_started`, and their completed counterparts. If a failure
occurs before Linux installation begins, `Rollback -RestoreOriginalNetwork`
restores recorded Hyper-V, Docker, guardian, `.wslconfig` and endpoint state
without calling an absent Linux helper. Once Linux installation may have begun,
Windows-only recovery is refused and the host stays closed.

After a verified restore, the journal and snapshots are archived before a new
generation is installed. This allows a later Install without discarding the
previous recovery evidence.

The archive journal is read back to verify its phase and generation; an
existing `.wslconfig` snapshot must match its recorded SHA256 before any live
recovery artifact is retired. Unrelated recovery data is retained. These
changes address PR review comments 2 and 3.

On 2026-10-22 the development tree passed the Windows unit suite with 166
assertions and the workflow suite with 244 assertions. The unit suite includes
real archive copies in a temporary directory, JSON readback, snapshot hashes,
retirement of live artifacts, and rejection of missing or tampered snapshots
while preserving the live journal. The elevation suite passed 21 assertions,
the administrator job construction suite passed 25, profile restore passed 18,
package staging passed 70 and package upgrade passed 53. The administrator job
suite executes the local elevation function with an isolated sudo capture hook,
so paths containing spaces remain one native argument without opening UAC.
These offline results also passed at `efa400d`, whose GitHub CI is green. The
current UI and dependency-snapshot verification development changes have not
yet been confirmed by a new hosted run. They do not modify production network
policy.

## Package lifecycle

The helper can be deployed independently of the desktop UI through
`clash-of-wsl/Install-ClashOfWsl.ps1`. Its privileged
scripts and guardian live in a protected Program Files package; the desktop
supplies explicit user requests and displays structured results. A code-only
package upgrade stages and verifies the replacement before modifying installed
files, preserves the active network generation and recovery artifacts, and
does not uninstall an active guard.

The fork also disables the upstream automatic update channel so an official
package cannot silently replace the custom helper resources. This is a change
to update behavior beyond the WSL page; it is documented explicitly in
[the upstream comparison](UPSTREAM_COMPARISON.md).

## Scope

The WSL broker does not modify Windows-wide VPN state, unrelated adapters,
`C:\Users\xuan\.cc-switch`, existing Clash/Mihomo services, or VPS state. Live
network changes require the mandatory Windows connectivity baseline and an
immediate targeted recovery path.

The installed Clash of Rust 0.6.0 desktop remains in
`%ProgramFiles%\Clash of Rust`; the source tree has incorporated upstream 0.6.1
but has not replaced that installed desktop. Earlier 2026-10-18 UAC-authorized
payload synchronization and a controlled Linux Stop→Start tunnel restoration
are historical evidence only. The current profile, endpoint and broker state
override that history. Archive and workflow tests establish local implementation
behavior; they do not replace cold-boot, physical network-switch or
sleep/resume tests.
