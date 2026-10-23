#Requires -Version 5.1
<#
.SYNOPSIS
  Ubuntu-26.04 manager migration, run 4.

.DESCRIPTION
  Run 3 reached Install and failed at stage 'linux_payload' with
  RuntimeException:line=333 inside the product module, i.e.

    if ($install.ExitCode -ne 0) { throw 'Hash-pinned Linux payload installation failed.' }

  Cause, read from the distro rather than guessed:

    /usr/local/lib/cor-egress already existed in Ubuntu-26.04 with a different
    manager.py (117403 bytes, 2026-10-22) than the installed package
    (112922 bytes). install-payload.py refuses a different payload without
    --reviewed-upgrade, which the Windows Install path never passes.

    /var/lib/cor-egress/state.json was a role=distro-config, phase=DistroRestored
    journal. manager.py install() line 1458 refuses any journal whose phase is
    not RolledBack: 'Already installed; use the owned rollback before a new
    generation.'

  Both were leftovers of an earlier attempt, so both were moved aside under
  /root/cor-egress-stale/ (reversible; no deletion), leaving the manager
  install a clean first-install path. Nothing else in the distro changed.

  The journal is now phase=preparing with linux_manager_install_started and
  linux_manager_installed both false, which is the product's own recoverable
  partial-install state; Install takes the Restore-WslEgressPartialInstall
  -PreserveGuard path and keeps the host default-deny active throughout.

  Sequence: baseline -> snapshot -> canary -> shutdown -> install -> start ->
  doctor -> structure audit -> final baseline.
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$Package = 'C:\Program Files\Clash of Rust\resources\wsl-secure-egress\Manage-WslSecureEgress.ps1',
    [string]$ProfilePath = (Join-Path $env:LOCALAPPDATA 'ClashOfRust\WslEgress\profile.json'),
    [string]$LogDir = (Join-Path $env:TEMP 'clash-of-rust-wsl-egress'),
    [int]$StepTimeoutSeconds = 900
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Journal = 'C:\ProgramData\ClashOfRust\WslEgress\state.json'
$StateRoot = 'C:\ProgramData\ClashOfRust\WslEgress'
$Creator = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$EndpointRuleName = 'ClashOfRust-WslEgress-Endpoint'
$FailMarker = Join-Path $LogDir 'FAILED.txt'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Remove-Item $FailMarker -ErrorAction SilentlyContinue

$script:LogFile = Join-Path $LogDir 'progress.log'
function Write-LogLine([string]$Text) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Text
    $line | Out-File -FilePath $script:LogFile -Append -Encoding utf8
    # Write-Host, never Write-Output: Invoke-Step's only pipeline output must be
    # the response object, or $r becomes an array and $r.outcome is $null.
    Write-Host $line
}

function Write-Json([string]$Name, [string]$Content) {
    $path = Join-Path $LogDir ("{0}.json" -f $Name)
    [IO.File]::WriteAllText($path, $Content, (New-Object Text.UTF8Encoding($false)))
    Write-LogLine ("{0} -> {1} ({2} bytes)" -f $Name, $path, $Content.Length)
}

function ConvertFrom-JsonSafe([string]$Text) {
    if ($null -eq $Text) { return $null }
    $t = $Text.TrimStart([char]0xFEFF, ' ', "`r", "`n", "`t")
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

trap {
    $msg = $_.Exception.Message
    Write-LogLine ("FAILED: " + $msg)
    Write-LogLine ("  line=" + $_.InvocationInfo.ScriptLineNumber + " command=" + $_.InvocationInfo.Line.Trim())
    try {
        @{ failedAt = (Get-Date -Format o); message = $msg
           line = $_.InvocationInfo.ScriptLineNumber } |
            ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $FailMarker -Encoding UTF8
    } catch { }
    exit 1
}

if (-not (Test-Path -LiteralPath $Package -PathType Leaf)) { throw "Management script not found: $Package" }
if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) { throw "Profile not found: $ProfilePath" }
$ModulePath = Join-Path (Split-Path $Package) 'WslSecureEgress.psm1'
$m = Import-Module $ModulePath -PassThru -Force

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
Write-LogLine ("elevated = " + $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

# Start-Process -ArgumentList joins with spaces and does NO quoting; the package
# path contains "Clash of Rust". Apply the CommandLineToArgvW rules first.
function ConvertTo-CommandLineArgument([string]$Argument) {
    if ($Argument -ne '' -and $Argument -notmatch '[\s"]' -and -not $Argument.EndsWith('\')) { return $Argument }
    $sb = New-Object Text.StringBuilder
    $backslashes = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append('\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$sb.Append('\' * $backslashes); $backslashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\' * ($backslashes * 2)) }
    '"' + $sb.ToString() + '"'
}

function Invoke-Step([string]$Name, [string[]]$StepArgs) {
    Write-LogLine ("STEP " + $Name + " begin")
    $stdout = Join-Path $LogDir ($Name + '.stdout.txt')
    $stderr = Join-Path $LogDir ($Name + '.stderr.txt')
    Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue

    $argv = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Package) + $StepArgs
    $quoted = ($argv | ForEach-Object { ConvertTo-CommandLineArgument ([string]$_) }) -join ' '
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $quoted `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    if (-not $p.WaitForExit($StepTimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { }
        Write-Json $Name '{"outcome":"timeout","detail":"step exceeded the wall-clock limit and was killed"}'
        throw ("Step " + $Name + " timed out after " + $StepTimeoutSeconds + "s.")
    }
    $p.WaitForExit()

    $text = ''
    if (Test-Path $stdout) { $text = [IO.File]::ReadAllText($stdout) }
    $err = ''
    if (Test-Path $stderr) { $err = [IO.File]::ReadAllText($stderr) }
    Write-Json $Name $text
    if ($err.Trim()) { Write-Json ($Name + '.stderr') $err }

    $json = ConvertFrom-JsonSafe $text
    if ($null -eq $json) {
        Write-LogLine ("  " + $Name + ": no structured response")
        return $null
    }
    Write-LogLine ("  outcome=" + $json.outcome + " phase=" + $json.phase)
    if ($json.PSObject.Properties['message']) { Write-LogLine ("  message=" + $json.message) }
    $json
}

function Test-Response($Response, [string[]]$Accept, [string]$Name) {
    if ($null -eq $Response) { throw ($Name + " returned no structured response.") }
    if ($Response -is [array]) {
        throw ($Name + " returned " + $Response.Count + " pipeline objects, expected exactly one response.")
    }
    if (-not $Response.PSObject.Properties['outcome']) {
        throw ($Name + " response has no outcome field.")
    }
    if ($Response.outcome -notin $Accept) {
        throw ($Name + " outcome was '" + $Response.outcome + "', expected one of: " + ($Accept -join ', '))
    }
    $Response
}

function Get-MandatoryCodes {
    $path = Join-Path $env:LOCALAPPDATA 'ClashOfRust\WslEgress\protected-connections.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Baseline file not found: $path" }
    $entries = @([IO.File]::ReadAllText($path) | ConvertFrom-Json)
    if ($entries.Count -eq 0) { throw 'Baseline file has no entries.' }
    $codes = [ordered]@{}
    foreach ($entry in $entries) {
        $hostName = ([uri]$entry.url).Host
        $code = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 25 $entry.url)
        $codes[$hostName] = $code
        Write-LogLine ("  " + $hostName + " -> " + $code + " (accepted: " + (@($entry.accepted_statuses) -join '/') + ")")
    }
    $codes
}

function Assert-BaselineAccepted($Codes, [string]$Label) {
    $path = Join-Path $env:LOCALAPPDATA 'ClashOfRust\WslEgress\protected-connections.json'
    foreach ($entry in @([IO.File]::ReadAllText($path) | ConvertFrom-Json)) {
        $hostName = ([uri]$entry.url).Host
        $observed = [int]$Codes[$hostName]
        if ($observed -notin @($entry.accepted_statuses | ForEach-Object { [int]$_ })) {
            throw ($Label + " unhealthy: " + $hostName + "=" + $observed + ", accepted " + (@($entry.accepted_statuses) -join '/') + ". No network change performed.")
        }
    }
    Write-LogLine ("  " + $Label + " accepted by product criteria")
}

# ---------------------------------------------------------------- step 0
Write-LogLine "=== BASELINE ==="
$baseline = Get-MandatoryCodes
Write-Json '00-baseline' ($baseline | ConvertTo-Json -Compress)
Assert-BaselineAccepted $baseline 'Baseline'

# ---------------------------------------------------------------- state gate
$journalState = & $m Read-WslEgressState
if ($null -eq $journalState) { throw 'Journal is absent; this script expects the recoverable partial install from run 3.' }
Write-LogLine ("journal phase = " + $journalState.phase + " manager = " + $journalState.manager_distro)
if ([string]$journalState.manager_distro -ne 'Ubuntu-26.04') {
    throw ('Manager distribution is ' + $journalState.manager_distro + ', expected Ubuntu-26.04.')
}
# StrictMode rejects a missing key on an ordered dictionary, and these two
# markers are absent until the matching stage writes them; use the module's
# defaulting accessor rather than property syntax.
if ([bool](& $m Get-WslEgressStateValue $journalState 'linux_manager_install_started' $false) -or
    [bool](& $m Get-WslEgressStateValue $journalState 'linux_manager_installed' $false)) {
    throw 'Linux manager installation already started; the Windows-only partial recovery path does not apply.'
}
if ([string]$journalState.phase -notin @('preparing','prepared_for_reinstall','failed_closed_requested','closure_unverified','installed_closed')) {
    throw ('Unexpected journal phase: ' + $journalState.phase)
}

# ---------------------------------------------------------------- step 1 snapshot
Write-LogLine "=== SNAPSHOT ==="
$hypervRules = @(Get-NetFirewallHyperVRule -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
    Where-Object { [string]$_.VMCreatorId -eq $Creator -and [string]$_.Direction -eq 'Outbound' })
$hyperv = @()
foreach ($rule in $hypervRules) {
    $hyperv += [ordered]@{ name = [string]$rule.Name; enabled = [int]$rule.Enabled; action = [int]$rule.Action }
}
$hypervJson = if ($hyperv.Count -eq 0) { '[]' } else { ($hyperv | ConvertTo-Json -Depth 3 -Compress) }
$parts = New-Object 'Collections.Generic.List[string]'
$parts.Add(('"capturedAt":' + (([string](Get-Date -Format o)) | ConvertTo-Json -Depth 1 -Compress)))
$parts.Add(('"stateJson":' + (([IO.File]::ReadAllText($Journal)) | ConvertTo-Json -Depth 1 -Compress)))
$parts.Add(('"wslconfig":' + (($(if (Test-Path "$env:USERPROFILE\.wslconfig") { [IO.File]::ReadAllText("$env:USERPROFILE\.wslconfig") } else { '' })) | ConvertTo-Json -Depth 1 -Compress)))
$parts.Add(('"hyperv":' + $hypervJson))
Write-Json '01-snapshot' ('{' + ($parts -join ',') + '}')

# ---------------------------------------------------------------- canary
Write-LogLine "=== CANARY (argument quoting) ==="
$canary = Invoke-Step 'canary-doctor' @('-Action', 'Doctor')
if ($null -eq $canary -or -not $canary.PSObject.Properties['outcome']) { throw 'Canary produced no structured response.' }
Write-LogLine ("  canary outcome=" + $canary.outcome + " (quoting OK)")

if (-not $Execute) {
    Write-LogLine "=== PLAN ONLY ==="
    Write-LogLine "  shutdown -> install -> start -> doctor -> structure audit -> baseline"
    exit 0
}

# ---------------------------------------------------------------- step 2
Write-LogLine "=== SHUTDOWN ==="
$shutdownOut = (& wsl.exe --shutdown 2>&1)
Write-Json '02-shutdown' (($shutdownOut | Out-String).Trim())
Start-Sleep -Seconds 8
$runningNow = @(& $m Get-WslEgressRunningDistributions)
Write-LogLine ("  still running: " + $(if ($runningNow.Count -eq 0) { 'none' } else { $runningNow -join ', ' }))
if ($runningNow.Count -ne 0) { throw 'Distributions still running after shutdown; refusing to continue.' }

# ---------------------------------------------------------------- step 3
$r = Invoke-Step '03-install' @('-Action', 'Install', '-Execute', '-ProfilePath', $ProfilePath)
Test-Response $r @('succeeded') '03-install' | Out-Null

# ---------------------------------------------------------------- step 4
$r = Invoke-Step '04-start' @('-Action', 'Start', '-Execute', '-ProfilePath', $ProfilePath)
Test-Response $r @('succeeded') '04-start' | Out-Null

# ---------------------------------------------------------------- step 5
$r = Invoke-Step '05-doctor' @('-Action', 'Doctor')
Write-LogLine ("  doctor outcome = " + $(if ($r) { $r.outcome } else { 'no response' }))

# ---------------------------------------------------------------- step 6
Write-LogLine "=== STRUCTURE AUDIT ==="
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
    throw ('Structural audit failed: WSL is not default-deny (out=' + $struct.defaultOutbound + ', in=' + $struct.defaultInbound + ').')
}
$allows = @(Get-NetFirewallHyperVRule -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {
    [string]$_.Enabled -eq 'True' -and [string]$_.Direction -eq 'Outbound' -and
    [string]$_.Action -eq 'Allow' -and [string]$_.VMCreatorId -eq $Creator
})
$allowSummary = @($allows | ForEach-Object { [ordered]@{ name = [string]$_.Name
    remoteAddresses = @($_.RemoteAddresses); remotePorts = @($_.RemotePorts); protocol = [string]$_.Protocol } })
Write-Json '06-structure' (($struct | ConvertTo-Json -Depth 3) + "`n" + ($allowSummary | ConvertTo-Json -Depth 5))
Write-LogLine ("  enabled outbound allow rules = " + $allows.Count)
foreach ($a in $allows) { Write-LogLine ("    " + $a.Name + " -> " + (@($a.RemoteAddresses) -join ',') + ':' + (@($a.RemotePorts) -join ',') + ' ' + $a.Protocol) }
$foreign = @($allows | Where-Object { [string]$_.Name -ne $EndpointRuleName })
if ($foreign.Count -gt 0) {
    throw ('Structural audit failed: ' + $foreign.Count + ' outbound allow rule(s) other than the managed endpoint exist.')
}

# ---------------------------------------------------------------- step 7
Write-LogLine "=== FINAL BASELINE ==="
$final = Get-MandatoryCodes
Write-Json '07-final-baseline' ($final | ConvertTo-Json -Compress)
Assert-BaselineAccepted $final 'Final baseline'

$endState = & $m Read-WslEgressState
Write-LogLine ("  final phase = " + $endState.phase + " manager = " + $endState.manager_distro + " endpoint_enabled = " + $endState.endpoint_enabled)
if ([string]$endState.manager_distro -ne 'Ubuntu-26.04') {
    throw ('Manager distribution is ' + $endState.manager_distro + ', expected Ubuntu-26.04.')
}
Write-LogLine "=== MIGRATION FINISHED ==="
exit 0
