# Security model

## Scope

This feature protects outbound traffic from enrolled WSL2 distributions and
native Linux container forwarding inside those distributions. It keeps the
Windows host's adapters, IPv4/IPv6 connectivity, DNS and existing Clash/Mihomo
service outside the tunnel. Protected Linux workloads intentionally have
IPv4-only Internet access. WSL has no NEU, domestic-site, campus, LAN, or
Windows-host direct exceptions: every permitted Internet flow uses the fixed
VPS path, and IPv6 is denied rather than routed locally.

## Current host state and evidence

This section records operational status separately from the design guarantees:

| Item | Current evidence |
| --- | --- |
| Windows profile | Missing from the protected Windows target |
| Hyper-V endpoint | Matching UDP rule is present with `Enabled=False` |
| Broker | `failed_closed_requested` |
| Guardian service | `Running / Automatic`; not evidence of a tunnel |
| Ubuntu 22.04 | Running with a NAT-only link; DNS and HTTPS unavailable |
| Ubuntu 26.04 | Installed under `F:\WSL`; stopped |
| VPS IPv4, tunnel DNS, IPv6 egress | `NOT_RUN` for the current generation |
| OpenAI, Anthropic, DeepSeek | `NOT_RUN` for the current generation |
| Chrome, Codex CLI, Claude Code CLI, Claude Desktop | `NOT_RUN` or not installed |
| VPN loss, cold boot, reboot, network switch | `NOT_RUN` |

The 2026-10-18 VPS source, DNS and vendor observations are historical evidence
for those exact operations. The current missing profile and disabled endpoint
take precedence over that history.

## Enforcement layers

1. **Persistent Windows boundary.** Hyper-V Firewall is configured for the
   owned WSL VM creator with default inbound/outbound block, host-policy merge
   disabled and loopback disabled. The sole transport exception is an exact
   fixed IPv4/UDP endpoint tuple. This boundary is applied before the first
   Linux helper mutation.
2. **Docker containment.** A project-owned WFP provider adds persistent,
   executable-specific ALE blocks for the Docker host backend and its current
   descendant processes. Docker data is preserved. This is containment, not
   evidence that Docker has functional protected egress.
3. **Linux shared guard.** The manager creates an owned nftables table with
   default-drop output and forward chains. It opens only the encrypted endpoint
   path and the controlled business-veth path. Ordinary shared-namespace WSL
   traffic and registered native bridge sources are admitted only by source,
   interface and direction. No global established/related bypass exists.
4. **Tunnel gateway.** A dedicated transport namespace owns the encrypted
   WireGuard socket. The WireGuard interface is moved to a workload gateway
   namespace whose remaining interfaces are the business veth and loopback.
   Business traffic is source-NATed to the tunnel address. IPv6 is dropped.
   Port 53 is restricted to the fixed tunnel resolver.
5. **Application isolation.** `secure-egress run` enters the gateway network
   namespace and creates new user, mount, PID, IPC and UTS views; a separate
   cgroup view is requested when the kernel permits it. It
   drops UID/GID privileges, clears supplementary groups and capabilities,
   sets `no_new_privs`, hides Windows mounts and host sockets, and refuses
   inherited directory/socket file descriptors.

6. **Name resolution.** Managed distributions set `generateResolvConf=false`
   and `generateHosts=false`. `/etc/resolv.conf` contains only the fixed tunnel
   resolver, and `/etc/hosts` is replaced with a loopback-only file containing
   the distribution's own hostname. The automatically generated Docker/Windows
   host aliases (`host.docker.internal`, `gateway.docker.internal`,
   `kubernetes.docker.internal`) are removed, so an application cannot resolve
   a Windows or Docker host address from its local name database. The launcher
   uses an even smaller `/etc/hosts` containing only `127.0.0.1 localhost`.

The Windows boundary remains the outer fail-closed control. A Linux manager
failure, transport loss, GUI exit or audit-service failure does not enable
direct Windows networking for WSL.

WSL may retain its shared `WSLInterop` binary handler even when the distro file
sets `interop.enabled=false`. The manager therefore verifies the handler is
the expected `/init` PE registration, records its prior state, and disables
that exact handler during installation and boot guard loading. Unknown
handlers are preserved and block the operation. Restoring the original
registration requires the matching journal and unchanged handler state.

## Boot and reconnect

The Windows policy is persistent. The Linux manager installs a boot hook that
recreates the owned default-deny table after a new boot but never opens the
transport. Start requires a fresh five-minute Windows attestation derived from
the current distribution set, per-distribution configuration audit, effective
Hyper-V policy, `.wslconfig` values and Docker containment.

The installed owner may authorize a fixed, protected scheduled action during
Start. That action uses the owner's interactive elevated token and repeats the
effective audit before renewing the root-private Linux assertion. It does not
run under SYSTEM or start stopped distributions. A failed renewal withdraws
the endpoint permit and records the failure. New isolated launches still reject
proof older than five minutes; a renewal is not permission to open a route.

The attestation is an orchestration assertion, not packet evidence. Cold boot,
network switching, sleep/resume, real WSL coverage and real VPS geography remain
separate acceptance gates until executed.

## Administrator channel

The ordinary client requests UAC only for explicit management actions and the
runtime test. It executes a fixed installed helper using `runas`. Arguments
travel over a first-instance local named pipe with a caller-specific ACL, not
over the UAC command line. Each peer verifies the other process ID, user and
session; the client also verifies the returned process is elevated. The helper
requires an administrator-owned Program Files resource tree without ordinary
user write access. Requests use an argument allowlist and bounded JSON frames.
Cancellation sends no management request. A timeout after dispatch is an
unknown outcome that requires inspection, not an automatic rollback or retry.

## Tailscale and WireGuard

Tailscale was evaluated, but its control-plane and DERP addresses can change
and a heartbeat, GUI ordering or asynchronous exit-node callback cannot prove
that the outer boundary exists before Linux networking starts. Windows
therefore refuses Tailscale install and start. Linux accepts a Tailscale
profile only as a closed deny guard: `start` refuses that backend, so no
transport is created in this branch.

The supported backend is WireGuard with a fixed numeric IPv4 endpoint, UDP port
and peer public key. DNS bootstrap does not occur. Runtime failure does not
switch backends, broaden the endpoint rule or restore direct access.

## Threat and verification boundaries

- A Windows administrator or Linux root can replace the enforcement components
  and is outside the threat model.
- A root or privileged workload that can modify its own namespace is outside
  the launcher boundary.
- An ordinary distro shell retains visible `/mnt/*`; only the strict launcher
  creates a private mount view without those host mounts.
- Interop being disabled prevents normal Windows executable invocation. It does
  not by itself hide every host file or prove that an application cannot infer
  local metadata.
- `protected-connections.json` is a required operator prerequisite for the
  Windows mutation path. Its absence blocks the deployment; it is not a default
  resource.
- Network reachability is not proof of the VPS source. A provider test is
  accepted only after the current generation proves the public IPv4 and tunnel
  path. Provider login, authentication and inference remain separate claims.
- The unified workspace-tool installer cannot change packages until it observes
  the configured VPS IPv4 from inside the strict launcher. A source-code
  review or offline test does not establish that the gate has run on the live
  tunnel.
- A hostile Windows administrator or Linux root can replace the enforcement
  components and is outside the protected-user threat model.
- A privileged workload that can change its networking or namespace is outside
  the launcher boundary.

## Trust assumptions and exclusions
- Docker Desktop receives network containment only until its independent host
  backend adapter is implemented and verified.
- DoH/DoT by applications is carried through the tunnel; only port-53 resolver
  use is pinned. No claim is made that encrypted DNS is forced to the VPS
  resolver.
- IPv6-only destinations are unsupported.
- Physical fault injection on the user's live network is prohibited. Fault
  tests run only in disposable CI namespaces or with verified independent
  access.
- No component may inspect or modify `C:\Users\xuan\.cc-switch`.

## Secret handling

The private profile reaches Linux through stdin. WireGuard keys are written
atomically to root-owned `0600` files. Command arguments, stderr, raw endpoint
values, controller credentials and full subscription URLs are excluded from
public reports. A payload manifest is an integrity check, not a code signature.
