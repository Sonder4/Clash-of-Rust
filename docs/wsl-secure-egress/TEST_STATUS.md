# Test status

This file records executed results and their limits. Update it only from an
actual run; never convert an unavailable or timed-out check into PASS.

Earlier dated runs are historical evidence for their own revision and payload.
They do not describe the current host state.

## Current snapshot, 2026-10-22

| Item | Current read-only evidence |
| --- | --- |
| Upstream | `2615ebc96f9f510802194727a6108bde73f4c8ed` |
| Last CI-verified head | `87ef6b206c49446bd9ed614923a6381a346d16a8` |
| Branch relation | `0` behind, `73` ahead at the verified head |
| Current worktree | Contains later uncommitted review, recovery, installer and documentation work |
| Installed desktop | Clash of Rust 0.6.0 under `C:\Program Files\Clash of Rust` |
| Source version | Upstream 0.6.1 synchronized; not installed over the 0.6.0 desktop |
| `.wslconfig` | NAT, `localhostForwarding=false`, `dnsTunneling=false`, `autoProxy=false`, `firewall=true` |
| Hyper-V WSL policy | Default inbound and outbound Block |
| Endpoint exception | `ClashOfRust-WslEgress-Endpoint`, `Enabled=False` |
| Windows profile | **MISSING** |
| Broker state | `failed_closed_requested` |
| Guardian service | Running / Automatic; this is not tunnel evidence |
| Ubuntu 26.04 | Installed under `F:\WSL`, WSL2, currently stopped |
| Ubuntu current network | Plain NAT `eth0`; DNS and `curl` fail |
| Chrome / Codex CLI / Claude Code CLI / Claude Desktop | `NOT_RUN` on the current host |
| Current VPS source and provider connections | `NOT_RUN` |
| Strict-launcher visibility and interop checks | Plain-shell evidence only; strict live check `NOT_RUN` |
| UAC transaction | `NOT_RUN` for the current repair |
| Stop/Start, cold boot, reboot, network switch | `NOT_RUN` |

The current fail-closed state takes precedence over the historical
2026-10-18 tunnel results below.

## Local offline checks

Run on 2026-10-17 in the `Clash-of-Rust` worktree:

| Check | Result | Scope |
| --- | --- | --- |
| PowerShell module parser | PASS | Syntax only |
| `tests/windows-unit.ps1` | PASS, 56 assertions | Mocked host boundaries; no WSL, firewall, DNS or route mutation |
| `tests/linux_static_test.py` | PASS, 17 tests | Portable evidence/gate logic; no kernel operations |
| `tests/server_unit.py` | PASS, 4 tests | Offline VPS profile validation |
| `scripts/test-build-tools.py` | PASS, 36 tests, 1 skipped | Build/resource validation; Windows PE version read skipped locally |
| `scripts/test-workflow-artifacts.py` | PASS, 6 tests | Immutable artifact logic |
| Docker WFP ABI layout | PASS | Structure layout only; no WFP engine opened |
| Git whitespace check | PASS | `git diff --check` |
| `cargo fmt --all -- --check` | PASS | Local Rust workspace |
| `cargo build --workspace --locked --offline` | PASS | Local Windows workspace build |
| `cargo clippy --workspace --all-targets --locked --offline -- -D warnings` | PASS | Local Windows workspace |
| Rust tests excluding two environment-dependent Windows checks | PASS, 301; 2 skipped by name; 1 ignored by test annotation | Active GUI singleton and Task Scheduler access-denied checks cannot pass in this session |

## Not executed locally

| Check | Status | Required environment |
| --- | --- | --- |
| Full Rust test command including GUI singleton test | FAIL (environment) | Existing `clash-of-rust` process holds the expected single-instance mutex |
| Real WSL2/Hyper-V firewall and Windows-to-Linux calls | NOT_RUN | Disposable Windows runner and WSL environment |
| Linux namespace/nftables/WireGuard integration | PASS, 86 cases | Real Ubuntu-22.04 WSL2 root; see the 2026-10-18 local WSL section below |
| Real Docker WFP TCP/UDP loopback probe | NOT_RUN | Disposable administrator Windows runner |
| Cold boot, reboot, sleep/resume and network switch | NOT_RUN | Disposable WSL/Hyper-V environment |
| Actual German IPv4 exit and receiver-source evidence | NOT_RUN | Authorized VPS and controlled receiver |
| Docker functional protected egress | NOT_SUPPORTED | Independent adapter not implemented |
| Tailscale strict cold-start protection | BLOCKED | Supported cold-start boundary not established |

## 2026-10-17 local verification

- Windows baseline was checked before WSL-related work: `ipgw.neu.edu.cn` returned
  HTTP 200 and `api.okinto.com` returned HTTP 200 with certificate validation
  enabled at 2026-10-17 23:13 Asia/Taipei.
- The active distribution is Ubuntu-22.04. Read-only inspection confirmed NAT
  mode, `eth0` on the private WSL subnet, and no IPv6 default route. The distro
  was not stopped or restarted during this test run.
- `tests/windows-unit.ps1`: PASS, 56 assertions. No WSL start, firewall
  modification, route change or DNS change.
- `tests/linux_static_test.py`: PASS, 17 tests, executed inside Ubuntu-22.04.
  The tests mock operating-system calls and perform no kernel mutation.
- A subsequent rerun after the upstream merge was refused by the WSL service
  with `E_ACCESSDENIED`; that invocation is recorded as unavailable and does
  not replace the earlier executed PASS.
- `tests/server_unit.py`: PASS, 4 tests. Offline VPS profile validation only.
- `python3 -m compileall -q scripts/wsl-secure-egress`: NOT_RUN; the WSL
  command was denied by the WSL service with `E_ACCESSDENIED`.
- `cargo fmt --all -- --check`: PASS.
- `cargo build --workspace --locked`: PASS, Windows workspace.
- `cargo clippy --workspace --all-targets --locked --offline -- -D warnings`:
  PASS.
- `cargo test --workspace --locked --offline`: the full run failed in two
  environment-dependent desktop tests: the existing Clash of Rust GUI owns the
  singleton mutex, and Windows denied Task Scheduler access.
- After fixing the WSL projection test fixture to request the same Tailscale
  backend as its report, its targeted rerun passed. The full workspace rerun
  excluding only those two environment-dependent tests passed 301 tests; 2 were
  skipped by name and 1 CI-only integration test remained ignored. The exact
  command was `cargo test --workspace --locked --offline -- --skip
  ordinary_user_can_initialize_desktop_control --skip
  scheduler_access_denied_falls_back_to_working_user_startup`.
- `git diff --check`: PASS.
- The disposable Linux namespace integration and Windows WFP integration were
  not run locally. Their explicit isolated-runner gates remain required; real
  WSL/Hyper-V and German VPS acceptance remain `NOT_RUN`.
- Bubblewrap 0.6.1 is present in Ubuntu-22.04 and does not support
  `--disable-userns`. A disposable probe confirmed that nested user namespace
  creation succeeds without an additional restriction. The workload sandbox
  now installs a seccomp filter that denies `unshare`, `setns`, `clone3`, and
  namespace-flagged `clone`, while retaining normal process creation. The
  isolated integration suite has not yet been rerun in GitHub Actions.
- The two GitHub runs for commit `5865aaf` were inspected. The Linux disposable
  integration reached and passed its direct-egress, DNS, IPv6, and attestation
  cases, then failed when starting the inspection workload. Rust CI exposed an
  overly permissive recovery-phase check; it now accepts only explicit terminal
  status phases. These CI fixes are pending a new hosted run.
- Upstream `upstream/main` was refreshed to commit `e2fb6f1` on 2026-10-17 and
  merged into this branch as commit `4f9b7d7`. The upstream change consolidated
  Windows CI checks and removed obsolete maintenance files; the WSL feature
  files were retained by the merge.
- Current host configuration was inspected read-only: `.wslconfig` uses
  `networkingMode=nat`. Hyper-V WSL firewall policy has not been verified as
  configured by this project on this machine. Repository support for NAT and
  Hyper-V default-deny exists, but the effective production guard has not been
  installed or accepted here.

## 2026-10-18 live WSL acceptance (Windows host, Ubuntu-22.04)

Admin-level Start and Stop transactions were executed through the reviewed
PowerShell UAC path. Addresses and packet payloads are omitted; raw reports stay
in the ignored local backup directory.

| Check | Result | Evidence and limits |
| --- | --- | --- |
| Windows baseline before start | PASS | `ipgw.neu.edu.cn` HTTP 200 and `api.okinto.com` HTTP 200, TLS validated, 02:05:25 Asia/Taipei |
| WSL host NAT readback | PASS | `eth0` on the WSL private `/20`, default route to the WSL gateway only, no global IPv6, `/etc/resolv.conf` nameserver is the tunnel resolver |
| `.wslconfig` readback | PASS | `networkingMode=nat`, `dnsTunneling=false`, `autoProxy=false`, `firewall=true`, `localhostForwarding=false` |
| Admin `Start -Execute` | PASS | 02:15:24; generation `1792256171034`; endpoint enabled with host policy audit PASS |
| Controlled live acceptance, ordinary WSL | PASS | DNS nonce observed on the tunnel and upstream, HTTPS 200 via IPv4, VPS-observed source match, IPv6 connect failed, no clear uplink nonce |
| Controlled live acceptance, isolated launcher | PASS | Interfaces exactly `lo`, `cor-bg0`, `wg0`; UID 1000; all capability sets zero; `NoNewPrivs=1`; `/mnt/c` and `ipconfig.exe` hidden; same DNS/HTTPS/IPv6/VPS evidence |
| Windows baseline after stop and restart | PASS | both mandatory Windows URLs HTTP 200 with TLS validation at 02:14:02 |
| Isolated CI data-plane and Windows WFP fixture runs | NOT_RUN locally | Tracked separately in GitHub Actions after the branch is pushed |

The live acceptance report is
`ClashOfRust-network-backups/wsl-host-20261018/live-acceptance-20261018-021627.json`.
An earlier run at 02:13:02 is retained as FAIL: the ordinary path passed, but
the isolated launcher correctly refused a stale Windows attestation and the
aggregate result was failed. It was not silently replaced.

## 2026-10-18 PR repair and current host retest (18:30 Asia/Taipei)

This section supersedes the older connected-state description above for the
current host state. The historical 02:15 live acceptance remains evidence only
for that earlier transaction and is not evidence that the tunnel is currently
connected.

- Windows `.wslconfig` was read as `networkingMode=nat`,
  `dnsTunneling=false`, `autoProxy=false`, `firewall=true`, and
  `localhostForwarding=false`.
- The current protected Windows journal was read through the administrator
  broker with secrets omitted. It began this retest at `installed_closed`, with
  endpoint disabled. The read-only Status action reported host policy PASS and
  WSL runtime FAIL.
- Initial WSL readback found ordinary NAT `eth0`, no `cor-eb0`, no named
  network namespaces and no WireGuard handshake. Manager Status first rejected
  a missing generation argument; with the journaled generation it reported
  `Guarded`. Claude's retry service was stopped after a root-only backup of its
  unit to `/var/backups/clash-wsl-repair-20261018/`.
- A Windows administrator hot update installed the reviewed helper and Linux
  payload after backing up the previous helper under
  `ClashOfRust-network-backups/review-repair-20261018/`. The live payload update
  returned `succeeded`, `phase=installed_closed`,
  `owned_config_matches=true`, `interop_runtime_disabled=true`, and
  `endpoint_enabled=false`. The WSL NAT network mode was not changed.
- A subsequent real `Start -Execute` passed the all-distro, Hyper-V, DNS,
  interop and Docker coverage scope audits. Linux start and endpoint enable
  proceeded, but registering the required fixed interactive scope-renewal task
  failed with a Windows `CimException`. The transaction's compensation closed
  the endpoint and returned `failed_closed_requested`; the operation is a
  **FAIL**, not a connected acceptance. No Claude or model-vendor request was
  made. Task Scheduler failure diagnosis remains unresolved.
- Windows baseline checks to `ipgw.neu.edu.cn` and `api.okinto.com` returned
  HTTP 200 with certificate validation at 18:18:24 and 18:18:25 +08:00.
  These are Windows-only checks; WSL has no NEU/domestic routing exception.
- Windows offline suites passed: `windows-unit` 149 assertions,
  `windows-workflow` 161, `elevation-unit` 21, and `package-upgrade-unit` 53.
  Their raw output is in the ignored repair backup directory.
- Real WSL offline suites passed: Linux static 66 (64 pass, two platform
  skips), payload 32, server 24, provision 26, and acceptance harness 3; total
  151 passed, no failures. A disposable in-kernel namespace test passed all
  89 cases with no skips. These fixtures do not prove production Hyper-V,
  actual VPS egress, or vendor reachability.
- Claude Desktop remains blocked from testing. Its saved user unit and launched
  process had a dead `127.0.0.1:12345` proxy, explaining the screenshot's
  `ERR_PROXY_CONNECTION_FAILED`. A root-only backup exists and its service is
  stopped. Separately, the installed native binding requests GLIBC 2.39
  symbols `pidfd_spawnp` and `pidfd_getpid`, while Ubuntu 22.04 provides glibc
  2.35. Do not replace system glibc. The package/runtime compatibility issue
  is independent of the proxy outage.
- No WSL public IP, private endpoint, SSH key, WireGuard key, or model-vendor
  connection was placed in the repository. The detailed local audit and raw
  machine reports are under the ignored
  `ClashOfRust-network-backups/review-repair-20261018/` directory.

### Hosts isolation upgrade, fail-closed and recovery

The user explicitly authorized administrator elevation. The upgrade was then
executed end to end:

- `Stop -Execute` closed the endpoint and removed the owned namespaces; the
  mandatory Windows URL baseline returned HTTP 200 with TLS validation at
  02:34:27 Asia/Taipei.
- `Update-LiveWslPayload.ps1 -Execute` completed with the atomic reviewed
  upgrade and wrote a protected receipt. `owned_config_matches=true`,
  `interop_runtime_disabled=true`, `endpoint_enabled=false`.
- Readback inside Ubuntu-22.04: `generateResolvConf=false`,
  `generateHosts=false`, interop `enabled=false`,
  `appendWindowsPath=false`, `/etc/resolv.conf` nameserver is the fixed tunnel
  resolver, and `/etc/hosts` contains only `127.0.0.1 localhost`,
  `127.0.1.1 Xuan` and `::1 localhost ip6-localhost ip6-loopback`. The
  installed `manager.py` SHA256 matched the repository file.
- `Start -Execute` recreated the namespaces and enabled the fixed endpoint.
  The post-upgrade acceptance at 02:36:27 returned PASS for both
  `ordinary-wsl` and `isolated-launcher`, including `hosts_leak_free=true`,
  `interop_disabled=true`, IPv6 denial and VPS receiver evidence.
- Controlled fail-closed test: the owned VPS receiver reported `READY`, the
  administrator `Stop -Execute` closed the endpoint, the ordinary WSL client
  failed with `TimeoutError` and `connected=false`, and the receiver reported
  `received=false` with `NO_RECEIPT`. Suite outcome: passed.
- Recovery: `Start -Execute` succeeded, both mandatory Windows URLs returned
  HTTP 200 with TLS validation at 02:38:47, host policy audit was PASS, and a
  final acceptance at 02:39:00 returned PASS for both scopes again.
- Offline suites after the change: `windows-unit.ps1` PASS, 79 assertions;
  `linux_static_test.py` PASS, 21 tests; payload unit PASS, 32 tests;
  provision unit PASS, 18 tests; server unit PASS, 24 tests; Python
  compilation PASS; acceptance-harness endpoint validation PASS, 3 tests.
- The acceptance scripts previously contained a hard-coded probe address that
  could make a fail-closed result meaningless. They now require the fixed
  public IPv4 endpoint to be supplied from the private profile and reject
  missing, non-numeric or private values. Real endpoint values are not written
  to reports or Git.

Still `NOT_RUN` on this host: Windows cold boot, sleep/resume, physical network
switch and independent geolocation corroboration.

## 2026-10-18 local WSL isolated integration run

Executed inside the real distribution, not a container: Ubuntu-22.04, kernel
`6.18.54.1-microsoft-standard-WSL2`, root, repository copied to a Linux-native
temporary directory first (the suite mounts tmpfs over `/mnt`, so a copy under
`/mnt/e` cannot be the run directory).

| Check | Result | Scope |
| --- | --- | --- |
| `tests/linux_integration.py --execute-isolated` | PASS, 86 cases | Disposable net/mount/PID namespaces with the fixture VPS, WireGuard transport and nftables guard; no Windows, WSL host or real VPS configuration participated |
| `python3 -m compileall -q scripts/wsl-secure-egress` | PASS | Syntax only |
| `tests/linux_static_test.py` | PASS, 21 tests | Portable evidence/gate logic |
| `tests/acceptance_harness_unit.py` | PASS, 3 tests | Endpoint validation |
| `tests/server_unit.py` | PASS, 24 tests | Offline VPS profile validation |
| `tests/payload_unit.py` | PASS, 32 tests | Real Linux root ownership, flock and atomic exchange on disposable directories under `/root` |
| `tests/provision_unit.py` | PASS, 18 tests | Mocked host boundaries only |
| `find scripts/wsl-secure-egress/linux ... -exec sh -n` | PASS | Shell syntax of the managed launchers |
| `cargo build --workspace --locked --offline` and `cargo build -p clash-of-rust --bins --release --locked --offline` | PASS | Produced `target/release/clash-of-rust.exe`, `clash-tun-launcher.exe`, `clash-wsl-guardian.exe` |

Evidence: `ClashOfRust-network-backups/wsl-local-20261018/linux-egress-integration-20261017-214237.json`
(`outcome=passed`, 86 cases). The suite reports the same limits as CI: the
Windows/WSL/Hyper-V effective audit, cold boot and real VPS/geography checks are
`notRun` inside it.

Two failures happened before that PASS and are recorded rather than replaced:

1. `manager install` returned `blocked` with `Private path ownership, symlink or
   permissions check failed.` The cause was the host, not the manager: an earlier
   automation defect ran `cp -a <repo>/. /` inside WSL, which copies the source
   directory attributes onto an existing destination and therefore left `/`
   owned by the desktop user with mode `0777`. The guard correctly refuses to
   install private state in that condition. The duplicated tree was moved to
   `/root/quarantine-root-repo-copy-20261018` and `/` was restored to
   `root:root 0755`; `/usr`, `/etc`, `/var`, `/root`, `/home`, `/mnt` and the
   `init`/`.package-cache-mutate` files were not modified, and `/.local-tools`
   and `/.cargo` were left in place.
2. `managed-unauthorized-dns-udp` then failed with `receiver positive control
   failed`, the same defect that failed CI. The negative-case helper re-probed
   the intentionally blocked destination as its trailing positive control; the
   fixture DNS receiver binds only the managed resolver address for UDP, so the
   control could never observe a receipt. Both the pre-probe and the post-probe
   control now use the declared control endpoint, and `COR_EGRESS_TEST_DEBUG=1`
   was added as an opt-in for redacted fixture stdout/stderr when a manager JSON
   event is missing. Default CI output stays redacted.

## 2026-10-18 CI failure, root cause and deterministic fixture fix

GitHub Actions run
[39063692775](https://github.com/Sonder4/Clash-of-Rust/actions/runs/39063692775)
for commit `f6e2542` failed the isolated suite at
`missing-tunnel-existing-tcp: timeout without a deny counter is not proof`.
The Windows/Rust workflow for the same commit passed. The first local rerun
afterwards failed on the same case with `sent=True errno=None
error=TimeoutError`.

Root cause, taken from the fixture rather than from the product: the case
deleted the managed WireGuard link and then added a fixture fallback route, but
the pre-established socket had selected the tunnel address `10.77.0.2/32` as
its source. Once that address disappeared with the device, the kernel refused
the flow during route lookup, so nftables never saw a packet and the guard
counter could not move. The case was proving that a deleted source address
blackholes a socket, not that the guard drops it.

A first attempt to accept a named local `errno` as refusal evidence was
reverted before commit: it weakened a real proof into a weaker one and still
did not hold, because the kernel retransmit path swallows route lookup
failures instead of reporting them to the application.

The fixture now reassigns `10.77.0.2/32` to the fallback link, so the
pre-existing flow stays routable and its packets must reach the guard. The
negative rule is unchanged and strict: every negative case still requires a
deny-counter increase, no receiver nonce and unchanged direct-path counters.
The same change makes the case deterministic for both scopes, because the
ordinary (root-namespace) session never lost its source address and already
produced counter evidence.

Executed after the fix on this host:

| Check | Result | Scope |
| --- | --- | --- |
| Full isolated suite in Ubuntu-22.04 | PASS, 86 cases | Disposable net/PID namespaces with the fixture VPS; no Windows, WSL host or real VPS configuration participated |
| `missing-tunnel-existing-tcp` evidence | PASS, deny counter 30 -> 35 | Pre-established managed flow genuinely dropped by the guard after tunnel loss |
| `missing-tunnel-existing-shared-tcp` evidence | PASS, deny counter 37 -> 42 | Same for the ordinary-namespace session |
| `python3 -m compileall` and `sh -n` launchers | PASS | Syntax only |
| `linux_static_test.py` | PASS, 21 tests | Portable evidence/gate logic |
| `acceptance_harness_unit.py` | PASS, 3 tests | Endpoint validation |
| `server_unit.py` | PASS, 24 tests | Offline VPS profile validation |
| `payload_unit.py` | PASS, 32 tests | Real Linux root ownership, flock and atomic exchange |
| `provision_unit.py` | PASS, 18 tests | Mocked host boundaries only |
| `windows-unit.ps1` (Windows PowerShell 5.1) | PASS, 86 assertions | Mocked host boundaries; no WSL, firewall, DNS or route mutation |

Evidence: `ClashOfRust-network-backups/wsl-local-20261018/linux-egress-integration-20261017-221209.json`
(`outcome=passed`, 86 cases). Run `39063692775` is recorded as the failure it
was; it is not replaced or reinterpreted.

The same change set fixes an installer defect found by the independent
read-only Windows review: the uninstall gate compared the live
`ClashOfRust.WslEgress` image path against the copy next to the script, while
the reviewed helper package is what installs the service under
`%ProgramFiles%\Clash of Rust WSL`. Any uninstall or ordinary reinstall on this
host would therefore have stopped with exit code 2 forever. The gate now
accepts exactly the two protected package locations and still requires a
`LocalSystem` account, an exact `--service` command line and a journal that
reached `restored`. The live service on this host
(`"C:\Program Files\Clash of Rust WSL\clash-wsl-guardian.exe" --service`,
`LocalSystem`) is accepted by the new check; the deletion itself was not
executed, because the active generation must keep its guardian.

The review also raised two follow-ups that are **not** fixed here and are
tracked for a later change: update mode (`/S /UPDATE`) does not run the WSL
guard pre-check that the ordinary path runs and restores only the main
executable if extraction fails, and several accepted-but-unused broker
parameters (`-Distro`, `-EndpointIPv4`, `-EndpointPort`) are forwarded from the
GUI without being read.

## 2026-10-18 independent reviews and install-path fixes

Two read-only review agents inspected commit `8b7fe19`: one for the Windows
side (broker, firewall, installer, GUI) and one for the Linux side (manager,
harness, contract). Neither found a P0 or an exploitable fail-open path. The
Windows review raised two P1 items; the uninstall half was already fixed in
`8b7fe19`, and this change set fixes the install half.

Fixes in this change set:

| Item | Fix |
| --- | --- |
| Guardian service identity at install time | A service already registered by either canonical package (`%ProgramFiles%\Clash of Rust WSL` or `%ProgramFiles%\Clash of Rust`) is adopted after the account, image path and automatic start mode are verified, instead of aborting the installation on a path comparison against the running copy |
| Alternate data stream profile path | `New-WslEgressUnixPath` rejected a second colon only when it appeared at index 1, so `C:\Private\egress.json:ads` was accepted; any colon after the drive colon is now refused |
| Stale documentation | `linux/CONTRACT.md` said 14 portable tests (now 21); `SECURITY_MODEL.md` claimed Linux rejects Tailscale install and start (Linux installs a closed deny guard and only `start` refuses the backend) |

Executed after the changes on this host (Windows PowerShell 5.1):

| Check | Result | Scope |
| --- | --- | --- |
| `tests/windows-unit.ps1` | PASS, 100 assertions (was 86) | Mocked host boundaries; the guardian service boundary is replaced by fixtures, no service, WSL, firewall, DNS or route was touched |
| New install-adoption assertions | PASS | A `LocalSystem` service from either canonical package is adopted without recreating it, is started once, and a foreign image is refused and never started |
| Extended-service-path assertion | PASS | The command line the installer writes is accepted by the ownership predicate that uninstall uses |
| Alternate-stream and network path assertions | PASS | `C:\Private\egress.json:ads` and `\\server\share\egress.json` are refused (`GetFullPath` returns the stream path unchanged, so the check, not the framework, is what refuses it) |
| PowerShell parser (module, broker, uninstall gate, guardian audit, helper install, unit suite) | PASS | Syntax only |

Not executed and not claimed: the live guardian service was not re-registered,
no WSL distribution was started, and no firewall, DNS, route or Hyper-V object
was modified by these tests.

## 2026-10-18 CI, package verification and the local install gate

Head commit `19ea903` on the `Sonder4` fork was verified by GitHub Actions, and
the same commit was packaged into an installer that was downloaded and
hash-checked on this host.

| Check | Result | Evidence |
| --- | --- | --- |
| `WSL Secure Egress` workflow, push | PASS | run 39067005355 on `19ea903` |
| `CI` workflow, push | PASS | run 39067005271 on `19ea903` |
| `CI` workflow, pull request | PASS | run 39068106473 on `19ea903`, then run 39082984419 after the documentation commit `0003cd6`; both events are `pull_request` with all ten `CI_JOBS` successful |
| `WSL Secure Egress` workflow, pull request | PASS | run 39082984425 on the branch head `0003cd6` |
| `Publish Release` test-only packaging | PARTIAL | run 39070338528: `package-windows-x64` PASS; `package-windows-arm64` cancelled and `Publish verified release` skipped because `check_only` was set |
| `Clash-of-Rust-0.6.0-windows-x64-setup.exe` | PASS | SHA-256 `5e282cdc36e4d8e966c6b812a38aa964a431842d47d2d6ae0fcc728d80e3e84a` recomputed locally and identical to the published `.sha256`; `package-receipt.json` names commit `19ea903…` and CI run 39068106473 |

Local update attempt on this host, recorded from the commands that ran:

| Step | Result |
| --- | --- |
| Read-only baseline before the update | PASS. Installed package was 0.5.11 in `D:\Clash of Rust` with no `resources\wsl-secure-egress`; `ipgw.neu.edu.cn` and `api.okinto.com` both returned HTTP 200; guardian audit `policy_matches: true`; broker status `host_policy PASS`, phase `connected_unverified`, backend WireGuard. Evidence: `ClashOfRust-network-backups\install-20261018\pre-install-verification.json` |
| User-data snapshot before the update | PASS. `%LOCALAPPDATA%\clash-of-rust\ClashOfRust` copied to `ClashOfRust-network-backups\install-20261018\userdata-pre-update` (13 files, 37,529,812 bytes). The EFS-encrypted `%LOCALAPPDATA%\ClashOfRust\WslEgress` profile was left untouched and is not part of the copy |
| Graceful client exit through `Local\ClashOfRust.Exit` | PASS. The GUI exited in 6.5 s and stopped its core; both mandatory URLs still returned HTTP 200 with the client stopped |
| Elevated uninstall and install of the verified package | BLOCKED, environment. `Start-Process -Verb RunAs` returned `ERROR_CANCELLED` four times; `consent.exe` was observed running, so the consent dialog was raised and then dismissed without an answer. Creating a `Highest` run-level task is refused for the filtered token (`Access is denied`). Completing a per-machine install therefore needs one interactive consent click |
| Fork build running locally, WSL page visible, copied admin command | NOT_RUN — depends on the blocked step |
| Reboot, sleep/resume and physical network switch | NOT_RUN |

The package, hash and CI conclusions above were read back from the GitHub API;
the local rows are the recorded output of the commands that actually ran.

The packaged installer corresponds to `19ea903`. The commits listed after it on
this branch edit this test record only, so they do not change the installed
binary; any further commit that touches this document alone has the same
property.

## 2026-10-18 installed application and vendor-facing live tests

The user subsequently completed the UAC installer. The installed application is
now 0.6.0 under `%ProgramFiles%\Clash of Rust`; both network services are running
and the installed Linux manager hash matches this repository's payload. This
supersedes the earlier blocked-install observation above.

The detailed [local test report](LOCAL_TEST_2026-10-18.md) records the actual
09:42–09:53 Asia/Taipei execution and the retained per-step evidence under the
ignored `ClashOfRust-network-backups/usability-20261018-094234/` directory.

- PASS: ordinary WSL neutral and OpenAI/Claude web traces returned the configured
  VPS IPv4, DE/FRA, with certificate verification enabled.
- PASS: three unauthenticated API connections (OpenAI, Anthropic, DeepSeek)
  returned 401 with valid TLS; an owned VPS packet observer correlated their
  tunnel SYN, uplink SYN and reply with the clients' actual destination address
  and verified the VPS source. This is network/source validation, not successful
  authenticated inference.
- PASS, sampled: one DNS nonce query/reply was observed on `wg0` and no matching
  clear nonce was observed on WSL `eth0` during the capture window.
- PASS, sampled: forced IPv6 failed; absolute Windows EXE execution failed with
  errno 8 and WSLInterop was disabled. Windows mounts remained visible in
  ordinary WSL and the current Desktop process.
- BLOCKED: current formal sandbox launcher refused the expired five-minute
  scope assertion. A new complete Windows WFP audit required UAC, whose attempt
  returned cancellation. No assertion was forged; the ordinary WSL tests above
  do not replace fresh sandbox acceptance.
- FAIL: current Claude Desktop still points to an unlistened local proxy and
  logs proxy failures. Its installed native binding also requires GLIBC_2.39
  while the distro has glibc 2.35. No persistent app configuration was changed.
- ERROR: a requested DeepSeek subagent was attempted but failed at the
  platform's sealed-task cross-model boundary before running its task.
- NOT_RUN: authenticated inference, a real standalone Claude Code session,
  current isolated GUI/CLI use, production VPN loss, reboot, physical network
  switch and sleep/resume. Overall protection remains Unverified.

The report preserves probe errors and failed SSH/diagnostic attempts separately
from the corrected reruns. Final Windows mandatory HTTPS and DNS checks passed.

## Acceptance rule (unchanged)

Positive connectivity requires a receiver-observed nonce, the expected source
and counter evidence. A send success or timeout alone is not proof. A negative
test requires a deny counter, no receiver nonce and unchanged direct-path
counters. When a fixture would otherwise let the kernel refuse a flow before
nftables sees it, the fixture must be extended until the traffic really reaches
the guard; weakening the rule instead is not an acceptable fix. Real production
fault injection is not authorized.

Update this document after GitHub Actions and any approved VPS/WSL acceptance
with the exact commit, run URL and per-scenario result.

## 2026-10-18 current installed-payload retest

> Historical section. The successful rows below describe the payload and host
> state on 2026-10-18. They do not override the current missing profile,
> disabled endpoint or blocked WSL DNS.

This section records the resumed local retest after the protected helper
payloads were synchronized to both Program Files package locations. It
supersedes earlier entries that described the endpoint as disabled before the
UAC-approved recovery.

| Check | Result | Actual evidence |
| --- | --- | --- |
| Upstream synchronization at that time | PASS | `upstream/main=37683750b37be9d2bbcfb22804bec96174e14af5`; that historical fork HEAD was 39 commits ahead and 0 behind |
| Stop transaction | PASS | Linux manager returned `succeeded`, phase `Guarded`; owned namespaces and policy routes were removed |
| First Start after Stop | PASS | Linux manager returned `succeeded`, phase `Running`; both `cor-egress-transport` and `cor-egress-gw` were recreated |
| Isolated IPv4 exit | PASS | `api.ipify.org` and `ifconfig.me/ip` both returned `62.84.164.122` |
| Isolated network view | PASS | only `lo`, `cor-bg0`, `wg0`; default IPv4 route is `wg0`; DNS is `10.77.0.1`; IPv6 default is unreachable |
| OpenAI endpoint | PASS | HTTPS/TLS reached `api.openai.com`; HTTP 401 for missing bearer authentication |
| Anthropic endpoint | PASS | HTTPS/TLS reached `api.anthropic.com`; HTTP 405 for a GET request |
| DeepSeek endpoint | PASS | HTTPS/TLS reached `api.deepseek.com`; HTTP 401 for missing authentication |
| Claude Code CLI | PASS | `claude --version` returned `2.1.302` inside the isolated launcher; no proxy environment variables were present |
| Fail-closed boundary | PASS | Stop withdrew the endpoint exception before namespace teardown; a subsequent Start was required to restore the tunnel |
| Windows baseline after retest | NOT_RUN in this exact command batch | The mandatory Windows URLs were validated by the earlier UAC-approved synchronization/recovery record; repeat before any future host-policy mutation |

The three provider results prove network reachability and TLS termination only;
they do not prove authenticated API use. The German address is intentionally
documented because it is the observed exit evidence, while private WireGuard
keys, SSH material and full profile contents remain outside Git. Claude Desktop
is not marked passed: its old `127.0.0.1:12345` proxy failure and the
Ubuntu-22.04 GLIBC 2.39 native-binding requirement are separate from the
working Claude Code CLI path.

## 2026-10-18 final payload synchronization and fail-closed retest

The reviewed source payload was synchronized through the administrator UAC
path to both protected Program Files package trees, then installed into the
journaled Ubuntu-22.04 WSL distribution with the endpoint closed. The update
receipt reported `owned_config_matches=true`, `interop_runtime_disabled=true`,
`endpoint_enabled=false`, and `network_changed=false`. The installed
`manager.py` SHA256 matched the repository file
(`9ce7fa6dd25cf7ffef88950202061ea20fe7790f9d87dd1ce6f9995e270df8b2`).

The Stop→Start regression was exercised through the real broker:

- UAC `Stop -Execute`: `succeeded`, phase `installed_closed`.
- A protected workload launched after Stop: `blocked` with
  `Namespace ownership mismatch; foreign namespace preserved.` No local
  Windows fallback was available.
- UAC `Start -Execute`: `succeeded`, phase `connected_unverified`; all five
  scope checks were `PASS`.
- Final isolated IPv4: `62.84.164.122`; Claude Code CLI: `2.1.302`.
- Windows baseline after recovery: `ipgw.neu.edu.cn` HTTP 302 and
  `api.okinto.com` HTTP 200.

The first-Start failure was traced to a boot guard and explicit Start racing
for `manager.lock`. The manager now waits up to 15 seconds with a 50 ms poll,
then fails closed on timeout. The Linux static suite passed 75 tests in the
Windows-host invocation (two Linux-only skips) and 75/75 inside Ubuntu-22.04;
the Windows suites passed 161 and 167 assertions, package-upgrade 53,
provisioning 26, and Rust WSL 27 tests. These results are the current local
evidence for the repaired fork head; new-head GitHub Actions remains required.

## 2026-10-18 PR repair verification

The following checks were executed after repairing the outstanding Fork PR
review comments. They are local results for the current worktree; they do not
replace the new GitHub Actions run that will be created after push.

| Check | Result | Evidence |
| --- | --- | --- |
| Linux static/boot-guard suite | PASS | WSL Ubuntu-22.04, 52 tests; expanded exact-rule, table ownership and boot-guard cases |
| Windows workflow fixture | PASS | PowerShell, 96 assertions; no firewall, WSL or scheduled-task mutation |
| Windows unit fixture | PASS | PowerShell, 125 assertions; includes actual temporary-directory archive copies, JSON readback and snapshot hash/tamper checks |
| Windows elevation fixture | PASS | 21 assertions; UAC/process boundaries mocked |
| Windows package-upgrade fixture | PASS | 38 assertions; package fixtures, no installed-package replacement |
| VPS provisioning unit suite | PASS | 18 tests |
| VPS server unit suite | PASS | 24 tests |
| Acceptance harness unit suite | PASS | 3 tests |
| PowerShell parser | PASS | Module, elevation, renewal, upgrade and workflow scripts |
| Python syntax and diff check | PASS | `manager.py`, `prepare-vps.py`, `git diff --check` |
| Rust WSL core tests | PASS | `cargo test -p clash-client-core wsl --release`: 27 passed |
| Rust desktop WSL tests | PASS | `cargo test -p clash-of-rust wsl --release`: 27 passed; supersedes the earlier 22-test run |
| Rust formatting | PASS | `cargo fmt --all -- --check` |
| Rust clippy | PASS | `cargo clippy --release --workspace --all-targets -- -D warnings` |
| Release build | PASS | `cargo build --release` |
| Real WSL nft load | PASS | Temporary `unshare -n`; canonical guard accepted by nftables |
| Real WSL deny probe | PASS | Temporary namespace could not connect to `192.0.2.1:9` after guard load |
| Full disposable Linux integration rerun | PASS | Fresh Linux-native source copy; 89 cases, including kernel loading of closed/open-single/open-multiple-bridge guards; fixture receiver only |

Review fixes covered by this pass:

1. Install/Start requires a profile path; visible endpoint values are not a
   substitute, and contradictory explicit overrides are rejected.
2. Partial Windows rollback handles absent journal properties and restores
   recorded host objects without an uninstalled Linux helper. Write-ahead
   markers distinguish pre-manager failures from a Linux install that may
   already have begun.
3. Restored journals permit a new installation after the recovery generation
   is archived. Real temporary-directory tests verify SHA256/readback before
   retirement and preserve live evidence when a snapshot is missing or changed.
4. All managed ordinary distros install the profile-independent boot guard.
   Exact static, owned manager and unknown table cases, atomic replacement and
   first-start races have regression coverage.
5. VPS preparation tolerates the new systemd unit being inactive before its
   first `enable --now`; exit status 3 is covered by the offline fixture.

Failures encountered and corrected are retained as failures:

- An initial Linux static invocation used Windows Python, which cannot import
  Linux `fcntl`; it ran no Linux tests. The corrected WSL invocation passed
  the 52-test suite.
- An initial Cargo invocation used the wrong crate name and ran no tests.
  The corrected package commands above each passed 27 tests.
- Kernel nftables can reorder elements in a multi-source address set. The
  guard matcher previously rejected that equivalent serialization. IP-prefix
  normalization now handles ordering while preserving exact rule matching;
  the subsequent kernel smoke and full disposable 89-case run passed.

The actual running desktop process remains the installed 0.6.0 package under
`C:\Program Files\Clash of Rust`; it was not replaced by this source build.
The live WSL journal remains `installed_closed` with its endpoint disabled.
Production cold boot, reboot, network switch, sleep/resume, authenticated model
inference, standalone Claude Code isolation and the current Claude Desktop
runtime remain `NOT_RUN`, `BLOCKED` or `FAIL` as recorded above.

These are local worktree results. A new-head GitHub CI result is still pending;
old-head CI evidence above must not be used to declare this repair's CI passed.

## 2026-10-22 final offline verification before fork push

The following suites were executed again from the review branch after the
last documentation and CI changes. No UAC prompt was raised, no WSL distro was
started by these tests, and no Windows firewall, route, DNS or service setting
was changed by these tests.

| Check | Result |
| --- | --- |
| Windows broker unit | PASS, 166 assertions |
| Windows workflow | PASS, 244 assertions |
| Windows elevation | PASS, 21 assertions; consent `NOT_RUN` |
| Administrator argument vector and ACL | PASS, 25 assertions; consent `NOT_RUN` |
| Profile restore | PASS, 18 assertions |
| Package staging | PASS, 70 assertions |
| Package upgrade | PASS, 53 assertions |
| Clash of WSL | PASS, 34 assertions; live tests `NOT_RUN` |
| Linux static and boot guard | PASS, 87 tests, 2 skipped |
| Acceptance harness | PASS, 3 tests |
| VPS server | PASS, 24 tests |
| VPS provisioning | PASS, 27 tests |
| Tool installer static regression | PASS, 8 tests |
| Rust desktop binary, serial | PASS, 106/106 |
| Rust formatting and compile check | PASS |
| WSL workflow YAML parse | PASS |
| Git whitespace check | PASS |

The hosted CI run for this new commit was still pending when this entry was
written. Every live deployment, tunnel, provider, Claude, interop, cold-boot,
network-switch, rollback, uninstall and reinstall item remains `NOT_RUN` until
authoritative evidence is collected.

## 2026-10-18 follow-up repair and recovery attempt (current session)

This entry records only commands actually executed in the resumed session.

| Check or operation | Result | Evidence and limits |
| --- | --- | --- |
| WSL PR repair coverage | PASS, 72 tests, 2 platform skips | `python scripts/wsl-secure-egress/tests/linux_static_test.py`; sibling runtime and uplink classifier fixtures |
| VPS provisioning unit tests | PASS, 26 tests | Offline mocked host boundaries |
| VPS server unit tests | PASS, 24 tests | Offline profile validation |
| Rust WSL request tests | PASS, 27 tests | `cargo test -p clash-client-core wsl::tests --locked --offline`; endpoint-only Install/Start requires a profile |
| Windows broker unit tests | PASS, 149 assertions | Offline mocks; no host policy writes |
| Windows workflow tests | PASS, 161 assertions | `wsl_started=false`, `firewall_modified=false`, `scheduled_tasks_modified=false` |
| Package upgrade tests | PASS, 53 assertions | Offline; no service or network changes |
| Git whitespace check | PASS | `git diff --check` |
| Admin Start / scope renewal | BLOCKED | UAC-launched PowerShell produced no result; prior elevation reported user cancellation |
| Current broker Status | FAIL-CLOSED | `phase=failed_closed_requested`, host policy PASS, Linux runtime PASS, scope attestation NOT_RUN, protection unknown |
| Hyper-V endpoint rule | Disabled | Persistent rule targets the journaled VPS UDP endpoint and port; `Enabled=False` |
| Linux manager Status | Local-only success, end-to-end UNVERIFIED | `phase=Running`, `protection=Unverified`; local guard/interface check explicitly makes no end-to-end claim |
| Claude stale proxy cleanup | Applied with backup | User unit backed up under `/var/backups/clash-wsl-repair-20261018/`, autostart disabled, old proxy environment and Electron arguments removed |
| Claude / model-vendor network tests | NOT_RUN | Endpoint exception disabled and no current end-to-end VPS proof exists |
| Legacy Claude proxy retirement | Preview only | Known old units inactive/disabled; original files retained; no `--execute` retirement |

The installed Linux namespaces and a recent WireGuard handshake were observed,
but that does not override the disabled Windows endpoint rule or manager
`Unverified` status. Do not start Claude or issue model-vendor requests until an
authorized administrator Start completes scope renewal and full egress
acceptance confirms the VPS source address, tunnel DNS, and IPv6 policy.

The Claude user service remains disabled as a fail-safe; its original unit
backup is preserved in the root-only WSL backup directory above.

## 2026-10-22 current fork review repair

> Historical subsection for the development tree immediately after the
> `87ef6b2` repair series. Later entries supersede its test counts and
> current-state conclusions.

This section records only commands executed on 2026-10-22. It does not change
the production host state described above.

| Check | Result | Evidence and limits |
| --- | --- | --- |
| Clash of WSL component tests | PASS, 22 assertions | `clash-of-wsl/Test-ClashOfWsl.ps1`; structure, parser and installer static checks only |
| Windows broker unit suite | PASS, 166 assertions | `tests/windows-unit.ps1`; host/WSL/network boundaries mocked |
| Windows workflow suite | PASS, 244 assertions | `tests/windows-workflow.ps1`; no WSL start, firewall or task mutation |
| Windows elevation suite | PASS, 21 assertions | `tests/elevation-unit.ps1`; UAC is NOT_RUN |
| Package-upgrade suite | PASS, 53 assertions | `tests/package-upgrade-unit.ps1`; installed services unchanged |
| Linux static/boot-guard suite | PASS, 87 tests, 2 skipped | Windows-host invocation; native permission and arch cases skipped |
| VPS server validation | PASS, 24 tests | Offline profile validation |
| Payload upgrade suite | PASS, 32 tests, 16 skipped | Portable cases passed; native root/flock cases skipped outside Linux root |
| Acceptance harness | PASS, 3 tests | Offline endpoint validation |
| VPS provisioning suite | PASS, 27 tests | Offline mocked host boundaries |
| PowerShell parser sweep | PASS | Module, admin job, installer self-test and repaired upgrade script |
| Linux syntax sweep | PASS | Ubuntu-22.04 `py_compile` and `bash -n`; no package or network change |
| Rust UI test binary | PASS, 101 tests | `cargo test -p clash-of-rust --bin clash-of-rust --locked` |
| Rust formatting | PASS | `cargo fmt --all -- --check` |
| Rust compile check | PASS | `cargo check -p clash-of-rust --bin clash-of-rust --locked`, 122 crates |
| Git whitespace check | PASS | `git diff --check` |

The review repair includes the following behavior changes:

- `ClashOfWsl` now builds a Windows command line with quote-aware arguments
  before requesting UAC, so source paths under `Program Files` remain one
  argument.
- The installer registers and starts the owned SYSTEM guardian only after
  copying the payload. A generic uninstall is refused; the explicit
  `-RestoreOriginalNetwork` path must succeed before the service or recovery
  payload is removed.
- `Update-LiveWslPayload` uses a caller-owned durable stage file, so a failure
  inside module scope cannot be mislabeled as `preflight`.
- A missing journal-owned legacy override now refuses rollback. Missing files
  are tolerated only while the second phase of an interrupted rollback is
  finishing.
- A `prepared_for_reinstall` journal enters partial recovery instead of the
  adoption path.
- The Slint page restores the explicit “恢复原网络” confirmation action while
  retaining the safer “断开并保留保护” action.

A first repository-wide syntax sweep incorrectly invoked Windows Python and
native Bash with Windows paths. It reported path/tool failures and is retained
here as a failed attempt; the corrected Ubuntu-22.04 invocation passed. This
host tooling mistake did not indicate a source syntax failure.

Live WSL state remains fail-closed at the end of this run:

- Broker phase: `failed_closed_requested`
- Hyper-V endpoint rule: disabled
- Runtime acceptance: `NOT_RUN`
- Scope renewal: `not_run`

No administrator tunnel start, VPS egress check, OpenAI/Anthropic/DeepSeek
request, Claude Code test, Claude Desktop test, cold boot, reboot, network
switch, or restore/reinstall live acceptance was executed in this section.
Those items remain `NOT_RUN` or `BLOCKED` until authoritative live evidence is
captured.

## 2026-10-22 upstream merge and ACL repair

The following checks were executed after merging
`upstream/main=2615ebc96f9f510802194727a6108bde73f4c8ed`, which contains
the upstream 0.6.1 UI-motion and Claude protection-mode changes.

| Check | Result | Evidence and limits |
| --- | --- | --- |
| Upstream ancestry | PASS | `git merge-base --is-ancestor upstream/main HEAD`; that intermediate snapshot was `0 behind / 72 ahead`. The later CI-verified `87ef6b2` snapshot is `0 / 73` |
| Admin ACL SID regression | PASS, 9 assertions | `tests/admin-job-acl.ps1`; canonical `*SID` rules pass and the host is unchanged |
| Desktop test binary after merge | PASS, 105 tests | `cargo test -p clash-of-rust --bin clash-of-rust --locked`; includes upstream motion and WSL UI dispatch tests |
| Workspace all-targets check | PASS | `cargo check --workspace --all-targets --locked` |
| Rust formatting | PASS | `cargo fmt --all -- --check` |
| Clash of WSL component suite | PASS, 22 assertions | Static/parser/installer checks; live UAC remains `NOT_RUN` |
| Windows broker unit suite | PASS, 166 assertions | Host, WSL and network boundaries mocked |
| Windows workflow suite | PASS, 244 assertions | No WSL, firewall or task mutation |
| Windows elevation suite | PASS, 21 assertions | UAC is `NOT_RUN` |
| Package-upgrade suite | PASS, 53 assertions | Installed services unchanged |
| Linux static/boot-guard suite | PASS, 87 tests | Real Ubuntu-22.04 invocation; no live host change |
| VPS server validation | PASS, 24 tests | Offline profile validation |
| Payload upgrade suite | PASS, 32 tests, 16 skipped | Ubuntu-22.04 invocation; root/native cases were skipped |
| Acceptance harness | PASS, 3 tests | Offline endpoint validation |
| VPS provisioning suite | PASS, 27 tests | Offline mocked host boundaries |

An intermediate commit created during merge preparation did not contain the
upstream commit as a parent. It was discarded before the final merge. The
final merge commit was then checked with `git merge-base --is-ancestor`; the
earlier compile and test checks are not used as proof of upstream ancestry.

The WireGuard client profile is still absent from its Windows target path.
A root-only copy is present at
`Ubuntu-22.04:/etc/cor-egress/profile.json` and matches the Linux manager
journal. It has not yet been copied to Windows because that write requires
protected ACL setup and UAC. No tunnel, provider request or model-client live
test occurred in this section.

## 2026-10-22 final documentation and review-test pass

This section supersedes old-head and intermediate worktree counts. It records
the development tree during documentation synchronization; it is still not a
new-head GitHub CI result.

| Check | Result | Evidence and limits |
| --- | --- | --- |
| Windows unit | PASS, 166 assertions | Mocked host, WSL and network boundaries |
| Windows workflow | PASS, 244 assertions | No firewall, WSL or task mutation |
| Windows elevation | PASS, 21 assertions | UAC remains `NOT_RUN` |
| Admin job construction | PASS, 25 assertions | ACL construction and an isolated execution of the native sudo argument vector; UAC remains `NOT_RUN` |
| Profile restore | PASS, 18 assertions | Read-only or temporary fixture; does not restore the live profile |
| Package staging | PASS, 70 assertions | Temporary fixture; preview did not write production package files |
| Package upgrade | PASS, 53 assertions | Installed package and services unchanged |
| Clash of WSL component | PASS, 34 assertions | Static/parser checks plus isolated execute-path tests for uninstall retention and guardian registration; live host checks remain `NOT_RUN` |
| Linux static and boot guard | PASS, 87 tests, 2 skipped | Portable fixtures; no real host mutation |
| VPS server validation | PASS, 24 tests | Offline schema and profile validation |
| VPS provisioning | PASS, 27 tests | Mocked SSH and host boundaries |
| Acceptance harness | PASS, 3 tests | Offline endpoint validation |
| Tool installer static regression | PASS, 8 tests | Single authoritative installer, absolute compatibility wrapper and fail-closed exit-code forwarding |
| Rust desktop binary, serial | PASS, 106/106 | Shared renderer tests were serialized |
| Rust formatting | PASS | `cargo fmt --all -- --check` |
| Git whitespace | PASS | `git diff --check` before final documentation edits |

An earlier parallel desktop run passed 105/106 tests. The motion test
`motion_overlays_reverse_on_reopen_release_content_and_leave_no_idle_clock`
lost a shared headless renderer race. The test passed alone and the complete
serial run passed 106/106. This failure remains part of the record.

The current review repairs include:

- profile-required validation for executed Install and Start;
- partial Windows recovery without an absent Linux helper;
- reinstalling after a verified restore;
- shared boot guards for every managed distribution;
- tolerance for an inactive systemd unit before its first start;
- `prepared_for_reinstall` propagation through the broker, Rust report and UI;
- explicit **恢复原网络** confirmation;
- retained payload and service when uninstall restore fails;
- guardian service registration and startup by the Execute path;
- durable payload-upgrade failure stages;
- refusal to roll back a missing journal-owned override;
- native sudo arguments that preserve spaces in installation paths.

The review-test gaps identified earlier are now covered by offline execution:
the native sudo vector preserves paths containing spaces; installer uninstall
retains the payload and service after a failed restore; the execute path
registers and starts the guardian; and the compatibility installer delegates to
the single authoritative implementation while preserving the exit-20
fail-closed gate. These tests do not perform UAC or mutate the live host.

The current host state is unchanged by these offline checks:

| Live item | Result |
| --- | --- |
| Windows profile | `MISSING` |
| Hyper-V endpoint | `Enabled=False` |
| Broker | `failed_closed_requested` |
| Guardian service | Running / Automatic |
| Ubuntu DNS and HTTPS | Blocked; fail-closed |
| VPS IPv4, provider reachability and Claude | `NOT_RUN` |
| UAC, stop/start, cold boot, network switch, rollback and reinstall | `NOT_RUN` |
