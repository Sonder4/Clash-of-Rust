# Clash of Rust UI and Controller Changes

Clash of Rust supplies the user-facing control surface and request broker for
the separate WSL Secure Egress backend.

## UI

The condensed WSL page exposes:

- **安装** when the component is not installed;
- **连接**, **断开**, **状态**, **测试**, **预检** and **日志**;
- **断开并保留保护** for a non-destructive transport stop;
- **恢复原网络** as a danger-styled action that requires separate confirmation.

The install form appears only while the component is not installed, and the
page displays endpoint, phase, protection, acceptance and bounded logs using
the shared page components. Test and status results continue to distinguish
`PASS`, `FAIL`, `BLOCKED` and `NOT_RUN`.

The page is intentionally compact. Its first card shows transport, exit and
protection status; the second keeps the primary connect/install action plus
read-only Status, Test and preflight; endpoint/profile fields, logs and the two
recovery actions are disclosed through **高级**. This follows the existing
network and diagnostic pages while preserving an explicit danger-styled
**恢复原网络** confirmation action.

Endpoint IPv4 and port are visible configuration fields, but they do not replace
the private WireGuard profile. Executed Install and Start requests require a
profile path; endpoint-only input is rejected before a privileged command is
shown as runnable.

## Broker contract

The Rust request types validate distro names, profile paths, IPv4 literals,
ports, action/elevation combinations and backend restrictions. Private profile
contents are not serialized into durable settings and request Debug output is
redacted. The Windows broker invokes fixed scripts with an argument allowlist;
secrets are supplied over stdin. This addresses PR review comment 1: endpoint
fields alone cannot satisfy the install/start profile requirement, and explicit
endpoint, port, distro or backend overrides must agree with the protected
configuration.

The `prepared_for_reinstall` phase is retained as a known protected
non-functional state. It keeps the deployment and recovery controls visible so
the component is not mistaken for a fully installed manager or allowed to enter
the adoption path.

The controller owns no Linux routes, nftables tables, WireGuard keys or
Hyper-V objects. It consumes structured reports from the broker and ignores
stale operation results after reconnect, reconfiguration or rollback.

## Scope and compatibility

The implementation is isolated to WSL modules, the WSL page, resource
packaging, tests and the dedicated scripts. Existing proxy, subscription,
Android, macOS and Linux client components remain outside the WSL feature path.
Shared UI/configuration registration and package/update hooks are enumerated
in [UPSTREAM_COMPARISON.md](UPSTREAM_COMPARISON.md); the fork's official update
channel is deliberately disabled, so it would be inaccurate to call all
non-WSL application behavior unchanged.

The current fetched upstream main is
`2615ebc96f9f510802194727a6108bde73f4c8ed` (0.6.1). The last CI-verified fork
head is `87ef6b2`, which contains upstream and is 73 commits ahead with zero
commits behind. Later changes in the current worktree are not represented by
that CI result. These changes retain the separate WSL backend and extend the
UI/controller, packaging, recovery tests and documentation. Delivery remains
the user's fork PR; no upstream PR is requested.

## Validation

The latest recorded development-tree checks passed 166 Windows unit, 244
workflow, 21 elevation, 25 admin-job construction, 18 profile-restore, 70
package-staging and 53 package-upgrade assertions. The Clash of WSL component
passed 34 assertions and the tool-installer static regression passed 8 tests.
The serial desktop binary suite passed 106 tests. `87ef6b2` also has a fully
green GitHub CI run, but that run does not include the current uncommitted
fixes. A parallel desktop run previously produced a 105/106 renderer race in
one motion test; the failing test and a serial full run passed. UI and
controller tests do not claim that a live WSL tunnel, VPS geography or cold
boot has been executed.

The installed app remains 0.6.0 under `%ProgramFiles%\Clash of Rust` and is
running. The source has incorporated upstream 0.6.1 but has not replaced this
installed application. Historical 2026-10-18 UAC-controlled payload tests are not
current online evidence. A successful source build is not a fresh GUI
acceptance test, and the current profile is absent.
