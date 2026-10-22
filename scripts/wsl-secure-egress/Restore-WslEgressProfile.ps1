#Requires -Version 5.1
<#
.SYNOPSIS
Restore the protected WireGuard profile from the installed Linux manager.

.DESCRIPTION
Reads the root-owned profile from the installed manager distribution through
binary standard output, validates its hash and schema without printing
secrets, and atomically writes it to the Windows profile location with a
protected ACL.

The approved SHA256 is mandatory and is never shipped with the script. Obtain
it from the manager distribution, for example with
`sha256sum /etc/cor-egress/profile.json`, which prints only the digest. The
source distribution defaults to the manager recorded in the broker journal.

Preview is the default. Pass -Execute from an elevated PowerShell session.
The script never writes profile contents to its logs.
#>
[CmdletBinding()]
param(
    [string]$ProfilePath = "$env:LOCALAPPDATA\ClashOfRust\WslEgress\profile.json",
    [string]$SourceDistro = '',
    [string]$ExpectedSha256 = '',
    [string]$ExpectedEndpointIpv4 = '',
    [string]$StatePath = (Join-Path $env:ProgramData 'ClashOfRust\WslEgress\state.json'),
    [string]$WslExecutable = (Join-Path $env:SystemRoot 'System32\wsl.exe'),
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-SourceDistro([string]$Requested, [string]$Journal) {
    $name = $Requested
    if (-not $name) {
        if (-not (Test-Path -LiteralPath $Journal -PathType Leaf)) {
            throw 'Pass -SourceDistro; no broker journal records the manager distribution.'
        }
        $name = [string]((Get-Content -LiteralPath $Journal -Raw | ConvertFrom-Json).manager_distro)
    }
    # The name is placed on the wsl.exe command line, so only plain WSL
    # distribution names are accepted.
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw 'The manager distribution name is missing or invalid.'
    }
    $name
}

function Assert-UnicastIpv4([object]$Value, [string]$Name) {
    $address = $null
    $text = [string]$Value
    if ($text -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        -not [Net.IPAddress]::TryParse($text, [ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "The installed Linux profile has an invalid $Name."
    }
    $bytes = $address.GetAddressBytes()
    if ($bytes[0] -eq 0 -or $bytes[0] -eq 127 -or $bytes[0] -ge 224) {
        throw "The installed Linux profile has a non-unicast $Name."
    }
}

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

function Get-Sha256File([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
    } finally {
        if ($stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Read-LinuxProfile([string]$Distro, [string]$Executable) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
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

function Assert-ProfileDocument([byte[]]$Bytes, [string]$Distro, [string]$Endpoint) {
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
    # Deployment values (endpoint, tunnel and resolver addresses) are private
    # data. They are validated by shape here and pinned by the approved hash.
    if ([int]$profile.schema -ne 1 -or
        [string]$profile.backend -ne 'wireguard' -or
        [string]$profile.manager_distro -ne $Distro -or
        [int]$profile.endpoint_port -lt 1 -or [int]$profile.endpoint_port -gt 65535 -or
        [int]$profile.uid -lt 1000 -or [int]$profile.gid -lt 1000) {
        throw 'The installed Linux profile does not match the protected configuration.'
    }
    Assert-UnicastIpv4 $profile.endpoint_ipv4 'endpoint_ipv4'
    Assert-UnicastIpv4 $profile.resolver_ipv4 'resolver_ipv4'
    $tunnel = [string]$profile.tunnel_address
    if ($tunnel -notmatch '^([^/]+)/(\d{1,2})$' -or [int]$Matches[2] -gt 32) {
        throw 'The installed Linux profile has an invalid tunnel_address.'
    }
    Assert-UnicastIpv4 $Matches[1] 'tunnel_address'
    if ($Endpoint -and [string]$profile.endpoint_ipv4 -ne $Endpoint) {
        throw 'The installed Linux profile endpoint differs from the expected endpoint.'
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
    # .NET ACL APIs are used instead of Set-Acl because the elevated worker
    # environment cannot always autoload the PowerShell security module.
    function New-Rule([string]$Sid, [string]$Rights, [string]$Inheritance) {
        [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($Sid), $Rights, $Inheritance, 'None', 'Allow')
    }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    # Directory ACEs stay inheritable so later results and receipts written by
    # an elevated helper remain readable by the installing user.
    $directoryAcl = [Security.AccessControl.DirectorySecurity]::new()
    $directoryAcl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $directoryAcl.AddAccessRule((New-Rule $sid 'FullControl' 'ContainerInherit,ObjectInherit'))
    }
    $directoryAcl.AddAccessRule((New-Rule $currentSid 'ReadAndExecute' 'ContainerInherit,ObjectInherit'))
    $directoryAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    [IO.Directory]::SetAccessControl($Directory, $directoryAcl)

    $fileAcl = [Security.AccessControl.FileSecurity]::new()
    $fileAcl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $fileAcl.AddAccessRule((New-Rule $sid 'FullControl' 'None'))
    }
    $fileAcl.AddAccessRule((New-Rule $currentSid 'Read' 'None'))
    $fileAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    [IO.File]::SetAccessControl($File, $fileAcl)
}

function Write-ProtectedProfile([string]$Target, [byte[]]$Bytes) {
    $full = [IO.Path]::GetFullPath($Target)
    $directory = [IO.Path]::GetDirectoryName($full)
    Assert-ProtectedDirectory $directory
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.profile-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if ((Get-Sha256File $temporary) -ne $ExpectedSha256) {
            throw 'The temporary profile hash changed.'
        }
        Set-ProfileAcl $directory $temporary
        if (Test-Path -LiteralPath $full) {
            [IO.File]::Replace($temporary, $full, $null)
        } else {
            [IO.File]::Move($temporary, $full)
        }
        Set-ProfileAcl $directory $full
        if ((Get-Sha256File $full) -ne $ExpectedSha256) {
            throw 'The installed profile hash does not match the approved value.'
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    if ($ExpectedSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'Pass -ExpectedSha256 with the approved 64-hex-digit profile digest.'
    }
    $ExpectedSha256 = $ExpectedSha256.ToUpperInvariant()
    $SourceDistro = Resolve-SourceDistro $SourceDistro $StatePath
    $bytes = Read-LinuxProfile $SourceDistro $WslExecutable
    $actual = Get-Sha256Bytes $bytes
    if ($actual -ne $ExpectedSha256) {
        throw 'The installed Linux profile does not match the approved SHA256.'
    }
    Assert-ProfileDocument $bytes $SourceDistro $ExpectedEndpointIpv4
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
