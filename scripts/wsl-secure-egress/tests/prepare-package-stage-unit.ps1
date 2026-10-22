#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\Prepare-PackageStage.ps1'
$upgradePath = Join-Path $PSScriptRoot '..\Upgrade-Package.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('cor-package-stage-' + [guid]::NewGuid().ToString('N'))
$assertions = 0
$failures = [Collections.Generic.List[string]]::new()

function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { $script:failures.Add($Message) }
}
function Get-Hash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Invoke-Fixture(
    [string]$Fixture,
    [string]$Repo,
    [string]$Stage,
    [switch]$Execute,
    [switch]$Replace
) {
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $Fixture, '-Repository', $Repo, '-PackageStage', $Stage)
    if ($Execute) { $arguments += '-Execute' }
    if ($Replace) { $arguments += '-Replace' }
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell promotes native stderr records to terminating
        # errors when the caller uses Stop. Capture both streams explicitly
        # and restore the preference after the child process exits.
        $ErrorActionPreference = 'Continue'
        $output = @(& powershell.exe @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $textLines = @($output | ForEach-Object { [string]$_ })
    $jsonLine = @($textLines | Where-Object {
        $trimmed = $_.Trim()
        $trimmed.StartsWith('{') -and $trimmed.EndsWith('}')
    }) | Select-Object -Last 1
    $joined = ($textLines -join [Environment]::NewLine).Trim()
    $parsed = $null
    if ($jsonLine) {
        try { $parsed = $jsonLine | ConvertFrom-Json } catch {}
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Output = $joined
        Response = $parsed
    }
}
function Get-ResponseOutcome($Response) {
    if ($null -eq $Response) { return $null }
    $property = $Response.PSObject.Properties['outcome']
    if ($property) { return [string]$property.Value }
    return $null
}
function Assert-ExplicitFailure($Result, [string]$Message) {
    Assert-True ($Result.ExitCode -eq 1) "$Message The command must exit 1."
    Assert-True ((Get-ResponseOutcome $Result.Response) -eq 'failed') `
        "$Message The command must return an explicit failed JSON response. Output: $($Result.Output)"
}

try {
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile(
        $scriptPath, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'Package stage script must parse.'

    $repo = Join-Path $testRoot 'repo'
    $debug = Join-Path $repo 'target\debug'
    $resources = Join-Path $repo 'resources'
    $module = Join-Path $repo 'scripts\wsl-secure-egress'
    $linux = Join-Path $module 'linux'
    $server = Join-Path $module 'server'
    foreach ($path in @(
        (Join-Path $repo '.git'), $debug, $resources, $module, $linux, $server)) {
        $null = New-Item -ItemType Directory -Path $path -Force
    }
    [IO.File]::WriteAllText((Join-Path $repo '.git\HEAD'), 'ref: refs/heads/test')
    foreach ($name in @('clash-of-rust.exe', 'clash-tun-launcher.exe', 'clash-wsl-guardian.exe')) {
        [IO.File]::WriteAllText((Join-Path $debug $name), "binary-$name")
    }
    [IO.File]::WriteAllText((Join-Path $repo 'LICENSE'), 'license')
    [IO.File]::WriteAllText((Join-Path $resources 'resource.dat'), 'resource')
    [IO.File]::WriteAllText((Join-Path $resources 'mihomo.exe'), 'mihomo')
    foreach ($name in @('WslSecureEgress.psm1', 'Upgrade-Package.ps1',
            'Restore-WslEgressProfile.ps1')) {
        [IO.File]::WriteAllText((Join-Path $module $name), "module-$name")
    }
    [IO.File]::WriteAllText((Join-Path $linux 'manager.py'), 'linux')
    [IO.File]::WriteAllText((Join-Path $server 'manage.py'), 'server')
    [IO.File]::WriteAllText((Join-Path $module 'ignored.tmp'), 'ignored')
    $programFiles = Join-Path $testRoot 'Program Files\Clash of Rust'
    $null = New-Item -ItemType Directory -Path $programFiles -Force
    [IO.File]::WriteAllText((Join-Path $programFiles 'uninstall.exe'), 'uninstall')

    # The production script resolves the installed uninstaller from Program
    # Files directly. This harness runs a source-equal copy whose only change is
    # that fixed fixture path; package copying and receipt behavior stay live.
    $harnessScript = Join-Path $testRoot 'Prepare-PackageStage.fixture.ps1'
    $source = Get-Content -LiteralPath $scriptPath -Raw
    $source = $source.Replace(
        "'C:\Program Files\Clash of Rust' 'uninstall.exe'",
        "'$($programFiles.Replace("'", "''"))' 'uninstall.exe'")
    [IO.File]::WriteAllText($harnessScript, $source, (New-Object Text.UTF8Encoding($false)))

    $stage = Join-Path $testRoot 'stage'
    $preview = Invoke-Fixture $harnessScript $repo $stage
    Assert-True ($preview.ExitCode -eq 0) 'Preview must exit successfully.'
    Assert-True ((Get-ResponseOutcome $preview.Response) -eq 'not_run') 'Preview must report not_run.'
    Assert-True (-not (Test-Path -LiteralPath $stage)) 'Preview must not create staging.'

    $executed = Invoke-Fixture $harnessScript $repo $stage -Execute
    $response = $executed.Response
    Assert-True ($executed.ExitCode -eq 0) 'Execute must exit successfully.'
    Assert-True ((Get-ResponseOutcome $response) -eq 'succeeded') 'Execute must report success.'
    $expectedReceipt = $stage + '.stage-receipt.json'
    Assert-True ([string]$response.receipt_path -eq $expectedReceipt) 'Receipt path must be reported.'
    Assert-True (Test-Path -LiteralPath $expectedReceipt -PathType Leaf) 'Receipt must be written beside staging.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage 'stage-receipt.json'))) `
        'Receipt must not enter package staging.'
    Assert-True (@(Get-ChildItem -LiteralPath $stage -Recurse -File -Filter '*.stage-receipt.json*').Count -eq 0) `
        'A receipt-like file must not enter package staging.'

    # Recurse the imported production upgrade functions. This avoids invoking
    # the privileged Apply transaction while proving the generated files are
    # accepted by its exact whitelist and manifest contract.
    . $upgradePath
    $plan = @(Get-PackagePlan $stage (Join-Path $testRoot 'installed'))
    Assert-True ($plan.Count -gt 0) 'Production upgrade plan must accept staging.'
    $manifest = Join-Path $testRoot 'approved.json'
    function Protect-PackageDirectory([string]$Path) {}
    $manifestHash = New-PackageManifest $stage $manifest
    Assert-PackageManifest $stage $manifest $manifestHash
    $manifestFiles = (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).files.PSObject.Properties
    $stageFiles = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
    Assert-True (@($manifestFiles).Count -eq $stageFiles.Count) 'Manifest must cover exactly the stage.'
    Assert-True (@($plan).Count -eq $stageFiles.Count) 'Every staged file must match the upgrade plan.'
    Assert-True (-not (@($manifestFiles.Name) -contains 'stage-receipt.json')) `
        'Manifest must not include the outside receipt.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stage 'resources\wsl-secure-egress\linux\manager.py')) `
        'Linux payload must be included.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage 'resources\wsl-secure-egress\ignored.tmp'))) `
        'Ignored temporary files must not enter staging.'

    $receipt = Get-Content -LiteralPath $expectedReceipt -Raw | ConvertFrom-Json
    Assert-True ($receipt.schema_version -eq 1) 'Receipt schema must be stable.'
    foreach ($property in $receipt.files.PSObject.Properties) {
        $relative = [string]$property.Name
        $path = Join-Path $stage $relative
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Receipt must name an existing file: $relative"
        Assert-True ((Get-Hash $path) -eq [string]$property.Value) "Receipt hash must match: $relative"
    }
    Assert-True (@($receipt.files.PSObject.Properties).Count -eq @(Get-ChildItem -LiteralPath $stage -Recurse -File).Count) `
        'Receipt must cover exactly the staged files.'
    Assert-True (-not (Test-Path -LiteralPath ($expectedReceipt + '.pending'))) `
        'Successful execution must not leave a pending receipt.'

    # A failed replacement must not preserve the prior receipt, because that
    # receipt would otherwise attest to a stage that no longer exists.
    $invalidResource = Join-Path $resources 'bad name.dat'
    [IO.File]::WriteAllText($invalidResource, 'outside-whitelist')
    $failure = Invoke-Fixture $harnessScript $repo $stage -Execute -Replace
    Assert-ExplicitFailure $failure 'A failed replacement must fail explicitly.'
    Assert-True (-not (Test-Path -LiteralPath $expectedReceipt)) `
        'A failed replacement must not leave its prior success receipt.'
    Assert-True (-not (Test-Path -LiteralPath ($expectedReceipt + '.pending'))) `
        'A failed replacement must not leave a pending receipt.'
    Assert-True (-not (Test-Path -LiteralPath $stage)) `
        'A failed replacement must remove the partial stage.'
    Remove-Item -LiteralPath $invalidResource -Force

    # Recreate a verified stage for the final successful contract checks.
    $executedAgain = Invoke-Fixture $harnessScript $repo $stage -Execute
    Assert-True ($executedAgain.ExitCode -eq 0) 'Stage fixture must be recreated after failure tests.'
    Assert-True (Test-Path -LiteralPath $expectedReceipt -PathType Leaf) `
        'A successful retry must recreate the external receipt.'

    $extra = Join-Path $stage 'outside-whitelist.json'
    [IO.File]::WriteAllText($extra, 'refused')
    $blocked = $false
    try { $null = Get-PackagePlan $stage (Join-Path $testRoot 'installed') } catch { $blocked = $true }
    Assert-True $blocked 'Production upgrade must reject extra staged content.'
    [IO.File]::Delete($extra)

    $stageInsideRepo = Join-Path $repo 'stage'
    $failure = Invoke-Fixture $harnessScript $repo $stageInsideRepo -Execute
    Assert-ExplicitFailure $failure 'Staging inside repository must fail.'
    Assert-True (-not (Test-Path -LiteralPath $stageInsideRepo)) 'Refused staging must not be created.'

    $redirected = Join-Path $testRoot 'redirected'
    $null = New-Item -ItemType Directory -Path $redirected
    $link = Join-Path $testRoot 'redirected-link'
    $linkCreated = $true
    try {
        $null = New-Item -ItemType Junction -Path $link -Target $redirected
    } catch {
        $linkCreated = $false
        $failures.Add('The test host could not create a reparse-point fixture.')
    }
    if ($linkCreated) {
        $redirectedStage = Join-Path $link 'stage'
        $failure = Invoke-Fixture $harnessScript $repo $redirectedStage -Execute
        Assert-ExplicitFailure $failure 'A staging path below a reparse point must fail.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $redirected 'clash-of-rust.exe'))) `
            'Redirected destination must remain unwritten.'

        $junctionStageTarget = Join-Path $testRoot 'junction-stage-target'
        $junctionStage = Join-Path $testRoot 'junction-stage'
        $null = New-Item -ItemType Directory -Path $junctionStageTarget
        $null = New-Item -ItemType Junction -Path $junctionStage -Target $junctionStageTarget
        $failure = Invoke-Fixture $harnessScript $repo $junctionStage -Execute
        Assert-ExplicitFailure $failure 'A staging target that is a junction must fail.'
        Assert-True (@(Get-ChildItem -LiteralPath $junctionStageTarget -Force).Count -eq 0) `
            'A refused junction target must not be cleaned through.'

        $receiptLink = $expectedReceipt
        Remove-Item -LiteralPath $receiptLink -Force
        $stageBackup = $stage + '.before-receipt-test'
        Move-Item -LiteralPath $stage -Destination $stageBackup
        $null = New-Item -ItemType Junction -Path $receiptLink -Target $redirected
        $failure = Invoke-Fixture $harnessScript $repo $stage -Execute
        Assert-ExplicitFailure $failure 'A redirected receipt target must fail.'
        Assert-True (-not (Test-Path -LiteralPath $stage)) 'A failed receipt write must remove its stage.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $redirected 'stage-receipt.json'))) `
            'A redirected receipt target must not receive a receipt.'
        # Remove the junction before restoring the prior stage.
        Remove-Item -LiteralPath $receiptLink -Recurse -Force
        Move-Item -LiteralPath $stageBackup -Destination $stage
        $executedAfterJunction = Invoke-Fixture $harnessScript $repo $stage -Execute -Replace
        Assert-True ($executedAfterJunction.ExitCode -eq 0) `
            'A restored stage path must remain usable after a junction failure.'
    }

    $brokenRepo = Join-Path $testRoot 'broken-repo'
    $brokenDebug = Join-Path $brokenRepo 'target\debug'
    $brokenResources = Join-Path $brokenRepo 'resources'
    $brokenModule = Join-Path $brokenRepo 'scripts\wsl-secure-egress'
    $brokenLinux = Join-Path $brokenModule 'linux'
    $brokenServer = Join-Path $brokenModule 'server'
    foreach ($path in @(
        (Join-Path $brokenRepo '.git'), $brokenDebug, $brokenResources,
        $brokenModule, $brokenLinux, $brokenServer)) {
        $null = New-Item -ItemType Directory -Path $path -Force
    }
    [IO.File]::WriteAllText((Join-Path $brokenRepo '.git\HEAD'), 'ref: refs/heads/test')
    foreach ($name in @('clash-of-rust.exe', 'clash-tun-launcher.exe',
            'clash-wsl-guardian.exe')) {
        [IO.File]::WriteAllText((Join-Path $brokenDebug $name), "binary-$name")
    }
    [IO.File]::WriteAllText((Join-Path $brokenRepo 'LICENSE'), 'license')
    [IO.File]::WriteAllText((Join-Path $brokenResources 'resource.dat'), 'resource')
    [IO.File]::WriteAllText((Join-Path $brokenResources 'mihomo.exe'), 'mihomo')
    foreach ($name in @('WslSecureEgress.psm1', 'Upgrade-Package.ps1')) {
        [IO.File]::WriteAllText((Join-Path $brokenModule $name), "module-$name")
    }
    [IO.File]::WriteAllText((Join-Path $brokenLinux 'manager.py'), 'linux')
    [IO.File]::WriteAllText((Join-Path $brokenServer 'manage.py'), 'server')
    $expectedRestore = Join-Path $brokenModule 'Restore-WslEgressProfile.ps1'
    $null = New-Item -ItemType Junction -Path $expectedRestore -Target $repo
    $brokenStage = Join-Path $testRoot 'broken-stage'
    $failure = Invoke-Fixture $harnessScript $brokenRepo $brokenStage -Execute
    Assert-ExplicitFailure $failure 'A redirected package source must fail.'
    Assert-True (-not (Test-Path -LiteralPath $brokenStage)) 'A failed partial build must be removed.'
    Assert-True (-not (Test-Path -LiteralPath ($brokenStage + '.stage-receipt.json'))) `
        'A failed build must not leave a success receipt.'
    Assert-True (-not (Test-Path -LiteralPath ($brokenStage + '.stage-receipt.json.pending'))) `
        'A failed build must not leave a pending receipt.'
} catch {
    $failures.Add("Unhandled exception: $($_.Exception.Message)")
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        $failures.Add($_.InvocationInfo.PositionMessage)
    }
} finally {
    $redirectedLink = Join-Path $testRoot 'redirected-link'
    $redirectedReceipt = $expectedReceipt
    $stageBackup = $stage + '.before-receipt-test'
    $brokenRestoreLink = Join-Path $testRoot 'broken-repo\scripts\wsl-secure-egress\Restore-WslEgressProfile.ps1'
    foreach ($linkPath in @($redirectedLink, $redirectedReceipt, $brokenRestoreLink)) {
        if (Test-Path -LiteralPath $linkPath) {
            $linkItem = Get-Item -LiteralPath $linkPath -Force
            if ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                # Recurse is required to remove a directory junction on some
                # Windows hosts without prompting. The test root is checked
                # again before recursive cleanup below.
                Remove-Item -LiteralPath $linkPath -Recurse -Force
            }
        }
    }
    if ((Test-Path -LiteralPath $stageBackup) -and
        -not (Test-Path -LiteralPath $stage)) {
        Move-Item -LiteralPath $stageBackup -Destination $stage
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        $expected = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') +
            '\cor-package-stage-'
        if (-not $resolved.StartsWith($expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Unexpected temporary test root; cleanup refused.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

[ordered]@{
    suite = 'prepare-package-stage-offline'
    result = $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
    assertions = $assertions
    hostWrites = $false
    services_modified = $false
    network_tests = 'NOT_RUN'
    failures = @($failures)
} | ConvertTo-Json -Compress
if ($failures.Count -ne 0) { exit 1 }
exit 0
