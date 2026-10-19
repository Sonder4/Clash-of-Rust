#Requires -Version 5.1
<#
.SYNOPSIS
  Run the reviewed WSL Secure Egress host transaction from a real elevated
  PowerShell session.

.DESCRIPTION
  The job is intentionally fail-closed. It self-requests UAC once when
  started from a medium-integrity administrator token, stops at the first
  failed stage, and writes DONE.txt only after every runtime assertion passes.
  A failed or cancelled elevation writes FAILED.txt and never claims success.

  This file is a backend deployment helper. It does not touch the CC Switch
  data directory.
#>
[CmdletBinding()]
param(
    [string]$PackageStage = 'F:\Codex\cor-package-stage',
    [string]$ManifestDirectory = 'F:\Codex\cor-upload-manifest',
    [string]$Repository = 'F:\Codex\Clash-of-Rust-work',
    [string]$JobDirectory = 'F:\Codex\admin-job',
    [string]$InstallationRoot = "$env:ProgramFiles\Clash of Rust WSL",
    [string]$ProfilePath = "$env:LOCALAPPDATA\ClashOfRust\WslEgress\profile.json",
    [string]$TestDistro = 'Ubuntu-26.04',
    [switch]$NoSelfElevation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProgressPath = Join-Path $JobDirectory 'PROGRESS.txt'
$ReportPath = Join-Path $JobDirectory 'REPORT.txt'
$DonePath = Join-Path $JobDirectory 'DONE.txt'
$FailedPath = Join-Path $JobDirectory 'FAILED.txt'
$script:Lines = [System.Collections.Generic.List[string]]::new()

New-Item -ItemType Directory -Path $JobDirectory -Force | Out-Null
Remove-Item -LiteralPath $DonePath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $FailedPath -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath $ProgressPath -Value ('started ' + (Get-Date -Format o))

function Write-JobLog {
    param([Parameter(Mandatory)][string]$Message)
    $line = ('{0} {1}' -f (Get-Date -Format o), $Message)
    $script:Lines.Add($Message)
    Add-Content -LiteralPath $ProgressPath -Value $line
}

function Test-HighIntegrity {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $high = @($identity.Groups | Where-Object { $_.Value -eq 'S-1-16-12288' }).Count -gt 0
    [pscustomobject]@{
        User = $identity.Name
        High = $high
        Administrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

function Start-SelfElevated {
    if ($NoSelfElevation) {
        throw 'This job requires a high-integrity administrator token.'
    }
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
        '-PackageStage', $PackageStage,
        '-ManifestDirectory', $ManifestDirectory,
        '-Repository', $Repository,
        '-JobDirectory', $JobDirectory,
        '-InstallationRoot', $InstallationRoot,
        '-ProfilePath', $ProfilePath,
        '-TestDistro', $TestDistro,
        '-NoSelfElevation'
    )
    try {
        $child = Start-Process -FilePath 'powershell.exe' -Verb RunAs `
            -ArgumentList $args -PassThru -Wait -ErrorAction Stop
        if ([int]$child.ExitCode -ne 0) {
            Set-Content -LiteralPath $FailedPath -Value (
                'elevation child exited with code ' + [int]$child.ExitCode)
        }
        exit ([int]$child.ExitCode)
    } catch {
        Set-Content -LiteralPath $FailedPath -Value ('elevation cancelled: ' + $_.Exception.Message)
        exit 1223
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$StageName
    )
    $output = @(& $FilePath @Arguments 2>&1)
    $code = [int]$LASTEXITCODE
    if ($code -ne 0) {
        $safe = (($output | Out-String).Trim() -replace '[\r\n]+', ' ')
        throw ('{0} failed with exit code {1}: {2}' -f $StageName, $code, $safe)
    }
    return $output
}

function Set-ProtectedDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path, [switch]$KeepUserAccess)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required directory is missing: $Path"
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $rules = @(
        'SYSTEM:(OI)(CI)F',
        'Administrators:(OI)(CI)F'
    )
    if ($KeepUserAccess) { $rules += "${sid}:(OI)(CI)F" }
    $result = @(& icacls.exe $Path /inheritance:r /grant:r @rules /T /C 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ('ACL repair failed for {0}: {1}' -f $Path, (($result | Out-String).Trim()))
    }
}

function Assert-Readable {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Expected file is not readable: $Path"
    }
    $null = [IO.File]::OpenRead($Path)
}

function Invoke-Wsl {
    param([Parameter(Mandatory)][string]$Command)
    $out = @(& wsl.exe -d $TestDistro -u root --exec /bin/sh -c $Command 2>&1)
    $code = [int]$LASTEXITCODE
    [pscustomobject]@{ Output = @($out); ExitCode = $code }
}

try {
    $proof = Test-HighIntegrity
    Write-JobLog ('identity user={0} high={1} administrator={2}' -f
        $proof.User, $proof.High, $proof.Administrator)
    if (-not $proof.High -or -not $proof.Administrator) {
        Start-SelfElevated
    }

    Write-JobLog 'stage 1: repair repository and staging ACLs'
    Set-ProtectedDirectoryAcl -Path $Repository -KeepUserAccess
    $adminHost = Join-Path (Split-Path -Parent $PSScriptRoot) 'admin-host'
    if (Test-Path -LiteralPath $adminHost -PathType Container) {
        Set-ProtectedDirectoryAcl -Path $adminHost -KeepUserAccess
    }
    Set-ProtectedDirectoryAcl -Path $PackageStage
    Set-ProtectedDirectoryAcl -Path $ManifestDirectory
    Assert-Readable (Join-Path $Repository '.git\HEAD')
    Write-JobLog 'stage 1: ACL and repository readback passed'

    Write-JobLog 'stage 2: create and apply the protected package manifest'
    $upgrade = Join-Path $Repository 'scripts\wsl-secure-egress\Upgrade-Package.ps1'
    $manifest = Join-Path $ManifestDirectory 'cor-upgrade-manifest.json'
    $create = Invoke-Native -FilePath 'powershell.exe' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
        '-Action', 'CreateManifest', '-PackagePath', $PackageStage,
        '-ManifestPath', $manifest
    ) -StageName 'CreateManifest'
    Assert-Readable $manifest
    $digest = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
    $null = Invoke-Native -FilePath 'powershell.exe' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
        '-Action', 'Apply', '-InstallationPath', $InstallationRoot,
        '-PackagePath', $PackageStage, '-ManifestPath', $manifest,
        '-ExpectedManifestSha256', $digest
    ) -StageName 'Apply'
    $null = Invoke-Native -FilePath 'powershell.exe' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
        '-Action', 'Commit', '-InstallationPath', $InstallationRoot,
        '-PackagePath', $PackageStage
    ) -StageName 'Commit'
    Write-JobLog 'stage 2: package apply and commit passed'

    Write-JobLog 'stage 3: start the installed WireGuard egress broker'
    $manage = Join-Path $InstallationRoot 'resources\wsl-secure-egress\Manage-WslSecureEgress.ps1'
    $start = Invoke-Native -FilePath 'powershell.exe' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $manage,
        '-Action', 'Start', '-Backend', 'WireGuard',
        '-ProfilePath', $ProfilePath, '-Execute'
    ) -StageName 'Start'
    $response = (($start | Out-String).Trim() | ConvertFrom-Json)
    if ([string]$response.outcome -ne 'succeeded') {
        throw ('Start returned outcome {0}' -f [string]$response.outcome)
    }
    Write-JobLog 'stage 3: broker start returned succeeded'

    Write-JobLog ('stage 4: runtime acceptance in {0}' -f $TestDistro)
    $checks = [System.Collections.Generic.List[string]]::new()
    $public = Invoke-Wsl 'curl -4 -fsS --connect-timeout 15 https://ifconfig.co/ip'
    if ($public.ExitCode -ne 0 -or (($public.Output -join '').Trim() -ne '62.84.164.122')) {
        throw ('IPv4 egress assertion failed: {0}' -f (($public.Output -join ' ').Trim()))
    }
    $checks.Add('ipv4=62.84.164.122')
    $dns = Invoke-Wsl 'getent hosts api.openai.com'
    if ($dns.ExitCode -ne 0) { throw 'DNS resolution through the tunnel failed.' }
    $checks.Add('dns=resolved')
    $v6 = Invoke-Wsl 'curl -6 -fsS --connect-timeout 10 https://ifconfig.co/ip'
    if ($v6.ExitCode -eq 0) { throw 'IPv6 egress unexpectedly succeeded.' }
    $checks.Add('ipv6=blocked')
    $interop = Invoke-Wsl 'command -v ipconfig.exe'
    if ($interop.ExitCode -eq 0) { throw 'Windows ipconfig.exe is reachable from the managed distro.' }
    $checks.Add('interop=blocked')
    $nft = Invoke-Wsl 'nft list tables'
    if ($nft.ExitCode -ne 0 -or (($nft.Output -join "`n") -notmatch 'cor_egress_guard')) {
        throw 'Linux fail-closed nftables guard is missing.'
    }
    $checks.Add('nft=cor_egress_guard')
    Write-JobLog ('stage 4: ' + ($checks -join ', '))

    Set-Content -LiteralPath $ReportPath -Value @($script:Lines)
    Set-Content -LiteralPath $DonePath -Value ('done ' + (Get-Date -Format o))
    Write-JobLog 'completed: all stages and assertions passed'
    exit 0
} catch {
    $message = $_.Exception.Message
    try {
        Add-Content -LiteralPath $ProgressPath -Value ('FAILED ' + (Get-Date -Format o) + ' ' + $message)
        Set-Content -LiteralPath $ReportPath -Value @($script:Lines + ('FAILED: ' + $message))
        Set-Content -LiteralPath $FailedPath -Value ('failed ' + (Get-Date -Format o) + ' ' + $message)
        Remove-Item -LiteralPath $DonePath -Force -ErrorAction SilentlyContinue
    } catch { }
    exit 1
}
