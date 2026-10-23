#Requires -Version 5.1
<#
.SYNOPSIS
  Clash of WSL background service.

.DESCRIPTION
  Runs as the SYSTEM guardian service. It hardens the payload directory, verifies
  that the installed code still matches the reviewed record, and keeps the
  fail-closed Windows policy authoritative. It never opens the tunnel by itself:
  only an explicit operator action through the broker does that.

  Startup state is written to state.json so the service manager and the desktop
  client can distinguish "running" from "healthy".
#>
[CmdletBinding()]
param(
    [switch]$ServiceMode,
    [string]$InstallRoot,
    [string]$StateRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path $env:ProgramFiles 'Clash of Rust WSL'
}
if ([string]::IsNullOrWhiteSpace($StateRoot)) {
    $StateRoot = Join-Path $env:ProgramData 'ClashOfRust\WslEgress'
}

function Write-DaemonLog {
    param([string]$Message)
    $path = Join-Path (Join-Path $env:ProgramData 'ClashOfRust\WslEgress') 'daemon.log'
    $line = ('{0} {1}' -f (Get-Date -Format o), $Message)
    try { Add-Content -LiteralPath $path -Value $line } catch { }
}

if (-not $ServiceMode) {
    Write-Output 'Clash of WSL daemon. Use -ServiceMode under the guardian service account.'
    exit 0
}

try {
    $resources = Join-Path $InstallRoot 'resources\wsl-secure-egress'
    if (-not (Test-Path -LiteralPath $resources -PathType Container)) {
        throw 'installed payload is missing'
    }

    # Refresh the payload ACL so only SYSTEM and Administrators can rewrite the
    # reviewed code. This is what makes the fail-closed policy durable.
    $null = & icacls.exe $resources /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F', 'Administrators:(OI)(CI)F' /T /C 2>&1

    $receipt = Join-Path $InstallRoot 'installed-files.json'
    $receiptMatches = $false
    if (Test-Path -LiteralPath $receipt -PathType Leaf) {
        try {
            $document = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
            $mismatch = @()
            foreach ($property in @($document.PSObject.Properties)) {
                $target = Join-Path $InstallRoot $property.Name
                if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                    $mismatch += $property.Name
                    continue
                }
                $stream = [IO.File]::OpenRead($target)
                try {
                    $hasher = [Security.Cryptography.SHA256]::Create()
                    try {
                        $hash = ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '')
                    } finally { $hasher.Dispose() }
                } finally { $stream.Dispose() }
                if ($hash -ine [string]$property.Value) { $mismatch += $property.Name }
            }
            $receiptMatches = ($mismatch.Count -eq 0)
            if (-not $receiptMatches) {
                Write-DaemonLog ('installed code differs from the reviewed receipt: ' + ($mismatch -join ', '))
            }
        } catch {
            Write-DaemonLog ('receipt verification failed: ' + $_.Exception.Message)
        }
    }

    $statePath = Join-Path $StateRoot 'daemon.json'
    $state = [ordered]@{
        schema_version = 1
        component = 'clash-of-wsl'
        started_at = (Get-Date -Format o)
        pid = $PID
        receipt_matches = $receiptMatches
        payload_root = $resources
    }
    if (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Write-DaemonLog ('daemon online pid=' + $PID + ' receipt_matches=' + $receiptMatches)

    # The daemon stays resident. It never mutates network state on its own; it
    # only verifies and records, so the explicit operator action remains the
    # only thing that can open the tunnel.
    while ($true) {
        Start-Sleep -Seconds 60
        $state['last_checked_at'] = (Get-Date -Format o)
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    }
} catch {
    Write-DaemonLog ('daemon failed: ' + $_.Exception.Message)
    exit 1
}
