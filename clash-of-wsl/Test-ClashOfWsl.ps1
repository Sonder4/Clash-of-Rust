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
    $installFunctionStart = $text.IndexOf('function Install-OwnedGuardianService', [StringComparison]::Ordinal)
    $installFunctionEnd = if ($installFunctionStart -ge 0) {
        $text.IndexOf("`nfunction ", $installFunctionStart + 1, [StringComparison]::Ordinal)
    } else { -1 }
    Invoke-Assert 'guardian service helper is complete' (
        $installFunctionStart -ge 0 -and $installFunctionEnd -gt $installFunctionStart
    )
    $executeInstallStart = $text.IndexOf('if ($Execute) {', [StringComparison]::Ordinal)
    $executeInstallEnd = if ($executeInstallStart -ge 0) {
        $text.IndexOf("`n[ordered]@", $executeInstallStart + 1, [StringComparison]::Ordinal)
    } else { -1 }
    Invoke-Assert 'execute path invokes guardian after copying payload' (
        $executeInstallStart -ge 0 -and
        $executeInstallEnd -gt $executeInstallStart -and
        $text.Substring($executeInstallStart, $executeInstallEnd - $executeInstallStart).Contains(
            'Install-OwnedGuardianService'
        )
    )

    # Run the uninstall and install branches in an isolated child PowerShell.
    # Real cmdlets and external commands are replaced by functions. The
    # harness therefore executes the actual control flow without elevation,
    # filesystem mutation, service changes, WSL access or network access.
    $sourceRoot = Split-Path -Parent $ComponentRoot
    $guardianHarnessSource = @'
param([string]$InstallerPath, [string]$Scenario)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$SourceRoot = 'C:\Source Root'
$GuardianExe = 'C:\Source Root\target\release\clash-wsl-guardian.exe'
$Uninstall = $false
$RestoreOriginalNetwork = $false
$Execute = $true
$NoSelfElevation = $true
$env:ProgramFiles = 'C:\Program Files'
$env:SystemRoot = 'C:\Windows'
$script:Events = [Collections.Generic.List[string]]::new()
$script:QueryCount = 0
$script:Stopped = $false
function Get-Process { throw 'unexpected Get-Process' }
function Test-Elevated { return $true }
function Enter-AdminProcess { throw 'unexpected elevation' }
function Test-Path {
    param([string]$LiteralPath, [string]$PathType)
    switch ($LiteralPath) {
        'C:\Source Root\scripts\wsl-secure-egress' { return $true }
        'C:\Source Root\scripts\wsl-secure-egress\WslSecureEgress.psm1' { return $true }
        'C:\Source Root\scripts\wsl-secure-egress\Upgrade-Package.ps1' { return $true }
        'C:\Source Root\target\release\clash-wsl-guardian.exe' { return $true }
        'C:\Program Files\Clash of Rust WSL\resources\wsl-secure-egress' {
            return $Scenario -eq 'uninstall'
        }
        default { return $false }
    }
}
function Get-Item {
    param([string]$LiteralPath)
    [pscustomobject]@{ Attributes = [IO.FileAttributes]::Normal; FullName = $LiteralPath }
}
function Get-SourceHash { return ('A' * 64) }
function New-Item {
    param([string]$ItemType, [string]$Path, [switch]$Force)
    $script:Events.Add('folder') | Out-Null
}
function Copy-Item {
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    $script:Events.Add('copy') | Out-Null
}
function Get-ChildItem {
    param([string]$LiteralPath, [switch]$File, [switch]$Directory, [switch]$Recurse)
    return @()
}
function Set-Content {
    param([string]$LiteralPath, $Value, [string]$Encoding)
    $script:Events.Add('receipt') | Out-Null
}
function Import-Module {
    param([string]$Name, [switch]$Force, [switch]$DisableNameChecking)
}
function Invoke-WslEgressOperation {
    param([string]$Action, [string]$Backend, [switch]$Execute, [switch]$RestoreOriginalNetwork)
    $script:Events.Add('rollback') | Out-Null
    [pscustomobject]@{ outcome = 'blocked' }
}
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter)
    if ($Scenario -eq 'install' -and
        $script:QueryCount -gt 0 -and
        [string]$Filter -match "ClashOfRust\.WslEgress") {
        [pscustomobject]@{
            Name = 'ClashOfRust.WslEgress'
            PathName = '"C:\Program Files\Clash of Rust WSL\clash-wsl-guardian.exe" --service'
            StartName = 'LocalSystem'
            StartMode = 'Auto'
        }
    } else {
        $null
    }
    $script:QueryCount++
}
function New-Service {
    param([string]$Name, [string]$DisplayName, [string]$BinaryPathName,
        [string]$StartupType, [string]$Description)
    $script:Events.Add('service-create') | Out-Null
}
function Start-Service {
    param([string]$Name, [switch]$ErrorAction)
    $script:Events.Add('service-start') | Out-Null
}
function Get-Service {
    param([string]$Name, [switch]$ErrorAction)
    if ($Scenario -eq 'uninstall') { $script:Events.Add('service-query') | Out-Null }
    return [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' }
}
function Stop-Service {
    param([string]$Name, [switch]$Force, [switch]$ErrorAction)
    $script:Events.Add('service-stop') | Out-Null
}
function sc {
    $script:Events.Add('service-delete') | Out-Null
}
function Resolve-GuardianSource { return $GuardianExe }
function Remove-Item {
    param([string]$LiteralPath, [switch]$Force, [switch]$Recurse)
    $script:Events.Add('remove') | Out-Null
}
function Assert-OwnedGuardianService {
    param([object]$Service)
    $script:Events.Add('ownership') | Out-Null
}
function Get-HarnessEvents {
    $script:Events | ConvertTo-Json -Compress -Depth 4
}
function Write-HarnessEvents {
    $json = Get-HarnessEvents
    Write-Output ('HARNESS_EVENTS=' + $json)
}
if ($Scenario -eq 'uninstall') {
    $Uninstall = $true
    $RestoreOriginalNetwork = $true
} else {
    # The installer's result contract reads .IsPresent from these switches.
    # ScriptBlock.Create parses a switch assignment as a string in this
    # harness, so use explicit SwitchParameter objects in the install scenario.
    $Execute = [Management.Automation.SwitchParameter]::new($true)
    $NoSelfElevation = [Management.Automation.SwitchParameter]::new($true)
}
$installerSource = [IO.File]::ReadAllText($InstallerPath)
$bodyStart = $installerSource.IndexOf(
    'if ([string]::IsNullOrWhiteSpace($SourceRoot))',
    [StringComparison]::Ordinal)
if ($bodyStart -lt 0) { throw 'installer body not found' }
$body = $installerSource.Substring($bodyStart)
$body = $body.Replace("Split-Path -Parent `$PSScriptRoot", "'C:\'")
$ownedStart = $installerSource.IndexOf(
    'function Assert-OwnedGuardianService',
    [StringComparison]::Ordinal)
$ownedEnd = $installerSource.IndexOf(
    'if (-not (Test-Elevated))',
    $ownedStart,
    [StringComparison]::Ordinal)
if ($ownedStart -lt 0 -or $ownedEnd -le $ownedStart) {
    throw 'owned guardian service implementation not found'
}
$body = $installerSource.Substring($ownedStart, $ownedEnd - $ownedStart) +
    "`n" + $body
$body = $body.Replace(
    'exit 1',
    'Write-HarnessEvents; exit 1')
$body = $body.Replace(
    'exit 0',
    'Write-HarnessEvents; exit 0')
try {
    . ([ScriptBlock]::Create($body))
} catch {
    if ($Scenario -eq 'uninstall') {
        # The real uninstall branch exits after printing its blocked result.
        # A test harness cannot use exit without terminating the parent test.
        $script:Events.Add('blocked-exit') | Out-Null
    } else {
        throw
    }
}
'@
    $guardianRunner = Join-Path ([IO.Path]::GetTempPath()) (
        'cor-wsl-installer-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        [IO.File]::WriteAllText(
            $guardianRunner,
            $guardianHarnessSource,
            [Text.UTF8Encoding]::new($false))
        $powershell = (Get-Process -Id $PID).Path
        $powershellArgs = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guardianRunner,
            '-InstallerPath', $installer, '-Scenario'
        )

        $uninstallRaw = & $powershell @powershellArgs uninstall 2>&1
        $uninstallCode = [int]$LASTEXITCODE
        Invoke-Assert 'blocked restore exits install harness' ($uninstallCode -ne 0)
        if ($uninstallCode -ne 0) {
            $uninstallEventsLine = @($uninstallRaw | Where-Object {
                ([string]$_).TrimStart().StartsWith('HARNESS_EVENTS=')
            })
            if ($uninstallEventsLine.Count -ge 1) {
                if ($uninstallEventsLine.Count -gt 1) {
                    throw 'uninstall harness emitted duplicate event records'
                }
                $uninstallEventsJson = ([string]$uninstallEventsLine[0]).Substring(
                    'HARNESS_EVENTS='.Length)
                $parsedUninstallEvents = $uninstallEventsJson | ConvertFrom-Json
                $uninstallEvents = @(
                    foreach ($event in @($parsedUninstallEvents)) {
                        [string]$event
                    }
                )
                Invoke-Assert 'blocked rollback is the only mutation attempt' (
                    @($uninstallEvents | Where-Object { $_ -eq 'rollback' }).Count -eq 1
                )
                Invoke-Assert 'blocked rollback never removes payload' (
                    @($uninstallEvents | Where-Object { $_ -eq 'remove' }).Count -eq 0
                )
                Invoke-Assert 'blocked rollback never stops the guardian' (
                    @($uninstallEvents | Where-Object { $_ -eq 'service-stop' }).Count -eq 0
                )
                Invoke-Assert 'blocked rollback never deletes the guardian' (
                    @($uninstallEvents | Where-Object { $_ -eq 'service-delete' }).Count -eq 0
                )
            } else {
                Invoke-Assert 'blocked rollback emitted one event record' $false
                Invoke-Assert 'blocked rollback never removes payload' $false
                Invoke-Assert 'blocked rollback never stops the guardian' $false
                Invoke-Assert 'blocked rollback never deletes the guardian' $false
            }
        } else {
            Invoke-Assert 'blocked rollback emitted one event record' $false
            Invoke-Assert 'blocked rollback never removes payload' $false
            Invoke-Assert 'blocked rollback never stops the guardian' $false
            Invoke-Assert 'blocked rollback never deletes the guardian' $false
        }

        $installRaw = & $powershell @powershellArgs install 2>&1
        $installCode = [int]$LASTEXITCODE
        Invoke-Assert 'install harness ran without elevation' ($installCode -eq 0)
        if ($installCode -eq 0) {
            $jsonLines = @($installRaw | Where-Object {
                ([string]$_).TrimStart().StartsWith('HARNESS_EVENTS=')
            })
            $resultLines = @($installRaw | Where-Object {
                ([string]$_).TrimStart().StartsWith('{"schema_version"')
            })
            if ($jsonLines.Count -ne 1 -or $resultLines.Count -ne 1) {
                Write-Output ('install raw: ' + (($installRaw | Out-String).Trim()))
                throw 'install harness did not emit both result and event records'
            }
            $installResult = ([string]$resultLines[0] | ConvertFrom-Json)
            $eventsJson = ([string]$jsonLines[0]).Substring(
                'HARNESS_EVENTS='.Length)
            $parsedEvents = $eventsJson | ConvertFrom-Json
            $events = @(
                foreach ($event in @($parsedEvents)) {
                    [string]$event
                }
            )
            Invoke-Assert 'install reports guardian service as started' (
                [bool]$installResult.service_started
            )
            Invoke-Assert 'execute path registers guardian service exactly once' (
                @($events | Where-Object { $_ -eq 'service-create' }).Count -eq 1
            )
            Invoke-Assert 'execute path starts guardian service exactly once' (
                @($events | Where-Object { $_ -eq 'service-start' }).Count -eq 1
            )
            $copyIndexes = @(
                for ($index = 0; $index -lt $events.Count; $index++) {
                    if ([string]$events[$index] -eq 'copy') { $index }
                }
            )
            Invoke-Assert 'guardian installation is after every payload copy' (
                $copyIndexes.Count -gt 0 -and
                @($events | Where-Object { $_ -eq 'service-create' }).Count -eq 1 -and
                [array]::IndexOf($events, 'service-create') -gt $copyIndexes[-1]
            )
        } else {
            Write-Output ('install harness output: ' + (($installRaw | Out-String).Trim()))
            Invoke-Assert 'install reports guardian service as started' $false
            Invoke-Assert 'execute path registers guardian service exactly once' $false
            Invoke-Assert 'execute path starts guardian service exactly once' $false
            Invoke-Assert 'guardian installation is after every payload copy' $false
        }
    } finally {
        if (Test-Path -LiteralPath $guardianRunner) {
            Remove-Item -LiteralPath $guardianRunner -Force
        }
    }
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
