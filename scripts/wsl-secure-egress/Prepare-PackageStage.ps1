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
    [string]$Repository = 'F:\Codex\Clash-of-Rust-work',
    [string]$PackageStage = 'F:\Codex\cor-package-stage',
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

try {
    $Repository = [IO.Path]::GetFullPath($Repository).TrimEnd('\')
    $PackageStage = [IO.Path]::GetFullPath($PackageStage).TrimEnd('\')
    $StageParent = [IO.Path]::GetDirectoryName($PackageStage)
    if (-not $StageParent) { throw 'The staging directory has no parent.' }
    Assert-NoReparseAncestor $StageParent
    if (Test-Path -LiteralPath $PackageStage) {
        $existingStage = Get-Item -LiteralPath $PackageStage -Force
        if (($existingStage.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not $existingStage.PSIsContainer) {
            throw 'The staging target must be a normal directory.'
        }
    }
    $script:StageRoot = $PackageStage
    if (-not (Test-Path -LiteralPath (Join-Path $Repository '.git\HEAD') -PathType Leaf)) {
        throw 'The repository path is not a Git worktree.'
    }
    if ($PackageStage -eq $Repository -or
        $PackageStage.StartsWith($Repository + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The staging directory must be outside the repository.'
    }
    if ($PackageStage -eq $StageParent -or
        [IO.Path]::GetPathRoot($PackageStage).TrimEnd('\') -eq $PackageStage) {
        throw 'Unsafe staging path.'
    }

    $records = [ordered]@{}
    $receiptPath = $PackageStage + '.stage-receipt.json'
    $receiptTemporaryPath = $receiptPath + '.pending'
    Assert-NormalReceiptPath $receiptPath
    Assert-NormalReceiptPath $receiptTemporaryPath
    if ($Execute) {
        $release = Join-Path $Repository 'target\release'
        $debug = Join-Path $Repository 'target\debug'
        $binaryDirectory = if ((Test-Path -LiteralPath (Join-Path $release 'clash-of-rust.exe')) -and
            (Test-Path -LiteralPath (Join-Path $release 'clash-tun-launcher.exe')) -and
            (Test-Path -LiteralPath (Join-Path $release 'clash-wsl-guardian.exe'))) {
            $release
        } elseif ((Test-Path -LiteralPath (Join-Path $debug 'clash-of-rust.exe')) -and
            (Test-Path -LiteralPath (Join-Path $debug 'clash-tun-launcher.exe')) -and
            (Test-Path -LiteralPath (Join-Path $debug 'clash-wsl-guardian.exe'))) {
            $debug
        } else {
            throw 'No complete Clash of Rust debug or release binary set is available.'
        }
        $sources = [ordered]@{
            'clash-of-rust.exe' = Join-Path $binaryDirectory 'clash-of-rust.exe'
            'clash-tun-launcher.exe' = Join-Path $binaryDirectory 'clash-tun-launcher.exe'
            'clash-wsl-guardian.exe' = Join-Path $binaryDirectory 'clash-wsl-guardian.exe'
            'LICENSE' = Join-Path $Repository 'LICENSE'
            'uninstall.exe' = Join-Path 'C:\Program Files\Clash of Rust' 'uninstall.exe'
        }
        foreach ($entry in $sources.GetEnumerator()) {
            if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
                throw "Required staging source is missing: $($entry.Key) ($($entry.Value))"
            }
        }
        if (Test-Path -LiteralPath $PackageStage) {
            if (-not $Replace) {
                throw 'The staging directory already exists. Pass -Replace after reviewing it.'
            }
            $resolved = (Resolve-Path -LiteralPath $PackageStage).Path.TrimEnd('\')
            $resolvedItem = Get-Item -LiteralPath $resolved -Force
            if ($resolvedItem.Attributes -band [IO.FileAttributes]::ReparsePoint -or
                $resolved -ne $PackageStage -or
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
        New-Item -ItemType Directory -Path $PackageStage -Force | Out-Null
        $stageCreatedByThisRun = $true
        # The stage is now owned by this run. A non-directory or reparse-point
        # produced by a race is rejected and the receipt remains absent.
        $createdStageItem = Get-Item -LiteralPath $PackageStage -Force
        if (($createdStageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not $createdStageItem.PSIsContainer) {
            throw 'The created staging target is unsafe.'
        }
        try {
            foreach ($entry in $sources.GetEnumerator()) {
                Copy-VerifiedFile $entry.Value (Join-Path $PackageStage $entry.Key) $records
            }
            Copy-VerifiedTree (Join-Path $Repository 'resources') (Join-Path $PackageStage 'resources') `
                @() @('mihomo.exe') $records
            # mihomo.exe is required by Upgrade-Package's fixed destination contract.
            Copy-VerifiedFile (Join-Path $Repository 'resources\mihomo.exe') `
                (Join-Path $PackageStage 'resources\mihomo.exe') $records
            Copy-VerifiedTree (Join-Path $Repository 'scripts\wsl-secure-egress') `
                (Join-Path $PackageStage 'resources\wsl-secure-egress') `
                @('linux', 'server') @('Restore-WslEgressProfile.ps1') $records
            Copy-VerifiedFile (Join-Path $Repository 'scripts\wsl-secure-egress\Restore-WslEgressProfile.ps1') `
                (Join-Path $PackageStage 'resources\wsl-secure-egress\Restore-WslEgressProfile.ps1') $records
            Assert-StagingWhitelist $PackageStage
        } catch {
            Remove-CreatedStage $PackageStage
            Remove-NormalFileIfPresent $receiptTemporaryPath
            throw
        }
        $receipt = [ordered]@{
            schema_version = 1
            repository = $Repository
            binary_directory = $binaryDirectory
            created_at = (Get-Date -Format o)
            files = $records
        }
        if ($receiptPath.StartsWith($PackageStage + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The staging receipt must be outside the package stage.'
        }
        try {
            Assert-NormalReceiptPath $receiptPath
            Assert-NormalReceiptPath $receiptTemporaryPath
            Write-ReceiptAtomically $receiptTemporaryPath $receiptPath `
                ($receipt | ConvertTo-Json -Depth 6)
        } catch {
            if ($stageCreatedByThisRun) {
                Remove-CreatedStage $PackageStage
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
        repository = $Repository
        package_stage = $PackageStage
        receipt_path = $(if ($Execute) { $receiptPath } else { $null })
        binary_directory = $(if ($Execute) { $binaryDirectory } else { $null })
        files = $records.Count
        secrets_copied = $false
    } | ConvertTo-Json -Compress
    [Console]::Error.Flush()
    [Console]::Out.Flush()
    exit 0
} catch {
    $primaryError = $_
    if ($stageCreatedByThisRun) {
        try { Remove-CreatedStage $PackageStage }
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
