#Requires -Version 5.1
# Offline regression for the administrator job's ACL and elevation construction.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$jobPath = Join-Path $PSScriptRoot '../COR-Full-AdminJob.ps1'
$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $jobPath, [ref]$tokens, [ref]$errors)
if (@($errors).Count -ne 0) {
    throw ('Parser errors: ' + (($errors | ForEach-Object Message) -join '; '))
}

$source = Get-Content -LiteralPath $jobPath -Raw

# The host transaction must prove that no WSL distribution is running before
# restoring a profile, repairing ACLs, staging files or changing firewall
# policy. A redirected wsl.exe list is UTF-16LE on Windows; the parser must
# remove preserved NUL bytes instead of interpreting empty padding as a name.
$convertStart = $source.IndexOf('function ConvertFrom-WslNativeText', [StringComparison]::Ordinal)
$guardStart = $source.IndexOf('function Assert-AllWslStopped', [StringComparison]::Ordinal)
$guardEnd = $source.IndexOf("`nfunction ", $guardStart + 1, [StringComparison]::Ordinal)
if ($convertStart -lt 0 -or $guardStart -le $convertStart -or $guardEnd -le $guardStart) {
    throw 'The all-WSL-stopped gate functions were not found.'
}
$guardSource = $source.Substring($convertStart, $guardEnd - $convertStart)
foreach ($expected in @(
    'wsl.exe --list --running --quiet',
    'wsl.exe returned exit code',
    'Refusing host changes while WSL is running',
    'Replace([string][char]0'
)) {
    if (-not $guardSource.Contains($expected)) {
        throw "Missing all-WSL-stopped guard contract: $expected"
    }
}

$transactionStart = $source.IndexOf("`ntry {", [StringComparison]::Ordinal)
$profileRestore = $source.IndexOf(
    'stage 1a: restore the protected WireGuard profile', $transactionStart,
    [StringComparison]::Ordinal)
$stopGate = $source.IndexOf(
    'stage 0a: require every WSL distribution to be stopped', $transactionStart,
    [StringComparison]::Ordinal)
$snapshotGate = $source.IndexOf(
    'stage 0b: snapshot network state inside the repository', $transactionStart,
    [StringComparison]::Ordinal)
$selfElevation = $source.IndexOf('Start-SelfElevated', $transactionStart,
    [StringComparison]::Ordinal)
if ($stopGate -lt 0 -or $snapshotGate -le $stopGate -or
    $profileRestore -le $snapshotGate -or $selfElevation -le $transactionStart -or
    $stopGate -le $selfElevation) {
    throw 'Elevation must precede the stop gate, snapshot and profile restore writes.'
}

# Snapshot contents are read-only inventory and must never include the
# WireGuard profile or private material. Verify both the privacy manifest and
# the exact project-contained destination before attempting host writes.
$snapshotStart = $source.IndexOf('function New-WslNetworkSnapshot', [StringComparison]::Ordinal)
$snapshotEnd = $source.IndexOf("`nfunction ", $snapshotStart + 1, [StringComparison]::Ordinal)
if ($snapshotStart -lt 0 -or $snapshotEnd -le $snapshotStart) {
    throw 'New-WslNetworkSnapshot was not found.'
}
$snapshotSource = $source.Substring($snapshotStart, $snapshotEnd - $snapshotStart)
foreach ($expected in @(
    'ClashOfRust-network-backups',
    "'state.json'",
    "'guardian-audit.json'",
    "'scope-renewal.json'",
    "'wslconfig.before'",
    'Get-NetFirewallHyperVVMSetting',
    'Get-NetFirewallHyperVRule',
    "Name -eq 'ClashOfRust.WslEgress'",
    "TaskName 'ClashOfRust-WslEgress-Renew'",
    "'wireguard-profile-excluded'",
    'Get-SnapshotSha256 $record.destination'
)) {
    if (-not $snapshotSource.Contains($expected)) {
        throw "Missing network snapshot contract: $expected"
    }
}
foreach ($expected in @(
    'Assert-NormalDirectoryPath',
    'endpoint-rules-persistent.json',
    'endpoint-rules-effective.json',
    '-PolicyStore PersistentStore',
    '-PolicyStore ActiveStore'
)) {
    if (-not $snapshotSource.Contains($expected)) {
        throw "Missing durable snapshot contract: $expected"
    }
}
if ($snapshotSource -match 'profile\.json|private_key|Queries\s*=') {
    throw 'Network snapshots must exclude private profile content and firewall queries.'
}

$secondStop = $source.IndexOf(
    '$null = Assert-AllWslStopped', $snapshotGate + 1,
    [StringComparison]::Ordinal)
if ($secondStop -le $snapshotGate -or $secondStop -ge $profileRestore) {
    throw 'The stop gate must run again after the snapshot and before profile restoration.'
}

$start = $source.IndexOf('function Set-ProtectedDirectoryAcl', [StringComparison]::Ordinal)
if ($start -lt 0) { throw 'Set-ProtectedDirectoryAcl was not found.' }
$end = $source.IndexOf("`nfunction ", $start + 1, [StringComparison]::Ordinal)
if ($end -lt 0) { throw 'The end of Set-ProtectedDirectoryAcl was not found.' }
$functionSource = $source.Substring($start, $end - $start)

if ($functionSource -match '''SYSTEM:''|''Administrators:''|\("\$\{sid\}:') {
    throw 'The administrator ACL still uses account-name forms.'
}
foreach ($expected in @(
    '''*S-1-5-18:(OI)(CI)F''',
    '''*S-1-5-32-544:(OI)(CI)F''',
    '"*${sid}:(OI)(CI)F"')) {
    if (-not $functionSource.Contains($expected)) {
        throw "Missing canonical SID rule: $expected"
    }
}
if ($functionSource -notmatch '/inheritance:r') {
    throw 'The ACL replacement must remove inherited permissions.'
}
if ($functionSource -notmatch '/grant:r') {
    throw 'The ACL replacement must use grant:r.'
}
if ($functionSource -notmatch '/T /C') {
    throw 'The ACL replacement must remain recursive and continue on errors.'
}

$parseScript = {
    param($Source)
    $scriptBlock = [ScriptBlock]::Create($Source)
    [void]$scriptBlock.Ast.ParamBlock
}
& $parseScript $functionSource

$elevateStart = $source.IndexOf('function Start-SelfElevated', [StringComparison]::Ordinal)
if ($elevateStart -lt 0) { throw 'Start-SelfElevated was not found.' }
$elevateEnd = $source.IndexOf("`nfunction ", $elevateStart + 1, [StringComparison]::Ordinal)
if ($elevateEnd -lt 0) { throw 'The end of Start-SelfElevated was not found.' }
$elevateSource = $source.Substring($elevateStart, $elevateEnd - $elevateStart)
if ($elevateSource -match 'ConvertTo-WindowsCommandLineArgument') {
    throw 'The elevation path must not prequote its native argument vector.'
}
if ($elevateSource -match 'Start-Process\s+-FilePath\s+''C:\\Windows\\System32\\sudo\.exe''') {
    throw 'The elevation path must not pass its argument vector through Start-Process.'
}
if ($elevateSource -notmatch "&\s*'C:\\Windows\\System32\\sudo\.exe'\s+@sudoArguments") {
    throw 'The elevation path must invoke sudo.exe with one native argument per array element.'
}

# Runtime acceptance must execute the same strict namespace helper and fixed
# provider probes used by the production backend. A plain root shell would
# expose the WSL root network namespace and is not valid acceptance evidence.
$isolatedStart = $source.IndexOf('function Invoke-IsolatedWsl', [StringComparison]::Ordinal)
$runtimeStart = $source.IndexOf('function Assert-IsolatedRuntime', [StringComparison]::Ordinal)
if ($isolatedStart -lt 0 -or $runtimeStart -lt 0 -or $runtimeStart -le $isolatedStart) {
    throw 'Strict isolated WSL acceptance functions were not found.'
}
$runtimeSource = $source.Substring(
    $runtimeStart, $source.IndexOf("`ntry {", $runtimeStart, [StringComparison]::Ordinal) - $runtimeStart)
foreach ($expected in @(
    "'--exec', `$helper",
    "'run', '--generation'",
    "'public_ipv4'",
    "'virtual_interfaces'",
    "'tunnel_default_route'",
    "'host_mount_hidden'",
    "'interop_guarded'",
    "'provider_openai'",
    "'provider_anthropic'",
    "'provider_deepseek'"
)) {
    $haystack = $runtimeSource + $source.Substring($isolatedStart, $runtimeStart - $isolatedStart)
    if (-not $haystack.Contains($expected)) {
        throw "Missing strict runtime acceptance token: $expected"
    }
}
if ($source -notmatch 'Invoke-IsolatedWsl\s+-Generation\s+\$generation' -or
    $source -match 'curl -4 -fsS --connect-timeout 15 https://ifconfig\.co/ip') {
    throw 'Runtime acceptance must not regress to the plain WSL root shell.'
}
if ($source -notmatch 'Assert-IsolatedRuntime\s+\$response\s+\$state') {
    throw 'Start acceptance must invoke the strict isolated runtime probe.'
}
if ($source -notmatch 'Invoke-Wsl ''/usr/sbin/nft list tables''') {
    throw 'The nftables guard audit must run only as a host-level invariant check.'
}

# The protected staging directories intentionally reject the ordinary user.
# The elevated transaction must rebuild the stage after repairing the staging
# ACLs and before creating the digest that Apply trusts.
$aclStageIndex = $source.IndexOf(
    'Set-ProtectedDirectoryAcl -Path $PackageStage', [StringComparison]::Ordinal)
$buildStageIndex = $source.IndexOf(
    'Prepare-PackageStage.ps1', [StringComparison]::Ordinal)
$manifestIndex = $source.IndexOf(
    "'-Action', 'CreateManifest'", [StringComparison]::Ordinal)
if ($aclStageIndex -lt 0 -or $buildStageIndex -le $aclStageIndex -or
    $manifestIndex -le $buildStageIndex) {
    throw 'The elevated stage build must follow the ACL repair and precede manifest creation.'
}
foreach ($expected in @(
    "'-Repository', `$Repository, '-PackageStage', `$PackageStage",
    "'-Execute', '-Replace'",
    "'The reviewed package stage was not built and verified.'"
)) {
    if (-not $source.Contains($expected)) {
        throw "Missing protected package-stage build contract: $expected"
    }
}

# Execute the actual elevation function in an isolated runspace. The external
# sudo program is replaced by a PowerShell function, so this verifies the
# native argument vector without opening consent.exe or changing the host.
$vectorSource = $elevateSource.Replace(
    "& 'C:\Windows\System32\sudo.exe' @sudoArguments",
    'Capture-Sudo @sudoArguments')
if ($vectorSource -eq $elevateSource) {
    throw 'The sudo invocation could not be isolated for the argument test.'
}
$vectorSource = $vectorSource.Replace('$PSCommandPath', '$COR_TEST_JOB_PATH')
$vectorSource = $vectorSource.Replace(
    'exit ', '$script:CapturedExitCode = [int]')
$vectorSource += @'
function Capture-Sudo {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Vector)
    $script:CapturedSudoArguments = @($Vector)
    $global:LASTEXITCODE = 0
}
'@
$runnerSource = @'
param([string]$FunctionSource)
Set-StrictMode -Version Latest
$COR_TEST_JOB_PATH = 'C:\Program Files\COR Job\COR-Full-AdminJob.ps1'
$NoSelfElevation = $false
$PackageStage = 'F:\Package Stage'
$ManifestDirectory = 'F:\Manifest Directory'
$Repository = 'F:\Repository With Spaces'
$JobDirectory = 'F:\Job Directory'
$VerifiedBuild = 'F:\Repository With Spaces\dist\build'
$InstallationRoot = 'C:\Program Files\Clash of Rust WSL'
$ProfilePath = 'C:\Users\Test User\AppData\Local\ClashOfRust\WslEgress\profile.json'
$SnapshotRoot = 'F:\Repository With Spaces\ClashOfRust-network-backups'
$TestDistro = 'Ubuntu-26.04'
$DonePath = 'F:\Job Directory\DONE.txt'
$FailedPath = 'F:\Job Directory\FAILED.txt'
function Set-Content {
    param([string]$LiteralPath, $Value)
    $script:CapturedFailure = [string]$Value
}
function Test-Path {
    param([string]$LiteralPath, $PathType)
    return $LiteralPath -eq $DonePath
}
. ([ScriptBlock]::Create($FunctionSource))
try { Start-SelfElevated } catch {
    Write-Output ('RUNNER_ERROR=' + $_.Exception.Message)
    exit 90
}
if ($null -eq $script:CapturedSudoArguments) {
    Write-Output 'RUNNER_ERROR=sudo vector was not captured'
    exit 91
}
[pscustomobject]@{
    Arguments = @($script:CapturedSudoArguments)
    Failure = $script:CapturedFailure
} | ConvertTo-Json -Compress -Depth 5
'@
$runnerPath = Join-Path ([IO.Path]::GetTempPath()) (
    'cor-admin-vector-' + [guid]::NewGuid().ToString('N') + '.ps1')
try {
    [IO.File]::WriteAllText(
        $runnerPath,
        $runnerSource,
        [Text.UTF8Encoding]::new($false))
    $powershell = (Get-Process -Id $PID).Path
    $raw = & $powershell -NoProfile -ExecutionPolicy Bypass -File $runnerPath `
        -FunctionSource $vectorSource 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('Isolated elevation runner failed: ' + (($raw | Out-String).Trim()))
    }
    $result = (($raw | Out-String).Trim() | ConvertFrom-Json)
} finally {
    if (Test-Path -LiteralPath $runnerPath) {
        Remove-Item -LiteralPath $runnerPath -Force
    }
}

$expectedVector = @(
    '--new-window',
    'powershell.exe',
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    'C:\Program Files\COR Job\COR-Full-AdminJob.ps1',
    '-PackageStage',
    'F:\Package Stage',
    '-ManifestDirectory',
    'F:\Manifest Directory',
    '-Repository',
    'F:\Repository With Spaces',
    '-JobDirectory',
    'F:\Job Directory',
    '-VerifiedBuild',
    'F:\Repository With Spaces\dist\build',
    '-InstallationRoot',
    'C:\Program Files\Clash of Rust WSL',
    '-ProfilePath',
    'C:\Users\Test User\AppData\Local\ClashOfRust\WslEgress\profile.json',
    '-SnapshotRoot',
    'F:\Repository With Spaces\ClashOfRust-network-backups',
    '-TestDistro',
    'Ubuntu-26.04',
    '-NoSelfElevation'
)
$actualVector = @($result.Arguments)
if ($actualVector.Count -ne $expectedVector.Count) {
    throw ('Elevation vector count mismatch: expected {0}, got {1}.' -f
        $expectedVector.Count, $actualVector.Count)
}
for ($index = 0; $index -lt $expectedVector.Count; $index++) {
    if ([string]$actualVector[$index] -cne $expectedVector[$index]) {
        throw ('Elevation vector mismatch at index {0}: expected [{1}], got [{2}].' -f
            $index, $expectedVector[$index], $actualVector[$index])
    }
}
if (-not [string]::IsNullOrEmpty([string]$result.Failure) -and
    [string]$result.Failure -ne 'elevated child exited without a completion journal') {
    throw ('Unexpected elevated-child failure journal: ' + [string]$result.Failure)
}

[pscustomobject]@{
    suite = 'admin-job-acl-offline'
    result = 'PASS'
    assertions = 44
    hostWrites = $false
    elevationConsent = 'NOT_RUN'
    elevationVector = 'PASS'
} | ConvertTo-Json -Compress
