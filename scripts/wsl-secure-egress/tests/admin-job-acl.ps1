#Requires -Version 5.1
# Offline regression for the administrator job's ACL and elevation construction.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$jobPath = Join-Path $PSScriptRoot '../COR-Full-AdminJob.ps1'
$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $jobPath, [ref]$tokens, [ref]$errors)
$script:Checks = 0

# A failing check stops the suite; every executed check is counted so the
# reported total always describes this run instead of a stale constant.
function Check([bool]$Condition, [string]$Message) {
    $script:Checks++
    if (-not $Condition) { throw $Message }
}

Check (@($errors).Count -eq 0) (
    'Parser errors: ' + (($errors | ForEach-Object Message) -join '; '))

$source = Get-Content -LiteralPath $jobPath -Raw

# Deployment data is private. The job must take the expected egress address
# and profile digest from the operator and must not carry stale host-specific
# staging paths as defaults.
Check ($source -notmatch '\b(?:\d{1,3}\.){3}\d{1,3}\b') `
    'The administrator job must not embed a literal IPv4 address.'
Check ($source -notmatch 'F:\\Codex') `
    'The administrator job must not default to host-specific staging paths.'
foreach ($expected in @(
    '-ExpectedEgressIpv4',
    '-ExpectedProfileSha256',
    'ExpectedEgressIpv4 -notmatch',
    'ExpectedProfileSha256 -notmatch'
)) {
    Check ($source.Contains($expected)) `
        "Missing private-deployment input contract: $expected"
}

# The host transaction must prove that no WSL distribution is running before
# restoring a profile, repairing ACLs, staging files or changing firewall
# policy. A redirected wsl.exe list is UTF-16LE on Windows; the parser must
# remove preserved NUL bytes instead of interpreting empty padding as a name.
$convertStart = $source.IndexOf('function ConvertFrom-WslNativeText', [StringComparison]::Ordinal)
$guardStart = $source.IndexOf('function Assert-AllWslStopped', [StringComparison]::Ordinal)
$guardEnd = $source.IndexOf("`nfunction ", $guardStart + 1, [StringComparison]::Ordinal)
Check ($convertStart -ge 0 -and $guardStart -gt $convertStart -and
    $guardEnd -gt $guardStart) 'The all-WSL-stopped gate functions were not found.'
$guardSource = $source.Substring($convertStart, $guardEnd - $convertStart)
foreach ($expected in @(
    '$script:WslExe --list --running --quiet',
    'wsl.exe returned exit code',
    'Refusing host changes while WSL is running',
    'Replace([string][char]0'
)) {
    Check ($guardSource.Contains($expected)) `
        "Missing all-WSL-stopped guard contract: $expected"
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
Check ($stopGate -ge 0 -and $snapshotGate -gt $stopGate -and
    $profileRestore -gt $snapshotGate -and $selfElevation -gt $transactionStart -and
    $stopGate -gt $selfElevation) `
    'Elevation must precede the stop gate, snapshot and profile restore writes.'

# Snapshot contents are read-only inventory and must never include the
# WireGuard profile or private material. Verify both the privacy manifest and
# the exact project-contained destination before attempting host writes.
$snapshotStart = $source.IndexOf('function New-WslNetworkSnapshot', [StringComparison]::Ordinal)
$snapshotEnd = $source.IndexOf("`nfunction ", $snapshotStart + 1, [StringComparison]::Ordinal)
Check ($snapshotStart -ge 0 -and $snapshotEnd -gt $snapshotStart) `
    'New-WslNetworkSnapshot was not found.'
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
    Check ($snapshotSource.Contains($expected)) `
        "Missing network snapshot contract: $expected"
}
foreach ($expected in @(
    'Assert-NormalDirectoryPath',
    'endpoint-rules-persistent.json',
    'endpoint-rules-effective.json',
    '-PolicyStore PersistentStore',
    '-PolicyStore ActiveStore'
)) {
    Check ($snapshotSource.Contains($expected)) `
        "Missing durable snapshot contract: $expected"
}
Check ($snapshotSource -notmatch 'profile\.json|private_key|Queries\s*=') `
    'Network snapshots must exclude private profile content and firewall queries.'

$secondStop = $source.IndexOf(
    '$null = Assert-AllWslStopped', $snapshotGate + 1,
    [StringComparison]::Ordinal)
Check ($secondStop -gt $snapshotGate -and $secondStop -lt $profileRestore) `
    'The stop gate must run again after the snapshot and before profile restoration.'

$start = $source.IndexOf('function Get-IdentitySids', [StringComparison]::Ordinal)
Check ($start -ge 0) 'Get-IdentitySids was not found.'
$aclFunctionStart = $source.IndexOf('function Set-ProtectedDirectoryAcl', [StringComparison]::Ordinal)
Check ($aclFunctionStart -gt $start) 'Set-ProtectedDirectoryAcl was not found.'
$end = $source.IndexOf("`nfunction ", $aclFunctionStart + 1, [StringComparison]::Ordinal)
Check ($end -gt $aclFunctionStart) 'The end of Set-ProtectedDirectoryAcl was not found.'
$functionSource = $source.Substring($start, $end - $start)

Check ($functionSource -notmatch '''SYSTEM:''|''Administrators:''|\("\$\{sid\}:') `
    'The administrator ACL still uses account-name forms.'
foreach ($expected in @(
    '''*S-1-5-18:(OI)(CI)F''',
    '''*S-1-5-32-544:(OI)(CI)F''',
    '"*${sid}:(OI)(CI)F"')) {
    Check ($functionSource.Contains($expected)) `
        "Missing canonical SID rule: $expected"
}
Check ($functionSource -match '/inheritance:r') `
    'The ACL replacement must remove inherited permissions.'
Check ($functionSource -match '/grant:r') `
    'The ACL replacement must use grant:r.'
Check ($functionSource -match '/T /C') `
    'The ACL replacement must remain recursive and continue on errors.'
# A tree-wide rewrite must be preceded by a recorded snapshot and must refuse
# to silently drop an identity that the caller asked to keep.
Check ($functionSource -match 'acl-before-') `
    'The ACL rewrite must snapshot the previous grants before changing them.'
Check ($functionSource -match 'Get-IdentitySids \$Path' -and
    $functionSource -match 'ACL repair dropped existing access') `
    'A keep-access ACL rewrite must verify that no identity lost access.'

$elevateStart = $source.IndexOf('function Start-SelfElevated', [StringComparison]::Ordinal)
Check ($elevateStart -ge 0) 'Start-SelfElevated was not found.'
$elevateEnd = $source.IndexOf("`nfunction ", $elevateStart + 1, [StringComparison]::Ordinal)
Check ($elevateEnd -gt $elevateStart) 'The end of Start-SelfElevated was not found.'
$elevateSource = $source.Substring($elevateStart, $elevateEnd - $elevateStart)
Check ($elevateSource -notmatch 'ConvertTo-WindowsCommandLineArgument') `
    'The elevation path must not prequote its native argument vector.'
Check ($elevateSource -notmatch 'Start-Process\s+-FilePath') `
    'The elevation path must not pass its argument vector through Start-Process.'
Check ($elevateSource -match '&\s*\$script:SudoExe\s+@sudoArguments') `
    'The elevation path must invoke sudo.exe with one native argument per array element.'
Check ($elevateSource -notmatch "'powershell\.exe'") `
    'The elevation path must not pass a bare command name to sudo.'
Check ($elevateSource -match '\$script:PowerShellExe') `
    'The elevated shell must be addressed by its absolute path.'

# Runtime acceptance must execute the same strict namespace helper and fixed
# provider probes used by the production backend. A plain root shell would
# expose the WSL root network namespace and is not valid acceptance evidence.
$isolatedStart = $source.IndexOf('function Invoke-IsolatedWsl', [StringComparison]::Ordinal)
$runtimeStart = $source.IndexOf('function Assert-IsolatedRuntime', [StringComparison]::Ordinal)
Check ($isolatedStart -ge 0 -and $runtimeStart -gt $isolatedStart) `
    'Strict isolated WSL acceptance functions were not found.'
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
    Check ($haystack.Contains($expected)) `
        "Missing strict runtime acceptance token: $expected"
}
Check ($source -match 'Invoke-IsolatedWsl\s+-Generation\s+\$generation' -and
    $source -notmatch 'curl -4 -fsS --connect-timeout 15 https://ifconfig\.co/ip') `
    'Runtime acceptance must not regress to the plain WSL root shell.'
Check ($source -match 'Assert-IsolatedRuntime\s+\$response\s+\$state') `
    'Start acceptance must invoke the strict isolated runtime probe.'
Check ($source -match "Invoke-Wsl @\('/usr/sbin/nft', 'list', 'tables'\)") `
    'The nftables guard audit must run only as a host-level invariant check.'
Check ($source -notmatch '/bin/sh -c') `
    'The elevated transaction must not hand a command string to a shell.'

# The protected staging directories intentionally reject the ordinary user.
# The elevated transaction must rebuild the stage after repairing the staging
# ACLs and before creating the digest that Apply trusts.
$buildStageIndex = $source.IndexOf(
    "'-File', `$stageTool", [StringComparison]::Ordinal)
$aclStageIndex = $source.IndexOf(
    'Set-ProtectedDirectoryAcl -Path $PackageStage', [StringComparison]::Ordinal)
$manifestIndex = $source.IndexOf(
    "'-Action', 'CreateManifest'", [StringComparison]::Ordinal)
Check ($buildStageIndex -ge 0 -and $aclStageIndex -gt $buildStageIndex -and
    $manifestIndex -gt $aclStageIndex) `
    'The stage must be protected after its rebuild and before manifest creation.'
foreach ($expected in @(
    "'-Repository', `$Repository, '-PackageStage', `$PackageStage",
    "'-PythonExecutable', `$PythonExecutable",
    "'-Execute', '-Replace'",
    "'The reviewed package stage was not built and verified.'"
)) {
    Check ($source.Contains($expected)) `
        "Missing protected package-stage build contract: $expected"
}
# The manifest digest is consumed in the same elevated process that created
# it; Get-FileHash may be unavailable there, so the .NET stream hash is used.
Check ($source -match '\$digest = \(Get-SnapshotSha256 \$manifest\)') `
    'The manifest digest must use the worker-safe SHA256 helper.'

# Execute the actual elevation function in an isolated runspace. The external
# sudo program is replaced by a PowerShell function, so this verifies the
# native argument vector without opening consent.exe or changing the host.
$vectorSource = $elevateSource.Replace(
    '& $script:SudoExe @sudoArguments',
    'Capture-Sudo @sudoArguments')
Check ($vectorSource -ne $elevateSource) `
    'The sudo invocation could not be isolated for the argument test.'
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
$ExpectedEgressIpv4 = '198.51.100.10'
$ExpectedProfileSha256 = 'A' * 64
$PythonExecutable = 'C:\Program Files\Python312\python.exe'
$ReviewedCommit = 'b' * 40
$script:PowerShellExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$script:SudoExe = 'C:\Windows\System32\sudo.exe'
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
    Check ($LASTEXITCODE -eq 0) `
        ('Isolated elevation runner failed: ' + (($raw | Out-String).Trim()))
    $result = (($raw | Out-String).Trim() | ConvertFrom-Json)
} finally {
    if (Test-Path -LiteralPath $runnerPath) {
        Remove-Item -LiteralPath $runnerPath -Force
    }
}

$expectedVector = @(
    '--new-window',
    'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
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
    '-NoSelfElevation',
    '-ExpectedEgressIpv4',
    '198.51.100.10',
    '-ExpectedProfileSha256',
    ('A' * 64),
    '-PythonExecutable',
    'C:\Program Files\Python312\python.exe',
    '-ReviewedCommit',
    ('b' * 40)
)
$actualVector = @($result.Arguments)
Check ($actualVector.Count -eq $expectedVector.Count) `
    ('Elevation vector count mismatch: expected {0}, got {1}.' -f
        $expectedVector.Count, $actualVector.Count)
$mismatch = $null
for ($index = 0; $index -lt $expectedVector.Count; $index++) {
    if ([string]$actualVector[$index] -cne $expectedVector[$index]) {
        $mismatch = 'Elevation vector mismatch at index {0}: expected [{1}], got [{2}].' -f
            $index, $expectedVector[$index], $actualVector[$index]
        break
    }
}
Check ($null -eq $mismatch) ([string]$mismatch)
Check ([string]::IsNullOrEmpty([string]$result.Failure) -or
    [string]$result.Failure -eq 'elevated child exited without a completion journal') `
    ('Unexpected elevated-child failure journal: ' + [string]$result.Failure)

[pscustomobject]@{
    suite = 'admin-job-acl-offline'
    result = 'PASS'
    assertions = $script:Checks
    hostWrites = $false
    elevationConsent = 'NOT_RUN'
    elevationVector = 'PASS'
} | ConvertTo-Json -Compress
