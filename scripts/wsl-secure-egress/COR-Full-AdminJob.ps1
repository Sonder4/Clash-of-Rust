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
    [string]$PackageStage = "$env:LOCALAPPDATA\ClashOfRust\WslEgress\cor-package-stage",
    [string]$ManifestDirectory = "$env:LOCALAPPDATA\ClashOfRust\WslEgress\cor-upload-manifest",
    [string]$Repository = "$env:LOCALAPPDATA\ClashOfRust\WslEgress\repository",
    [string]$JobDirectory = "$env:LOCALAPPDATA\ClashOfRust\WslEgress\admin-job",
    [string]$VerifiedBuild = "$env:LOCALAPPDATA\ClashOfRust\WslEgress\dist\build",
    [string]$InstallationRoot = "$env:ProgramFiles\Clash of Rust WSL",
    [string]$ProfilePath = "$env:LOCALAPPDATA\ClashOfRust\WslEgress\profile.json",
    [string]$SnapshotRoot = "$env:LOCALAPPDATA\ClashOfRust\WslEgress\ClashOfRust-network-backups",
    [string]$TestDistro = 'Ubuntu-26.04',
    [string]$ExpectedEgressIpv4 = '',
    [string]$ExpectedProfileSha256 = '',
    [string]$PythonExecutable = '',
    [string]$ReviewedCommit = '',
    [switch]$NoSelfElevation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# An elevated PowerShell resolves bare command names through PATH. Every
# Windows tool is therefore addressed by its absolute System32 path.
$script:System32 = Join-Path $env:SystemRoot 'System32'
$script:PowerShellExe = Join-Path $script:System32 'WindowsPowerShell\v1.0\powershell.exe'
$script:WslExe = Join-Path $script:System32 'wsl.exe'
$script:IcaclsExe = Join-Path $script:System32 'icacls.exe'
$script:WhoamiExe = Join-Path $script:System32 'whoami.exe'
$script:SudoExe = Join-Path $script:System32 'sudo.exe'

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
    # WindowsIdentity.Groups does not reliably expose the mandatory label SID
    # on all PowerShell/.NET combinations. Query the token through whoami,
    # which reports the authoritative integrity SID.
    $tokenText = (& $script:WhoamiExe /groups 2>&1 | Out-String)
    $high = ($tokenText -match 'S-1-16-(12288|1688)')
    if (-not $high -and $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        # A real protected write is the final fallback for localized systems
        # whose whoami output omits the SID column.
        $probe = Join-Path $env:ProgramFiles ('cor-admin-integrity-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try { [IO.File]::WriteAllText($probe, 'x'); [IO.File]::Delete($probe); $high = $true } catch { }
    }
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
        '-VerifiedBuild', $VerifiedBuild,
        '-InstallationRoot', $InstallationRoot,
        '-ProfilePath', $ProfilePath,
        '-SnapshotRoot', $SnapshotRoot,
        '-TestDistro', $TestDistro,
        '-NoSelfElevation'
    )
    if ($ExpectedEgressIpv4) { $args += @('-ExpectedEgressIpv4', $ExpectedEgressIpv4) }
    if ($ExpectedProfileSha256) { $args += @('-ExpectedProfileSha256', $ExpectedProfileSha256) }
    if ($PythonExecutable) { $args += @('-PythonExecutable', $PythonExecutable) }
    if ($ReviewedCommit) { $args += @('-ReviewedCommit', $ReviewedCommit) }
    try {
        # Start-Process -Verb RunAs can return a medium-integrity child on this
        # host, so elevation is delegated to Windows sudo, which enforces its
        # own consent contract. This host forces new-window mode. Sudo does not
        # expose the elevated child's exit code, so success is proved only by
        # the DONE/FAILED journal written by the child.
        # Invoke the executable directly with a native argument vector. Passing
        # a prequoted string through Start-Process adds another quoting layer and
        # can split paths such as C:\Program Files\Clash of Rust WSL. The direct
        # invocation is also captured by the offline command-vector regression.
        $sudoArguments = @('--new-window', $script:PowerShellExe) + $args
        $sudoOutput = @(& $script:SudoExe @sudoArguments 2>&1)
        $sudoExitCode = [int]$LASTEXITCODE
        $waiting = [pscustomobject]@{ ExitCode = $sudoExitCode; Output = $sudoOutput }
        if ([int]$waiting.ExitCode -ne 0) {
            Set-Content -LiteralPath $FailedPath -Value (
                'elevation request failed with exit code ' + [int]$waiting.ExitCode)
            exit ([int]$waiting.ExitCode)
        }
        if (Test-Path -LiteralPath $DonePath -PathType Leaf) {
            exit 0
        }
        if (-not (Test-Path -LiteralPath $FailedPath -PathType Leaf)) {
            Set-Content -LiteralPath $FailedPath -Value 'elevated child exited without a completion journal'
        }
        exit 1
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

function Assert-SafeToolPath([string]$Path, [string]$Name) {
    # An elevated process must not execute a tool that an ordinary user can
    # replace. Reject anything inside a profile directory and anything whose
    # file or parent directory grants write access to a non-administrative
    # group.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ('{0} was not found at {1}.' -f $Name, $Path)
    }
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($prefix in @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:TEMP)) {
        if ([string]::IsNullOrWhiteSpace($prefix)) { continue }
        $root = [IO.Path]::GetFullPath($prefix).TrimEnd('\') + '\'
        if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            throw ('{0} resolves inside a user profile directory: {1}' -f $Name, $full)
        }
    }
    $writers = @('S-1-5-32-545', 'S-1-1-0', 'S-1-5-11')
    foreach ($target in @($full, [IO.Path]::GetDirectoryName($full))) {
        $item = Get-Item -LiteralPath $target -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw ('{0} is redirected: {1}' -f $Name, $target)
        }
        foreach ($rule in (Get-Acl -LiteralPath $target).Access) {
            if ($rule.AccessControlType -ne 'Allow') { continue }
            $sid = ''
            try {
                $sid = $rule.IdentityReference.Translate(
                    [Security.Principal.SecurityIdentifier]).Value
            } catch { }
            if ($sid -in $writers -and
                ($rule.FileSystemRights -band
                    [Security.AccessControl.FileSystemRights]::WriteData)) {
                throw ('{0} is writable by {1}; an elevated process must not run it: {2}' -f
                    $Name, $sid, $target)
            }
        }
    }
    $full
}

function Resolve-PythonExecutable([string]$Requested) {
    $candidate = $Requested
    if (-not $candidate) {
        $command = @(Get-Command python.exe -CommandType Application `
            -ErrorAction SilentlyContinue) | Select-Object -First 1
        if (-not $command) {
            throw 'python.exe was not found; pass -PythonExecutable with a machine-wide Python 3 path.'
        }
        $candidate = [string]$command.Source
    }
    Assert-SafeToolPath $candidate 'Python'
}

function Assert-CleanWorktree([string]$Path) {
    # The elevated job executes scripts taken from the worktree. Refusing a
    # dirty tree keeps the executed code identical to the reviewed commit.
    $status = @(& git.exe -C $Path status --porcelain 2>&1)
    $code = [int]$LASTEXITCODE
    if ($code -ne 0) {
        throw ('Unable to read the worktree status; git returned {0}.' -f $code)
    }
    $dirty = @($status | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($dirty.Count -ne 0) {
        throw ('Refusing to run elevated code from a dirty worktree: {0}' -f
            (($dirty | Select-Object -First 5) -join '; '))
    }
    $head = @(& git.exe -C $Path rev-parse HEAD 2>&1)
    if ([int]$LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($head -join ''))) {
        throw 'Unable to record the reviewed commit.'
    }
    [string](($head | Out-String).Trim())
}

function Publish-ReviewedTool([string]$Source, [string]$ToolRoot) {
    # The worktree is writable by the ordinary user, so an elevated process
    # must not execute scripts directly from it. Copy each reviewed script
    # into an administrator-only directory, verify the copy against the bytes
    # that were read, and execute only the protected copy.
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Reviewed tool is missing: $Source"
    }
    $item = Get-Item -LiteralPath $Source -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Reviewed tool is redirected: $Source"
    }
    $target = Join-Path $ToolRoot $item.Name
    [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes($Source))
    if ((Get-SnapshotSha256 $target) -ne (Get-SnapshotSha256 $Source)) {
        throw ('Protected tool copy verification failed: {0}' -f $item.Name)
    }
    $target
}

function Get-IdentitySids([string]$Path) {
    @(Get-Acl -LiteralPath $Path |
        ForEach-Object {
            $_.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        } | ForEach-Object {
            [string]$_.IdentityReference
        })
}

function Set-ProtectedDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path, [switch]$KeepUserAccess)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required directory is missing: $Path"
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    # icacls treats a bare SID as an account name and resolves it before
    # writing the ACL. Prefixing the SID with "*" selects the SID form, which
    # does not depend on an account-name mapping in the elevated token.
    $rules = @(
        '*S-1-5-18:(OI)(CI)F',
        '*S-1-5-32-544:(OI)(CI)F'
    )
    if ($KeepUserAccess) { $rules += "*${sid}:(OI)(CI)F" }
    # Every existing grant is snapshotted into the job directory before the
    # tree-wide rewrite so the user can audit and restore it; git recovers the
    # reviewed contents but not the previous ACL state.
    $before = Get-IdentitySids $Path
    $snapshot = Join-Path $JobDirectory ('acl-before-' +
        [IO.Path]::GetFileName($Path.TrimEnd('\')) + '.txt')
    [IO.File]::WriteAllText($snapshot, (@($before) -join "`r`n") + "`r`n",
        [Text.UTF8Encoding]::new($false))
    $result = @(& $script:IcaclsExe $Path /inheritance:r /grant:r @rules /T /C 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ('ACL repair failed for {0}: {1}' -f $Path, (($result | Out-String).Trim()))
    }
    # A keep-access repair must not silently revoke a previously present
    # identity; a revoke proves the tree changed beyond the reviewed grant set.
    if ($KeepUserAccess) {
        $after = Get-IdentitySids $Path
        $missing = @($before | Where-Object { $_ -notin $after })
        if ($missing.Count -gt 0) {
            throw ('ACL repair dropped existing access for: {0}' -f ($missing -join ', '))
        }
    }
}

function Assert-Readable {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Expected file is not readable: $Path"
    }
    $stream = [IO.File]::OpenRead($Path)
    $stream.Dispose()
}

function ConvertFrom-WslNativeText {
    param([AllowNull()][object[]]$Lines)
    # Redirected wsl.exe output is UTF-16LE. PowerShell can preserve NUL bytes
    # as characters, so normalize them before parsing distribution names.
    @($Lines | ForEach-Object {
        ([string]$_).Replace([string][char]0, '').Trim()
    } | Where-Object { $_ })
}

function Assert-AllWslStopped {
    $result = @(& $script:WslExe --list --running --quiet 2>&1)
    $code = [int]$LASTEXITCODE
    if ($code -ne 0) {
        throw ('Unable to prove that every WSL distribution is stopped; ' +
            'wsl.exe returned exit code {0}.' -f $code)
    }
    $running = @(ConvertFrom-WslNativeText $result)
    if ($running.Count -ne 0) {
        throw ('Refusing host changes while WSL is running: {0}' -f
            ($running -join ', '))
    }
    [pscustomobject]@{
        running = @()
        checked_at = Get-Date -Format o
    }
}

function Get-SnapshotSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Assert-NormalDirectoryPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowMissing
    )
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                -not $item.PSIsContainer) {
                throw ('Snapshot path is redirected or not a directory: {0}' -f
                    $current)
            }
        } elseif (-not $AllowMissing) {
            throw ('Snapshot path is missing: {0}' -f $current)
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function ConvertTo-SnapshotRecord {
    param(
        [AllowNull()][object[]]$Items,
        [string[]]$Properties
    )
    @($Items | ForEach-Object {
        $item = $_
        $record = [ordered]@{}
        foreach ($name in $Properties) {
            $value = $item.PSObject.Properties[$name]
            if ($value) { $record[$name] = $value.Value }
        }
        [pscustomobject]$record
    })
}

function New-WslNetworkSnapshot {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$SnapshotRoot
    )
    $repositoryFull = [IO.Path]::GetFullPath($Repository).TrimEnd('\')
    $snapshotRootFull = [IO.Path]::GetFullPath($SnapshotRoot).TrimEnd('\')
    # Snapshots are deployment evidence, not reviewed source. The user's brief
    # keeps them inside the repository root by name; Permitting any parent
    # directory would let a redirected path escape the audited tree, so the
    # root must be the repository-local backups name under the actual
    # repository passed in.
    $expectedRoot = Join-Path $repositoryFull 'ClashOfRust-network-backups'
    if ($snapshotRootFull -ne $expectedRoot) {
        throw ('The network snapshot root must be {0}.' -f $expectedRoot)
    }

    Assert-NormalDirectoryPath $repositoryFull
    Assert-NormalDirectoryPath $snapshotRootFull -AllowMissing
    New-Item -ItemType Directory -Path $snapshotRootFull -Force | Out-Null
    Assert-NormalDirectoryPath $snapshotRootFull
    $snapshotDirectory = Join-Path $snapshotRootFull (
        'admin-preflight-' + (Get-Date -Format 'yyyyMMddTHHmmssfffZ').Replace(
            (Get-Date -Format 'yyyy'), ''))
    New-Item -ItemType Directory -Path $snapshotDirectory -ErrorAction Stop | Out-Null
    Set-ProtectedDirectoryAcl -Path $snapshotDirectory -KeepUserAccess

    $files = [ordered]@{}
    function Copy-SnapshotSource {
        param([string]$Source, [string]$Destination, [string]$Name)
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
            $files[$Name] = [ordered]@{ state = 'missing'; source = $Source }
            return
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force |
            Out-Null
        [IO.File]::WriteAllBytes($Destination, [IO.File]::ReadAllBytes($Source))
        $sourceHash = Get-SnapshotSha256 $Source
        $destinationHash = Get-SnapshotSha256 $Destination
        if ($sourceHash -ne $destinationHash) {
            throw ('Snapshot copy readback failed: {0}' -f $Name)
        }
        $files[$Name] = [ordered]@{
            state = 'present'
            source = $Source
            destination = $Destination
            sha256 = $destinationHash
        }
    }

    $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
    Copy-SnapshotSource $wslConfig (Join-Path $snapshotDirectory 'files\wslconfig') 'wslconfig'
    $programDataRoot = Join-Path $env:ProgramData 'ClashOfRust\WslEgress'
    foreach ($name in @('state.json', 'guardian-audit.json', 'scope-renewal.json',
        'wslconfig.before')) {
        Copy-SnapshotSource (Join-Path $programDataRoot $name) (
            Join-Path $snapshotDirectory ('files\programdata\' + $name)) $name
    }

    $wslDistributions = @(& $script:WslExe --list --verbose 2>&1)
    if ([int]$LASTEXITCODE -ne 0) {
        throw 'Unable to snapshot the WSL distribution inventory.'
    }
    $distributionLog = Join-Path $snapshotDirectory 'wsl-distributions.txt'
    [IO.File]::WriteAllLines(
        $distributionLog,
        @(ConvertFrom-WslNativeText $wslDistributions),
        [Text.UTF8Encoding]::new($false))

    $hypervPersistentPath = Join-Path $snapshotDirectory 'hyperv-persistent.json'
    $hypervEffectivePath = Join-Path $snapshotDirectory 'hyperv-effective.json'
    $endpointPersistentPath = Join-Path $snapshotDirectory 'endpoint-rules-persistent.json'
    $endpointEffectivePath = Join-Path $snapshotDirectory 'endpoint-rules-effective.json'
    $guardianServicePath = Join-Path $snapshotDirectory 'guardian-service.json'
    $scheduledTaskPath = Join-Path $snapshotDirectory 'renewal-task.json'
    $settingFields = @(
        'Name', 'Enabled', 'DefaultInboundAction', 'DefaultOutboundAction',
        'AllowHostPolicyMerge', 'LoopbackEnabled', 'VMCreatorId'
    )
    $ruleFields = @(
        'Name', 'DisplayName', 'Enabled', 'Direction', 'Action', 'Protocol',
        'RemoteAddresses', 'RemotePorts', 'VMCreatorId', 'RulePriority'
    )
    $hypervPersistent = @(ConvertTo-SnapshotRecord @(
        Get-NetFirewallHyperVVMSetting -PolicyStore PersistentStore) $settingFields)
    $hypervEffective = @(ConvertTo-SnapshotRecord @(
        Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore) $settingFields)
    $endpointPersistent = @(ConvertTo-SnapshotRecord @(
        Get-NetFirewallHyperVRule -PolicyStore PersistentStore |
            Where-Object { $_.Name -eq 'ClashOfRust-WslEgress-Endpoint' }) $ruleFields)
    $endpointEffective = @(ConvertTo-SnapshotRecord @(
        Get-NetFirewallHyperVRule -PolicyStore ActiveStore |
            Where-Object { $_.Name -eq 'ClashOfRust-WslEgress-Endpoint' }) $ruleFields)
    $guardianService = @(ConvertTo-SnapshotRecord @(
        Get-CimInstance Win32_Service |
            Where-Object { $_.Name -eq 'ClashOfRust.WslEgress' }
        ) @('Name','State','StartMode','ProcessId','PathName','StartName'))
    $renewalTask = @(ConvertTo-SnapshotRecord @(Get-ScheduledTask `
        -TaskName 'ClashOfRust-WslEgress-Renew' -ErrorAction SilentlyContinue) @(
        'TaskName','TaskPath','State'))
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText(
        $hypervPersistentPath, ($hypervPersistent | ConvertTo-Json -Depth 8), $utf8)
    [IO.File]::WriteAllText(
        $hypervEffectivePath, ($hypervEffective | ConvertTo-Json -Depth 8), $utf8)
    [IO.File]::WriteAllText(
        $endpointPersistentPath, ($endpointPersistent | ConvertTo-Json -Depth 8), $utf8)
    [IO.File]::WriteAllText(
        $endpointEffectivePath, ($endpointEffective | ConvertTo-Json -Depth 8), $utf8)
    [IO.File]::WriteAllText(
        $guardianServicePath, ($guardianService | ConvertTo-Json -Depth 8), $utf8)
    [IO.File]::WriteAllText(
        $scheduledTaskPath, ($renewalTask | ConvertTo-Json -Depth 8), $utf8)

    foreach ($entry in @(
        @('wsl-distributions.txt', $distributionLog),
        @('hyperv-persistent.json', $hypervPersistentPath),
        @('hyperv-effective.json', $hypervEffectivePath),
        @('endpoint-rules-persistent.json', $endpointPersistentPath),
        @('endpoint-rules-effective.json', $endpointEffectivePath),
        @('guardian-service.json', $guardianServicePath),
        @('renewal-task.json', $scheduledTaskPath)
    )) {
        $files[$entry[0]] = [ordered]@{
            state = 'present'
            destination = $entry[1]
            sha256 = Get-SnapshotSha256 $entry[1]
        }
    }

    $manifest = [ordered]@{
        schema_version = 1
        created_at = (Get-Date -Format o)
        repository = $repositoryFull
        privacy = @(
            'wireguard-profile-excluded',
            'private-keys-excluded',
            'queries-excluded'
        )
        running_wsl = @()
        files = $files
    }
    $manifestPath = Join-Path $snapshotDirectory 'manifest.json'
    [IO.File]::WriteAllText(
        $manifestPath, ($manifest | ConvertTo-Json -Depth 10), $utf8)

    $readback = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($name in $readback.files.PSObject.Properties.Name) {
        $record = $readback.files.$name
        if ($record.state -eq 'present') {
            if (-not (Test-Path -LiteralPath $record.destination -PathType Leaf) -or
                (Get-SnapshotSha256 $record.destination) -ne [string]$record.sha256) {
                throw ('Network snapshot readback failed: {0}' -f $name)
            }
        }
    }
    [pscustomobject]@{
        directory = $snapshotDirectory
        manifest = $manifestPath
        manifest_sha256 = Get-SnapshotSha256 $manifestPath
        running_wsl = @()
    }
}

function Invoke-Wsl {
    # Fixed argv, no shell: the elevated host transaction must never hand a
    # command string to /bin/sh inside the distribution.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = @(& $script:WslExe -d $TestDistro -u root --exec @Arguments 2>&1)
    $code = [int]$LASTEXITCODE
    [pscustomobject]@{ Output = @($out); ExitCode = $code }
}

function Invoke-IsolatedWsl {
    param(
        [Parameter(Mandatory)][long]$Generation,
        [Parameter(Mandatory)][string[]]$Command,
        [string]$InputText
    )
    $helper = '/usr/local/lib/cor-egress/manager'
    $arguments = @(
        '--distribution', $TestDistro,
        '--user', 'root',
        '--exec', $helper,
        'run', '--generation', [string]$Generation,
        '--'
    ) + $Command
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $script:WslExe
    $quoted = foreach ($argument in $arguments) {
        if ($argument.Length -gt 0 -and $argument -notmatch '[\s"]') {
            $argument
        } else {
            '"' + $argument.Replace('\', '\\').Replace('"', '\"') + '"'
        }
    }
    $start.Arguments = $quoted -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        if ($InputText) {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        }
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(90000)) {
            $process.Kill()
            throw 'The strict isolated WSL command timed out.'
        }
        $null = $stderr.GetAwaiter().GetResult()
        [pscustomobject]@{
            Output = @(($stdout.GetAwaiter().GetResult() -split '\r?\n') |
                Where-Object { $_ })
            ExitCode = [int]$process.ExitCode
        }
    } finally {
        $process.Dispose()
    }
}

function Assert-IsolatedRuntime($StartResponse, $State) {
    $generation = [long]$State.generation
    $probe = @'
import ipaddress,json,os,pathlib,subprocess,sys,urllib.request
request=json.load(sys.stdin)
checks={}
def open_https(host):
    request_obj=urllib.request.Request('https://'+host+'/',headers={'User-Agent':'ClashOfWSL-Acceptance/1'})
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request_obj,timeout=15) as response:
        return 100 <= response.status < 500
try:
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open('https://api.ipify.org?format=json',timeout=15) as response:
        checks['public_ipv4']=json.loads(response.read(65537))['ip']==request['vps_ipv4']
except Exception:
    checks['public_ipv4']=False
try:
    interfaces=json.loads(subprocess.check_output(['/usr/sbin/ip','-j','address','show'],timeout=5))
    checks['virtual_interfaces']={item['ifname'] for item in interfaces}=={'lo','wg0','cor-bg0'}
except Exception:
    checks['virtual_interfaces']=False
try:
    result=subprocess.run(['/usr/sbin/ip','-j','route','show','default'],capture_output=True,text=True,timeout=5)
    routes=json.loads(result.stdout or '[]')
    checks['tunnel_default_route']=result.returncode==0 and len(routes)==1 and routes[0].get('dev')=='wg0'
except Exception:
    checks['tunnel_default_route']=False
checks['host_mount_hidden']=not pathlib.Path('/mnt/c').exists() and not pathlib.Path('/init').exists()
checks['interop_guarded']=not pathlib.Path('/mnt/c/Windows/System32/ipconfig.exe').exists()
checks['proxy_environment_clear']=not any(name.lower().endswith('proxy') for name in os.environ)
for name,host in request['providers'].items():
    try: checks['provider_'+name]=open_https(host)
    except Exception: checks['provider_'+name]=False
print(json.dumps({'schema':1,'generation':request['generation'],'checks':checks}))
'@
    $request = [ordered]@{
        generation = $generation
        vps_ipv4 = $ExpectedEgressIpv4
        providers = [ordered]@{
            openai = 'api.openai.com'
            anthropic = 'api.anthropic.com'
            deepseek = 'api.deepseek.com'
        }
    } | ConvertTo-Json -Compress
    $probeResult = Invoke-IsolatedWsl -Generation $generation `
        -Command @('/usr/bin/python3', '-I', '-S', '-c', $probe) -InputText $request
    if ($probeResult.ExitCode -ne 0 -or $probeResult.Output.Length -gt 65536) {
        throw 'The strict isolated runtime probe failed.'
    }
    $report = (($probeResult.Output -join "`n") | ConvertFrom-Json)
    $expected = @(
        'public_ipv4', 'virtual_interfaces', 'tunnel_default_route',
        'host_mount_hidden', 'interop_guarded', 'proxy_environment_clear',
        'provider_openai', 'provider_anthropic', 'provider_deepseek'
    )
    foreach ($name in $expected) {
        if (-not $report.checks.PSObject.Properties[$name] -or
            $report.checks.$name -ne $true) {
            throw ("Strict isolated runtime check failed: {0}" -f $name)
        }
    }
    $dns = Invoke-IsolatedWsl -Generation $generation `
        -Command @('/usr/bin/getent', 'ahostsv4', 'api.openai.com')
    if ($dns.ExitCode -ne 0) {
        throw 'DNS resolution through the tunnel failed in the strict launcher.'
    }
    $v6 = Invoke-IsolatedWsl -Generation $generation `
        -Command @('/usr/bin/curl', '-6', '-fsS', '--connect-timeout', '8', 'https://ifconfig.co/ip')
    if ($v6.ExitCode -eq 0) {
        throw 'IPv6 egress unexpectedly succeeded in the strict launcher.'
    }
    $nft = Invoke-Wsl @('/usr/sbin/nft', 'list', 'tables')
    if ($nft.ExitCode -ne 0 -or
        (($nft.Output -join "`n") -notmatch 'cor_egress_guard')) {
        throw 'Linux fail-closed nftables guard is missing.'
    }
}

try {
    # The deployment address and the approved profile digest are private data
    # and are never stored in this file. The operator supplies both from the
    # protected profile before running the job.
    if ($ExpectedEgressIpv4 -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        -not [Net.IPAddress]::TryParse(
            $ExpectedEgressIpv4, [ref][Net.IPAddress]::Loopback) -or
        $ExpectedEgressIpv4 -match '^0\.|^127\.|^(2(2[3-9]|[3-9][0-9])|2[34-9][0-9])\.') {
        throw 'Pass -ExpectedEgressIpv4 with the approved public VPS IPv4 address.'
    }
    $ExpectedEgressIpv4 = $ExpectedEgressIpv4.Trim()
    if ($ExpectedProfileSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'Pass -ExpectedProfileSha256 with the approved 64-hex-digit profile digest.'
    }
    $ExpectedProfileSha256 = $ExpectedProfileSha256.ToUpperInvariant()

    $proof = Test-HighIntegrity
    Write-JobLog ('identity user={0} high={1} administrator={2}' -f
        $proof.User, $proof.High, $proof.Administrator)
    if (-not $proof.High -or -not $proof.Administrator) {
        # The interpreter is resolved and the worktree is inspected in the
        # invoking medium-integrity session, before any elevation request.
        # Neither step runs elevated, so a user-writable git or python cannot
        # be used to escalate.
        $PythonExecutable = Resolve-PythonExecutable $PythonExecutable
        $ReviewedCommit = Assert-CleanWorktree $Repository
        Write-JobLog ('reviewed commit={0} python={1}' -f
            $ReviewedCommit, $PythonExecutable)
        Start-SelfElevated
    }

    Write-JobLog 'stage 0a: require every WSL distribution to be stopped'
    $null = Assert-AllWslStopped
    Write-JobLog 'stage 0a: all WSL distributions are stopped'

    Write-JobLog 'stage 0b: snapshot network state inside the repository'
    $snapshot = New-WslNetworkSnapshot -Repository $Repository `
        -SnapshotRoot $SnapshotRoot
    $null = Assert-AllWslStopped
    Write-JobLog 'stage 0b: all WSL distributions remained stopped during snapshot'
    Write-JobLog ('stage 0b: snapshot={0} sha256={1}' -f
        $snapshot.manifest, $snapshot.manifest_sha256)

    Write-JobLog 'stage 0c: publish the reviewed tools to an administrator-only directory'
    if ($ReviewedCommit -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') {
        throw 'The reviewed commit was not supplied by the invoking session.'
    }
    Write-JobLog ('stage 0c: reviewed commit={0}' -f $ReviewedCommit)
    $PythonExecutable = Assert-SafeToolPath $PythonExecutable 'Python'
    $toolRoot = Join-Path $JobDirectory 'protected-tools'
    if (-not (Test-Path -LiteralPath $toolRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
    }
    Set-ProtectedDirectoryAcl -Path $toolRoot
    $reviewedTools = Join-Path $Repository 'scripts\wsl-secure-egress'
    $restoreTool = Publish-ReviewedTool (
        Join-Path $reviewedTools 'Restore-WslEgressProfile.ps1') $toolRoot
    $stageTool = Publish-ReviewedTool (
        Join-Path $reviewedTools 'Prepare-PackageStage.ps1') $toolRoot
    $upgradeTool = Publish-ReviewedTool (
        Join-Path $reviewedTools 'Upgrade-Package.ps1') $toolRoot
    Write-JobLog 'stage 0c: protected tool copies verified'

    Write-JobLog 'stage 1a: restore the protected WireGuard profile'
    $profileRestore = Invoke-Native -FilePath $script:PowerShellExe -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $restoreTool,
        '-ProfilePath', $ProfilePath,
        '-ExpectedSha256', $ExpectedProfileSha256,
        '-ExpectedEndpointIpv4', $ExpectedEgressIpv4,
        '-Execute'
    ) -StageName 'RestoreProfile'
    $profileResponse = (($profileRestore | Out-String).Trim() | ConvertFrom-Json)
    if ([string]$profileResponse.outcome -ne 'succeeded' -or
        -not [bool]$profileResponse.hash_matches -or
        -not [bool]$profileResponse.schema_valid) {
        throw 'The protected WireGuard profile restore did not pass validation.'
    }
    Write-JobLog 'stage 1a: profile restored with hash, schema and ACL checks'

    Write-JobLog 'stage 1: protect the manifest directory'
    # Only directories created for this deployment are rewritten. The reviewed
    # worktree is deliberately left untouched: a tree-wide /T repair there
    # would revoke the developer's own ACEs without a prior snapshot and the
    # job never executes from it after stage 0c. The package stage is
    # protected after its rebuild, because -Replace recreates the directory.
    Set-ProtectedDirectoryAcl -Path $ManifestDirectory
    Assert-Readable (Join-Path $Repository '.git\HEAD')
    Write-JobLog 'stage 1: manifest ACL and repository readback passed'

    Write-JobLog 'stage 2a: rebuild the stage from the reviewed repository'
    $stageBuild = Invoke-Native -FilePath $script:PowerShellExe -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $stageTool,
        '-Repository', $Repository, '-PackageStage', $PackageStage,
        '-VerifiedBuild', $VerifiedBuild,
        '-PythonExecutable', $PythonExecutable,
        '-Execute', '-Replace'
    ) -StageName 'PreparePackageStage'
    $stageResponse = (($stageBuild | Out-String).Trim() | ConvertFrom-Json)
    if ([string]$stageResponse.outcome -ne 'succeeded' -or
        [string]$stageResponse.package_stage -ne $PackageStage -or
        -not (Test-Path -LiteralPath (
            Join-Path $PackageStage 'resources\wsl-secure-egress\WslSecureEgress.psm1') -PathType Leaf)) {
        throw 'The reviewed package stage was not built and verified.'
    }
    # The rebuild replaced the directory, so the protected ACL is applied only
    # now, before the manifest digest is created from these contents.
    Set-ProtectedDirectoryAcl -Path $PackageStage
    Write-JobLog 'stage 2a: package stage rebuilt, protected and verified'

    Write-JobLog 'stage 2b: create and apply the protected package manifest'
    $manifest = Join-Path $ManifestDirectory 'cor-upgrade-manifest.json'
    $create = Invoke-Native -FilePath $script:PowerShellExe -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgradeTool,
        '-Action', 'CreateManifest', '-PackagePath', $PackageStage,
        '-ManifestPath', $manifest
    ) -StageName 'CreateManifest'
    Assert-Readable $manifest
    # Get-FileHash cannot always load in the elevated worker environment; the
    # .NET stream hash is equivalent and does not depend on module autoloading.
    $digest = (Get-SnapshotSha256 $manifest)
    $null = Invoke-Native -FilePath $script:PowerShellExe -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgradeTool,
        '-Action', 'Apply', '-InstallationPath', $InstallationRoot,
        '-PackagePath', $PackageStage, '-ManifestPath', $manifest,
        '-ExpectedManifestSha256', $digest
    ) -StageName 'Apply'
    $null = Invoke-Native -FilePath $script:PowerShellExe -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgradeTool,
        '-Action', 'Commit', '-InstallationPath', $InstallationRoot,
        '-PackagePath', $PackageStage
    ) -StageName 'Commit'
    Write-JobLog 'stage 2: package apply and commit passed'

    Write-JobLog 'stage 3: start the installed WireGuard egress broker'
    $manage = Join-Path $InstallationRoot 'resources\wsl-secure-egress\Manage-WslSecureEgress.ps1'
    $start = Invoke-Native -FilePath $script:PowerShellExe -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $manage,
        '-Action', 'Start', '-Backend', 'WireGuard',
        '-ProfilePath', $ProfilePath, '-Execute'
    ) -StageName 'Start'
    $response = (($start | Out-String).Trim() | ConvertFrom-Json)
    if ([string]$response.outcome -ne 'succeeded') {
        throw ('Start returned outcome {0}' -f [string]$response.outcome)
    }
    Write-JobLog 'stage 3: broker start returned succeeded'

    Write-JobLog ('stage 4: strict isolated runtime acceptance in {0}' -f $TestDistro)
    $checks = [System.Collections.Generic.List[string]]::new()
    $statePath = Join-Path $env:ProgramData 'ClashOfRust\WslEgress\state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'The broker state journal is missing after Start.'
    }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ([string]$response.generation -ne [string]$state.generation) {
        throw 'The broker response does not match the installed state generation.'
    }
    if ([string]$state.phase -ne 'Running') {
        throw 'The installed broker journal is not in the running phase after Start.'
    }
    Assert-IsolatedRuntime $response $state
    $checks.Add('public_ipv4=verified')
    $checks.Add('virtual_interfaces=lo,wg0,cor-bg0')
    $checks.Add('default_route=wg0')
    $checks.Add('host_mounts=hidden')
    $checks.Add('interop=blocked')
    $checks.Add('proxy_environment=clear')
    $checks.Add('providers=openai,anthropic,deepseek')
    $checks.Add('dns=resolved')
    $checks.Add('ipv6=blocked')
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
