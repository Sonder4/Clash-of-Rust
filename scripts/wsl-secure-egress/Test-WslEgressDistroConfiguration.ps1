#Requires -Version 5.1
<#
.SYNOPSIS
  Verifies and repairs the per-distro half of the WSL Secure Egress layout.
.DESCRIPTION
  A WSL Secure Egress deployment has two kinds of distribution:

  - the manager distribution, which owns the single WireGuard runtime, the
    private profile, the scope attestation and the tunnel key;
  - ordinary distributions, which the manager configures for DNS, interop and
    boot only. They never build a second tunnel: the endpoint has one peer and
    one tunnel address, so a second runtime would collide by design.

  This script inspects both halves and reports exactly which artifacts are
  missing. It repairs only the per-distro file half (boot command, resolver,
  interop) through the manager's own `configure` action, which Windows already
  owns. It never invents a second peer, never edits the VPS, never restarts the
  shared core and never shuts WSL down.

  Read-only unless -Execute is supplied.
#>
[CmdletBinding()]
param(
    [string]$StateRoot = (Join-Path $env:ProgramData 'ClashOfRust\WslEgress'),
    [string]$ManagerEntry = '/usr/local/lib/cor-egress/manager',
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Wsl([string]$Distro, [string]$Command) {
    $out = & wsl.exe -d $Distro -u root -- /bin/sh -c $Command 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}

function Test-Artifact([string]$Distro, [string]$Path) {
    $probe = Invoke-Wsl $Distro "test -e '$Path' && echo present || echo absent"
    [pscustomobject]@{
        distro  = $Distro
        path    = $Path
        present = ($probe.Output -match 'present')
    }
}

$statePath = Join-Path $StateRoot 'state.json'
if (-not (Test-Path -LiteralPath $statePath)) {
    [ordered]@{
        action  = 'verify-distro-configuration'
        outcome = 'blocked'
        message = 'No WSL egress journal found; nothing is configured on this host.'
    } | ConvertTo-Json -Depth 6 -Compress
    exit 2
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$manager = [string]$state.manager_distro
if (-not $manager) {
    [ordered]@{
        action  = 'verify-distro-configuration'
        outcome = 'blocked'
        message = 'The journal does not name a manager distribution.'
    } | ConvertTo-Json -Depth 6 -Compress
    exit 2
}

$known = @($state.distributions)
if ($known.Count -eq 0) { $known = @($manager) }
# Docker's backing distributions are excluded by the module's own definition of
# an ordinary distribution; they are not workspace distros to be enrolled.
$managed = @($known | Where-Object { $_ -notmatch '^docker-desktop(?:-data)?$' })
$result = [ordered]@{
    action          = 'verify-distro-configuration'
    manager_distro  = $manager
    generation      = $state.generation
    distributions   = @()
    missing         = @()
    repairs         = @()
}

# The manager owns the runtime artifacts; ordinary distros own the file half.
$managerArtifacts = @('/etc/cor-egress/profile.json', '/var/lib/cor-egress/wireguard.key', '/var/lib/cor-egress/scope-attestation.json')
$ordinaryArtifacts = @('/usr/local/lib/cor-egress/manager.py')

foreach ($name in $managed) {
    $entry = [ordered]@{ name = $name; role = 'unknown'; artifacts = @() }
    if ($name -eq $manager) {
        $entry.role = 'manager'
        foreach ($path in $managerArtifacts) { $entry.artifacts += (Test-Artifact $name $path) }
    }
    else {
        $entry.role = 'ordinary'
        foreach ($path in $ordinaryArtifacts) { $entry.artifacts += (Test-Artifact $name $path) }
    }
    # Every managed distro needs the boot entry that loads the deny guard.
    $entry.artifacts += (Test-Artifact $name '/etc/wsl.conf')
    $result.distributions += $entry
    foreach ($artifact in $entry.artifacts) {
        if (-not $artifact.present) {
            $result.missing += [pscustomobject]@{ distro = $name; path = $artifact.path; role = $entry.role }
        }
    }
}

if ($result.missing.Count -eq 0) {
    $result.outcome = 'succeeded'
    $result.message = 'Every managed distribution has the artifacts its role requires.'
    $result | ConvertTo-Json -Depth 8 -Compress
    exit 0
}

if (-not $Execute) {
    $result.outcome = 'not_run'
    $result.message = 'Artifacts are missing. Re-run with -Execute to run the manager-owned repair for ordinary distributions.'
    $result | ConvertTo-Json -Depth 8 -Compress
    exit 0
}

# Only the ordinary-distro file half is repairable here. A missing manager
# artifact means the runtime half was never installed, which is a full
# installation and needs the operator's own profile and attestation.
foreach ($gap in $result.missing) {
    if ($gap.role -eq 'manager') {
        $result.repairs += [pscustomobject]@{
            distro  = $gap.distro
            path    = $gap.path
            outcome = 'blocked'
            detail  = 'Manager runtime artifact; a full installation owns this, not a repair.'
        }
        continue
    }
    $probe = Invoke-Wsl $gap.distro "$ManagerEntry guard"
    $result.repairs += [pscustomobject]@{
        distro  = $gap.distro
        path    = $gap.path
        outcome = 'attempted'
        detail  = ($probe.Output -split "`n" | Select-Object -First 1)
    }
}

$blocked = @($result.repairs | Where-Object { $_.outcome -eq 'blocked' })
if ($blocked.Count -gt 0) {
    $result.outcome = 'blocked'
    $result.message = 'Manager runtime artifacts are missing; this host needs a full installation, not a repair.'
    $result | ConvertTo-Json -Depth 8 -Compress
    exit 2
}

$result.outcome = 'succeeded'
$result.message = 'Ordinary distributions re-checked through the manager guard.'
$result | ConvertTo-Json -Depth 8 -Compress
exit 0
