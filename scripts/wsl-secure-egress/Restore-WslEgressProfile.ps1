#Requires -Version 5.1
<#
.SYNOPSIS
Restore the protected WireGuard profile from the installed Linux manager.

.DESCRIPTION
Reads the root-owned profile from Ubuntu-22.04 through binary standard output,
validates its hash and schema without printing secrets, and atomically writes
it to the Windows profile location with a protected ACL.

Preview is the default. Pass -Execute from an elevated PowerShell session.
The script never writes profile contents to its logs.
#>
[CmdletBinding()]
param(
    [string]$ProfilePath = "$env:LOCALAPPDATA\ClashOfRust\WslEgress\profile.json",
    [string]$SourceDistro = 'Ubuntu-22.04',
    [string]$ExpectedSha256 = '9DA000C7399DE02A675C18AE929356DDC5F6072ABA9169E4BE84A85519A397F7',
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This operation requires an elevated administrator token.'
    }
}

function Get-Sha256Bytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Read-LinuxProfile([string]$Distro) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $env:SystemRoot 'System32\wsl.exe'
    # Windows PowerShell 5.1 cannot consume ProcessStartInfo.ArgumentList.
    # Each fixed argument is already a validated single token, so a quote-free
    # command line is sufficient and does not expose the profile.
    $start.Arguments = ('-d {0} -u root --exec /bin/cat /etc/cor-egress/profile.json' -f
        $Distro)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $memory = [IO.MemoryStream]::new()
        try {
            $process.StandardOutput.BaseStream.CopyTo($memory)
            $null = $process.StandardError.ReadToEnd()
            if (-not $process.WaitForExit(30000)) {
                $process.Kill()
                throw 'Reading the installed Linux profile timed out.'
            }
            if ($process.ExitCode -ne 0) {
                throw ('Reading the installed Linux profile failed with exit code {0}.' -f
                    $process.ExitCode)
            }
            if ($memory.Length -le 0 -or $memory.Length -gt 65536) {
                throw 'The installed Linux profile has an invalid size.'
            }
            return ,$memory.ToArray()
        } finally {
            $memory.Dispose()
        }
    } finally {
        $process.Dispose()
    }
}

function Assert-ProfileDocument([byte[]]$Bytes) {
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    $profile = $text | ConvertFrom-Json
    $required = @(
        'schema', 'backend', 'endpoint_ipv4', 'endpoint_port', 'manager_distro',
        'tunnel_address', 'resolver_ipv4', 'uid', 'gid', 'private_key',
        'peer_public_key'
    )
    foreach ($name in $required) {
        if ($null -eq $profile.PSObject.Properties[$name]) {
            throw "The installed Linux profile is missing $name."
        }
    }
    if ([int]$profile.schema -ne 1 -or
        [string]$profile.backend -ne 'wireguard' -or
        [string]$profile.endpoint_ipv4 -ne '62.84.164.122' -or
        [int]$profile.endpoint_port -ne 51820 -or
        [string]$profile.manager_distro -ne 'Ubuntu-22.04' -or
        [string]$profile.tunnel_address -ne '10.77.0.2/32' -or
        [string]$profile.resolver_ipv4 -ne '10.77.0.1' -or
        [int]$profile.uid -lt 1000 -or [int]$profile.gid -lt 1000) {
        throw 'The installed Linux profile does not match the protected configuration.'
    }
    foreach ($name in @('private_key', 'peer_public_key')) {
        try {
            $decoded = [Convert]::FromBase64String([string]$profile.$name)
            if ($decoded.Length -ne 32) { throw 'length' }
        } catch {
            throw "The installed Linux profile contains an invalid $name."
        }
    }
}

function Assert-ProtectedDirectory([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and
            ((Get-Item -LiteralPath $current -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint)) {
            throw 'A redirected profile path was refused.'
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Set-ProfileAcl([string]$Directory, [string]$File) {
    $directoryAcl = [Security.AccessControl.DirectorySecurity]::new()
    $directoryAcl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $directoryAcl.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($sid),
                'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    $directoryAcl.AddAccessRule(
        [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().User,
            'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    $directoryAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -LiteralPath $Directory -AclObject $directoryAcl

    $fileAcl = [Security.AccessControl.FileSecurity]::new()
    $fileAcl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $fileAcl.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($sid),
                'FullControl', 'None', 'None', 'Allow'))
    }
    $fileAcl.AddAccessRule(
        [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().User,
            'Read', 'None', 'None', 'Allow'))
    $fileAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -LiteralPath $File -AclObject $fileAcl
}

function Write-ProtectedProfile([string]$Target, [byte[]]$Bytes) {
    $full = [IO.Path]::GetFullPath($Target)
    $directory = [IO.Path]::GetDirectoryName($full)
    Assert-ProtectedDirectory $directory
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.profile-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $ExpectedSha256) {
            throw 'The temporary profile hash changed.'
        }
        Set-ProfileAcl $directory $temporary
        if (Test-Path -LiteralPath $full) {
            [IO.File]::Replace($temporary, $full, $null)
        } else {
            [IO.File]::Move($temporary, $full)
        }
        Set-ProfileAcl $directory $full
        if ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ne $ExpectedSha256) {
            throw 'The installed profile hash does not match the approved value.'
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    $bytes = Read-LinuxProfile $SourceDistro
    $actual = Get-Sha256Bytes $bytes
    if ($actual -ne $ExpectedSha256) {
        throw 'The installed Linux profile does not match the approved SHA256.'
    }
    Assert-ProfileDocument $bytes
    if ($Execute) {
        Assert-Administrator
        Write-ProtectedProfile $ProfilePath $bytes
        $outcome = 'succeeded'
        $message = 'The protected WireGuard profile was restored and validated.'
    } else {
        $outcome = 'not_run'
        $message = 'Profile source and schema validated; no Windows file was written.'
    }
    [ordered]@{
        schema_version = 1
        component = 'clash-of-wsl'
        action = 'restore-profile'
        outcome = $outcome
        executed = $Execute.IsPresent
        source_distro = $SourceDistro
        hash_matches = $true
        schema_valid = $true
        secrets_printed = $false
    } | ConvertTo-Json -Compress
    exit 0
} catch {
    [ordered]@{
        schema_version = 1
        component = 'clash-of-wsl'
        action = 'restore-profile'
        outcome = 'failed'
        executed = $Execute.IsPresent
        hash_matches = $false
        schema_valid = $false
        secrets_printed = $false
        message = $_.Exception.Message
    } | ConvertTo-Json -Compress
    exit 1
}
