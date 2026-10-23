#Requires -Version 5.1
<#
.SYNOPSIS
  Restores the WSL Secure Egress transport once, at user logon.

.DESCRIPTION
  The product restores its fail-closed guard automatically through each
  distro's /etc/wsl.conf boot hook, but it never starts the tunnel by itself:
  Start is a Windows-side, elevated action. After a host reboot or logon the
  tunnel is therefore down until someone runs it.

  This script closes that gap, once per logon:

    1 refuse to run if the product package or the journal is missing
    2 decide whether the tunnel is really up from three live facts, never from
       the journal alone: the journal phase, the effective Hyper-V endpoint
       rule, and the Linux manager reporting Running
    3 if it is not up, start every managed ordinary distribution (the product's
       renewal audit closes the endpoint unless all of them are running)
    4 run the product's own Start and record its response

  The Windows journal is deliberately NOT trusted for the "already up" check:
  after a WSL restart it still says connected_unverified while the Linux side
  is back at Guarded with no namespaces.

  It never edits the guard, the profile or the Hyper-V policy, and it never
  bypasses Start's own audits.

  Triggered by the 'ClashOfRust-WslEgress-Autostart' scheduled task
  (AtLogOn, highest privileges, 30 s delay).
#>
[CmdletBinding()]
param(
    [string]$Package = 'C:\Program Files\Clash of Rust\resources\wsl-secure-egress\Manage-WslSecureEgress.ps1',
    [string]$LogDir = 'C:\ProgramData\ClashOfRust\WslEgress-Autostart'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogFile = Join-Path $LogDir 'autostart.log'
$EndpointRuleName = 'ClashOfRust-WslEgress-Endpoint'
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log([string]$Text) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    $line | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Get-EndpointRuleEnabled {
    $rules = @(Get-NetFirewallHyperVRule -PolicyStore ActiveStore -Name $EndpointRuleName -ErrorAction SilentlyContinue)
    ($rules.Count -eq 1 -and [string]$rules[0].Enabled -eq 'True')
}

try {
    Write-Log 'autostart begin'
    $ModulePath = Join-Path (Split-Path $Package) 'WslSecureEgress.psm1'
    if (-not (Test-Path -LiteralPath $Package -PathType Leaf)) { Write-Log 'product package missing; nothing to do'; exit 1 }
    if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) { Write-Log 'product module missing; nothing to do'; exit 1 }

    $m = Import-Module $ModulePath -PassThru -Force
    $state = & $m Read-WslEgressState
    if ($null -eq $state) { Write-Log 'no journal; the product is not installed, nothing to restore'; exit 0 }

    $phase = [string]$state.phase
    $journalEnabled = [bool]$state.endpoint_enabled
    $ruleEnabled = Get-EndpointRuleEnabled
    Write-Log ("journal phase=" + $phase + " endpoint_enabled=" + $journalEnabled +
        " effective_rule_enabled=" + $ruleEnabled + " manager=" + $state.manager_distro)

    if ($phase -eq 'restored') {
        Write-Log 'journal is restored; the product is not installed, leaving it untouched'
        exit 0
    }

    # The journal alone is not proof: after a WSL restart it still reports the
    # previous connected generation. Require the live manager runtime too.
    $managerRunning = $false
    if ($phase -in @('connected_unverified', 'verified') -and $journalEnabled -and $ruleEnabled) {
        try {
            $status = & $m Invoke-WslEgressLinux $state 'status'
            $managerRunning = ($status.outcome -eq 'succeeded' -and [string]$status.phase -eq 'Running')
            Write-Log ("manager status outcome=" + $status.outcome + " phase=" + $status.phase)
        } catch {
            Write-Log ('manager status check failed: ' + $_.Exception.Message)
        }
    }

    if ($managerRunning) {
        Write-Log 'tunnel verified open (journal + endpoint rule + manager Running); skipping'
        exit 0
    }

    # The renewal audit requires every managed ordinary distribution to be
    # running. Starting them while the guard is closed is safe: each boot hook
    # classifies the closed table and does not install an emergency deny.
    $distributions = @(& $m Get-WslEgressDistributions)
    foreach ($item in $distributions) {
        $name = [string]$item.name
        if ($name -match '^docker-desktop') { continue }
        if ($name -eq [string]$state.manager_distro) { continue }
        Write-Log ("starting ordinary distribution: " + $name)
        $null = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wsl.exe') `
            -ArgumentList @('-d', $name, '-u', 'root', '--exec', 'sleep', 'infinity') `
            -WindowStyle Hidden -PassThru
    }
    Start-Sleep -Seconds 6

    $params = @{ Action = 'Start'; Execute = $true }
    $raw = & $Package @params
    $text = ($raw | Out-String).Trim()
    $response = $null
    try { $response = $text | ConvertFrom-Json } catch { }
    if ($null -eq $response) {
        Write-Log ('start produced no structured response: ' + $text)
        exit 1
    }
    Write-Log ("start outcome=" + $response.outcome + " phase=" + $response.phase)
    if ($response.PSObject.Properties['message']) { Write-Log ("message=" + $response.message) }
    foreach ($check in @($response.checks)) { Write-Log ("check " + $check.result + " " + $check.id + " " + $check.detail) }
    if ([string]$response.outcome -ne 'succeeded') { exit 1 }

    Write-Log ("endpoint rule enabled after start = " + (Get-EndpointRuleEnabled))
    Write-Log 'autostart complete'
    exit 0
} catch {
    Write-Log ('autostart failed: ' + $_.Exception.Message)
    exit 1
}
