# Windows Changes

The Windows side is the outer enforcement and orchestration boundary. The
desktop UI remains a controller; privileged mutations are performed by the
installed broker and guardian resources.

## WSL and Hyper-V

- `.wslconfig` is merged to `networkingMode=nat`, with `localhostForwarding`,
  `dnsTunneling` and `autoProxy` disabled and the supported WSL firewall path
  enabled. Existing unrelated keys are preserved.
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

## Elevation and fail-closed behavior

The normal UI is non-administrative. Explicit mutating actions use the fixed
installed broker and UAC. Preview, Doctor and Status do not change host state.
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

The Windows unit suite passed 125 assertions, including real archive copies in
a temporary directory, JSON readback, snapshot hashes, retirement of live
artifacts, and rejection of missing or tampered snapshots while preserving the
live journal. The 96-assertion workflow suite passed with mocked policy, WSL
and service boundaries. Neither suite modifies production network policy.

## Package lifecycle

The helper can be deployed independently of the desktop UI. Its privileged
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

During this PR repair the installed Clash of Rust 0.6.0 remains running; the
newly compiled source has not replaced that installation. Production WSL is
`installed_closed`. Archive and workflow tests establish local implementation
behavior, not production restart, external exit or model-client acceptance.
