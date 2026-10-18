#Requires -Version 5.1
# Real temporary-file transactions with no host, service or network operations.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Upgrade-Package.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('cor-package-unit-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$testCount = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -cne $Expected) { throw "FAIL: $Label" }
    $script:testCount++
}
function New-Fixture([string]$Name) {
    $root = Join-Path $testRoot $Name
    $null = New-Item -ItemType Directory -Path $root
    $source = Join-Path $root 'stage'
    $target = Join-Path $root 'installed'
    $recovery = Join-Path $root 'backup'
    foreach ($path in @($source,$target,$recovery)) { $null = New-Item -ItemType Directory -Path $path }
    $files = @('clash-of-rust.exe','clash-tun-launcher.exe','clash-wsl-guardian.exe',
        'LICENSE','uninstall.exe','resources\mihomo.exe',
        'resources\wsl-secure-egress\WslSecureEgress.psm1',
        'resources\wsl-secure-egress\Upgrade-Package.ps1')
    foreach ($name in $files) {
        $path = Join-Path $source $name
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -Force
        [IO.File]::WriteAllText($path, ('new-' + $name))
        if ($name -eq 'LICENSE') { continue }
        $path = Join-Path $target $name
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -Force
        [IO.File]::WriteAllText($path, ('old-' + $name))
    }
    [IO.File]::WriteAllText((Join-Path $target 'unrelated.txt'), 'keep')
    [pscustomobject]@{ root=$root; source=$source; target=$target; recovery=$recovery
        journal=[ordered]@{ phase='applying'; files=@(Get-PackagePlan $source $target) } }
}
try {
    $fixture = New-Fixture 'success'
    Write-PackageFiles $fixture.journal $fixture.recovery
    foreach ($item in $fixture.journal.files) {
        Assert-Equal (Get-PackageHash $item.target) $item.after 'every installed byte matches the staged digest'
    }
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $fixture.target 'unrelated.txt'))) 'keep' 'unrelated user file retained'
    Assert-Equal ([IO.File]::Exists((Join-Path $fixture.recovery 'journal.json'))) $true 'write-ahead journal persisted'
    Restore-PackageFiles $fixture.journal $fixture.recovery -Immediate
    foreach ($item in $fixture.journal.files) {
        Assert-Equal (Get-PackageHash $item.target) $item.before 'every old byte restored'
    }
    Assert-Equal ([IO.File]::Exists((Join-Path $fixture.target 'LICENSE'))) $false 'new file removed during rollback'

    $fixture = New-Fixture 'drift'
    $item = $fixture.journal.files[0]
    [IO.File]::WriteAllText($item.source, 'changed-after-preflight')
    $blocked = $false
    try { Write-PackageFiles $fixture.journal $fixture.recovery } catch { $blocked = $true }
    Assert-Equal $blocked $true 'changed stage rejected before replacement'
    Assert-Equal (Get-PackageHash $item.target) $item.before 'original retained after stage drift'

    $fixture = New-Fixture 'interrupted'
    $script:FailTarget = $fixture.journal.files[2].target
    function Copy-Item {
        param([string]$LiteralPath,[string]$Destination,[switch]$Force,[string]$ErrorAction)
        if ($Destination -eq $script:FailTarget) {
            $script:FailTarget = ''
            [IO.File]::WriteAllText($Destination, 'partial-copy')
            throw 'Injected copy interruption.'
        }
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
    }
    $blocked = $false
    try { Write-PackageFiles $fixture.journal $fixture.recovery } catch { $blocked = $true }
    Assert-Equal $blocked $true 'partial copy interruption surfaced'
    Remove-Item Function:\Copy-Item
    Restore-PackageFiles $fixture.journal $fixture.recovery -Immediate
    foreach ($item in $fixture.journal.files) {
        Assert-Equal (Get-PackageHash $item.target) $item.before 'partial transaction restores all originals'
    }

    $fixture = New-Fixture 'backup-tamper'
    Write-PackageFiles $fixture.journal $fixture.recovery
    $item = @($fixture.journal.files | Where-Object { $_.backup })[-1]
    [IO.File]::WriteAllText($item.backup, 'tampered')
    $blocked = $false
    try { Restore-PackageFiles $fixture.journal $fixture.recovery } catch { $blocked = $true }
    Assert-Equal $blocked $true 'modified recovery code refuses rollback'

    $fixture = New-Fixture 'later-edit'
    Write-PackageFiles $fixture.journal $fixture.recovery
    $fixture.journal.phase = 'applied'
    [IO.File]::WriteAllText($fixture.journal.files[-1].target, 'later-user-edit')
    $blocked = $false
    try { Restore-PackageFiles $fixture.journal $fixture.recovery } catch { $blocked = $true }
    Assert-Equal $blocked $true 'later user file edits are not silently overwritten'

    $fixture = New-Fixture 'same-call-partial'
    Write-PackageFiles $fixture.journal $fixture.recovery
    [IO.File]::WriteAllText($fixture.journal.files[0].target, 'partial-copy')
    Restore-PackageFiles $fixture.journal $fixture.recovery -Immediate
    Assert-Equal (Get-PackageHash $fixture.journal.files[0].target) `
        $fixture.journal.files[0].before 'live transaction may replace its own partial copy'
    $fixture = New-Fixture 'later-partial'
    Write-PackageFiles $fixture.journal $fixture.recovery
    [IO.File]::WriteAllText($fixture.journal.files[0].target, 'partial-copy')
    $blocked = $false
    try { Restore-PackageFiles $fixture.journal $fixture.recovery } catch { $blocked = $true }
    Assert-Equal $blocked $true 'manual rollback preserves a third-hash file even in applying phase'

    $fixture = New-Fixture 'incomplete'
    Remove-Item -LiteralPath (Join-Path $fixture.source 'clash-wsl-guardian.exe')
    $blocked = $false
    try { $null = Get-PackagePlan $fixture.source $fixture.target } catch { $blocked = $true }
    Assert-Equal $blocked $true 'incomplete stage refused'

    $fixture = New-Fixture 'manifest'
    $manifest = Join-Path $fixture.root 'approved.json'
    $records = [ordered]@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $fixture.source -Recurse -File)) {
        $records[$file.FullName.Substring($fixture.source.Length + 1)] = Get-PackageHash $file.FullName
    }
    [IO.File]::WriteAllText($manifest, ([ordered]@{schema_version=1;files=$records} | ConvertTo-Json -Depth 6))
    $manifestHash = Get-PackageHash $manifest
    Assert-PackageManifest $fixture.source $manifest $manifestHash
    $script:testCount++
    [IO.File]::WriteAllText((Join-Path $fixture.source 'LICENSE'), 'changed-after-review')
    $blocked = $false
    try { Assert-PackageManifest $fixture.source $manifest $manifestHash } catch { $blocked = $true }
    Assert-Equal $blocked $true 'changed stage rejected against elevation-pinned manifest'
    $blocked = $false
    try { Assert-PackageManifest $fixture.source $manifest ('0' * 64) } catch { $blocked = $true }
    Assert-Equal $blocked $true 'changed manifest rejected against approved digest'

    [ordered]@{ suite='package-upgrade-offline'; result='PASS'; assertions=$testCount
        services_modified=$false; network_tests='NOT_RUN'; wsl_started=$false } | ConvertTo-Json -Compress
} finally {
    if (Test-Path Function:\Copy-Item) { Remove-Item Function:\Copy-Item }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $expected = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\cor-package-unit-'
    if (-not $resolved.StartsWith($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected temporary test root; cleanup refused.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
