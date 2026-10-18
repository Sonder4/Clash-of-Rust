# WSL Changes

This document records the Linux-side changes in the WSL Secure Egress feature.
The implementation is a standalone root-owned helper under
`scripts/wsl-secure-egress/linux`; Clash of Rust invokes it through the Windows
broker but does not embed the data plane in the desktop process.

## Runtime

- WSL remains in NAT mode. The helper does not depend on mirrored networking,
  host DNS tunneling, NEU routing, domestic-site exceptions or Windows-host
  proxy delegation.
- The manager creates a transport namespace for the WireGuard UDP socket and a
  gateway namespace for `wg0`, the business veth and loopback. The shared WSL
  `eth0` is retained and is never moved.
- IPv4 business traffic is routed through the gateway and SNATed to the fixed
  tunnel address. IPv6 is denied for protected traffic.
- DNS is pinned to the fixed tunnel resolver. Managed distributions disable
  generated `resolv.conf`, generated hosts and WSL PE interop. `/etc/hosts`
  contains loopback and the local hostname only.
- `secure-egress run` adds a workload network, mount, PID, IPC, UTS and user
  namespace. It drops capabilities and supplementary groups, hides Windows
  mounts and host sockets, and blocks nested namespace creation through seccomp.

## nftables boot guard

Every configured distribution writes the same root-owned boot command. The
command establishes a canonical `inet cor_egress_guard` default-drop table
before reading the private profile or creating transport interfaces.

- `static` is the exact two-chain output/forward IPv4/IPv6 deny table.
- `manager` is retained only when the local private journal and table hash prove
  ownership and the manager structure is valid.
- `unknown` is never deleted or overwritten. A separate
  `cor_egress_boot_emergency` table is installed at a higher priority and the
  operation reports `blocked`.
- Concurrent first starts re-read the table after a create race and accept only
  an exact static or verified manager table.
- Manager replacement uses one nft transaction containing delete and create, so
  the static guard is not intentionally removed before the manager guard exists.

The WSL boot hook is not a substitute for the Windows Hyper-V boundary. Windows
retains default-deny policy and permits only the configured endpoint tuple.
Because that exception can survive a VM restart, a non-manager distribution
must install the shared boot guard even when it is the first distribution to
start. This is PR review comment 4's repair; it does not depend on access to the
manager's private profile. Cold boot, reboot, network-switch, sleep/resume and
receiver-geography acceptance remain separate tests.

## Lifecycle and recovery

`install`, `configure`, `guard`, `start`, `stop`, `run`, `test`, `attest`,
`rollback` and `restore-config` are explicit actions. The generation number,
root-private journal and content hashes prevent stale actions from reusing
another installation. Tailscale profiles may be stored as a closed guard, but
strict `start` remains blocked; fixed-endpoint WireGuard is the supported
backend.

The Linux helper never deletes an unknown nft table, global ruleset or
distribution. It reports `succeeded`, `blocked` or `failed`; no local test
result is elevated to an end-to-end production claim.

## VPS preparation repair

PR review comment 5 concerns the separate `prepare-vps.py` provisioning tool.
A newly copied systemd unit can legitimately return inactive (exit 3) before
`enable --now`. Its pre-start activity query now reads `subprocess.run`'s
return code without treating inactivity as a fatal provisioning error. The
18-test provisioning suite passed with an inactive-unit regression fixture;
this repair pass did not deploy or restart any real VPS service.

## Latest verification boundary

On 2026-10-18 the expanded Linux static suite passed 73 tests with two
platform skips. A fresh Linux-native source copy also passed 89 isolated
integration cases, including kernel loading of closed and open guards with one
and multiple business sources. This uses disposable namespaces and a fixture
receiver; it does not test the actual German VPS.

The synchronized installed payload was exercised on Ubuntu-22.04 with a
controlled Stop→Start transaction. Stop returned `succeeded/Guarded`; the
first subsequent Start returned `succeeded/Running` and recreated both owned
namespaces. Three independent IPv4 probes from the isolated launcher returned
the German VPS address `62.84.164.122`. The isolated view contained only
`lo`, `cor-bg0` and `wg0`, used `nameserver 10.77.0.1`, and had an unreachable
IPv6 default route. OpenAI, Anthropic and DeepSeek unauthenticated endpoint
probes returned 401, 405 and 401 respectively, proving reachability but not
authentication or inference.

The Claude Code CLI (`2.1.302`) ran inside the isolated launcher without proxy
environment variables. Claude Desktop remains a separate compatibility issue:
its old Windows/desktop proxy configuration is not part of this Linux data
plane, and the Ubuntu-22.04 native binding requires GLIBC 2.39 while the
distro provides 2.35. Do not replace system glibc; use a compatible distro for
the desktop package. Earlier results remain in [TEST_STATUS.md](TEST_STATUS.md),
tied to their own revision and scope. Cold boot, reboot, physical network
switch, sleep/resume and independent geographic corroboration remain separate
tests.
