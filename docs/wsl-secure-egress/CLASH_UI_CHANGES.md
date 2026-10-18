# Clash of Rust UI and Controller Changes

Clash of Rust supplies the user-facing control surface and request broker for
the separate WSL Secure Egress backend.

## UI

The WSL page exposes Doctor, Status, installation preflight, Install, Connect,
Disconnect while retaining protection, Test, Rollback and Restore Original
Network. It displays operation identity, generation, backend, endpoint state,
per-distro coverage, bounded logs and explicit `PASS`, `FAIL`, `BLOCKED` and
`NOT_RUN` results.

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

The last upstream revision included in HEAD is `a27d154`, merged by `1eed8b3`.
The refreshed upstream main is `37683750b37be9d2bbcfb22804bec96174e14af5`;
its contributor-documentation commit has not yet been merged at this writing.
No upstream PR is requested.

## Validation

Executed release Rust checks passed 27 WSL core tests and 27 desktop WSL tests.
PowerShell fixtures passed 125 Windows unit, 96 workflow, 21 elevation and 38
package-upgrade assertions. UI and controller tests do not claim that a live
WSL tunnel, VPS geography or cold boot has been executed.

The actual installed app remains 0.6.0 under `%ProgramFiles%\Clash of Rust`
and is running. A successful source build is not an installed application
upgrade or a fresh GUI acceptance test; the repaired source has not replaced
the installed binary.
