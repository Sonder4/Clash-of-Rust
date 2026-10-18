# Upstream Comparison

## References and comparison method

This snapshot was checked on 2026-10-18:

- Upstream: `Fu021/Clash-of-Rust`, main
  `37683750b37be9d2bbcfb22804bec96174e14af5`.
- Fork: `Sonder4/Clash-of-Rust`, branch `feat/wsl-secure-egress`, PR #2.
- Current committed feature HEAD:
  `ad27eff322b07eb7e0dec6ec20c59639b209ba72` plus the PR-repair worktree changes described here.
- Most recent upstream ancestor included in HEAD:
  `a27d1540e81def416c22936f87f7e008d3e8b3b7`.
- The fork's main ref is `e2fb6f1`; it is an older comparison base than
  refreshed upstream main.

The comparison below separates the existing feature branch from the five review repairs; the repair commit and merge result are filled from Git before delivery. The task's early local handoff recorded the official `v0.5.9` checkout,
`f8a1379`, before WSL implementation. That historical release explains the
starting environment; it is not the correct sole baseline for reviewing the
current feature. The feature history starts with plan commit `0bbe6b0` and
implementation commit `2661c25`, and incorporates later upstream changes.
Current review compares the complete worktree against refreshed upstream main,
then separates inherited upstream history from feature additions.

Reproduce the comparison with:

```powershell
git rev-parse HEAD upstream/main
git merge-base HEAD upstream/main
git log --oneline HEAD..upstream/main
git diff --stat upstream/main
git diff upstream/main -- apps/desktop crates/client-core crates/client-ui installer scripts
```

`git diff upstream/main` includes staged and unstaged tracked changes. New
untracked files are absent until explicitly added, so `git status --short`
must be reviewed as well. Counts during ongoing work are not a permanent
release manifest.

## Upstream synchronization status

Merge `1eed8b3` incorporates `a27d154`. Upstream subsequently added
`3768375`, “docs: add contributor guidelines and AI contribution policy”.
That commit changes `.github/CONTRIBUTING.md`, `README.md` and
`docs/workflows.md`; it has been fetched but is not yet merged at this
snapshot. Differences showing those new upstream paragraphs missing are
synchronization differences, not an intended feature deletion.

There is no upstream code update after `a27d154` in the currently fetched
history. Refresh and integrate the documentation update before declaring the
branch synchronized. Delivery remains the user's fork PR #2; no PR to
`Fu021/Clash-of-Rust` is requested.

## Functional change boundary

| Area | Before the WSL feature | Feature branch change |
| --- | --- | --- |
| Desktop control | Existing proxy, subscription and diagnostics pages | WSL page and request/report controller, file selection, UAC feedback, bounded status/log lists |
| Shared configuration | No WSL preference schema | Defaulted WSL preference field and separate request/report/state types |
| Windows enforcement | No feature-owned WSL policy broker | Separately packaged PowerShell broker, Hyper-V policy, Docker WFP guard, guardian audit, recovery journal |
| Linux enforcement | No feature-owned WSL manager | Installable root-owned manager, namespaces, nftables, WireGuard, DNS/interop configuration and workload launcher |
| VPS provisioning | Existing VPS configuration is external to the client | Explicit standalone preparation/server tools; no automatic SSH deployment from the UI |
| Packaging and updates | Official installer and update lifecycle | Helper resources, protected code-upgrade/rollback transaction, active-recovery uninstall gate; official self-update disabled in the fork |
| Validation | Upstream CI and unit suites | WSL core/UI fixtures, Windows offline suites and disposable Linux/WFP integration |

The WSL data plane is implemented in `scripts/wsl-secure-egress/linux`, not
inside the Clash desktop process. Windows privileged policy lives in
`scripts/wsl-secure-egress` and its guardian binary. The Rust WSL controller
issues fixed broker requests and consumes structured responses.

The complete feature still requires a desktop adapter, request schema and
package resources. “Standalone backend” does not mean zero changes to shared
registration or installation code.

## Files outside the dedicated backend

The intended integration points are WSL-specific desktop modules and Slint
page/state/models; application page/message registration, confirmation and
presentation; a defaulted WSL settings field; the guardian target;
installer/resource packaging; and tests and CI entry points. These additions
do not rewrite the proxy engine, subscription model or platform traffic logic.

There are two explicit broader effects:

1. `apps/desktop/src/update/mod.rs` and application update handlers disable the
   official updater for this fork. This prevents an upstream package from
   overwriting custom WSL resources, but changes existing update behavior and
   should be reconsidered if a maintained fork update channel becomes available.
2. `crates/client-ui/ui/components/controls.slint` adds an `enabled` input to
   the shared field component, defaulting to true. It permits WSL controls to
   be disabled during operations; existing call sites retain their default.

Installer and build/CI files are also changed. Their scope is package
preservation, helper delivery and validation; they are not UI-only changes.
The retained WSL workflow is fork infrastructure and does not imply permission
to add it to upstream. Upstream workflow ownership and review rules remain
applicable to any future upstream contribution.

## Five outstanding PR comments

1. **Profile requirement:** executed Install/Start requests require
   `profile_path`; endpoint-only input cannot generate a runnable request.
   Explicit endpoint, port, distro and backend values are checked against the
   protected configuration rather than silently ignored.
2. **Partial installation rollback:** dictionary-safe optional state reads and
   write-ahead markers allow recorded host changes to be restored without an
   absent Linux manager. Once Linux installation may have started, Windows-only
   recovery refuses to release the host guard.
3. **Restore followed by reinstall:** a `restored` journal is archived with its
   recovery artifacts before a new generation. Phase/generation readback and
   snapshot SHA256 validation precede retiring live artifacts.
4. **Every-distro boot guard:** each managed ordinary distribution has a
   profile-independent boot hook. Exact static and verified manager guards
   are recognized; unknown tables are preserved under a separate emergency
   deny. Atomic replacement and first-start races are covered by regression
   cases.
5. **Fresh VPS unit:** the pre-start `systemctl is-active` query tolerates
   nonzero inactive status, so a new unit can proceed to `enable --now`.

## Executed checks and outstanding acceptance

Windows unit tests passed 125 assertions, workflow 96, elevation 21 and
package-upgrade 38. Release WSL core and desktop WSL tests each passed 27.
Expanded Linux static tests passed 52 and the newest full isolated integration
run passed 89 cases from a fresh Linux-native source copy. Release build and
workspace/all-targets Clippy with warnings denied also passed. Exact commands
and subsequent results belong in
[TEST_STATUS.md](TEST_STATUS.md).

These results do not upgrade the production acceptance claim. The installed
Clash of Rust 0.6.0 is running from Program Files; this source revision has not
replaced it. Production WSL is `installed_closed`. Current VPS/Claude use,
authenticated inference, cold boot, physical network changes and sleep/resume
remain outside this repair's completed verification.

New-head GitHub CI must complete before the fork PR is merged. Historical
successful CI runs belong to their exact old commits and cannot be reused as
the result for these changes.
