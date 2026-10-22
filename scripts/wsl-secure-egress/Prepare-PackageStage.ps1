#Requires -Version 5.1
<#
.SYNOPSIS
Build a verified package stage from the current reviewed worktree.

.DESCRIPTION
Copies only the application binaries and WSL helper files required by the
transactional package contract. The output directory is replaced only when
-Replace is supplied.
The staging receipt is written beside, not inside, the package stage because
the upgrade whitelist accepts only package content.

Preview is the default. Pass -Execute to write the staging tree.
#>
[CmdletBinding()]
param(
    [string]$Repository = '',
    [string]$VerifiedBuild = $null,
    [string]$PackageStage = "$env:LOCALAPPDATA\ClashOfRust\WslEgress\cor-package-stage",
    [string]$PythonExecutable = 'python.exe',
    [switch]$Execute,
    [switch]$Replace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stageCreatedByThisRun = $false
$receiptPath = $null
$receiptTemporaryPath = $null

function Get-FileSha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
        finally { $sha.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Copy-VerifiedFile([string]$Source, [string]$Destination, $Records) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required package source is missing: $Source"
    }
    Assert-NoReparseAncestor $Source
    $item = Get-Item -LiteralPath $Source -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Redirected package source was refused: $Source"
    }
    $destinationParent = [IO.Path]::GetDirectoryName($Destination)
    Assert-NoReparseAncestor $destinationParent
    New-Item -ItemType Directory -Path $destinationParent -Force |
        Out-Null
    if ((Test-Path -LiteralPath $Destination) -and
        ((Get-Item -LiteralPath $Destination -Force).Attributes -band
            [IO.FileAttributes]::ReparsePoint)) {
        throw "Redirected package destination was refused: $Destination"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    $sourceHash = Get-FileSha256 $Source
    $destinationHash = Get-FileSha256 $Destination
    if ($sourceHash -ne $destinationHash) {
        throw "Staged file hash mismatch: $Destination"
    }
    $relative = $Destination.Substring($script:StageRoot.Length + 1)
    $Records[$relative] = $destinationHash
}

function Copy-VerifiedTree(
    [string]$Source,
    [string]$Destination,
    [string[]]$IncludeDirectories,
    [string[]]$ExcludeNames,
    $Records
) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Required package source is missing: $Source"
    }
    Assert-NoReparseAncestor $Source
    foreach ($file in @(Get-ChildItem -LiteralPath $Source -File -Force)) {
        if ($file.Name -in $ExcludeNames -or $file.Extension -in @('.pyc', '.log', '.tmp')) {
            continue
        }
        Copy-VerifiedFile $file.FullName (Join-Path $Destination $file.Name) $Records
    }
    foreach ($directoryName in $IncludeDirectories) {
        $directory = Join-Path $Source $directoryName
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw "Required package directory is missing: $directory"
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Recurse -File -Force)) {
            $relative = $file.FullName.Substring($directory.Length + 1)
            $target = Join-Path (Join-Path $Destination $directoryName) $relative
            Copy-VerifiedFile $file.FullName $target $Records
        }
    }
}

function Assert-StagingWhitelist([string]$Path) {
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File)) {
        $relative = $file.FullName.Substring($Path.Length + 1)
        if ($relative -notmatch
            '^(?:clash-of-rust\.exe|clash-tun-launcher\.exe|clash-wsl-guardian\.exe|LICENSE|uninstall\.exe|resources\\[A-Za-z0-9_.\\-]+)$') {
            throw "A staged file is outside the package whitelist: $relative"
        }
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "A staged file is redirected: $relative"
        }
    }
}

function Assert-NoReparseAncestor([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "A redirected staging path was refused: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Remove-CreatedStage([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        -not $item.PSIsContainer) {
        throw 'Created staging cleanup refused an unsafe path.'
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Remove-NormalFileIfPresent([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $item.PSIsContainer) {
        throw 'Refused unsafe file cleanup.'
    }
    Remove-Item -LiteralPath $Path -Force
}

function Assert-NormalReceiptPath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $item.PSIsContainer) {
        throw 'The staging receipt target must be a normal file.'
    }
}

function Write-ReceiptAtomically([string]$TemporaryPath, [string]$FinalPath, [string]$Content) {
    Assert-NormalReceiptPath $FinalPath
    Assert-NormalReceiptPath $TemporaryPath
    Assert-NoReparseAncestor ([IO.Path]::GetDirectoryName($FinalPath))
    Assert-NoReparseAncestor ([IO.Path]::GetDirectoryName($TemporaryPath))
    [IO.File]::WriteAllText(
        $TemporaryPath,
        $Content,
        [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $FinalPath) {
        [IO.File]::Replace(
            $TemporaryPath,
            $FinalPath,
            [System.Management.Automation.Language.NullString]::Value)
    } else {
        [IO.File]::Move($TemporaryPath, $FinalPath)
    }
}

function Get-DependencySnapshot([string]$Repository, [string]$BuildPath) {
    # The verifier requires the frozen dependency snapshot as a directory that
    # still holds inputs.json. A published build only carries the same object
    # inside manifest.json under build_inputs, so reconstruct it byte-for-byte
    # and verify every referenced file against the current worktree before the
    # verifier is allowed to trust it.
    $build = [IO.Path]::GetFullPath($BuildPath).TrimEnd('\')
    $manifestPath = Join-Path $build 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The build manifest is missing; a verified build is required.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $inputs = $manifest.PSObject.Properties['build_inputs']
    if (-not $inputs -or $null -eq $inputs.Value) {
        throw 'The build manifest omits the frozen dependency snapshot.'
    }
    $directory = Join-Path $build 'dependency-snapshot'
    Assert-NoReparseAncestor $directory
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $document = $inputs.Value | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText((Join-Path $directory 'inputs.json'), $document,
        [Text.UTF8Encoding]::new($false))
    $snapshot = $document | ConvertFrom-Json
    foreach ($name in @('commit', 'baseline', 'constraints', 'files')) {
        if ($null -eq $snapshot.PSObject.Properties[$name]) {
            throw ('The frozen dependency snapshot omits {0}.' -f $name)
        }
    }
    foreach ($relative in @($snapshot.files.PSObject.Properties.Name)) {
        $source = Join-Path $Repository $relative
        $record = $snapshot.files.$relative
        $destination = Join-Path $directory $relative
        $parent = [IO.Path]::GetDirectoryName($destination)
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw ('The dependency snapshot file is missing from the worktree: {0}' -f $relative)
        }
        $actual = Get-FileSha256 $source
        if ($actual -ne [string]$record) {
            throw ('The worktree differs from the frozen dependency snapshot: {0}' -f $relative)
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
        if ((Get-FileSha256 $destination) -ne [string]$record) {
            throw ('The dependency snapshot copy verification failed: {0}' -f $relative)
        }
    }
    $directory
}

function Get-VerifiedBuild([string]$Repository, [string]$BuildPath) {
    if ([string]::IsNullOrWhiteSpace($BuildPath)) {
        throw 'A verified Windows x64 build is required for administrator deployment.'
    }
    $verifier = Join-Path $Repository 'scripts\wsl-secure-egress\verify-build.py'
    if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) {
        throw 'The build verifier is missing.'
    }
    $snapshot = Get-DependencySnapshot -Repository $Repository -BuildPath $BuildPath
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $PythonExecutable $verifier --repository $Repository `
            --build $BuildPath --dependency-snapshot $snapshot `
            --system windows --arch x64 2>&1)
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $code = [int]$LASTEXITCODE
    $text = (($raw | Out-String).Trim())
    Write-Verbose $text
    if ($code -ne 0) {
        throw ('The verified build check failed: ' + $text)
    }
    $response = $null
    try { $response = $text | ConvertFrom-Json } catch { }
    if ($code -ne 0 -or -not $response -or
        [string]$response.outcome -ne 'verified' -or
        [string]$response.system -ne 'windows' -or
        [string]$response.arch -ne 'x64' -or
        [string]$response.profile -ne 'release' -or
        [string]$response.version -ne '0.6.1') {
        throw ('The verified build did not pass the production manifest contract: ' +
            $text)
    }
    $build = [IO.Path]::GetFullPath($BuildPath).TrimEnd('\')
    $payload = Join-Path $build 'payload'
    foreach ($relative in @(
        'clash-of-rust.exe',
        'clash-tun-launcher.exe',
        'clash-wsl-guardian.exe',
        'LICENSE',
        'resources\mihomo.exe'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $payload $relative) -PathType Leaf)) {
            throw "Verified build payload is missing: $relative"
        }
    }
    return [pscustomobject]@{
        root = $build
        payload = $payload
        response = $response
    }
}

$verifiedBuildResult = $null
$binaryDirectory = $null
try {
    if ([string]::IsNullOrWhiteSpace($Repository)) {
        throw 'Pass -Repository with the reviewed worktree path.'
    }
    $repositoryPath = [IO.Path]::GetFullPath($Repository).TrimEnd('\')
    $packageStagePath = [IO.Path]::GetFullPath($PackageStage).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($VerifiedBuild)) {
        throw 'A verified Windows x64 build is required for administrator deployment.'
    }
    $StageParent = [IO.Path]::GetDirectoryName($packageStagePath)
    if (-not $StageParent) { throw 'The staging directory has no parent.' }
    Assert-NoReparseAncestor $StageParent
    if (Test-Path -LiteralPath $packageStagePath) {
        $existingStage = Get-Item -LiteralPath $packageStagePath -Force
        if (($existingStage.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not $existingStage.PSIsContainer) {
            throw 'The staging target must be a normal directory.'
        }
    }
    $script:StageRoot = $packageStagePath
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryPath '.git\HEAD') -PathType Leaf)) {
        throw 'The repository path is not a Git worktree.'
    }
    if ($packageStagePath -eq $repositoryPath -or
        $packageStagePath.StartsWith($repositoryPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The staging directory must be outside the repository.'
    }
    if ($packageStagePath -eq $StageParent -or
        [IO.Path]::GetPathRoot($packageStagePath).TrimEnd('\') -eq $packageStagePath) {
        throw 'Unsafe staging path.'
    }

    $records = [ordered]@{}
    $receiptPath = $packageStagePath + '.stage-receipt.json'
    $receiptTemporaryPath = $receiptPath + '.pending'
    Assert-NormalReceiptPath $receiptPath
    Assert-NormalReceiptPath $receiptTemporaryPath
    $verifiedBuildResult = Get-VerifiedBuild -Repository $repositoryPath `
        -BuildPath $VerifiedBuild
    if ($null -eq $verifiedBuildResult) {
        throw 'The verified build returned no result.'
    }
    $binaryDirectory = [string]$verifiedBuildResult.payload
    if ($Execute) {
        $sources = [ordered]@{
            'clash-of-rust.exe' = Join-Path $binaryDirectory 'clash-of-rust.exe'
            'clash-tun-launcher.exe' = Join-Path $binaryDirectory 'clash-tun-launcher.exe'
            'clash-wsl-guardian.exe' = Join-Path $binaryDirectory 'clash-wsl-guardian.exe'
            'LICENSE' = Join-Path $repositoryPath 'LICENSE'
            'uninstall.exe' = Join-Path 'C:\Program Files\Clash of Rust' 'uninstall.exe'
        }
        foreach ($entry in $sources.GetEnumerator()) {
            if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
                throw "Required staging source is missing: $($entry.Key) ($($entry.Value))"
            }
        }
        if (Test-Path -LiteralPath $packageStagePath) {
            if (-not $Replace) {
                throw 'The staging directory already exists. Pass -Replace after reviewing it.'
            }
            $resolved = (Resolve-Path -LiteralPath $packageStagePath).Path.TrimEnd('\')
            $resolvedItem = Get-Item -LiteralPath $resolved -Force
            if ($resolvedItem.Attributes -band [IO.FileAttributes]::ReparsePoint -or
                $resolved -ne $packageStagePath -or
                [IO.Path]::GetPathRoot($resolved).TrimEnd('\') -eq $resolved) {
                throw 'Unsafe staging replacement path.'
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
        Assert-NormalReceiptPath $receiptPath
        Assert-NormalReceiptPath $receiptTemporaryPath
        # Invalidate prior transaction metadata before replacing its stage.
        Remove-NormalFileIfPresent $receiptPath
        Remove-NormalFileIfPresent $receiptTemporaryPath
        New-Item -ItemType Directory -Path $packageStagePath -Force | Out-Null
        $stageCreatedByThisRun = $true
        # The stage is now owned by this run. A non-directory or reparse-point
        # produced by a race is rejected and the receipt remains absent.
        $createdStageItem = Get-Item -LiteralPath $packageStagePath -Force
        if (($createdStageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not $createdStageItem.PSIsContainer) {
            throw 'The created staging target is unsafe.'
        }
        try {
            foreach ($entry in $sources.GetEnumerator()) {
                Copy-VerifiedFile $entry.Value (Join-Path $packageStagePath $entry.Key) $records
            }
            Copy-VerifiedTree (Join-Path $repositoryPath 'resources') (Join-Path $packageStagePath 'resources') `
                @() @('mihomo.exe') $records
            # mihomo.exe is required by Upgrade-Package's fixed destination contract.
            Copy-VerifiedFile (Join-Path $binaryDirectory 'resources\mihomo.exe') `
                (Join-Path $packageStagePath 'resources\mihomo.exe') $records
            Copy-VerifiedTree (Join-Path $repositoryPath 'scripts\wsl-secure-egress') `
                (Join-Path $packageStagePath 'resources\wsl-secure-egress') `
                @('linux', 'server') @('Restore-WslEgressProfile.ps1') $records
            Copy-VerifiedFile (Join-Path $repositoryPath 'scripts\wsl-secure-egress\Restore-WslEgressProfile.ps1') `
                (Join-Path $packageStagePath 'resources\wsl-secure-egress\Restore-WslEgressProfile.ps1') $records
            Assert-StagingWhitelist $packageStagePath
        } catch {
            Remove-CreatedStage $packageStagePath
            Remove-NormalFileIfPresent $receiptTemporaryPath
            throw
        }
        $receipt = [ordered]@{
            schema_version = 1
            repository = $repositoryPath
            verified_build = $verifiedBuildResult.root
            build_manifest_sha256 = [string]$verifiedBuildResult.response.manifest_sha256
            build_commit = [string]$verifiedBuildResult.response.commit
            build_version = [string]$verifiedBuildResult.response.version
            binary_directory = $binaryDirectory
            created_at = (Get-Date -Format o)
            files = $records
        }
        if ($receiptPath.StartsWith($packageStagePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The staging receipt must be outside the package stage.'
        }
        try {
            Assert-NormalReceiptPath $receiptPath
            Assert-NormalReceiptPath $receiptTemporaryPath
            Write-ReceiptAtomically $receiptTemporaryPath $receiptPath `
                ($receipt | ConvertTo-Json -Depth 6)
        } catch {
            if ($stageCreatedByThisRun) {
                Remove-CreatedStage $packageStagePath
                $stageCreatedByThisRun = $false
            }
            if (Test-Path -LiteralPath $receiptTemporaryPath) {
                Remove-Item -LiteralPath $receiptTemporaryPath -Force
            }
            throw
        }
    }

    [ordered]@{
        schema_version = 1
        component = 'clash-of-wsl'
        action = 'prepare-package-stage'
        outcome = $(if ($Execute) { 'succeeded' } else { 'not_run' })
        executed = $Execute.IsPresent
        repository = $repositoryPath
        package_stage = $packageStagePath
        receipt_path = $(if ($Execute) { $receiptPath } else { $null })
        binary_directory = $(if ($Execute) { $binaryDirectory } else { $null })
        verified_build = $verifiedBuildResult.root
        build_manifest_sha256 = [string]$verifiedBuildResult.response.manifest_sha256
        build_commit = [string]$verifiedBuildResult.response.commit
        files = $records.Count
        secrets_copied = $false
    } | ConvertTo-Json -Compress
    [Console]::Error.Flush()
    [Console]::Out.Flush()
    exit 0
} catch {
    $primaryError = $_
    if ($stageCreatedByThisRun) {
        try { Remove-CreatedStage $packageStagePath }
        catch {
            [ordered]@{
                schema_version = 1
                component = 'clash-of-wsl'
                action = 'prepare-package-stage'
                outcome = 'failed'
                executed = $Execute.IsPresent
                secrets_copied = $false
                message = $primaryError.Exception.Message
                cleanup_error = $_.Exception.Message
            } | ConvertTo-Json -Compress
            exit 1
        }
    }
    try {
        if ($receiptTemporaryPath) {
            Remove-NormalFileIfPresent $receiptTemporaryPath
        }
    } catch {
        [ordered]@{
            schema_version = 1
            component = 'clash-of-wsl'
            action = 'prepare-package-stage'
            outcome = 'failed'
            executed = $Execute.IsPresent
            secrets_copied = $false
            message = $primaryError.Exception.Message
            cleanup_error = $_.Exception.Message
        } | ConvertTo-Json -Compress
        exit 1
    }
    [ordered]@{
        schema_version = 1
        component = 'clash-of-wsl'
        action = 'prepare-package-stage'
        outcome = 'failed'
        executed = $Execute.IsPresent
        secrets_copied = $false
        message = $primaryError.Exception.Message
    } | ConvertTo-Json -Compress
    [Console]::Error.Flush()
    [Console]::Out.Flush()
    exit 1
}
