# Upstream Comparison

## Exact baseline

This comparison was checked on 2026-10-22:

- Upstream: `Fu021/Clash-of-Rust`, `upstream/main` at
  `2615ebc96f9f510802194727a6108bde73f4c8ed`, version 0.6.1.
- User fork: `Sonder4/Clash-of-Rust`, PR #3, branch
  `fix/wsl-recovery-review-20261018`.
- Last CI-verified fork head: `87ef6b206c49446bd9ed614923a6381a346d16a8`.
- Graph relation at that head:
  `git rev-list --left-right --count upstream/main...HEAD` returned `0 73`:
  zero commits behind and 73 fork commits ahead.
- Delivery target is the user's fork only. No upstream PR is authorized.

The old head `87ef6b2` has a successful GitHub `CI` workflow and a successful
`WSL Secure Egress` workflow. This proves the exact commit in those runs. The
worktree subsequently contains profile restore, package staging, additional
review tests, tool installer work and documentation changes. Those changes are
not covered by the old-head CI result until committed, pushed and run again.

The initial WSL work began from an older upstream release. The feature branch
was later synchronized with upstream 0.6.1 and then the fork-only code was
retained in a merge. Review the complete PR #3 commit range for the delivered
feature; review `upstream/main...HEAD` for the final fork delta.

## Reproduce the comparison

```powershell
git fetch upstream
git rev-list --left-right --count upstream/main...HEAD
git merge-base --is-ancestor upstream/main HEAD
git log --oneline upstream/main..HEAD
git diff --stat upstream/main...HEAD
git diff --name-status upstream/main...HEAD
git status --short
```

Use the three-dot comparison for the feature delta and inspect
`git status --short` separately. Uncommitted or untracked files appear in
neither commit comparison and are not represented by a remote CI run.

## Functional boundary

| Area | Upstream baseline | Fork change |
| --- | --- | --- |
| Desktop surface | Existing proxy, subscription, diagnostics and settings pages | WSL page, request/report controller, profile selection, status/log display and explicit recovery confirmation |
| Shared configuration | No WSL profile field | Defaulted WSL settings registration |
| Windows boundary | No feature-owned WSL broker | Hyper-V policy, Docker containment, guardian service, protected profile handling, recovery journal and endpoint transaction |
| Linux boundary | No feature-owned WSL egress manager | Root-owned manager, namespaces, nftables guard, fixed WireGuard transport, DNS policy, interop controls, boot guard and strict launcher |
| VPS | No bundled WSL exit-node lifecycle | Separate fixed-endpoint VPS service and provisioning tools |
| Packaging | Upstream installer and updater | Protected helper resources and code-only package recovery |
| Validation | Upstream CI | Additional Windows, Linux, Rust and WSL-specific CI jobs |

The Linux backend is implemented under
`scripts/wsl-secure-egress/linux`; the Windows lifecycle wrapper is under
`clash-of-wsl/` and `scripts/wsl-secure-egress/`. Clash of Rust acts as the
controller and status surface. It does not embed the Linux data plane or own the
WireGuard keys.

## Changes outside WSL-specific modules

The feature necessarily touches shared registration and packaging:

- application page/message registration, confirmation flow and UI projection;
- a defaulted WSL configuration field;
- the guardian binary and installer resources;
- build, test and CI wiring;
- the shared field control's optional disabled state.

The fork also disables the upstream automatic updater because an official
package cannot carry the fork's protected WSL resources. This is a visible fork
behavior change and must remain documented if a maintained fork update channel
is later introduced.

The proxy engine, subscription model, platform traffic engine and unrelated
network components are not rewritten by the WSL feature.

## Pull request review matrix

The review feedback contains eight independent issue groups represented by nine
comments. The duplicate `prepared_for_reinstall` finding is one issue. The
listed repairs have matching offline checks; the new-head CI column remains
`Pending` until this development tree is committed, pushed and run.

| Review issue | Repair | Offline evidence | New-head CI |
| --- | --- | --- | --- |
| Executed Install/Start needs a profile | Rust validation rejects empty profile and endpoint-only requests | Core/desktop tests | Pending |
| Partial Windows install must roll back without Linux helper | Explicit partial-phase recovery and write-ahead state | Windows broker/workflow fixtures | Pending |
| A restored generation can be reinstalled safely | Verified `restored` journal is archived, then a new generation starts | Windows unit/workflow fixtures | Pending |
| Every managed distro needs a boot guard | Every configured role writes the shared default-drop guard | Linux static and boot-guard fixtures | Pending |
| Fresh VPS unit may still be inactive | Pre-start activity check tolerates inactive status before `enable --now` | Provisioning suite | Pending |
| `prepared_for_reinstall` must not enter adoption | Broker partial recovery, Rust report allowlist and UI state were extended | Rust and Windows workflow tests | Pending |
| UI must retain restore-original-network | Danger-styled button dispatches `Rollback` with `restore-confirm` | Rust UI tests | Pending |
| Restore failure must retain payload | Uninstall returns `blocked` before service or file removal | Isolated execute-path fixture is PASS | Pending |
| Installation must register and start guardian | Execute path creates, starts and reads back the owned service | Isolated execute-path fixture is PASS | Pending |

The administrator argument-vector regression now executes the elevation
function against an isolated capture hook and verifies that paths containing
spaces remain single arguments. The installer test executes both the install
and failed-restore uninstall branches with cmdlets mocked. These tests provide
offline execution evidence; they do not replace the required UAC and live-host
acceptance.

## Current host and acceptance boundary

The last CI success does not imply deployment:

| Item | Current state |
| --- | --- |
| Windows profile | Missing |
| Hyper-V endpoint rule | Present, `Enabled=False` |
| Broker phase | `failed_closed_requested` |
| Guardian service | Running and Automatic |
| Ubuntu 26.04 | NAT-only; DNS and HTTPS blocked |
| Current VPS source | `NOT_RUN` |
| OpenAI, Anthropic, DeepSeek | `NOT_RUN` |
| Chrome, Codex CLI, Claude Code CLI, Claude Desktop | `NOT_RUN` or not installed |
| Interop and strict-launcher isolation | Plain-shell checks only; current strict live test `NOT_RUN` |
| Stop/Start, cold boot, network switch | `NOT_RUN` |

Historical 2026-10-18 live evidence remains in
[TEST_STATUS.md](TEST_STATUS.md) and
[LOCAL_TEST_2026-10-18.md](LOCAL_TEST_2026-10-18.md). That evidence is tied to
the payload and network state at that time and cannot prove the current missing
profile or disabled endpoint is usable.

## Test interpretation

The latest development-tree results recorded in
[TEST_STATUS.md](TEST_STATUS.md) include:

| Suite | Result |
| --- | --- |
| Windows unit | PASS, 166 assertions |
| Windows workflow | PASS, 244 assertions |
| Windows elevation | PASS, 21 assertions |
| Profile restore | PASS, 18 assertions |
| Package staging | PASS, 70 assertions |
| Package upgrade | PASS, 53 assertions |
| Admin job construction | PASS, 25 assertions |
| Clash of WSL | PASS, 34 assertions |
| Linux static/boot guard | PASS, 87 tests, 2 skipped |
| VPS server | PASS, 24 tests |
| VPS provisioning | PASS, 27 tests |
| Tool installer static regression | PASS, 8 tests |
| Desktop Rust binary, serial | PASS, 106/106 |

An earlier parallel desktop run returned 105/106 because one motion test raced
the shared headless renderer. The failing test passed alone and the complete
serial run passed. The parallel failure remains recorded rather than being
rewritten as an all-green parallel result.

Before merge, the exact final commit must pass both GitHub workflows. Offline
tests, a historical live connection and a running service are separate forms of
evidence.
