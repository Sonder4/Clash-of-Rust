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
Assert-True ($text -match '9DA000C7399DE02A675C18AE929356DDC5F6072ABA9169E4BE84A85519A397F7') `
    'Expected profile hash must be fixed.'
Assert-True ($text -match 'Assert-ProfileDocument') 'Profile schema validation must be present.'
Assert-True ($text -match 'FromBase64String') 'WireGuard key lengths must be validated.'
Assert-True ($text -match 'WriteAllBytes') 'Profile must use binary atomic staging.'
Assert-True ($text -match 'SetAccessRuleProtection\(\$true, \$false\)') `
    'Profile ACL inheritance must be disabled.'
Assert-True ($text -match 'ReadAndExecute') 'The current user must receive directory read access.'
Assert-True ($text -notmatch 'Write-Output.*private_key') 'Secrets must not be logged.'
Assert-True ($text -notmatch 'Arguments.*private_key') 'Secrets must not be passed in argv.'
Assert-True ($text -match 'preview.*default|Preview is the default') 'Preview must be default.'

# Exercise the source-only preview. It reads the actual root-owned Linux copy,
# validates its exact hash and schema, and must not create the Windows target.
$target = Join-Path ([IO.Path]::GetTempPath()) ('cor-profile-preview-' + [guid]::NewGuid().ToString('N') + '.json')
$output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -ProfilePath $target 2>&1)
$exitCode = $LASTEXITCODE
$response = (($output | Out-String).Trim() | ConvertFrom-Json)
Assert-True ($exitCode -eq 0) 'Preview must exit successfully.'
Assert-True ([string]$response.outcome -eq 'not_run') 'Preview must report not_run.'
Assert-True ([bool]$response.hash_matches) 'Preview must validate the exact source hash.'
Assert-True ([bool]$response.schema_valid) 'Preview must validate the profile schema.'
Assert-True (-not (Test-Path -LiteralPath $target)) 'Preview must not create the target profile.'

[ordered]@{
    suite = 'restore-profile-offline'
    result = $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
    assertions = $assertions
    hostWrites = $false
    failures = @($failures)
} | ConvertTo-Json -Compress
if ($failures.Count -ne 0) { exit 1 }
