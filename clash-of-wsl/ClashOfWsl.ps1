#Requires -Version 5.1
<#
.SYNOPSIS
  Clash of WSL - install, manage and remove the WSL secure egress component.

.DESCRIPTION
  This is the single elevated entry point for the WSL half of Clash of Rust.
  It installs the reviewed payload, configures WSL networking, starts and stops
  the tunnel, reports status, runs the acceptance tests, and removes everything
  again. The Clash of Rust desktop client only calls this through its broker.

  Layout
    -Action Install      Install the component and the reviewed payload.
    -Action Configure    Apply the managed WSL network configuration.
    -Action Start        Open the tunnel (all WSL traffic leaves via VPS).
    -Action Stop         Close the tunnel but keep the deny protection.
    -Action Status       Report state without changing anything.
    -Action Test         Run the acceptance checks.
    -Action Uninstall    Remove the component and restore prior state.
    -Action Rollback     Restore the recorded prior network configuration.

  Every action except Status and Test previews by default. -Execute is required
  for a real change. Nothing here touches the CC Switch data directory.

.EXAMPLE
  Install-ClashOfWsl -Action Status
  Install-ClashOfWsl -Action Install -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Install', 'Configure', 'Start', 'Stop', 'Status', 'Test', 'Uninstall', 'Rollback')]
    [string]$Action,

    [ValidateSet('WireGuard', 'Tailscale')]
    [string]$Backend = 'WireGuard',

    [string]$ProfilePath,
    [string]$Distro,
    [switch]$Execute,
    [switch]$RestoreOriginalNetwork
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ComponentRoot = Join-Path $env:ProgramFiles 'Clash of Rust WSL'
$Resources = Join-Path $ComponentRoot 'resources\wsl-secure-egress'
$Module = Join-Path $Resources 'WslSecureEgress.psm1'

function Write-ToolResult {
    param([string]$Status, [string]$Message, [object]$Extra = $null)
    $document = [ordered]@{
        schema_version = 1
        component = 'clash-of-wsl'
        action = $Action
        outcome = $Status
        executed = $Execute.IsPresent
        backend = $Backend
        message = $Message
    }
    if ($null -ne $Extra) {
        foreach ($entry in $Extra.GetEnumerator()) { $document[$entry.Key] = $entry.Value }
    }
    $document | ConvertTo-Json -Depth 10 -Compress
}

function Assert-Installed {
    if (-not (Test-Path -LiteralPath $Resources -PathType Container)) {
        throw 'Clash of WSL is not installed in Program Files; run the elevated installer first.'
    }
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
        throw 'The reviewed WSL egress module is missing from the installation.'
    }
}

try {
    $requiresInstall = $Action -in @('Install', 'Configure', 'Start')
    if ($requiresInstall) { Assert-Installed }

    Import-Module $Module -Force -DisableNameChecking -ErrorAction Stop

    $parameters = @{
        Action = $Action
        Backend = $Backend
        ProfilePath = $ProfilePath
        Distro = $Distro
    }
    if ($PSBoundParameters.ContainsKey('Execute')) { $parameters['Execute'] = $Execute }
    if ($PSBoundParameters.ContainsKey('RestoreOriginalNetwork')) {
        $parameters['RestoreOriginalNetwork'] = $RestoreOriginalNetwork
    }

    $response = Invoke-WslEgressOperation @parameters

    $summary = [ordered]@{
        generation = $response.generation
        phase = $response.phase
        backend = $response.backend
        checks = $response.checks
        distributions = $response.distributions
    }
    switch ($response.outcome) {
        'succeeded' { Write-ToolResult 'succeeded' ($response.message) $summary; exit 0 }
        'blocked' { Write-ToolResult 'blocked' ($response.message) $summary; exit 2 }
        default { Write-ToolResult 'failed' ($response.message) $summary; exit 1 }
    }
} catch {
    # Exception text may contain private paths or configuration. Never echo it raw.
    Write-ToolResult 'failed' 'Clash of WSL could not complete the action; see the protected journal and log.'
    exit 1
}
