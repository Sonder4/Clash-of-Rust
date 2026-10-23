#Requires -Version 5.1
<#
.SYNOPSIS
  Starts the installed WSL egress transport and verifies the result.

.DESCRIPTION
  The journal reached installed_closed through the product's own routines:

    * Ubuntu-26.04 manager installed, phase Guarded, boot guard in /etc/wsl.conf
    * Ubuntu-22.04 configured as the ordinary distro
    * host Hyper-V VM firewall at default-deny with the endpoint rule disabled

  Start is the product's own command. It builds the WireGuard tunnel in the
  manager, re-audits the whole scope, and only then enables the endpoint rule.

  Verification after Start:
    1 product Doctor (read-only)
    2 structure audit - WSL must be default-deny with exactly one outbound
      allow rule, the VPS WireGuard endpoint. That is the no-leak proof: no
      WSL process has any other permit, so nothing can reach the internet
      except through the tunnel.
    3 product mandatory-connection baseline again
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$Package = 'C:\Program Files\Clash of Rust\resources\wsl-secure-egress\Manage-WslSecureEgress.ps1',
    [string]$ProfilePath = (Join-Path $env:LOCALAPPDATA 'ClashOfRust\WslEgress\profile.json'),
    [string]$LogDir = (Join-Path $env:TEMP 'clash-of-rust-wsl-egress')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Creator = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$EndpointRuleName = 'ClashOfRust-WslEgress-Endpoint'
$ModulePath = Join-Path (Split-Path $Package) 'WslSecureEgress.psm1'

function Write-LogLine([string]$Text) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Text
    $line | Out-File -FilePath (Join-Path $LogDir 'start.log') -Append -Encoding utf8
    Write-Host $line
}

function Write-Json([string]$Name, [string]$Content) {
    $path = Join-Path $LogDir ("{0}.json" -f $Name)
    [IO.File]::WriteAllText($path, $Content, (New-Object Text.UTF8Encoding($false)))
    Write-LogLine ("{0} -> {1} ({2} bytes)" -f $Name, $path, $Content.Length)
}

trap {
    Write-LogLine ("FAILED: " + $_.Exception.Message)
    Write-LogLine ("  line=" + $_.InvocationInfo.ScriptLineNumber)
    exit 1
}

$m = Import-Module $ModulePath -PassThru -Force

$state = & $m Read-WslEgressState
Write-LogLine ("phase = " + $state.phase + " manager = " + $state.manager_distro + " endpoint_enabled = " + $state.endpoint_enabled)
# 'blocked' is the product's own fail-closed latch after a failed renewal
# audit; the Linux manager is still Running, so Start is the correct retry.
if ([string]$state.phase -notin @('installed_closed','blocked','connected_unverified')) {
    throw ('Expected installed_closed, blocked or connected_unverified, found ' + $state.phase)
}

$baseline = [ordered]@{}
foreach ($entry in @([IO.File]::ReadAllText((Join-Path $env:LOCALAPPDATA 'ClashOfRust\WslEgress\protected-connections.json')) | ConvertFrom-Json)) {
    $hostName = ([uri]$entry.url).Host
    $baseline[$hostName] = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 25 $entry.url)
    Write-LogLine ("  baseline " + $hostName + " -> " + $baseline[$hostName])
    if ([int]$baseline[$hostName] -notin @($entry.accepted_statuses | ForEach-Object { [int]$_ })) {
        throw ('Baseline unhealthy before Start: ' + $hostName + '=' + $baseline[$hostName])
    }
}

if (-not $Execute) { Write-LogLine 'PLAN ONLY: would run Start and verify.'; exit 0 }

Write-LogLine '=== START ==='
$raw = & $Package -Action Start -Execute -ProfilePath $ProfilePath
$text = ($raw | Out-String).Trim()
Write-Json '10-start' $text
$start = $text | ConvertFrom-Json
Write-LogLine ("  outcome=" + $start.outcome + " phase=" + $start.phase)
if ($start.PSObject.Properties['message']) { Write-LogLine ("  message=" + $start.message) }
foreach ($check in @($start.checks)) { Write-LogLine ("  check " + $check.result + " " + $check.id) }
if ([string]$start.outcome -ne 'succeeded') { throw ('Start outcome was ' + $start.outcome) }

Write-LogLine '=== DOCTOR ==='
$raw = & $Package -Action Doctor
$text = ($raw | Out-String).Trim()
Write-Json '11-doctor' $text
$doctor = $text | ConvertFrom-Json
Write-LogLine ("  outcome=" + $doctor.outcome + " phase=" + $doctor.phase)
foreach ($check in @($doctor.checks)) { Write-LogLine ("  check " + $check.result + " " + $check.id) }

Write-LogLine '=== STRUCTURE AUDIT ==='
$effective = Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name $Creator -ErrorAction Stop
$struct = [ordered]@{
    enabled = [string]$effective.Enabled
    defaultInbound = [string]$effective.DefaultInboundAction
    defaultOutbound = [string]$effective.DefaultOutboundAction
    allowHostPolicyMerge = [string]$effective.AllowHostPolicyMerge
    loopbackEnabled = [string]$effective.LoopbackEnabled
}
Write-LogLine ("  effective: enabled=" + $struct.enabled + " in=" + $struct.defaultInbound + " out=" + $struct.defaultOutbound + " merge=" + $struct.allowHostPolicyMerge + " loopback=" + $struct.loopbackEnabled)
if ($struct.defaultOutbound -ne 'Block' -or $struct.defaultInbound -ne 'Block') {
    throw ('WSL is not default-deny (out=' + $struct.defaultOutbound + ', in=' + $struct.defaultInbound + ').')
}
$allows = @(Get-NetFirewallHyperVRule -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {
    [string]$_.Enabled -eq 'True' -and [string]$_.Direction -eq 'Outbound' -and
    [string]$_.Action -eq 'Allow' -and [string]$_.VMCreatorId -eq $Creator
})
$allowSummary = @($allows | ForEach-Object { [ordered]@{ name = [string]$_.Name
    remoteAddresses = @($_.RemoteAddresses); remotePorts = @($_.RemotePorts); protocol = [string]$_.Protocol } })
Write-Json '12-structure' (($struct | ConvertTo-Json -Depth 3) + "`n" + ($allowSummary | ConvertTo-Json -Depth 5))
Write-LogLine ("  enabled outbound allow rules = " + $allows.Count)
foreach ($a in $allows) { Write-LogLine ("    " + $a.Name + " -> " + (@($a.RemoteAddresses) -join ',') + ':' + (@($a.RemotePorts) -join ',') + ' ' + $a.Protocol) }
$foreign = @($allows | Where-Object { [string]$_.Name -ne $EndpointRuleName })
if ($foreign.Count -gt 0) {
    throw ('Structural audit failed: ' + $foreign.Count + ' outbound allow rule(s) other than the managed endpoint exist.')
}

Write-LogLine '=== FINAL BASELINE ==='
$final = [ordered]@{}
foreach ($entry in @([IO.File]::ReadAllText((Join-Path $env:LOCALAPPDATA 'ClashOfRust\WslEgress\protected-connections.json')) | ConvertFrom-Json)) {
    $hostName = ([uri]$entry.url).Host
    $final[$hostName] = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 25 $entry.url)
    Write-LogLine ("  final " + $hostName + " -> " + $final[$hostName])
    if ([int]$final[$hostName] -notin @($entry.accepted_statuses | ForEach-Object { [int]$_ })) {
        throw ('Final baseline unhealthy: ' + $hostName + '=' + $final[$hostName])
    }
}
Write-Json '13-final-baseline' ($final | ConvertTo-Json -Compress)

$endState = & $m Read-WslEgressState
Write-LogLine ("  final phase = " + $endState.phase + " endpoint_enabled = " + $endState.endpoint_enabled)
Write-LogLine 'START AND VERIFY COMPLETE'
exit 0
