#Requires -Version 5.1
<#
.SYNOPSIS
Replace an installed package transactionally without stopping the Windows core.
.DESCRIPTION
Only installer-extracted files are accepted. Persistent WSL default deny remains
in place and the owned endpoint is closed before replacing its audit service.
The code-only recovery journal never contains a profile or a network snapshot.
#>
[CmdletBinding()]
param(
    [ValidateSet('CreateManifest','Apply','Commit','Rollback')][string]$Action = 'Apply',
    [string]$InstallationPath,
    [string]$PackagePath,
    [string]$ManifestPath,
    [string]$ExpectedManifestSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PackagePath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'An absolute package path is required.' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $cursor = $full
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and
            ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Redirected package paths are refused.'
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    $full
}

function Protect-PackageDirectory([string]$Path) {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'))) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($entry[0])), $entry[1],
            'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-PackageHash([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return $null
}

function Save-PackageJournal([object]$Journal, [string]$Root) {
    $path = Join-Path $Root 'journal.json'
    $temporary = Join-Path $Root 'journal.pending'
    [IO.File]::WriteAllText($temporary, ($Journal | ConvertTo-Json -Depth 12),
        (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $path) {
        [IO.File]::Replace($temporary, $path, [System.Management.Automation.Language.NullString]::Value)
    } else { [IO.File]::Move($temporary, $path) }
}

function Get-PackagePlan([string]$Source, [string]$Destination) {
    $required = @('clash-of-rust.exe','clash-tun-launcher.exe','clash-wsl-guardian.exe',
        'LICENSE','uninstall.exe','resources\mihomo.exe',
        'resources\wsl-secure-egress\WslSecureEgress.psm1',
        'resources\wsl-secure-egress\Upgrade-Package.ps1')
    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Source $name) -PathType Leaf)) {
            throw 'The staged package is incomplete.'
        }
    }
    $result = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Source -Recurse -Force -File)) {
        $sourcePath = Assert-PackagePath $file.FullName
        $name = $sourcePath.Substring($Source.Length + 1)
        if ($name -notmatch '^(?:clash-of-rust\.exe|clash-tun-launcher\.exe|clash-wsl-guardian\.exe|LICENSE|uninstall\.exe|resources\\[A-Za-z0-9_.\\-]+)$') {
            throw 'An unrecognized staged package path was refused.'
        }
        $target = Assert-PackagePath (Join-Path $Destination $name)
        $after = Get-PackageHash $sourcePath
        $before = Get-PackageHash $target
        if ($before -ne $after) {
            $result += [ordered]@{ target=$target; source=$sourcePath; before=$before
                after=$after; backup=''; written=$false }
        }
    }
    $result
}

function Assert-PackageManifest([string]$Source, [string]$Manifest, [string]$Expected) {
    if (-not $Manifest -and -not $Expected) { return }
    if (-not $Manifest -or $Expected -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'A local stage requires both its manifest and the approved manifest SHA256.'
    }
    $manifestFile = Assert-PackagePath $Manifest
    if ((Get-PackageHash $manifestFile) -ine $Expected) { throw 'The approved package manifest changed.' }
    $document = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    if ($document.schema_version -ne 1) { throw 'Unknown package manifest format.' }
    # schema_version=1, files={"relative\\path":"64-character SHA256", ...}.
    # The approved manifest hash is carried in the elevation arguments.
    $records = @($document.files.PSObject.Properties)
    $files = @(Get-ChildItem -LiteralPath $Source -Recurse -Force -File)
    if ($records.Count -ne $files.Count) { throw 'The package manifest does not cover the complete stage.' }
    foreach ($file in $files) {
        $path = Assert-PackagePath $file.FullName
        $name = $path.Substring($Source.Length + 1)
        $record = $document.files.PSObject.Properties[$name]
        if (-not $record -or $record.Value -notmatch '^[a-fA-F0-9]{64}$' -or
            (Get-PackageHash $path) -ine [string]$record.Value) {
            throw 'Staged package bytes differ from the approved manifest.'
        }
    }
}

function New-PackageManifest([string]$Source, [string]$Manifest) {
    $source = Assert-PackagePath $Source
    $manifestFile = Assert-PackagePath $Manifest
    if ($manifestFile -ieq $source -or
        $manifestFile.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The manifest must be outside the staged package.'
    }
    Protect-PackageDirectory ([IO.Path]::GetDirectoryName($manifestFile))
    Protect-PackageDirectory $source
    $records = [ordered]@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $source -Recurse -Force -File)) {
        $path = Assert-PackagePath $file.FullName
        $records[$path.Substring($source.Length + 1)] = Get-PackageHash $path
    }
    [IO.File]::WriteAllText($manifestFile,
        ([ordered]@{ schema_version=1; files=$records } | ConvertTo-Json -Depth 6),
        (New-Object Text.UTF8Encoding($false)))
    Get-PackageHash $manifestFile
}

function Write-PackageFiles([object]$Journal, [string]$Root) {
    $index = 0
    foreach ($item in @($Journal.files)) {
        if ((Get-PackageHash $item.target) -ne $item.before -or
            (Get-PackageHash $item.source) -ne $item.after) {
            throw 'A package file changed after preflight.'
        }
        if ($null -ne $item.before) {
            $backup = Join-Path $Root ('original-' + $index.ToString('D5'))
            Copy-Item -LiteralPath $item.target -Destination $backup -ErrorAction Stop
            if ((Get-PackageHash $backup) -ne $item.before) { throw 'Code backup hash mismatch.' }
            $item.backup = $backup
        }
        # The write-ahead entry precedes replacement, including creation of a
        # previously absent file. Rollback also handles an interrupted copy.
        $item.written = $true
        Save-PackageJournal $Journal $Root
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($item.target)) -Force | Out-Null
        Copy-Item -LiteralPath $item.source -Destination $item.target -Force -ErrorAction Stop
        if ((Get-PackageHash $item.target) -ne $item.after) { throw 'Installed code hash mismatch.' }
        $index++
    }
}

function Restore-PackageFiles([object]$Journal, [string]$Root, [switch]$Immediate) {
    $files = @($Journal.files)
    [array]::Reverse($files)
    foreach ($item in $files) {
        if (-not $item.written) { continue }
        $current = Get-PackageHash $item.target
        if ($current -eq $item.before) {
            $item.written = $false
            Save-PackageJournal $Journal $Root
            continue
        }
        if ($current -ne $item.after -and $current -ne $item.before -and $null -ne $current) {
            # Only the live Apply catch can identify the third hash as a partial
            # copy. A later manual rollback must preserve an unknown later edit.
            if (-not $Immediate) { throw 'A later package edit prevents automatic rollback.' }
        }
        if ($null -ne $item.before) {
            if ((Get-PackageHash $item.backup) -ne $item.before) { throw 'Recovery code hash mismatch.' }
            Copy-Item -LiteralPath $item.backup -Destination $item.target -Force -ErrorAction Stop
        } elseif (Test-Path -LiteralPath $item.target) {
            Remove-Item -LiteralPath $item.target -Force -ErrorAction Stop
        }
        if ((Get-PackageHash $item.target) -ne $item.before) { throw 'Restored code hash mismatch.' }
        $item.written = $false
        Save-PackageJournal $Journal $Root
    }
}

function Get-PackageRegistration {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall\ClashOfRust')
    } finally { $base.Dispose() }
    if (-not $key) { throw 'The existing application registration is missing.' }
    try {
        @($key.GetValueNames() | ForEach-Object {
            [ordered]@{ name=$_; kind=[string]$key.GetValueKind($_); value=$key.GetValue($_) }
        })
    } finally { $key.Dispose() }
}

function Restore-PackageRegistration([object]$Journal) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall\ClashOfRust')
    } finally { $base.Dispose() }
    try {
        foreach ($entry in @($Journal.registration)) {
            $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse(
                [Microsoft.Win32.RegistryValueKind], [string]$entry.kind)
            $value = $entry.value
            if ($kind -eq [Microsoft.Win32.RegistryValueKind]::DWord) { $value = [int]$value }
            if ($kind -eq [Microsoft.Win32.RegistryValueKind]::QWord) { $value = [long]$value }
            $key.SetValue([string]$entry.name, $value, $kind)
        }
    } finally { $key.Dispose() }
}

function Update-PackageLinux([string]$ModulePath, [bool]$Repair) {
    $module = Import-Module $ModulePath -Force -PassThru -DisableNameChecking
    & $module {
        param($RepairConfiguration)
        $state = Read-WslEgressState
        if (-not $state -or $state.phase -eq 'restored') { return }
        if (-not (Get-WslEgressClosureAudit $state).confirmed) {
            throw 'Linux code upgrade requires a confirmed closed Windows endpoint.'
        }
        Install-WslEgressPayload $state ([string]$state.manager_distro) -ReviewedUpgrade
        if ($RepairConfiguration) {
            $repair = Invoke-WslEgressLinux $state 'repair-config'
            if ($repair.outcome -ne 'succeeded') { throw 'Post-upgrade Linux configuration repair failed.' }
            $audit = Invoke-WslEgressLinux $state 'audit-config'
            if ($audit.outcome -ne 'succeeded' -or -not $audit.facts.owned_config_matches -or
                -not $audit.facts.interop_runtime_disabled) {
                throw 'Post-upgrade Linux configuration audit failed.'
            }
        }
    } $Repair
}

function Invoke-PackageUpgrade {
    param([string]$Operation, [string]$Destination, [string]$Source,
        [string]$ApprovedManifest, [string]$ApprovedDigest)
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator authorization is required for package replacement.'
    }
    $destination = Assert-PackagePath $Destination
    $root = Assert-PackagePath (Join-Path $destination '.package-update')
    $mutex = New-Object Threading.Mutex($false, 'Global\ClashOfRust.WslEgress.Operation')
    $held = $false
    $journal = $null
    try {
        $held = $mutex.WaitOne(0)
        if (-not $held) { throw 'A WSL operation is already active.' }
        if ($Operation -ne 'Apply') {
            $null = Assert-PackagePath $root
            $journal = Get-Content -LiteralPath (Join-Path $root 'journal.json') -Raw | ConvertFrom-Json
            if ($journal.owner -ne 'ClashOfRust.PackageUpgrade' -or $journal.installation -ine $destination) {
                throw 'Package recovery identity differs.'
            }
            if ($Operation -eq 'Commit') {
                if ($journal.phase -ne 'applied') { throw 'Only a completed file transaction can be committed.' }
                foreach ($item in @($journal.files)) {
                    if ((Get-PackageHash $item.target) -ne $item.after) { throw 'The applied package changed.' }
                }
                $journal.phase = 'committed'
                Save-PackageJournal $journal $root
                return
            }
            if ($journal.phase -in @('committed','restored')) { return }
            if ($journal.guardian_was_running) { Stop-Service 'ClashOfRust.WslEgress' -ErrorAction Stop }
            Restore-PackageFiles $journal $root
            Restore-PackageRegistration $journal
            if ($journal.linux_payload_updated) {
                Update-PackageLinux (Join-Path $destination 'resources\wsl-secure-egress\WslSecureEgress.psm1') $false
            }
            if ($journal.guardian_was_running) { Start-Service 'ClashOfRust.WslEgress' -ErrorAction Stop }
            $journal.phase = 'restored'
            Save-PackageJournal $journal $root
            return
        }
        $source = Assert-PackagePath $Source
        if ($source -ieq $destination -or $source.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The stage must be separate from the installed package.'
        }
        if (Test-Path -LiteralPath $root) {
            $previous = Get-Content -LiteralPath (Join-Path $root 'journal.json') -Raw | ConvertFrom-Json
            if ($previous.phase -notin @('committed','restored')) {
                throw 'An interrupted upgrade requires its code-only rollback before retrying.'
            }
            # Retain each completed recovery set instead of deleting backups.
            Move-Item -LiteralPath $root -Destination ($root + '-' + [guid]::NewGuid().ToString('N'))
        }
        Protect-PackageDirectory $source
        Assert-PackageManifest $source $ApprovedManifest $ApprovedDigest
        $plan = @(Get-PackagePlan $source $destination)
        $helperTargets = @()
        $network = Get-CimInstance Win32_Service -Filter "Name='ClashOfRust.Network'"
        if (-not $network) { throw 'The installed Windows network helper is missing; use a separate reviewed repair.' }
        $guardian = Get-CimInstance Win32_Service -Filter "Name='ClashOfRust.WslEgress'"
        $journal = [ordered]@{ schema_version=1; owner='ClashOfRust.PackageUpgrade'
            installation=$destination; phase='preflight'; files=@($plan)
            guardian_was_running=$false; network_process_id=[long]$network.ProcessId
            network_service_preserved=$true; endpoint_reopened=$false
            registration=@(Get-PackageRegistration); linux_payload_updated=$false }
        New-Item -ItemType Directory -Path $root | Out-Null
        Protect-PackageDirectory $root
        Save-PackageJournal $journal $root
        $active = $false
        $modulePath = Join-Path $destination 'resources\wsl-secure-egress\WslSecureEgress.psm1'
        $statePath = Join-Path $env:ProgramData 'ClashOfRust\WslEgress\state.json'
        if ($guardian -or (Test-Path -LiteralPath $statePath)) {
            $installed = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            $active = & $installed {
                $state = Read-WslEgressState
                if (-not $state) { throw 'Guardian state is missing; package update refused.' }
                if ($state.owner_sid -ne (Assert-WslEgressUser)) { throw 'The WSL installation belongs to a different user.' }
                if ($state.phase -eq 'restored') { return $false }
                Assert-WslEgressBaseline @(Get-WslEgressBaseline)
                if (-not (Get-WslEgressGuardAudit $state).valid) { throw 'Effective WSL guard differs before upgrade.' }
                Set-WslEgressEndpoint $state $false
                $state.phase = 'installed_closed'
                Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
                if (-not (Get-WslEgressClosureAudit $state).confirmed) { throw 'Endpoint closure could not be verified.' }
                # stop refuses active workload namespaces; this never kills a
                # user's isolated process just to complete a package update.
                $linux = Invoke-WslEgressLinux $state 'stop'
                if ($linux.outcome -ne 'succeeded') { throw 'Stop isolated WSL workloads before upgrading the Linux payload.' }
                return $true
            }
            if ($guardian) {
                if ($guardian.StartName -notin @('LocalSystem','NT AUTHORITY\SYSTEM') -or
                    -not (Test-WslEgressGuardianServicePath ([string]$guardian.PathName))) {
                    throw 'The guardian service identity differs.'
                }
                $guardianRoot = [IO.Path]::GetDirectoryName(([regex]::Match($guardian.PathName, '^"([^"]+)" --service$')).Groups[1].Value)
                if ($guardianRoot -ine $destination) {
                    # Keep the service ImagePath intact for the separately
                    # installed canonical helper package.
                    $null = Assert-PackagePath $guardianRoot
                    $helperPlan = @()
                    $helperFiles = @('clash-wsl-guardian.exe') + @(
                        Get-ChildItem -LiteralPath (Join-Path $source 'resources\wsl-secure-egress') -Recurse -File |
                            ForEach-Object { $_.FullName.Substring($source.Length + 1) })
                    $receiptPath = Join-Path $guardianRoot 'installed-files.json'
                    if (Test-Path -LiteralPath $receiptPath) {
                        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
                        foreach ($entry in $receipt.PSObject.Properties) {
                            if ($entry.Name -notin $helperFiles -or
                                (Get-PackageHash (Join-Path $guardianRoot $entry.Name)) -ne $entry.Value) {
                                throw 'The helper package differs from its installed receipt.'
                            }
                        }
                    }
                    $hashes = [ordered]@{}
                    foreach ($name in $helperFiles) {
                        $target = Assert-PackagePath (Join-Path $guardianRoot $name)
                        $after = Get-PackageHash (Join-Path $source $name)
                        $before = Get-PackageHash $target
                        $hashes[$name] = $after
                        if ($before -ne $after) {
                            $helperPlan += [ordered]@{ target=$target; source=(Join-Path $source $name)
                                before=$before; after=$after; backup=''; written=$false }
                        }
                    }
                    $newReceipt = Join-Path $root 'helper-next-receipt.json'
                    [IO.File]::WriteAllText($newReceipt, ($hashes | ConvertTo-Json),
                        (New-Object Text.UTF8Encoding($false)))
                    $helperPlan += [ordered]@{ target=$receiptPath; source=$newReceipt
                        before=(Get-PackageHash $receiptPath); after=(Get-PackageHash $newReceipt)
                        backup=''; written=$false }
                    $journal.files = @($journal.files) + $helperPlan
                    $helperTargets = @($helperPlan | ForEach-Object { $_.target })
                }
                $journal.guardian_was_running = $guardian.State -eq 'Running'
            } elseif ($active) { throw 'An active WSL guard has no owned audit service.' }
        }
        Save-PackageJournal $journal $root
        if ($journal.guardian_was_running) {
            Stop-Service -Name 'ClashOfRust.WslEgress' -ErrorAction Stop
            $controller = Get-Service -Name 'ClashOfRust.WslEgress'
            $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(20))
        }
        $journal.phase = 'applying'
        Save-PackageJournal $journal $root
        try {
            Write-PackageFiles $journal $root
            if ($active) {
                $journal.linux_payload_updated = $true
                Save-PackageJournal $journal $root
                Update-PackageLinux $modulePath $true
            }
            if ($guardian) {
                $updated = Import-Module $modulePath -Force -PassThru -DisableNameChecking
                & $updated {
                    param($HelperTargets, $Journal)
                    $state = Read-WslEgressState
                    if ($state -and $state.phase -ne 'restored' -and -not (Get-WslEgressClosureAudit $state).confirmed) {
                        throw 'The post-upgrade WSL guard is not confirmed closed.'
                    }
                    foreach ($file in @($HelperTargets)) {
                        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne
                            (@($Journal.files | Where-Object { $_.target -eq $file })[0].after)) {
                            throw 'An installed helper resource changed during upgrade.'
                        }
                    }
                    Assert-WslEgressBaseline @(Get-WslEgressBaseline)
                } $helperTargets $journal
            }
            if ($journal.guardian_was_running) { Start-Service 'ClashOfRust.WslEgress' -ErrorAction Stop }
            $networkAfter = Get-CimInstance Win32_Service -Filter "Name='ClashOfRust.Network'"
            if ([long]$networkAfter.ProcessId -ne $journal.network_process_id) {
                throw 'The shared Windows network service changed during upgrade.'
            }
            $journal.phase = 'applied'
            Save-PackageJournal $journal $root
        } catch {
            $failure = $_
            try {
                if ($journal.guardian_was_running) { Stop-Service 'ClashOfRust.WslEgress' -ErrorAction Stop }
                Restore-PackageFiles $journal $root -Immediate
                Restore-PackageRegistration $journal
                if ($journal.linux_payload_updated) { Update-PackageLinux $modulePath $false }
                if ($journal.guardian_was_running) { Start-Service 'ClashOfRust.WslEgress' -ErrorAction Stop }
                $journal.phase = 'restored'
                Save-PackageJournal $journal $root
            } catch { throw 'Package upgrade and code rollback failed; retain the closed guard and recovery journal.' }
            throw $failure
        }
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($Action -eq 'CreateManifest') {
            # The elevated installer creates this only after extracting its
            # complete package. The digest is passed separately to Apply.
            [Console]::Write((New-PackageManifest $PackagePath $ManifestPath))
            exit 0
        }
        $approvedPath = $null
        $manifestDigest = $null
        if ($Action -eq 'Apply') {
            if (-not $ManifestPath -or $ExpectedManifestSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
                throw 'Apply requires a private manifest and its exact SHA256.'
            }
            $ManifestPath = Assert-PackagePath $ManifestPath
            $manifestDigest = Get-PackageHash $ManifestPath
            if ($manifestDigest -ne $ExpectedManifestSha256.ToUpperInvariant()) {
                throw 'The private manifest differs from the approved SHA256.'
            }
            $approvedPath = $ManifestPath
        }
        Invoke-PackageUpgrade $Action $InstallationPath $PackagePath $approvedPath $manifestDigest
        [ordered]@{ outcome='succeeded'; action=$Action; endpoint_reopened=$false
            network_service_preserved=$true } | ConvertTo-Json -Compress
        exit 0
    } catch {
        # Avoid printing target/profile contents from nested PowerShell errors.
        [ordered]@{ outcome='failed'; action=$Action; message=[string]$_.Exception.Message
            recovery='Retain .package-update and run the installed code-only rollback before retrying.' } |
            ConvertTo-Json -Compress
        exit 1
    }
}
