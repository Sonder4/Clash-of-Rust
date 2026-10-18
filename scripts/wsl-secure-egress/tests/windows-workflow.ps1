#Requires -Version 5.1
# All network, WSL, policy, task and filesystem-write boundaries are mocked.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot '../WslSecureEgress.psm1') -Force -PassThru
& $module {
    $script:Assertions = 0
    $script:Calls = New-Object 'Collections.Generic.List[string]'
    $script:Writes = New-Object 'Collections.Generic.List[object]'
    function Assert-Equal($Actual, $Expected, [string]$Name) {
        if ($Actual -cne $Expected) { throw "FAIL: $Name" }
        $script:Assertions++
    }
    $completeInstallationImplementation = (Get-Command Test-WslEgressCompleteInstallation).ScriptBlock
    function Reset-Fixture {
        $script:Calls.Clear(); $script:Writes.Clear()
        $script:Administrator = $true; $script:AuditValid = $true
        $script:BaselineGood = $true; $script:ScopeGood = $true
        $script:CompleteInstallation = $false
        $script:Running = @('Ubuntu')
        $script:Fixture = [ordered]@{
            schema_version = 1; owner = 'ClashOfRust.WslEgress'; owner_sid = 'S-1-5-21-fixture'
            generation = 41; backend = 'WireGuard'; manager_distro = 'Ubuntu'
            phase = 'connected_unverified'; endpoint_ipv4 = '203.0.113.8'; endpoint_port = 51820
            endpoint_enabled = $true; distributions = @('Ubuntu'); distro_configs = @()
            uid = 1000; gid = 1000; operation_id = '00000000-0000-0000-0000-000000000041'
        }
    }
    function script:Assert-WslEgressUser { 'S-1-5-21-fixture' }
    function script:Test-WslEgressAdministrator { $script:Administrator }
    function script:Read-WslEgressState { $script:Fixture }
    function script:Get-WslEgressDistributions {
        @([pscustomobject]@{ name = 'Ubuntu'; state = 'unknown'; coverage = 'unknown' })
    }
    function script:Get-WslEgressRunningDistributions {
        $script:Calls.Add('running-inventory')
        $script:Running
    }
    function script:Get-WslEgressBaseline {
        $script:Calls.Add('baseline')
        if (-not $script:BaselineGood) { throw 'fixture baseline unhealthy' }
        @([pscustomobject]@{ dns = 'PASS'; tls = 'PASS'; http_status = 200; expected_statuses = @(200) })
    }
    function script:Protect-WslEgressDirectory { param([string]$Path) }
    function script:Get-WslEgressGuardAudit { [pscustomobject]@{ valid = $script:AuditValid; issues = @() } }
    function script:Test-WslEgressCompleteInstallation {
        param($State, $Distributions)
        $script:Calls.Add('complete-installation-audit')
        [bool]$script:CompleteInstallation
    }
    function script:Get-WslEgressScopeAttestation {
        $script:Calls.Add('full-scope-audit')
        [ordered]@{ schema = 1; generation = 41; issued_at_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            all_distros_managed = $script:ScopeGood; hyperv_default_deny = $true
            dns_tunneling_disabled = $true; interop_disabled = $true
            docker_desktop_blocked = $true; effective_audit_passed = $script:ScopeGood }
    }
    function script:Read-WslEgressProfile { throw 'Unexpected private profile reread.' }
    function script:Get-WslEgressInstalledIdentity {
        param($State, $SuppliedProfile)
        if ($null -ne $SuppliedProfile) { throw 'Unexpected profile override.' }
        $script:Calls.Add('installed-profile-identity')
        [pscustomobject]@{ uid = 1000; gid = 1000 }
    }
    function script:Invoke-WslEgressLinux {
        param($State, $Action, $InputText, $AdditionalArguments, $Distribution)
        $script:Calls.Add('linux:' + $Action)
        if ($Action -eq 'attest') {
            $proof = $InputText | ConvertFrom-Json
            if ($proof.generation -ne 41 -or -not $proof.effective_audit_passed) { throw 'Invalid fixture proof.' }
        }
        [ordered]@{ outcome = 'succeeded'; phase = 'Running'; checks = @() }
    }
    function script:Invoke-WslEgressProcess { throw 'Unexpected unmocked WSL process.' }
    function script:Start-WslEgressLifetime { $script:Calls.Add('lifetime') }
    function script:Save-WslEgressJson {
        param($Value, $Path)
        $script:Writes.Add([pscustomobject]@{ file = [IO.Path]::GetFileName($Path); value = $Value })
    }
    function script:Set-WslEgressEndpoint {
        param($State, $Enabled)
        $State.endpoint_enabled = [bool]$Enabled
        $script:Calls.Add('endpoint:' + [string][bool]$Enabled)
    }
    function script:Install-WslEgressRenewalTask { $script:Calls.Add('install-renewal-task') }
    function script:Remove-WslEgressRenewalTask { $script:Calls.Add('remove-renewal-task') }
    function script:Add-WslEgressInspection {
        param($Result, $State, $Distributions)
        $script:Calls.Add('inspection')
        $Result.checks += [ordered]@{ id = 'wsl_runtime'; result = 'PASS'; detail = 'fixture local invariants' }
    }
    function script:Set-WslEgressPersistentGuard { throw 'Unexpected host policy install.' }
    function script:Install-WslEgressConfig { throw 'Unexpected WSL config install.' }
    function script:Set-WslEgressDockerGuard {
        param($State, [bool]$Remove)
        $script:Calls.Add('docker:' + [string][bool]$Remove)
    }
    function script:Remove-WslEgressGuardianIfOwned {
        $script:Calls.Add('remove-guardian')
    }
    function script:Restore-WslEgressConfig {
        param($State)
        $script:Calls.Add('restore-wslconfig')
    }
    function script:Save-WslEgressRestoredGeneration {
        param($State, [switch]$RetainLiveState)
        $script:Calls.Add('archive-restored')
        $script:Archived = $State
        $script:RetainedLiveState = [bool]$RetainLiveState
        'fixture-archive'
    }
    function script:Set-NetFirewallHyperVVMSetting {
        param($PolicyStore, $Name, $Enabled, $DefaultInboundAction,
            $DefaultOutboundAction, $AllowHostPolicyMerge, $LoopbackEnabled)
        $script:Calls.Add('restore-hyperv')
    }
    function script:Get-WslEgressSettingsFromStore {
        param($PolicyStore)
        if ($script:Fixture.Contains('before_persistent_settings')) {
            $script:Fixture.before_persistent_settings
        } else {
            [ordered]@{ Enabled = 'False'; DefaultInboundAction = 'Allow'; DefaultOutboundAction = 'Allow'
                AllowHostPolicyMerge = 'True'; LoopbackEnabled = 'True' }
        }
    }
    function script:Get-WslEgressSettings {
        if ($script:Fixture.Contains('before_persistent_settings')) {
            $script:Fixture.before_persistent_settings
        } else {
            [ordered]@{ Enabled = 'False'; DefaultInboundAction = 'Allow'; DefaultOutboundAction = 'Allow'
                AllowHostPolicyMerge = 'True'; LoopbackEnabled = 'True' }
        }
    }
    function script:Set-WslEgressEndpoint {
        param($State, [bool]$Enabled)
        $State.endpoint_enabled = $Enabled
        $script:Calls.Add('endpoint:' + [string]$Enabled)
    }

    Reset-Fixture
    $script:Fixture.phase = 'restored'
    $script:Fixture.endpoint_enabled = $false
    $script:Running = @()
    $reinstallRejected = Invoke-WslEgressOperation -Action Install -Execute -ProfilePath 'C:\Private\missing.json'
    Assert-Equal $reinstallRejected.outcome 'failed' 'invalid reinstall profile reports failure'
    Assert-Equal $reinstallRejected.phase 'restored' 'invalid reinstall preserves the terminal phase'
    Assert-Equal $script:Fixture.generation 41 'invalid reinstall preserves the retired generation'
    Assert-Equal ($script:Calls -contains 'archive-restored') $false 'invalid profile never retires the old journal'
    Assert-Equal @($script:Writes | Where-Object { $_.file -eq 'state.json' }).Count 0 'invalid reinstall never rewrites restored state'
    $restoredStatus = Invoke-WslEgressOperation -Action Status
    Assert-Equal $restoredStatus.generation 41 'status after invalid reinstall keeps its nonzero generation'
    Assert-Equal $restoredStatus.phase 'restored' 'status after invalid reinstall remains terminal and refreshable'

    Reset-Fixture
    $started = Invoke-WslEgressOperation -Action Start -Execute
    Assert-Equal $started.outcome 'succeeded' 'existing Start succeeds without private profile re-entry'
    Assert-Equal $started.phase 'connected_unverified' 'Start does not invent full acceptance'
    Assert-Equal ($script:Calls -contains 'installed-profile-identity') $true 'Start validates the root-owned installed identity'
    Assert-Equal ($script:Calls -contains 'install-renewal-task') $true 'Start installs the owned proof-renewal task'
    Assert-Equal ($script:Calls -contains 'linux:start') $true 'Start invokes the fixed Linux lifecycle'
    Assert-Equal @($script:Writes | Where-Object { $_.file -eq 'scope-renewal.json' }).Count 1 'fresh Start proof issuance is recorded'
    Assert-Equal ($started.operation_id -eq '00000000-0000-0000-0000-000000000041') $false 'each invocation receives a fresh operation identity'

    foreach ($parameters in @(
        @{ Backend = 'Tailscale' }, @{ Distro = 'Other' },
        @{ EndpointIPv4 = '203.0.113.9' }, @{ EndpointPort = 51999 })) {
        Reset-Fixture
        $rejected = Invoke-WslEgressOperation -Action Start -Execute @parameters
        Assert-Equal $rejected.outcome 'blocked' 'explicit conflicting deployment parameter is rejected'
        Assert-Equal $script:Calls.Count 0 'configuration mismatch does not enter network or WSL boundaries'
        Assert-Equal $script:Fixture.endpoint_enabled $true 'configuration rejection does not change the installed endpoint'
    }

    Reset-Fixture
    $script:BaselineGood = $false
    $rejected = Invoke-WslEgressOperation -Action Start -Execute
    Assert-Equal $rejected.outcome 'blocked' 'unhealthy mandatory Windows baseline blocks Start'
    Assert-Equal $script:Calls.Count 1 'no action follows the failed baseline'
    Assert-Equal $script:Writes.Count 0 'failed baseline preserves the existing journal'
    Assert-Equal $script:Fixture.phase 'connected_unverified' 'baseline failure does not corrupt deployment phase'

    Reset-Fixture
    $script:ScopeGood = $false
    $failed = Invoke-WslEgressOperation -Action Start -Execute
    Assert-Equal $failed.outcome 'failed' 'incomplete current scope audit fails Start'
    Assert-Equal ($script:Calls -contains 'endpoint:False') $true 'failed scope audit closes the endpoint'
    Assert-Equal ($script:Calls -contains 'endpoint:True') $false 'failed scope never opens the endpoint'
    Assert-Equal ($script:Calls -contains 'install-renewal-task') $false 'failed Start never schedules proof issuance'
    Assert-Equal ($failed.checks | Where-Object { $_.id -eq 'all_wsl_coverage' }).result 'FAIL' 'scope failure reaches the structured report'

    Reset-Fixture
    $adopted = Invoke-WslEgressOperation -Action Install -Execute
    Assert-Equal $adopted.outcome 'succeeded' 'existing Install is idempotent'
    Assert-Equal ($script:Calls -contains 'inspection') $true 'adopted installation is inspected'
    Assert-Equal $script:Writes.Count 0 'idempotent Install never replaces the rollback snapshot'
    Assert-Equal ($script:Calls -contains 'endpoint:True') $false 'idempotent Install does not open an endpoint'

    foreach ($failedPhase in @('failed_closed_requested', 'closure_unverified')) {
        Reset-Fixture
        $script:Fixture.phase = $failedPhase
        $script:Fixture.endpoint_enabled = $false
        $script:Fixture.linux_manager_install_started = $true
        $script:Running = @()
        $blockedInstall = Invoke-WslEgressOperation -Action Install -Execute -ProfilePath 'C:\Private\egress.json'
        Assert-Equal $blockedInstall.outcome 'blocked' "$failedPhase Install cannot recover after Linux install started"
        Assert-Equal $blockedInstall.phase $failedPhase "$failedPhase Install preserves recovery phase"
        Assert-Equal (@($script:Calls | Where-Object { $_ -notin @('baseline', 'running-inventory', 'complete-installation-audit') }).Count -eq 0) $true "$failedPhase Install performs no mutating network or WSL operation"
    }

    Reset-Fixture
    $script:Fixture.phase = 'blocked'
    $script:Fixture.endpoint_enabled = $false
    $script:Fixture.linux_manager_install_started = $true
    $script:Fixture.linux_manager_installed = $false
    $script:CompleteInstallation = $true
    $script:Running = @()
    $adoptedHistorical = Invoke-WslEgressOperation -Action Install -Execute
    Assert-Equal $adoptedHistorical.outcome 'succeeded' 'exact historical blocked deployment is adopted'
    Assert-Equal $adoptedHistorical.phase 'installed_closed' 'adoption records only the closed phase'
    Assert-Equal $script:Fixture.installation_complete $true 'adoption writes the completion marker'
    Assert-Equal ($script:Calls -contains 'endpoint:True') $false 'adoption never opens the endpoint'

    Reset-Fixture
    $script:Fixture.phase = 'blocked'
    $script:Fixture.endpoint_enabled = $false
    $script:Fixture.linux_manager_install_started = $true
    $script:Fixture.linux_manager_installed = $false
    $script:CompleteInstallation = $false
    $script:Running = @()
    $ambiguousBlocked = Invoke-WslEgressOperation -Action Install -Execute
    Assert-Equal $ambiguousBlocked.outcome 'blocked' 'unverified historical blocked deployment is not adopted'
    Assert-Equal $ambiguousBlocked.phase 'blocked' 'ambiguous adoption preserves the blocked phase'
    Assert-Equal (@($script:Calls | Where-Object { $_ -notin @('baseline', 'running-inventory', 'complete-installation-audit') }).Count -eq 0) $true 'ambiguous adoption performs no mutation'

    Reset-Fixture
    $script:Fixture.phase = 'blocked'
    $script:Fixture.endpoint_enabled = $false
    $script:Fixture.linux_manager_install_started = $false
    $script:Fixture.linux_manager_installed = $false
    $script:CompleteInstallation = $true
    $script:Running = @()
    $adoptedMarkerless = Invoke-WslEgressOperation -Action Install -Execute
    Assert-Equal $adoptedMarkerless.outcome 'succeeded' 'exact markerless blocked deployment is adopted'
    Assert-Equal $adoptedMarkerless.phase 'installed_closed' 'markerless adoption records only the closed phase'
    Assert-Equal $script:Fixture.installation_complete $true 'markerless adoption writes the completion marker'
    Assert-Equal ($script:Calls -contains 'endpoint:True') $false 'markerless adoption never opens the endpoint'

    Reset-Fixture
    $script:Fixture.phase = 'blocked'
    $script:Fixture.endpoint_enabled = $false
    $script:Fixture.linux_manager_install_started = $false
    $script:Fixture.linux_manager_installed = $false
    $script:CompleteInstallation = $false
    $script:Running = @()
    $ambiguousMarkerless = Invoke-WslEgressOperation -Action Install -Execute
    Assert-Equal $ambiguousMarkerless.outcome 'blocked' 'unverified markerless blocked deployment is not adopted'
    Assert-Equal $ambiguousMarkerless.phase 'blocked' 'ambiguous markerless adoption preserves the blocked phase'
    Assert-Equal (@($script:Calls | Where-Object { $_ -notin @('baseline', 'running-inventory', 'complete-installation-audit') }).Count -eq 0) $true 'ambiguous markerless adoption performs no mutation'

    $modulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../WslSecureEgress.psm1'))
    $moduleText = Get-Content -LiteralPath $modulePath -Raw
    $start = $moduleText.IndexOf('function Test-WslEgressCompleteInstallation', [StringComparison]::Ordinal)
    $end = $moduleText.IndexOf("`nfunction ", $start + 1, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -lt 0) { throw 'Could not isolate the real complete-installation audit.' }
    $completeInstallationSource = $moduleText.Substring($start, $end - $start)
    $completeInstallationImplementation = [scriptblock]::Create(
        "param(`$State, `$Distributions)`n$completeInstallationSource`n" +
        "Test-WslEgressCompleteInstallation `$State `$Distributions")

    $completeState = [ordered]@{
        schema_version = 1; owner = 'ClashOfRust.WslEgress'; owner_sid = 'S-1-5-21-fixture'
        generation = 41; backend = 'WireGuard'; manager_distro = 'Ubuntu'; phase = 'blocked'
        endpoint_enabled = $false; distributions = @('Ubuntu', 'Debian'); distro_configs = @('Debian')
        distro_config_pending = @(); linux_manager_installed = $true
        endpoint_ipv4 = '203.0.113.8'; endpoint_port = 51820; uid = 1000; gid = 1000
    }
    $completeDistributions = @(
        [pscustomobject]@{ name = 'Ubuntu' },
        [pscustomobject]@{ name = 'Debian' })
    $script:AuditValid = $true
    $script:AdoptionLinuxActions = New-Object 'Collections.Generic.List[string]'
    function script:Invoke-WslEgressLinux {
        param($State, $Action, $InputText, $AdditionalArguments, $Distribution)
        $script:AdoptionLinuxActions.Add($Action)
        if ($Action -eq 'status') {
            [ordered]@{ outcome = 'succeeded'; phase = 'Guarded'; generation = 41; facts = @{} }
        } elseif ($Action -eq 'audit-config') {
            [ordered]@{ outcome = 'succeeded'; phase = 'DistroConfigured'; generation = 41
                facts = [pscustomobject]@{ owned_config_matches = $true; interop_runtime_disabled = $true } }
        } else { throw 'Unexpected Linux action.' }
    }
    Assert-Equal (& $completeInstallationImplementation $completeState $completeDistributions) $true 'same-generation complete blocked installation is adoptable'
    Assert-Equal ($script:AdoptionLinuxActions -join ',') 'status,audit-config,audit-config' 'adoption audits the manager and configured distro'
    $completeState.generation = 40
    Assert-Equal (& $completeInstallationImplementation $completeState $completeDistributions) $false 'generation mismatch prevents adoption'
    $completeState.generation = 41
    $completeState.distro_config_pending = @($null)
    Assert-Equal (& $completeInstallationImplementation $completeState $completeDistributions) $true 'legacy null pending entry does not block adoption'
    $completeState.linux_manager_installed = $true
    function script:Invoke-WslEgressLinux {
        param($State, $Action, $InputText, $AdditionalArguments, $Distribution)
        if ($Action -eq 'status') {
            [ordered]@{ outcome = 'succeeded'; phase = 'Running'; generation = 41; facts = @{} }
        } else { throw 'Unexpected Linux action.' }
    }
    Assert-Equal (& $completeInstallationImplementation $completeState $completeDistributions) $false 'manager not in the closed guarded phase prevents adoption'
    function script:Invoke-WslEgressLinux {
        param($State, $Action, $InputText, $AdditionalArguments, $Distribution)
        if ($Action -eq 'status') {
            [ordered]@{ outcome = 'succeeded'; phase = 'Guarded'; generation = 41; facts = @{} }
        } elseif ($Action -eq 'audit-config') {
            [ordered]@{ outcome = 'succeeded'; phase = 'DistroConfigured'; generation = 41
                facts = [pscustomobject]@{ owned_config_matches = $true; interop_runtime_disabled = $false } }
        } else { throw 'Unexpected Linux action.' }
    }
    Assert-Equal (& $completeInstallationImplementation $completeState $completeDistributions) $false 'enabled interop prevents adoption'
    function script:Invoke-WslEgressLinux {
        param($State, $Action, $InputText, $AdditionalArguments, $Distribution)
        if ($Action -eq 'status') {
            [ordered]@{ outcome = 'succeeded'; phase = 'Guarded'; generation = 41; facts = @{} }
        } elseif ($Action -eq 'audit-config') {
            [ordered]@{ outcome = 'succeeded'; phase = 'DistroConfigured'; generation = 41
                facts = [pscustomobject]@{ owned_config_matches = $true; interop_runtime_disabled = $true } }
        } else { throw 'Unexpected Linux action.' }
    }
    $completeState.distro_config_pending = @('Debian')
    Assert-Equal (& $completeInstallationImplementation $completeState $completeDistributions) $false 'pending distro configuration prevents adoption'
    $completeState.distro_config_pending = @()
    $completeState.endpoint_enabled = $true
    Assert-Equal (& $completeInstallationImplementation $completeState $completeDistributions) $false 'enabled endpoint prevents adoption'
    $completeState.endpoint_enabled = $false
    $completeState.distro_config_pending = @()
    $script:AuditValid = $false
    Assert-Equal (& $completeInstallationImplementation $completeState $completeDistributions) $false 'invalid host guard prevents adoption'
    $script:AuditValid = $true
    Assert-Equal (& $completeInstallationImplementation $completeState @([pscustomobject]@{ name = 'Ubuntu' })) $false 'distribution inventory mismatch prevents adoption'
    $completeState.distro_configs = @()
    Assert-Equal (& $completeInstallationImplementation $completeState $completeDistributions) $false 'missing distro configuration ownership prevents adoption'
    $completeState.distro_configs = @('Debian')
    function script:Invoke-WslEgressLinux {
        param($State, $Action, $InputText, $AdditionalArguments, $Distribution)
        if ($Action -eq 'status') {
            [ordered]@{ outcome = 'succeeded'; phase = 'Guarded'; generation = 41; facts = @{} }
        } elseif ($Action -eq 'audit-config') {
            [ordered]@{ outcome = 'succeeded'; phase = 'DistroConfigured'; generation = 41
                facts = [pscustomobject]@{
                    owned_config_matches = $Distribution -ne 'Ubuntu'
                    interop_runtime_disabled = $true } }
        } else { throw 'Unexpected Linux action.' }
    }
    Assert-Equal (& $completeInstallationImplementation $completeState $completeDistributions) $false 'manager configuration drift prevents adoption'

    foreach ($failedPhase in @('failed_closed_requested', 'closure_unverified')) {
        Reset-Fixture
        $script:Fixture.phase = $failedPhase
        $script:Fixture.endpoint_enabled = $false
        $script:Fixture.linux_manager_install_started = $false
        $script:Fixture.linux_manager_installed = $false
        $script:Running = @()
        $partialRecovered = Invoke-WslEgressOperation -Action Install -Execute -ProfilePath 'C:\Private\egress.json'
        Assert-Equal $partialRecovered.outcome 'failed' "$failedPhase Install reaches the profile gate after Windows-only recovery"
        Assert-Equal $script:Fixture.phase $failedPhase "$failedPhase Install preserves closed recovery state when profile validation fails"
        Assert-Equal ($script:Calls -contains 'archive-restored') $false "$failedPhase Install validates before restoring the journal"
        Assert-Equal ($script:Calls -contains 'restore-hyperv') $false "$failedPhase Install validates before restoring host settings"
    }

    Reset-Fixture
    $script:Fixture.phase = 'failed_closed_requested'
    $script:Fixture.endpoint_enabled = $false
    $script:Fixture.settings_write_started = $true
    $script:Fixture.settings_written = $true
    $script:Fixture.linux_manager_install_started = $false
    $script:Fixture.linux_manager_installed = $false
    $script:Fixture.before_persistent_settings = [ordered]@{
        Enabled = 'False'; DefaultInboundAction = 'Allow'; DefaultOutboundAction = 'Allow'
        AllowHostPolicyMerge = 'True'; LoopbackEnabled = 'True' }
    $script:Running = @()
    $script:preservedDuringReinstall = $false
    function script:Restore-WslEgressPartialInstall {
        param($State, [switch]$PreserveGuard)
        $script:Calls.Add('partial-cleanup')
        Assert-Equal $PreserveGuard.IsPresent $true 'reinstall preserves the current host guard'
        Assert-Equal $script:AuditValid $true 'reinstall cleanup runs under a closed guard'
        $State.phase = 'prepared_for_reinstall'
        $script:preservedDuringReinstall = $true
    }
    function script:Read-WslEgressProfile {
        [pscustomobject]@{ schema = 1; backend = 'WireGuard'; manager_distro = 'Ubuntu'
            endpoint_ipv4 = '203.0.113.8'; endpoint_port = 51820; uid = 1000; gid = 1000 }
    }
    function script:Get-WslEgressDockerPaths { throw 'fixture stops after guarded cleanup' }
    $preservedRecovery = Invoke-WslEgressOperation -Action Install -Execute -ProfilePath 'C:\Private\egress.json'
    Assert-Equal $preservedRecovery.outcome 'failed' 'post-cleanup validation failure is reported'
    Assert-Equal $script:Fixture.phase 'prepared_for_reinstall' 'partial cleanup records reinstall preparation'
    Assert-Equal $script:preservedDuringReinstall $true 'reinstall cleanup completed before the later failure'
    Assert-Equal ($script:Calls -contains 'partial-cleanup') $true 'reinstall cleanup requested guard preservation'
    Assert-Equal ($script:Calls -contains 'restore-hyperv') $false 'reinstall never releases host deny during cleanup'
    $partialCleanupImplementation = (Get-Command Restore-WslEgressPartialInstall).ScriptBlock
    Set-Item -LiteralPath Function:script:Restore-WslEgressPartialInstall -Value {
        param($State, [switch]$PreserveGuard)
        if ($PreserveGuard.IsPresent) {
            $script:Calls.Add('partial-cleanup')
            $State.phase = 'prepared_for_reinstall'
        } else {
            $script:Calls.Add('partial-full-restore')
            if ($State.settings_write_started) { $script:Calls.Add('restore-hyperv') }
            if ($State.docker_guard_written) { $script:Calls.Add('docker:True') }
            if ($State.guardian_service_installed) { $script:Calls.Add('remove-guardian') }
            if ($State.Contains('wslconfig')) { $script:Calls.Add('restore-wslconfig') }
            $State.phase = 'restored'
        }
    }
    function script:Get-WslEgressDockerPaths { @() }

    Reset-Fixture
    $script:Fixture.phase = 'restored'
    $script:Fixture.before_persistent_settings = [ordered]@{
        Enabled = 'False'; DefaultInboundAction = 'Allow'; DefaultOutboundAction = 'Allow'
        AllowHostPolicyMerge = 'True'; LoopbackEnabled = 'True' }
    $script:Archived = $null
    $script:Writes.Clear()
    $script:Running = @()
    $distributionFixtureImplementation = (Get-Command Get-WslEgressDistributions).ScriptBlock
    function script:Get-WslEgressDistributions {
        @(
            [pscustomobject]@{ name = 'Ubuntu'; state = 'unknown'; coverage = 'unknown' },
            [pscustomobject]@{ name = 'Debian'; state = 'unknown'; coverage = 'unknown' },
            [pscustomobject]@{ name = 'Fedora'; state = 'unknown'; coverage = 'unknown' },
            [pscustomobject]@{ name = 'Arch'; state = 'unknown'; coverage = 'unknown' })
    }
    function script:Read-WslEgressProfile {
        [pscustomobject]@{ schema = 1; backend = 'WireGuard'; manager_distro = 'Ubuntu'
            endpoint_ipv4 = '203.0.113.8'; endpoint_port = 51820; uid = 1000; gid = 1000 }
    }
    function script:Get-WslEgressDockerPaths { @() }
    function script:Set-WslEgressPersistentGuard {
        param($State)
        $State.settings_written = $true
        $script:Calls.Add('install-hyperv')
    }
    function script:Install-WslEgressGuardian {
        param($State)
        $script:Calls.Add('install-guardian')
    }
    function script:Install-WslEgressConfig {
        param($State)
        $State.wslconfig = [ordered]@{ existed = $false; before_hash = $null; after_hash = 'after' }
        $script:Calls.Add('install-wslconfig')
    }
    function script:Install-WslEgressPayload {
        param($State, $Distro)
        $script:Calls.Add('install-payload:' + $Distro)
    }
    function script:Stop-WslEgressDistribution {
        param([string]$Name)
        $script:Calls.Add('stop-distro:' + $Name)
    }
    function script:Invoke-WslEgressProcess {
        param($Arguments, $InputText, $TimeoutSeconds)
        $script:Calls.Add('process:' + ($Arguments -join ','))
        [pscustomobject]@{ ExitCode = 0; Output = ''; Error = '' }
    }
    function script:Complete-WslEgressGenerationCutover { $script:Calls.Add('complete-generation-cutover') }
    function script:Invoke-WslEgressLinux {
        param($State, $Action, $InputText, $AdditionalArguments, $Distribution)
        $script:Calls.Add('linux:' + $Action + ':' + $Distribution)
        [ordered]@{ outcome = 'succeeded'; phase = 'Guarded'; checks = @() }
    }
    $script:Fixture.operation_id = 'fixture-operation'
    $reinstalled = Invoke-WslEgressOperation -Action Install -Execute -ProfilePath 'C:\Private\egress.json'
    Assert-Equal ($script:Calls -contains 'archive-restored') $true 'fresh Install archives the verified restored journal'
    Assert-Equal ($script:Archived.generation) 41 'archive retains the retired Windows generation'
    Assert-Equal $script:RetainedLiveState $true 'reinstall retains the old live journal until the new atomic save'
    Assert-Equal $reinstalled.outcome 'succeeded' "restored journal permits a fresh install transaction ($($reinstalled.message); phase=$($reinstalled.phase); checks=$($reinstalled.checks | ConvertTo-Json -Compress))"
    Assert-Equal $reinstalled.phase 'installed_closed' 'fresh install completes in a closed state'
    Assert-Equal ($script:Calls -contains 'install-hyperv') $true 'fresh install recreates the host guard'
    Assert-Equal ($script:Calls -contains 'complete-generation-cutover') $true 'fresh install retires generation sidecars only after writing its new state'
    foreach ($name in @('Ubuntu', 'Debian', 'Fedora', 'Arch')) {
        Assert-Equal @($script:Calls | Where-Object { $_ -eq ('install-payload:' + $name) }).Count 1 "fresh install stages exactly one payload for $name"
    }
    foreach ($name in @('Debian', 'Fedora', 'Arch')) {
        Assert-Equal @($script:Calls | Where-Object { $_ -eq ('linux:configure:' + $name) }).Count 1 "fresh install configures exactly once: $name"
    }
    Assert-Equal @($script:Calls | Where-Object { $_ -eq 'linux:configure:Ubuntu' }).Count 0 'manager is not configured as a sibling'
    foreach ($name in @('Ubuntu', 'Debian', 'Fedora', 'Arch')) {
        Assert-Equal @($script:Calls | Where-Object { $_ -eq ('stop-distro:' + $name) }).Count 1 "fresh install stops exactly once: $name"
    }
    Assert-Equal @($script:Calls | Where-Object { $_ -eq 'linux:audit-config:' }).Count 1 'fresh install audits the manager exactly once'
    foreach ($name in @('Debian', 'Fedora', 'Arch')) {
        Assert-Equal @($script:Calls | Where-Object { $_ -eq ('linux:audit-config:' + $name) }).Count 1 "fresh install audits exactly once: $name"
    }
    Assert-Equal @($script:Calls | Where-Object { $_ -eq 'process:--shutdown' }).Count 1 'fresh install performs one shared WSL restart'
    Set-Item -LiteralPath Function:script:Get-WslEgressDistributions -Value $distributionFixtureImplementation

    Reset-Fixture
    $stopped = Invoke-WslEgressOperation -Action Stop -Execute
    Assert-Equal $stopped.outcome 'succeeded' 'Stop completes with an installed deployment'
    Assert-Equal $script:Fixture.endpoint_enabled $false 'Stop leaves the persistent endpoint closed'
    Assert-Equal ($script:Calls -contains 'remove-renewal-task') $true 'Stop removes only its owned renewal task'
    Assert-Equal @($script:Calls | Where-Object { $_ -eq 'linux:stop:' }).Count 1 'Stop asks the running Linux manager to stop exactly once'

    foreach ($stage in @(
        @{ Name = 'hyperv'; Settings = $true },
        @{ Name = 'docker'; Settings = $true; Docker = $true },
        @{ Name = 'guardian'; Settings = $true; Docker = $true; Guardian = $true },
        @{ Name = 'wslconfig'; Settings = $true; Docker = $true; Guardian = $true; Config = $true },
        @{ Name = 'payload'; Settings = $true; Docker = $true; Guardian = $true; Config = $true },
        @{ Name = 'linux-install-started'; Settings = $true; Docker = $true; Guardian = $true
            Config = $true; LinuxStarted = $true })) {
        Reset-Fixture
        $script:Fixture.phase = 'failed_closed_requested'
        $script:Fixture.linux_manager_installed = $false
        $script:Fixture.linux_manager_install_started = [bool]($stage.ContainsKey('LinuxStarted') -and $stage.LinuxStarted)
        $script:Fixture.settings_write_started = [bool]$stage.Settings
        $script:Fixture.docker_guard_written = [bool]$stage.ContainsKey('Docker')
        $script:Fixture.guardian_service_installed = [bool]$stage.ContainsKey('Guardian')
        if ($stage.ContainsKey('Docker')) { $script:Fixture.docker_backends = @('C:\Docker\com.docker.backend.exe') }
        if ($stage.ContainsKey('Config')) {
            $script:Fixture.wslconfig = [ordered]@{ existed = $true; before_hash = 'before'; after_hash = 'after' }
        }
        $script:Fixture.before_persistent_settings = [ordered]@{
            Enabled = 'False'; DefaultInboundAction = 'Allow'; DefaultOutboundAction = 'Allow'
            AllowHostPolicyMerge = 'True'; LoopbackEnabled = 'True' }
        $script:Running = @()
        if ($stage.ContainsKey('LinuxStarted') -and $stage.LinuxStarted) {
            $script:AuditValid = $false
            $recovered = Invoke-WslEgressOperation -Action Rollback -Execute -RestoreOriginalNetwork
            Assert-Equal $recovered.outcome 'failed' 'rollback after Linux install started refuses Windows-only recovery'
            Assert-Equal $script:Fixture.phase 'closure_unverified' 'rollback after Linux install started keeps the host closed'
            Assert-Equal ($script:Calls -contains 'linux:rollback') $false 'rollback after Linux install started does not invoke an unverified manager'
            continue
        }
        try { $recovered = Invoke-WslEgressOperation -Action Rollback -Execute -RestoreOriginalNetwork }
        catch { throw "partial $($stage.Name) exception: $($_.Exception.Message)" }
        Assert-Equal $recovered.outcome 'succeeded' "partial $($stage.Name) rollback succeeds without Linux manager; got $($recovered.outcome) phase=$($recovered.phase) message=$($recovered.message) checks=$($recovered.checks | ConvertTo-Json -Compress)"
        Assert-Equal $script:Fixture.phase 'restored' "partial $($stage.Name) rollback records restored phase"
        Assert-Equal ($script:Calls -contains 'linux:rollback') $false "partial $($stage.Name) never invokes absent Linux manager"
        Assert-Equal ($script:Calls -contains 'restore-hyperv') $stage.Settings "partial $($stage.Name) restores recorded Hyper-V settings"
        Assert-Equal ($script:Calls -contains 'docker:True') ([bool]$stage.ContainsKey('Docker')) "partial $($stage.Name) restores only recorded Docker guard"
        Assert-Equal ($script:Calls -contains 'remove-guardian') ([bool]$stage.ContainsKey('Guardian')) "partial $($stage.Name) removes only recorded guardian"
        Assert-Equal ($script:Calls -contains 'restore-wslconfig') ([bool]$stage.ContainsKey('Config')) "partial $($stage.Name) restores only recorded WSL config"
    }

    Reset-Fixture
    $script:Fixture.phase = 'restored'
    $script:Fixture.before_persistent_settings = [ordered]@{
        Enabled = 'False'; DefaultInboundAction = 'Allow'; DefaultOutboundAction = 'Allow'
        AllowHostPolicyMerge = 'True'; LoopbackEnabled = 'True' }
    $script:Archived = $null
    $script:Writes.Clear()
    $script:Running = @()
    function script:Read-WslEgressProfile {
        [pscustomobject]@{ schema = 1; backend = 'WireGuard'; manager_distro = 'Ubuntu'
            endpoint_ipv4 = '203.0.113.8'; endpoint_port = 51820; uid = 1000; gid = 1000 }
    }
    function script:Get-WslEgressDockerPaths { @() }
    function script:Read-WslEgressProfile {
        [pscustomobject]@{ schema = 1; backend = 'WireGuard'; manager_distro = 'Ubuntu'
            endpoint_ipv4 = '203.0.113.8'; endpoint_port = 51820; uid = 1000; gid = 1000 }
    }
    function script:Set-WslEgressPersistentGuard {
        param($State)
        $State.settings_written = $true
        $script:Calls.Add('install-hyperv')
    }
    function script:Install-WslEgressGuardian {
        param($State)
        $script:Calls.Add('install-guardian')
    }
    function script:Install-WslEgressConfig {
        param($State)
        $State.wslconfig = [ordered]@{ existed = $false; before_hash = $null; after_hash = 'after' }
        $script:Calls.Add('install-wslconfig')
    }
    function script:Install-WslEgressPayload {
        param($State, $Distro)
        $script:Calls.Add('install-payload')
    }
    function script:Stop-WslEgressDistribution {
        param([string]$Name)
        $script:Calls.Add('stop-distro:' + $Name)
    }
    function script:Invoke-WslEgressProcess {
        param($Arguments, $InputText, $TimeoutSeconds)
        $script:Calls.Add('process:' + ($Arguments -join ','))
        [pscustomobject]@{ ExitCode = 0; Output = ''; Error = '' }
    }
    function script:Complete-WslEgressGenerationCutover { $script:Calls.Add('complete-generation-cutover') }
    function script:Invoke-WslEgressLinux {
        param($State, $Action, $InputText, $AdditionalArguments, $Distribution)
        $script:Calls.Add('linux:' + $Action)
        [ordered]@{ outcome = 'succeeded'; phase = 'Guarded'; checks = @() }
    }
    $script:Fixture.operation_id = 'fixture-operation'
    $reinstalled = Invoke-WslEgressOperation -Action Install -Execute -ProfilePath 'C:\Private\egress.json'
    Assert-Equal ($script:Calls -contains 'archive-restored') $true 'fresh Install archives the verified restored journal'
    Assert-Equal ($script:Archived.generation) 41 'archive retains the retired Windows generation'
    Assert-Equal $script:RetainedLiveState $true 'reinstall retains the old live journal until the new atomic save'
    Assert-Equal $reinstalled.outcome 'succeeded' "restored journal permits a fresh install transaction ($($reinstalled.message); phase=$($reinstalled.phase); checks=$($reinstalled.checks | ConvertTo-Json -Compress))"
    Assert-Equal $reinstalled.phase 'installed_closed' 'fresh install completes in a closed state'
    Assert-Equal ($script:Calls -contains 'install-hyperv') $true 'fresh install recreates the host guard'
    Assert-Equal ($script:Calls -contains 'complete-generation-cutover') $true 'fresh install retires generation sidecars only after writing its new state'

    # The full path must use dictionary-safe snapshot lookup, not PSObject's
    # property list (which does not expose OrderedDictionary keys).
    function script:Get-NetFirewallHyperVRule { @() }
    foreach ($action in @('Rollback', 'Uninstall')) {
        Reset-Fixture
        $script:Running = @()
        $script:Fixture.settings_written = $true
        $script:Fixture.endpoint_rule_written = $false
        $script:Fixture.before_persistent_settings = [ordered]@{
            Enabled = 'False'; DefaultInboundAction = 'Allow'; DefaultOutboundAction = 'Allow'
            AllowHostPolicyMerge = 'True'; LoopbackEnabled = 'True' }
        $script:Fixture.after_settings = $script:Fixture.before_persistent_settings
        $fullRestore = Invoke-WslEgressOperation -Action $action -Execute -RestoreOriginalNetwork
        Assert-Equal $fullRestore.outcome 'succeeded' "$action restores an OrderedDictionary journal"
        Assert-Equal $fullRestore.phase 'restored' "$action records the completed terminal phase"
        Assert-Equal ($script:Calls -contains 'linux:rollback') $true "$action reaches Linux rollback after reading the snapshot"
        Assert-Equal ($script:Calls -contains 'restore-hyperv') $true "$action restores the recorded persistent Hyper-V snapshot"
    }

    $linuxFixtureImplementation = (Get-Command Invoke-WslEgressLinux).ScriptBlock
    $stopFixtureImplementation = (Get-Command Stop-WslEgressDistribution).ScriptBlock
    $processFixtureImplementation = (Get-Command Invoke-WslEgressProcess).ScriptBlock
    $saveFixtureImplementation = (Get-Command Save-WslEgressJson).ScriptBlock
    function script:Invoke-WslEgressLinux {
        param($State, $Action, $InputText, $AdditionalArguments, $Distribution)
        if ($Action -eq 'configure') {
            Assert-Equal (@($State.distro_configs) -contains $Distribution) $true 'distro recovery target is recorded before configure can write'
            Assert-Equal (@($State.distro_config_pending) -contains $Distribution) $true 'unacknowledged configuration is recorded before Linux journal creation'
            Assert-Equal ($script:Writes[-1].file) 'state.json' 'distro recovery target is persisted immediately before configure'
            if ($script:DistroFailure -eq 'configure' -and $Distribution -eq 'Fedora') { throw 'fixture second configure failure' }
        }
        [ordered]@{ outcome = 'succeeded'; phase = 'Guarded'; checks = @() }
    }
    function script:Stop-WslEgressDistribution {
        param([string]$Name)
        if ($script:DistroFailure -eq 'terminate' -and $Name -eq 'Debian') { throw 'fixture terminate failure' }
    }
    function script:Invoke-WslEgressProcess {
        param($Arguments, $InputText, $TimeoutSeconds)
        [pscustomobject]@{ ExitCode = $(if ($script:DistroFailure -eq 'shutdown') { 1 } else { 0 }); Output = ''; Error = '' }
    }
    Reset-Fixture
    $script:Fixture.phase = 'preparing'
    $script:Fixture.endpoint_enabled = $false
    $script:Fixture.linux_manager_install_started = $false
    $script:Fixture.linux_manager_installed = $false
    $script:Fixture.before_persistent_settings = [ordered]@{
        Enabled = 'False'; DefaultInboundAction = 'Allow'; DefaultOutboundAction = 'Allow'
        AllowHostPolicyMerge = 'True'; LoopbackEnabled = 'True' }
    $script:Running = @()
    $script:DistroFailure = 'configure'
    $script:AuditValidBeforeReinstallFailure = $true
    $script:preservedDuringReinstall = $false
    # Restore the persistent default-deny guard used by this Install fixture.
    # The previous partial-recovery test intentionally replaced it.
    function script:Set-WslEgressPersistentGuard {
        param($State)
        $State.settings_written = $true
        $script:Calls.Add('install-hyperv')
    }
    function script:Restore-WslEgressPartialInstall {
        param($State, [switch]$PreserveGuard)
        $script:Calls.Add('partial-cleanup')
        $State.phase = 'prepared_for_reinstall'
    }
    $distroConfigurationImplementation = (Get-Command Invoke-WslEgressDistroConfiguration).ScriptBlock
    function script:Invoke-WslEgressDistroConfiguration {
        param($State, $Profile, $Distributions)
        $script:Calls.Add('distro-configuration')
        throw 'fixture distro configuration failure'
    }
    $distroInstallFailure = Invoke-WslEgressOperation -Action Install -Execute -ProfilePath 'C:\Private\egress.json'
    Assert-Equal $distroInstallFailure.outcome 'failed' 'distro configuration failure is reported'
    Assert-Equal $script:Fixture.linux_manager_installed $false 'manager completion marker is not set before distro configuration'
    Assert-Equal ([bool](Get-WslEgressStateValue $script:Fixture 'installation_complete' $false)) $false 'installation completion marker is not set before distro configuration'
    Set-Item -LiteralPath Function:script:Invoke-WslEgressDistroConfiguration -Value $distroConfigurationImplementation
    foreach ($failure in @('configure', 'terminate', 'shutdown')) {
        Reset-Fixture
        $script:DistroFailure = $failure
        $distroRejected = $false
        try {
            Invoke-WslEgressDistroConfiguration $script:Fixture ([pscustomobject]@{}) @(
                [pscustomobject]@{ name = 'Ubuntu' },
                [pscustomobject]@{ name = 'Debian' },
                [pscustomobject]@{ name = 'Fedora' })
        } catch { $distroRejected = $true }
        Assert-Equal $distroRejected $true "$failure failure is reported"
        $expectedDistros = if ($failure -eq 'terminate') { 'Debian' } else { 'Debian,Fedora' }
        Assert-Equal (@($script:Fixture.distro_configs) -join ',') $expectedDistros "$failure failure retains every possible modified distro for rollback"
        $expectedPending = if ($failure -eq 'configure') { 'Fedora' } else { '' }
        Assert-Equal (@($script:Fixture.distro_config_pending) -join ',') $expectedPending "$failure failure only permits an absent Linux journal for unacknowledged configuration"
    }
    Set-Item -LiteralPath Function:script:Invoke-WslEgressLinux -Value $linuxFixtureImplementation
    Set-Item -LiteralPath Function:script:Stop-WslEgressDistribution -Value $stopFixtureImplementation
    Set-Item -LiteralPath Function:script:Invoke-WslEgressProcess -Value $processFixtureImplementation

    function script:Invoke-WslEgressLinux {
        param($State, $Action, $InputText, $AdditionalArguments, $Distribution)
        $script:Calls.Add('linux:' + $Action)
        if ($Action -eq 'restore-config') {
            $allowUnconfigured = @($AdditionalArguments) -contains '--allow-unconfigured'
            Assert-Equal $allowUnconfigured ($script:RestoreFixtureKind -ne 'completed-no-journal') 'missing-journal recovery is explicitly limited to write-ahead configuration'
            if ($script:RestoreFixtureKind -eq 'pending-transport-error') { throw 'fixture transport error' }
            if ($script:RestoreFixtureKind -in @('completed-no-journal', 'pending-drift')) {
                return [ordered]@{ outcome = 'blocked'; phase = 'Blocked'; checks = @() }
            }
            return [ordered]@{ outcome = 'succeeded'; phase = 'DistroUnconfigured'; checks = @() }
        }
        [ordered]@{ outcome = 'succeeded'; phase = 'Guarded'; checks = @() }
    }
    foreach ($scenario in @('pending-no-journal', 'completed-no-journal', 'pending-drift', 'pending-transport-error')) {
        Reset-Fixture
        $script:RestoreFixtureKind = $scenario
        $script:Running = @()
        $script:Fixture.settings_written = $true
        $script:Fixture.endpoint_rule_written = $false
        $script:Fixture.before_persistent_settings = Get-WslEgressSettings
        $script:Fixture.after_settings = $script:Fixture.before_persistent_settings
        $script:Fixture.distro_configs = @('Debian')
        if ($scenario -ne 'completed-no-journal') { $script:Fixture.distro_config_pending = @('Debian') }
        $recovered = Invoke-WslEgressOperation -Action Rollback -Execute -RestoreOriginalNetwork
        $expectedOutcome = if ($scenario -eq 'pending-no-journal') { 'succeeded' } else { 'failed' }
        Assert-Equal $recovered.outcome $expectedOutcome "$scenario recovery reports the Linux result"
        Assert-Equal ($script:Calls -contains 'restore-hyperv') ($scenario -eq 'pending-no-journal') "$scenario only restores host access after verified distro recovery"
        Assert-Equal ($script:Calls -contains 'linux:rollback') ($scenario -eq 'pending-no-journal') "$scenario does not swallow Linux drift or transport errors"
        Assert-Equal $script:Fixture.endpoint_enabled $false "$scenario keeps the endpoint disabled throughout recovery"
    }
    Set-Item -LiteralPath Function:script:Invoke-WslEgressLinux -Value $linuxFixtureImplementation

    Reset-Fixture
    $script:Fixture.phase = 'restored'
    $script:Fixture.endpoint_enabled = $false
    $script:Running = @()
    function script:Save-WslEgressJson {
        param($Value, $Path)
        if ([IO.Path]::GetFileName($Path) -eq 'state.json' -and $Value.generation -ne 41) {
            throw 'fixture new generation atomic save failure'
        }
        $script:Writes.Add([pscustomobject]@{ file = [IO.Path]::GetFileName($Path); value = $Value })
    }
    $saveRejected = Invoke-WslEgressOperation -Action Install -Execute -ProfilePath 'C:\Private\egress.json'
    Assert-Equal $saveRejected.outcome 'failed' 'new generation save failure is reported'
    Assert-Equal $saveRejected.phase 'restored' 'new generation save failure retains terminal phase'
    Assert-Equal $script:Fixture.generation 41 'new generation save failure keeps the old journal identity'
    Assert-Equal ($script:Calls -contains 'install-hyperv') $false 'new generation save failure cannot start host mutations'
    Set-Item -LiteralPath Function:script:Save-WslEgressJson -Value $saveFixtureImplementation

    Reset-Fixture
    $null = Invoke-WslEgressScopeRenewal
    Assert-Equal ($script:Calls -contains 'full-scope-audit') $true 'scheduled renewal performs a fresh complete audit'
    Assert-Equal ($script:Calls -contains 'linux:attest') $true 'successful renewal sends only a proof to Linux'
    Assert-Equal ($script:Calls -contains 'endpoint:True') $false 'renewal never opens the endpoint'
    Assert-Equal ($script:Writes | Where-Object { $_.file -eq 'scope-renewal.json' }).value.outcome 'succeeded' 'successful proof renewal is recorded'

    Reset-Fixture
    $script:Running = @()
    $null = Invoke-WslEgressScopeRenewal
    Assert-Equal ($script:Calls -contains 'full-scope-audit') $false 'renewal does not audit-start a stopped distribution'
    Assert-Equal ($script:Calls -contains 'linux:attest') $false 'stopped distribution cannot receive a fabricated proof'
    Assert-Equal $script:Fixture.endpoint_enabled $false 'stopped required distribution retains fail-closed host state'
    Assert-Equal $script:Fixture.phase 'blocked' 'failed renewal publishes a blocked deployment state'

    Reset-Fixture
    $script:ScopeGood = $false
    $null = Invoke-WslEgressScopeRenewal
    Assert-Equal ($script:Calls -contains 'linux:attest') $false 'incomplete audit cannot renew proof'
    Assert-Equal $script:Fixture.endpoint_enabled $false 'failed renewal closes endpoint without reopening it'
    Assert-Equal ($script:Writes | Where-Object { $_.file -eq 'scope-renewal.json' }).value.outcome 'failed' 'failed renewal records failure honestly'

    Reset-Fixture
    $script:Fixture.endpoint_enabled = $false
    $null = Invoke-WslEgressScopeRenewal
    Assert-Equal ($script:Calls -contains 'running-inventory') $false 'closed deployment renewal does not query WSL'
    Assert-Equal ($script:Calls -contains 'linux:attest') $false 'closed deployment receives no proof'

    $definition = [pscustomobject]@{ name = 'ClashOfRust-WslEgress-Renew'; path = '\'
        executable = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        arguments = '-NoLogo -NoProfile -NonInteractive -File "C:\Program Files\Clash of Rust\resources\wsl-secure-egress\Renew-ScopeAttestation.ps1"'
        owner_sid = 'S-1-5-21-1001-1002-1003-1000'
        owner_account = 'CONTOSO\wsl-owner' }
    $task = [pscustomobject]@{ TaskName = $definition.name; TaskPath = '\'
        Principal = [pscustomobject]@{ UserId = $definition.owner_sid; LogonType = 'Interactive'; RunLevel = 'Highest' }
        Actions = @([pscustomobject]@{ Execute = $definition.executable; Arguments = $definition.arguments; WorkingDirectory = '' }) }
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $task $definition) $true 'exact interactive-owner fixed task is accepted'
    $task.Principal.UserId = 'S-1-5-18'
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $task $definition) $false 'SYSTEM renewal task is rejected'
    $task.Principal.UserId = $definition.owner_sid; $task.Actions[0].Arguments += ' -Command unsafe'
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $task $definition) $false 'task command injection is rejected'
    $task.Actions[0].Arguments = $definition.arguments; $task.Principal.RunLevel = 'Limited'
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $task $definition) $false 'insufficient task run level is rejected'

    [pscustomobject]@{ suite = 'windows-workflow-offline'; result = 'PASS'; assertions = $script:Assertions
        network_tests = 'NOT_RUN'; wsl_started = $false; firewall_modified = $false; scheduled_tasks_modified = $false } |
        ConvertTo-Json -Compress
}
