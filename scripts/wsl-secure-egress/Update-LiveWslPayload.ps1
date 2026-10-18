#Requires -Version 5.1
<#
.SYNOPSIS
  Reviewed live payload upgrade for one installed WSL Secure Egress generation.
.DESCRIPTION
  Preview by default. With -Execute, the transport must already be closed with
  -Action Stop; this script stages the current reviewed Linux payload, performs
  the installer's atomic reviewed upgrade, reruns manager repair-config, and
  audits the owned WSL configuration. It never enables the Windows endpoint and
  never touches WSL distributions other than the recorded manager distribution.
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$Distro,
    [string]$StatusPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Read-PayloadUpdateStatus([string]$Path) {
    if (-not $Path) { return $null }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $record = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($record.PSObject.Properties['stage'] -and [string]$record.stage) {
            return [string]$record.stage
        }
    } catch {
        return $null
    }
    return $null
}
function Write-PayloadUpdateFailure([string]$Stage, [System.Management.Automation.ErrorRecord]$ErrorRecord) {
    [ordered]@{
        schema_version = 1
        action = 'update-live-payload'
        outcome = 'failed'
        stage = $Stage
        error_type = $ErrorRecord.Exception.GetType().FullName
        error_id = [string]$ErrorRecord.FullyQualifiedErrorId
        line = [int]$ErrorRecord.InvocationInfo.ScriptLineNumber
        message = 'Payload upgrade failed; endpoint remains closed and the journal is retained for review.'
    } | ConvertTo-Json -Compress
}
if (-not $Execute) {
    [ordered]@{
        schema_version = 1
        action = 'update-live-payload'
        outcome = 'not_run'
        message = 'Preview only. Run Stop -Execute first, then rerun this script as administrator with -Execute.'
        opens_endpoint = $false
    } | ConvertTo-Json -Compress
    exit 0
}
$module = Import-Module (Join-Path $PSScriptRoot 'WslSecureEgress.psm1') -Force -PassThru -DisableNameChecking
$progress = [pscustomobject]@{ stage = 'preflight' }
try {
    $result = & $module {
        param($RequestedDistro, $Progress, $StatusFile)
        $setStage = {
            param([string]$Stage)
            $Progress.stage = $Stage
            if ($StatusFile) {
                [ordered]@{ stage = $Stage } | ConvertTo-Json -Compress |
                    Set-Content -LiteralPath $StatusFile -Encoding ASCII -ErrorAction Stop
            }
        }
        if (-not (Test-WslEgressAdministrator)) {
            throw 'Administrator required for the reviewed payload upgrade.'
        }
        $sid = Assert-WslEgressUser
        $state = Read-WslEgressState
        if (-not $state) { throw 'Not installed.' }
        if ($state.owner_sid -ne $sid) { throw 'State belongs to a different Windows user.' }
        if ($state.phase -notin @('installed_closed','failed_closed_requested')) {
            throw 'Run the Stop action first; the reviewed payload upgrade requires a verified closed phase.'
        }
        if (-not (Get-WslEgressClosureAudit $state).confirmed) {
            throw 'Endpoint closure is not confirmed; payload upgrade refused.'
        }
        $distro = if ($RequestedDistro) { [string]$RequestedDistro } else { [string]$state.manager_distro }
        if ($distro -ne [string]$state.manager_distro) {
            throw 'Payload upgrade must target the journaled manager distribution.'
        }
        $running = @(Get-WslEgressRunningDistributions)
        if ($running -notcontains $distro) {
            # Starting this installed distro executes only its fixed boot guard.
            # The Windows endpoint is already verified closed, so this cannot
            # create a fallback egress path.
            $started = Invoke-WslEgressProcess -Arguments @(
                '--distribution',$distro,'--user','root','--exec',
                '/usr/bin/true') -TimeoutSeconds 45
            if ($started.ExitCode -ne 0) {
                throw 'The manager distribution did not start for the reviewed payload upgrade.'
            }
            $running = @(Get-WslEgressRunningDistributions)
            if ($running -notcontains $distro) {
                throw 'Start the manager distribution before the reviewed payload upgrade.'
            }
        }
        & $setStage 'payload_stage'
        Install-WslEgressPayload $state $distro -ReviewedUpgrade
        & $setStage 'manager_repair'
        $repair = Invoke-WslEgressLinux $state 'repair-config'
        if ($repair.outcome -ne 'succeeded') {
            throw 'Manager repair-config did not succeed after the payload upgrade.'
        }
        & $setStage 'configuration_audit'
        $audit = Invoke-WslEgressLinux $state 'audit-config'
        if ($audit.outcome -ne 'succeeded' -or
            -not $audit.facts.owned_config_matches -or
            -not $audit.facts.interop_runtime_disabled) {
            throw 'Post-upgrade owned-config audit failed.'
        }
        $state.phase = 'installed_closed'
        Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
        $result = [ordered]@{
            schema_version = 1
            action = 'update-live-payload'
            outcome = 'succeeded'
            generation = [long]$state.generation
            distro = $distro
            phase = 'installed_closed'
            owned_config_matches = [bool]$audit.facts.owned_config_matches
            interop_runtime_disabled = [bool]$audit.facts.interop_runtime_disabled
            endpoint_enabled = $false
            message = 'Reviewed payload and owned WSL configuration upgraded while the endpoint remained closed.'
        }
        $receipt = Join-Path $env:LOCALAPPDATA ('ClashOfRust\WslEgress\results\payload-upgrade-' +
            (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.json')
        Save-WslEgressJson $result $receipt
        $result['receipt'] = $receipt
        $result
    } $Distro $progress $StatusPath
    $result | ConvertTo-Json -Depth 8 -Compress
} catch {
    # Module scope cannot reliably assign properties on a caller-owned object
    # under every host. The optional status file provides the durable boundary;
    # retain the in-memory object too for direct/imported-script invocation.
    $failureStage = Read-PayloadUpdateStatus $StatusPath
    if (-not $failureStage) { $failureStage = [string]$progress.stage }
    Write-PayloadUpdateFailure $failureStage $_
    exit 1
}
