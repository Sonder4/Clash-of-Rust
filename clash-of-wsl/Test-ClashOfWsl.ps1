#Requires -Version 5.1
<#
.SYNOPSIS
  Offline self-test for the Clash of WSL component.

.DESCRIPTION
  Checks structure and syntax only. It does not need administrator rights, does
  not touch WSL, the registry, the firewall or the network, and never claims a
  live egresstunnel. Actions that need an elevated host are reported as NOT_RUN
  so a passing result here cannot be mistaken for an end-to-end acceptance.
#>
[CmdletBinding()]
param([string]$ComponentRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failures = New-Object System.Collections.Generic.List[string]
$assertions = 0

function Invoke-Assert([string]$Name, [bool]$Condition) {
    $script:assertions++
    if ($Condition) { Write-Output ('PASS  ' + $Name) }
    else {
        Write-Output ('FAIL  ' + $Name)
        $script:failures.Add($Name)
    }
}

if ([string]::IsNullOrWhiteSpace($ComponentRoot)) {
    $ComponentRoot = Split-Path -Parent $PSCommandPath
}
$ComponentRoot = [IO.Path]::GetFullPath($ComponentRoot)

Write-Output ('component root: ' + $ComponentRoot)

# --- required files -------------------------------------------------------
$required = @(
    'ClashOfWsl.ps1',
    'ClashOfWsl-Daemon.ps1',
    'Install-ClashOfWsl.ps1',
    'linux\clash-of-wsl-daemon.py',
    'linux\clash-of-wsl-guard.service',
    'linux\install-guard.sh'
)
foreach ($name in $required) {
    $path = Join-Path $ComponentRoot $name
    Invoke-Assert ('file present: ' + $name) (Test-Path -LiteralPath $path -PathType Leaf)
}

# --- PowerShell syntax ----------------------------------------------------
Get-ChildItem -LiteralPath $ComponentRoot -Filter '*.ps1' -File | ForEach-Object {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
    Invoke-Assert ('parses: ' + $_.Name) ($errors.Count -eq 0)
}

# --- the elevated entry point must be fail-closed on missing install ------
$managed = Join-Path $ComponentRoot 'ClashOfWsl.ps1'
if (Test-Path -LiteralPath $managed -PathType Leaf) {
    $text = [IO.File]::ReadAllText($managed)
    Invoke-Assert 'entry point declares every action' (
        $text -match "'Install'" -and $text -match "'Configure'" -and
        $text -match "'Start'" -and $text -match "'Stop'" -and
        $text -match "'Status'" -and $text -match "'Test'" -and
        $text -match "'Uninstall'" -and $text -match "'Rollback'"
    )
    Invoke-Assert 'entry point requires an installed module' ($text -match 'Assert-Installed')
    Invoke-Assert 'entry point never echoes raw exceptions' ($text -match 'Never echo' -or $text -match 'outcome=\"failed\"')
}

# --- installer must request elevation and never claim success quietly ----
$installer = Join-Path $ComponentRoot 'Install-ClashOfWsl.ps1'
if (Test-Path -LiteralPath $installer -PathType Leaf) {
    $text = [IO.File]::ReadAllText($installer)
    Invoke-Assert 'installer requests UAC' ($text -match 'RunAs')
    Invoke-Assert 'installer previews by default' ($text -match 'not_run')
    Invoke-Assert 'installer refuses without elevation' ($text -match 'NoSelfElevation')
    Invoke-Assert 'installer quotes elevated arguments' (
        $text -match 'ConvertTo-WindowsCommandLineArgument' -and
        $text -match '-ArgumentList \$commandLine'
    )
    Invoke-Assert 'restore failure aborts before service removal' (
        $text.IndexOf("if (`$restoreOutcome -ne 'succeeded')") -lt
        $text.IndexOf('$stopped = $false')
    )
    Invoke-Assert 'generic uninstall cannot remove recovery tooling' (
        $text -match 'Uninstall requires -RestoreOriginalNetwork' -and
        $text.IndexOf("if (-not `$RestoreOriginalNetwork)") -lt
        $text.IndexOf("`$restoreOutcome = 'not_run'")
    )
    Invoke-Assert 'install registers the owned guardian service' (
        $text -match 'Install-OwnedGuardianService' -and
        $text -match 'New-Service' -and
        $text -match 'Start-Service'
    )
}

# --- daemon must not open the tunnel itself ------------------------------
$daemon = Join-Path $ComponentRoot 'ClashOfWsl-Daemon.ps1'
if (Test-Path -LiteralPath $daemon -PathType Leaf) {
    $text = [IO.File]::ReadAllText($daemon)
    Invoke-Assert 'daemon records receipt verification' ($text -match 'installed-files.json')
    Invoke-Assert 'daemon keeps the payload directory protected' ($text -match 'icacls')
}

# --- not-run items --------------------------------------------------------
Write-Output ''
Write-Output 'NOT_RUN  live tunnel start (requires elevation)'
Write-Output 'NOT_RUN  VPS egress address check (requires elevation and a live tunnel)'
Write-Output 'NOT_RUN  Uninstall and rollback (requires elevation)'

Write-Output ''
if ($failures.Count -eq 0) {
    [ordered]@{
        schema_version = 1
        component = 'clash-of-wsl'
        result = 'PASS'
        assertions = $script:assertions
        live_tests = 'NOT_RUN'
    } | ConvertTo-Json -Compress
    exit 0
}
[ordered]@{
    schema_version = 1
    component = 'clash-of-wsl'
    result = 'FAIL'
    assertions = $script:assertions
    failures = @($failures)
} | ConvertTo-Json -Compress
exit 1
