#Requires -Version 5.1
# Offline checks for the two WSL egress automation entry points. Every
# filesystem, WSL and network boundary is mocked; nothing on this host changes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Assertions = 0
$script:Failures = New-Object 'Collections.Generic.List[string]'

function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -cne $Expected) { $script:Failures.Add("FAIL: $Name (expected <$Expected>, got <$Actual>)") }
    else { $script:Assertions++ }
}
function Assert-True([Parameter(Mandatory=$true,Position=0)][bool]$Condition,
                      [Parameter(Position=1)][string]$Name) {
    if (-not $Condition) { $script:Failures.Add("FAIL: $Name") }
    else { $script:Assertions++ }
}

$ruleScript = Join-Path $PSScriptRoot '../Set-WslEgressClashDirectRule.ps1'
$distroScript = Join-Path $PSScriptRoot '../Test-WslEgressDistroConfiguration.ps1'
$ruleSource = Get-Content -LiteralPath $ruleScript -Raw
$distroSource = Get-Content -LiteralPath $distroScript -Raw

# --- The rule script must target the subscription the core actually reads. ---
$ruleBuildsProfilePath = $ruleSource.Contains('profiles') -and $ruleSource.Contains('{0}.yaml')
Assert-True $ruleBuildsProfilePath 'rule script builds the runtime profile path from the active id'
Assert-True $ruleSource.Contains('runtime/config.yaml') 'rule script documents that the runtime file is regenerated on start'
Assert-True $ruleSource.Contains('active_profile') 'rule script reads the active subscription from settings.json'
$ruleReportsBothOutcomes = $ruleSource.Contains('already present') -and $ruleSource.Contains('Dry run only')
Assert-True $ruleReportsBothOutcomes 'rule script distinguishes idempotent success from a dry run'
Assert-True $ruleSource.Contains('-not $Execute') 'rule script stays read-only without -Execute'
$ruleSnapshotsBeforeEdit = $ruleSource.Contains('Copy-Item') -and $ruleSource.Contains('$backup')
Assert-True $ruleSnapshotsBeforeEdit 'rule script snapshots the subscription immediately before editing'
Assert-True $ruleSource.Contains('IP-CIDR,') 'rule script inserts an IP-CIDR direct rule'

# --- The rule must be inserted at the top-level block, never a nested one. ---
Assert-True $ruleSource.Contains('if ($lines[$i] -eq ''rules:'')') 'rule script locates a column-zero rules block'
Assert-True $ruleSource.Contains('More than one top-level rules block') 'rule script refuses to guess between several top-level blocks'
Assert-True $ruleSource.Contains('Rule count changed unexpectedly') 'rule script verifies the rule count after writing'

# --- No endpoint may be silently inferred. ---
Assert-True $ruleSource.Contains('if (-not $EndpointIPv4)') 'rule script requires an explicit endpoint address'
Assert-True (-not $ruleSource.Contains('Read-WslEgressState')) 'rule script does not import the WSL egress module'

# --- The distro script must reproduce the module's own distro filter. ---
Assert-True $distroSource.Contains('^docker-desktop(?:-data)?$') 'distro script excludes Docker backing distributions like the module does'
Assert-True $distroSource.Contains('manager_distro') 'distro script reads the manager distribution from the journal'
$distroChecksRuntimeArtifacts = $distroSource.Contains('profile.json') -and $distroSource.Contains('wireguard.key') -and $distroSource.Contains('scope-attestation.json')
Assert-True $distroChecksRuntimeArtifacts 'distro script checks the manager runtime artifacts'
Assert-True $distroSource.Contains('ordinary') 'distro script distinguishes ordinary distributions'
Assert-True $distroSource.Contains('Manager runtime artifact; a full installation owns this') 'distro script refuses to repair manager runtime artifacts'
Assert-True $distroSource.Contains('-not $Execute') 'distro script stays read-only without -Execute'
Assert-True $distroSource.Contains('Join-Path $env:ProgramData') 'distro script resolves the journal root as a real absolute path'
Assert-True (-not $distroSource.Contains("'\ProgramData")) 'distro script has no drive-relative default path'

# --- Neither script may restart the core, shut down WSL, or touch the VPS. ---
foreach ($name in @($ruleSource, $distroSource)) {
    foreach ($forbidden in @('wsl.exe --shutdown', 'Restart-Service', 'Stop-Process', 'ssh ')) {
        Assert-True (-not $name.Contains($forbidden)) "no automation script invokes <$forbidden>"
    }
}

if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Output $_ }
    Write-Output "FAILED: $($script:Failures.Count) assertion(s) failed; $($script:Assertions) passed."
    exit 1
}
Write-Output "PASS: $($script:Assertions) assertions."
exit 0
