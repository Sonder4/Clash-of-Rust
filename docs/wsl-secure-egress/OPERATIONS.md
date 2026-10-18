# Operating guide

## Before changing the host

1. Read [the security model](SECURITY_MODEL.md) and
   [compatibility guide](COMPATIBILITY.md).
2. Verify that normal Windows IPv4/IPv6 and the existing Clash/Mihomo service
   work. Configure the private mandatory-connection baseline described in the
   [project README](README.md).
3. Prepare `COR-Egress` and stop every WSL distribution. Save all Linux work.
4. Prepare the private profile and dedicated VPS service. Never put the
   profile, keys, SSH credentials or real endpoint into this repository.
5. Run the page's **Doctor** and **安装预检** actions. A preview changes no files,
   firewall objects, WSL runtime, routes or DNS.

## Install

Choose the local private JSON profile, run the installation preflight, then
click **执行安装**. The installed client requests Windows UAC for the current
user. Approve that Windows prompt to run the fixed installed broker. Doctor,
status and preflight do not elevate or start stopped distributions. A different
administrator account is rejected because WSL registrations belong to the
original user. Installation performs these operations in order:

- validate the private profile and fixed endpoint;
- record the immediate Hyper-V and Docker object snapshots;
- apply the persistent Windows default-deny boundary and Docker containment;
- install and verify the fixed SYSTEM audit service;
- snapshot and merge only owned `.wslconfig` fields;
- stage and hash-pin the Linux runtime payload;
- install the manager's shared deny guard;
- configure every ordinary WSL distribution and stop it to reload interop and
  resolver settings;
- audit the effective scope while the Windows boundary remains closed.

Failure leaves the outer boundary closed where it was installed. An already
installed generation is inspected rather than overwritten; its original
snapshots remain the rollback source. A conflicting configuration is rejected.
Inspect `%ProgramData%\ClashOfRust\WslEgress` and the displayed recovery advice
before retrying a failed transaction.

## Connect and verify

**连接** runs the Windows scope audit, sends a short-lived attestation to the
Linux manager, creates the WireGuard namespaces and policy routes, and only then
enables the exact Windows endpoint. Enabling and verification are one
compensated transaction: a failed post-enable check closes the endpoint again.
An existing installation uses its protected profile, so reconnecting does not
require re-entering keys or selecting the original private profile.

Start also registers a fixed Task Scheduler action for the installation owner,
using an interactive user token with the highest granted privileges. Once a
minute, the task audits the effective Windows policy and running distributions
and refreshes the Linux assertion only on success. It never runs user WSL as
SYSTEM, starts a stopped distribution, opens an endpoint or extends the
five-minute proof lifetime. Renewal failures close the endpoint and retain a
failure receipt. Stop removes only the exactly matching owned task.

**断开 · 留保护** closes the Windows endpoint before stopping Linux transport
objects. The shared deny guard remains. Closing the GUI does not remove
protection.

The Test action requests UAC and runs real, bounded probes through the strict
launcher: IPv4 source and German geolocation, verified HTTPS, IPv6 refusal,
virtual interface visibility, hidden host mounts and a clean proxy environment.
A recent WireGuard handshake and successful probes are required to report a
working connection. DNS packet-path evidence, cold boot, sleep/resume, physical
network switch and controlled receiver-source evidence remain separate tests.
The UI preserves their NOT_RUN results.

## Logs and evidence

The UI displays bounded, redacted reports. Runtime state and snapshots live
under `%ProgramData%\ClashOfRust\WslEgress`; completion receipts live under
`%LOCALAPPDATA%\ClashOfRust\WslEgress\results`. Never attach private profiles,
WireGuard keys or raw packet captures to an upstream issue.

Cancelled UAC means the request was not sent. An operation timeout after the
request was sent means its outcome is unknown; refresh status before retrying.
The client does not kill an elevated firewall transaction on that timeout.
The displayed administrator command remains a manual recovery option.

## Updating an installed client

Updates stage the complete package, verify its file set and hashes, then create
a code-only write-ahead recovery journal. An active WSL endpoint is closed and
its Linux transport stopped before resources are replaced; active isolated
workloads block that operation. The existing Windows Network service and core
remain running. The canonical guardian image path is preserved, including an
installation using the separate Program Files helper package.

Windows code and the Linux payload are upgraded together. A failed update
restores only recorded package files and the prior Linux payload; it retains
the closed network boundary. The code recovery set is kept under the installed
application's `.package-update` directory. This recovery set contains no
private profiles or network snapshots. Reconnect through the updated client
after the update has committed. A live Windows core upgrade is a separate
operation and is not performed by this WSL update transaction.

Use only disposable runners for kernel tests:

```sh
CI=true COR_EGRESS_ISOLATED_CI=1 python3 \
  scripts/wsl-secure-egress/tests/linux_integration.py --execute-isolated
```

The suite labels real Windows/WSL, Hyper-V, cold boot and VPS geography
`NOT_RUN`; its PASS applies only to the isolated Linux data-plane model.

## Recover

Default **回退 · 保留保护** closes the endpoint and leaves the guard installed.
The destructive **恢复原网络…** action requires a separate confirmation and all
WSL distributions to be stopped. It then restores per-distribution files,
removes only the owned Linux table and namespaces, restores the exact
`.wslconfig` snapshot, removes Docker containment and restores the immediate
Hyper-V settings.

Restore refuses when an object has changed since this generation wrote it.
Never clear the whole firewall, reset WSL, delete distributions or overwrite
later edits to force recovery. Preserve the journal and recovery files for
manual review.

## Uninstall

Uninstall is allowed only after the journal reaches `restored` and the fixed
audit service matches its expected path. The installer does not remove Docker
or WSL data. If the check fails, uninstall stops and retains the recovery
tooling.

The audit service is accepted from either protected package location: the
helper package directory `%ProgramFiles%\Clash of Rust WSL` or an application
package installed under `%ProgramFiles%\Clash of Rust`. Any other image path,
account or command line keeps the service, the journal and the recovery
payload in place and refuses to uninstall. That refusal is intentional: it
means an unowned or relocated guardian owns the service name, so the removal
must be reviewed by hand instead of being forced.

Install applies the same ownership rule. When either canonical package already
registered the fixed service name, the installation adopts that image: it
verifies the account, the location and the automatic start mode, but it never
rewrites the command line of a live service. Only a foreign account or an image
outside `%ProgramFiles%` stops the installation before the host guard opens.

## VPS service

The dedicated VPS service under
`scripts/wsl-secure-egress/server` is separate from existing proxy and
subscription services. It changes only its own interface, nftables table,
private DNS process and the IPv4 forwarding sysctl. Deploy only after reviewing
the XUAN VPS reference and taking a current backup. A server operation is not
performed by the Windows client automatically.

On Windows, `scripts/wsl-secure-egress/prepare-vps.py` prepares a new private
profile and installs the reviewed server files over an existing SSH alias.
It requires preinstalled `wireguard-tools`, `dnsmasq-base`, iproute2 and nftables;
it does not install a global DNS service. Supply `--ssh-alias`,
`--identity-file`, `--distro`, and `--profile` explicitly, then add `--execute`
after reviewing the preview. Profiles must live in
`%LOCALAPPDATA%\ClashOfRust\WslEgress`, outside the repository.

Only the client's public key is sent to the VPS. The new private client key
remains in the protected local profile; the server generates its own key.
The VPS deployment records its service file hashes and exact added UFW rules
in `/var/lib/cor-wsl-egress/deployment.json`. An interrupted deployment retains
the pending client profile and the recovery journal. With the same SSH options,
`--rollback-server --execute` stops the dedicated service and removes only
matching owned UFW entries; private recovery files are retained.

## Existing WSL and local builds

The manager distro name comes from the private profile; it may be an existing
ordinary distro such as `Ubuntu-22.04`. Prepare its dependencies before the
default-deny cutover. Do not import or delete a distro just to match the
documentation's example name.

`linux/retire-legacy.py` is a separate, explicit migration tool for the known
XUAN WSL service names. It stops/disables those units, suppresses the old Docker
unit's unsafe privileged-container cleanup, and installs a final APT DIRECT
override. It retains original service files and credential-bearing proxy files.
Its metadata-only journal can be stored in the project's ignored
`ClashOfRust-network-backups` directory. Use the same journal with
`--rollback --execute` to restore only those service states and the owned
override. This is not a general Mihomo or firewall uninstaller.

For a local source build, build `clash-wsl-guardian.exe` from the reviewed
worktree, then run `Install-HostTools.ps1 -GuardianExe <built-exe>` first as a
preview. Its `-Execute` operation installs only the fixed guardian and reviewed
resources under Program Files, with administrators/SYSTEM write access and
ordinary-user read/execute access. It does not install another desktop client.
`-UpdatePreparedPackage` is limited to a prepared helper package with no
guardian service or active deployment journal; live upgrades require a separate
reviewed transaction. Use `Update-LiveWslPayload.ps1` for an installed
generation: close the transport with `Stop -Execute`, run the upgrade script as
administrator, confirm the owned-config audit, then reconnect with
`Start -Execute`.

Windows PowerShell 5.1 is tested separately: JSON array enumeration, WSL option
quoting, and UTF-8 stdin transfer differ from modern PowerShell/.NET.
