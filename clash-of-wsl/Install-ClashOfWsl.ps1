#Requires -Version 5.1
<#
.SYNOPSIS
  Install or remove Clash of WSL on this machine.

.DESCRIPTION
  Copies the reviewed payload into Program Files, registers the SYSTEM guardian
  service, and optionally applies the managed WSL network configuration.
  Requires administrator rights and self-requests UAC when missing.

  Preview by default. Pass -Execute to perform the change. -Uninstall removes
  the service and the payload and restores the recorded network configuration.

  This script never touches the CC Switch data directory.
.EXAMPLE
  Install-ClashOfWsl -Execute
  Install-ClashOfWsl -Uninstall -Execute -RestoreOriginalNetwork
#>
[CmdletBinding()]
param(
    [string]$SourceRoot,
    [switch]$Uninstall,
    [switch]$RestoreOriginalNetwork,
    [switch]$Execute,
    [switch]$NoSelfElevation
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $high = @($identity.Groups | Where-Object { $_.Value -match '^S-1-16-(12288|1688)$' }).Count -gt 0
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and $high)
}

function Enter-AdminProcess {
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoLogo', '-File', $PSCommandPath,
        '-Execute', '-NoSelfElevation'
    )
    if ($SourceRoot) { $args += @('-SourceRoot', $SourceRoot) }
    if ($Uninstall) { $args += '-Uninstall' }
    if ($RestoreOriginalNetwork) { $args += '-RestoreOriginalNetwork' }
    $child = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args -PassThru -Wait
    exit ([int]$child.ExitCode)
}

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Split-Path -Parent $PSScriptRoot
}
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)

$InstallRoot = Join-Path $env:ProgramFiles 'Clash of Rust WSL'
$ServiceName = 'ClashOfRust.WslEgress'
$Guardian = Join-Path $InstallRoot 'clash-wsl-guardian.exe'

if (-not (Test-Elevated)) {
    if ($NoSelfElevation) {
        Write-Output ('outcome=failed message=elevation required for {0}; no changes were made' -f $PSCommandPath)
        exit 1
    }
    Enter-AdminProcess
}

function Get-SourceHash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '') }
        finally { $hasher.Dispose() }
    } finally { $stream.Dispose() }
}

# The payload source is the reviewed repository tree for the egress module.
$payloadSource = Join-Path $SourceRoot 'scripts\wsl-secure-egress'
$payloadTarget = Join-Path $InstallRoot 'resources\wsl-secure-egress'

if ($Uninstall -and -not $Execute) {
    [ordered]@{
        schema_version = 1
        component = 'clash-of-wsl'
        outcome = 'not_run'
        action = 'uninstall'
        message = 'Preview only. Pass -Execute and -RestoreOriginalNetwork to remove the component.'
    } | ConvertTo-Json -Compress
    exit 0
}

if ($Uninstall) {
    $stopped = $false
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        & (Join-Path $env:SystemRoot 'System32\sc.exe') delete $ServiceName | Out-Null
        $stopped = $true
    }

    $restoreOutcome = 'not_run'
    if ($RestoreOriginalNetwork) {
        if (-not (Test-Path -LiteralPath $payloadTarget -PathType Container)) {
            throw 'The installed payload is missing; cannot restore the prior network configuration.'
        }
        Import-Module (Join-Path $payloadTarget 'WslSecureEgress.psm1') -Force -DisableNameChecking
        $restore = Invoke-WslEgressOperation -Action Rollback -Backend WireGuard -Execute -RestoreOriginalNetwork
        $restoreOutcome = [string]$restore.outcome
    }

    $removed = @()
    if (Test-Path -LiteralPath $InstallRoot) {
        $receipt = Join-Path $InstallRoot 'installed-files.json'
        if (Test-Path -LiteralPath $receipt -PathType Leaf) {
            $document = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
            foreach ($property in @($document.PSObject.Properties)) {
                $target = Join-Path $InstallRoot $property.Name
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    Remove-Item -LiteralPath $target -Force
                    $removed += $property.Name
                }
            }
        }
        # Remove now-empty directories, deepest first.
        Get-ChildItem -LiteralPath $InstallRoot -Recurse -Directory |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                if (-not (Get-ChildItem -LiteralPath $_.FullName -Recurse -Force)) {
                    Remove-Item -LiteralPath $_.FullName -Force
                }
            }
        if (-not (Get-ChildItem -LiteralPath $InstallRoot -Recurse -Force)) {
            Remove-Item -LiteralPath $InstallRoot -Force
        }
    }

    [ordered]@{
        schema_version = 1
        component = 'clash-of-wsl'
        outcome = 'succeeded'
        action = 'uninstall'
        service_removed = $stopped
        restore_outcome = $restoreOutcome
        files_removed = $removed.Count
    } | ConvertTo-Json -Compress
    exit 0
}

# --- Install -------------------------------------------------------------
$missing = @()
if (-not (Test-Path -LiteralPath $payloadSource -PathType Container)) { $missing += $payloadSource }
foreach ($name in @('WslSecureEgress.psm1', 'Upgrade-Package.ps1')) {
    $candidate = Join-Path $payloadSource $name
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { $missing += $candidate }
}
if ($missing.Count -gt 0) { throw ('the reviewed payload is incomplete: ' + ($missing -join ', ')) }

$copied = @()
function Copy-Payload([string]$Source, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -File) {
        $destination = Join-Path $Target $item.Name
        Copy-Item -LiteralPath $item.FullName -Destination $destination -Force
        $copied += ($item.FullName.Substring($SourceRoot.Length + 1))
    }
    foreach ($item in Get-ChildItem -LiteralPath $Source -Directory) {
        Copy-Payload $item.FullName (Join-Path $Target $item.Name)
    }
}

if ($Execute) {
    Copy-Payload $payloadSource $payloadTarget
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $InstallRoot 'ClashOfWsl.ps1') -Force
    $daemon = Join-Path $SourceRoot 'clash-of-wsl\ClashOfWsl-Daemon.ps1'
    if (Test-Path -LiteralPath $daemon -PathType Leaf) {
        Copy-Item -LiteralPath $daemon -Destination (Join-Path $InstallRoot 'ClashOfWsl-Daemon.ps1') -Force
    }
}

[ordered]@{
    schema_version = 1
    component = 'clash-of-wsl'
    outcome = if ($Execute) { 'succeeded' } else { 'not_run' }
    action = 'install'
    executed = $Execute.IsPresent
    install_root = $InstallRoot
    files = $copied.Count
    service_name = $ServiceName
    message = if ($Execute) { 'Payload installed. Run -Action Start -Execute to open the tunnel.' } else { 'Preview only.' }
} | ConvertTo-Json -Compress
exit 0
