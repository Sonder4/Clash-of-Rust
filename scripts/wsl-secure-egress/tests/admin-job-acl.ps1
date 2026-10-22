#Requires -Version 5.1
# Offline regression for the administrator job's ACL construction.
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

[pscustomobject]@{
    suite = 'admin-job-acl-offline'
    result = 'PASS'
    assertions = 9
    hostWrites = $false
} | ConvertTo-Json -Compress
