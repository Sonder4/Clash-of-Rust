#Requires -Version 5.1
<#
.SYNOPSIS
  Keeps the Clash of Rust active subscription's VPS direct rule in place.
.DESCRIPTION
  The WSL Secure Egress tunnel carries its own WireGuard endpoint. When the
  Meta TUN adapter owns the default route, that endpoint is captured and the
  node's bypass logic drops it, so the tunnel never handshakes. The fix is one
  IP-CIDR direct rule at the top of the active subscription's rules.

  This script edits the subscription profile the application itself reads, not
  the generated runtime/config.yaml. The application rewrites config.yaml from
  the active profile on every core start, so editing config.yaml alone is lost
  on the next restart.

  It is idempotent and read-only unless -Execute is supplied. It never touches
  the upstream application source, never installs a second client, and never
  restarts the core: applying the rule to a running core is the application's
  own restart, which the operator triggers.
#>
[CmdletBinding()]
param(
    [string]$EndpointIPv4 = '',
    [ValidateRange(1, 65535)][int]$EndpointPort = 51820,
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'clash-of-rust\ClashOfRust\data'),
    [string]$BackupRoot = (Join-Path $env:TEMP 'clash-of-rust-rule-backups'),
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RulePayload = "IP-CIDR,$EndpointIPv4/32,DIRECT"
$RuleComment = @(
    'WSL Secure Egress: the journaled WireGuard endpoint must leave through'
    'the physical uplink. The Meta TUN adapter otherwise captures it and the'
    "node's own bypass logic drops it, so the tunnel never handshakes."
)

function Get-ActiveProfilePath([string]$root) {
    $settings = Join-Path $root 'settings.json'
    if (-not (Test-Path -LiteralPath $settings)) {
        throw "Clash of Rust settings not found: $settings"
    }
    $state = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
    $id = [string]$state.active_profile
    if (-not $id) { throw 'No active subscription is selected in Clash of Rust.' }
    # The application reads <root>/profiles/<id>.yaml and rewrites
    # runtime/config.yaml from it on every core start. The catalog's `source`
    # is only where the subscription was imported from, not a runtime path.
    $catalog = Join-Path $root 'profiles.json'
    if (Test-Path -LiteralPath $catalog) {
        $known = @(Get-Content -LiteralPath $catalog -Raw | ConvertFrom-Json)
        if (@($known | Where-Object { $_.id -eq $id }).Count -eq 0) {
            throw "The active subscription $id is not in the catalog."
        }
    }
    $path = Join-Path $root (Join-Path 'profiles' ("{0}.yaml" -f $id))
    if (-not (Test-Path -LiteralPath $path)) { throw "Active subscription file not found: $path" }
    $path
}

function Get-TopLevelRuleLines([string[]]$lines) {
    # The profile has nested `rules:` blocks (for example under sniffer), so the
    # top-level block is the one starting at column zero.
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq 'rules:') {
            if ($start -ge 0) { throw 'More than one top-level rules block; refusing to guess.' }
            $start = $i
        }
    }
    if ($start -lt 0) { throw 'No top-level rules block in the active subscription.' }
    $items = @()
    for ($j = $start + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -like '  - *') { $items += $lines[$j] }
        elseif ([string]::IsNullOrWhiteSpace($lines[$j]) -or $lines[$j] -like '  #*') { continue }
        else { break }
    }
    [pscustomobject]@{ Start = $start; Items = $items }
}

function Test-RulePresent([string[]]$lines) {
    (Get-TopLevelRuleLines $lines).Items |
        Where-Object { $_.Trim() -like "*$RulePayload*" } | Select-Object -First 1
}

$result = [ordered]@{
    action        = 'ensure-vps-direct-rule'
    endpoint_ipv4 = $EndpointIPv4
    endpoint_port = $EndpointPort
    rule          = $RulePayload
}

if (-not $EndpointIPv4) { throw '-EndpointIPv4 is required; the rule is never inferred from state.' }

$profile = Get-ActiveProfilePath $DataRoot
$result.profile = $profile
$raw = Get-Content -LiteralPath $profile -Raw
$lines = $raw -split "`r?`n"

$existing = Test-RulePresent $lines
if ($existing) {
    $result.outcome = 'succeeded'
    $result.changed = $false
    $result.message = 'The VPS direct rule is already present at the top of the active subscription.'
    $result | ConvertTo-Json -Depth 6 -Compress
    exit 0
}

if (-not $Execute) {
    $result.outcome = 'not_run'
    $result.changed = $false
    $result.message = 'Dry run only: the rule is absent. Re-run with -Execute to insert it.'
    $result | ConvertTo-Json -Depth 6 -Compress
    exit 0
}

# Snapshot immediately before the change so rollback reflects the real
# pre-edit content, never an older full backup.
if (-not (Test-Path -LiteralPath $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $BackupRoot ("subscription-{0}.yaml" -f $stamp)
Copy-Item -LiteralPath $profile -Destination $backup -Force
$result.backup = $backup

$block = Get-TopLevelRuleLines $lines
$insert = @()
$insert += ($RuleComment | ForEach-Object { "  # $_" })
$insert += "  - $RulePayload"
$updated = @()
$updated += $lines[0..$block.Start]
$updated += $insert
if ($block.Start + 1 -lt $lines.Count) { $updated += $lines[($block.Start + 1)..($lines.Count - 1)] }

# Preserve the file's own line endings.
$newline = "`r`n"
if ($raw -notmatch "`r`n") { $newline = "`n" }
$text = ($updated -join $newline)
if ($raw.EndsWith($newline) -and -not $text.EndsWith($newline)) { $text += $newline }

$temp = "$profile.tmp"
[System.IO.File]::WriteAllText($temp, $text, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $temp -Destination $profile -Force

$verify = Get-Content -LiteralPath $profile -Raw
$verifyLines = $verify -split "`r?`n"
if (-not (Test-RulePresent $verifyLines)) { throw 'The rule was not readable back from the subscription file.' }
$verifyBlock = Get-TopLevelRuleLines $verifyLines
if ($verifyBlock.Items.Count -ne $block.Items.Count + 1) {
    throw "Rule count changed unexpectedly: expected $($block.Items.Count + 1), found $($verifyBlock.Items.Count)."
}

$result.outcome = 'succeeded'
$result.changed = $true
$result.message = 'Rule inserted. Restart Clash of Rust to regenerate runtime/config.yaml from this subscription.'
$result | ConvertTo-Json -Depth 6 -Compress
exit 0
