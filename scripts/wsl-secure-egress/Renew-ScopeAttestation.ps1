#Requires -Version 5.1
# Fixed, same-user elevated scheduled action. Never run as SYSTEM.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WslSecureEgress.psm1') -Force -DisableNameChecking
try {
    $result = Invoke-WslEgressScopeRenewal
    if ($result -and $result.outcome -eq 'failed') { exit 1 }
    exit 0
} catch { exit 1 }
