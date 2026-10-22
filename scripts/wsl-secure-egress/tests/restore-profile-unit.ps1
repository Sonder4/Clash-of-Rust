#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'Restore-WslEgressProfile.ps1'
$failures = [Collections.Generic.List[string]]::new()
$assertions = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { $script:failures.Add($Message) }
}

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'Restore profile script must parse.'
$text = Get-Content -LiteralPath $script -Raw
Assert-True ($text -match 'ProcessStartInfo') 'Linux profile must be read by a Windows process.'
Assert-True ($text -match 'RedirectStandardOutput = \$true') 'Profile transfer must use stdout, not argv.'
Assert-True ($text -match 'StandardError\.ReadToEnd') 'Stderr must be drained.'
Assert-True ($text -notmatch '[0-9A-Fa-f]{64}') 'No deployment profile digest may be embedded.'
Assert-True ($text -notmatch '\b(?:\d{1,3}\.){3}\d{1,3}\b') 'No deployment IPv4 address may be embedded.'
Assert-True ($text -match "ExpectedSha256 -notmatch '\^\[0-9A-Fa-f\]\{64\}\$'") `
    'The approved profile digest must be a mandatory caller input.'
Assert-True ($text -match 'Assert-ProfileDocument') 'Profile schema validation must be present.'
Assert-True ($text -match 'FromBase64String') 'WireGuard key lengths must be validated.'
Assert-True ($text -match 'WriteAllBytes') 'Profile must use binary atomic staging.'
Assert-True ($text -match 'SetAccessRuleProtection\(\$true, \$false\)') `
    'Profile ACL inheritance must be disabled.'
Assert-True ($text -match 'ReadAndExecute') 'The current user must receive directory read access.'
Assert-True ($text -notmatch 'Write-Output.*private_key') 'Secrets must not be logged.'
Assert-True ($text -notmatch 'Arguments.*private_key') 'Secrets must not be passed in argv.'
Assert-True ($text -match 'preview.*default|Preview is the default') 'Preview must be default.'

# Exercise the source-only preview against an isolated native fixture. The
# synthetic keys are generated only for this process and are never sent in
# argv or written by Preview.
$syntheticPrivateKey = [byte[]]::new(32)
$syntheticPeerKey = [byte[]]::new(32)
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $random.GetBytes($syntheticPrivateKey)
    $random.GetBytes($syntheticPeerKey)
} finally {
    $random.Dispose()
}
$profileBytes = [Text.UTF8Encoding]::new($false).GetBytes(
    '{"schema":1,"backend":"wireguard","endpoint_ipv4":"203.0.113.10",' +
    '"endpoint_port":51820,"manager_distro":"Fixture-Manager",' +
    '"tunnel_address":"10.77.0.2/32","resolver_ipv4":"10.77.0.1",' +
    '"uid":1000,"gid":1000,' +
    ('"private_key":"' + [Convert]::ToBase64String($syntheticPrivateKey) + '",') +
    ('"peer_public_key":"' + [Convert]::ToBase64String($syntheticPeerKey) + '"}'))
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $profileHash = (
        [BitConverter]::ToString($sha.ComputeHash($profileBytes))
    ).Replace('-', '')
} finally {
    $sha.Dispose()
}
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'cor-profile-reader-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$reader = Join-Path $fixtureRoot 'fixture-reader.exe'
$encoded = [Convert]::ToBase64String($profileBytes)
$source = @"
using System;
class ProfileReader {
    static int Main(string[] args) {
        Console.OpenStandardOutput().Write(Convert.FromBase64String("$encoded"), 0,
            Convert.FromBase64String("$encoded").Length);
        return 0;
    }
}
"@
try {
    Add-Type -TypeDefinition $source -OutputAssembly $reader `
        -OutputType ConsoleApplication
} catch {
    Assert-True $false ('Could not build native profile fixture: ' + $_.Exception.Message)
}
$target = Join-Path ([IO.Path]::GetTempPath()) ('cor-profile-preview-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    [IO.File]::WriteAllBytes($reader + '.source', $profileBytes)
    function Invoke-Preview([string[]]$Extra) {
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File $script -ProfilePath $target -SourceDistro 'Fixture-Manager' `
            -StatePath (Join-Path $fixtureRoot 'absent-state.json') `
            -WslExecutable $reader @Extra 2>&1)
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Response = (($output | Out-String).Trim() | ConvertFrom-Json)
        }
    }
    $preview = Invoke-Preview @('-ExpectedSha256', $profileHash.ToLowerInvariant())
    Assert-True ($preview.ExitCode -eq 0) 'Preview must exit successfully.'
    Assert-True ([string]$preview.Response.outcome -eq 'not_run') 'Preview must report not_run.'
    Assert-True ([bool]$preview.Response.hash_matches) 'Preview must validate the exact source hash.'
    Assert-True ([bool]$preview.Response.schema_valid) 'Preview must validate the profile schema.'
    Assert-True (-not (Test-Path -LiteralPath $target)) 'Preview must not create the target profile.'

    $missingHash = Invoke-Preview @()
    Assert-True ($missingHash.ExitCode -ne 0 -and
        [string]$missingHash.Response.outcome -eq 'failed') 'A missing approved digest must be refused.'

    $wrongEndpoint = Invoke-Preview @('-ExpectedSha256', $profileHash,
        '-ExpectedEndpointIpv4', '198.51.100.7')
    Assert-True ($wrongEndpoint.ExitCode -ne 0 -and
        [string]$wrongEndpoint.Response.outcome -eq 'failed') 'An unexpected endpoint must be refused.'
    Assert-True (-not (Test-Path -LiteralPath $target)) 'Refused previews must not create the target profile.'
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
}

[ordered]@{
    suite = 'restore-profile-offline'
    result = $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
    assertions = $assertions
    hostWrites = $false
    failures = @($failures)
} | ConvertTo-Json -Compress
if ($failures.Count -ne 0) { exit 1 }
