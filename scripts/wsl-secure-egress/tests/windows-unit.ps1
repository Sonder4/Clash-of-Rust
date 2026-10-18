#Requires -Version 5.1
# Offline tests: replace every host/WSL/network boundary before invoking actions.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot '../WslSecureEgress.psm1') -Force -PassThru
& $module {
    $saveJsonImplementation = (Get-Command Save-WslEgressJson).ScriptBlock
    $script:Calls = [Collections.Generic.List[string]]::new()
    $script:MockAdministrator = $false
    $script:MockState = $null
    function script:Assert-WslEgressUser { 'S-1-5-21-offline-fixture' }
    function script:Test-WslEgressAdministrator { $script:MockAdministrator }
    function script:Get-WslEgressDistributions {
        $script:Calls.Add('enumerate')
        @([pscustomobject]@{ name = 'Ubuntu'; state = 'stopped'; coverage = 'not_enrolled' })
    }
    function script:Read-WslEgressState { $script:MockState }
    function script:Get-WslEgressBaseline { throw 'Unexpected network request in offline test.' }
    function script:Invoke-WslEgressProcess { throw 'Unexpected WSL process in offline test.' }
    function script:Save-WslEgressJson { throw 'Unexpected state write in offline test.' }
    function script:Set-WslEgressPersistentGuard { throw 'Unexpected firewall mutation in offline test.' }
    function script:Set-WslEgressEndpoint { throw 'Unexpected endpoint mutation in offline test.' }
    function script:Start-WslEgressLifetime { throw 'Unexpected WSL lifetime process in offline test.' }

    $count = 0
    function Assert-Equal($Actual, $Expected, [string]$Label) {
        if ($Actual -cne $Expected) { throw "FAIL: $Label" }
        $script:TestCount++
    }
    $script:TestCount = 0
    $connections = @(ConvertFrom-WslEgressConnections '[{"url":"https://portal.example.test/","accepted_statuses":[200,302]},{"url":"https://api.example.test/","accepted_statuses":[200]}]')
    Assert-Equal $connections.Count 2 'JSON baseline array is enumerated under Windows PowerShell 5.1'
    Assert-Equal ([uri]$connections[0].url).Host 'portal.example.test' 'each baseline entry has one URI'
    Assert-Equal $connections[1].accepted_statuses.Count 1 'accepted status list remains attached to its own URI'
    Assert-Equal (ConvertTo-WslEgressProcessArgument '--distribution') '--distribution' 'WSL options remain unquoted'
    Assert-Equal (ConvertTo-WslEgressProcessArgument 'Ubuntu-22.04') 'Ubuntu-22.04' 'simple WSL argument remains unquoted'
    Assert-Equal (ConvertTo-WslEgressProcessArgument 'a b') '"a b"' 'spaced argument is quoted'
    $roundtrip = ConvertTo-WslEgressOrderedState ('{"empty":[],"single":["one"],"multiple":["one","two"],"map":{}}' | ConvertFrom-Json)
    Assert-Equal ($roundtrip.empty -is [Array]) $true 'empty journal arrays retain array identity'
    Assert-Equal $roundtrip.empty.Count 0 'empty journal array has no synthetic dictionary item'
    Assert-Equal ($roundtrip.single -is [Array]) $true 'single-item journal arrays retain array identity'
    Assert-Equal $roundtrip.single.Count 1 'single-item journal array has one item'
    Assert-Equal $roundtrip.multiple.Count 2 'multi-item journal array retains both items'
    Assert-Equal ($roundtrip.map -is [Collections.IDictionary]) $true 'JSON maps remain dictionaries'
    $legacyPending = ConvertTo-WslEgressOrderedState ('{"distro_config_pending":[null]}' | ConvertFrom-Json)
    Assert-Equal (@($legacyPending.distro_config_pending | Where-Object { $null -ne $_ }).Count) 0 'a serialized null pending item is not a configured distro'
    $doctor = Invoke-WslEgressOperation -Action Doctor
    Assert-Equal $doctor.outcome 'succeeded' 'doctor works without administrator'
    Assert-Equal $doctor.protection 'unknown' 'uninstalled does not claim protection'
    Assert-Equal $doctor.generation 0 'uninstalled has no old generation'
    Assert-Equal $doctor.distributions[0].state 'unknown' 'doctor does not infer running state'
    foreach ($action in @('Install','Start','Stop','Rollback','Uninstall')) {
        $preview = Invoke-WslEgressOperation -Action $action
        Assert-Equal $preview.outcome $(if ($action -eq 'Install') { 'blocked' } else { 'not_run' }) "preview $action cannot mutate"
        Assert-Equal $preview.phase 'preflight' "preview $action reports preflight"
        Assert-Equal $preview.protection 'unknown' "preview $action cannot claim a block"
    }
    $blocked = Invoke-WslEgressOperation -Action Install -Backend WireGuard -Execute
    Assert-Equal $blocked.outcome 'blocked' 'nonadministrator install fails before mutation'
    $script:MockAdministrator = $true
    $blocked = Invoke-WslEgressOperation -Action Install -Backend Tailscale -Execute
    Assert-Equal $blocked.outcome 'blocked' 'strict Tailscale fails before widening permissions'
    Assert-Equal $blocked.protection 'unknown' 'blocked request is not a proven packet block'
    $test = Invoke-WslEgressOperation -Action Test
    Assert-Equal $test.outcome 'not_run' 'acceptance not invented'
    Assert-Equal $test.phase 'acceptance_pending' 'acceptance pending is distinct from connection'
    Assert-Equal @($test.checks | Where-Object { $_.id -ne 'administrator' -and $_.result -ne 'NOT_RUN' }).Count 0 'no unexecuted runtime test is passed'
    Assert-Equal ($script:Calls | Where-Object { $_ -ne 'enumerate' } | Measure-Object).Count 0 'no boundary calls escaped mocks'
    $base = @(
        [pscustomobject]@{host='portal.example.test';dns='PASS';tls='PASS';http_status=302;expected_statuses=@(200,302)},
        [pscustomobject]@{host='api.example.test';dns='PASS';tls='PASS';http_status=200;expected_statuses=@(200)}
    )
    Assert-WslEgressBaseline $base
    $script:TestCount++
    foreach ($field in @('dns','tls','http_status')) {
        $bad = $base | ConvertTo-Json | ConvertFrom-Json
        if ($field -eq 'http_status') { $bad[1].$field = 503 } else { $bad[1].$field = 'FAIL' }
        $rejected = $false
        try { Assert-WslEgressBaseline $bad } catch { $rejected = $true }
        Assert-Equal $rejected $true "bad $field baseline prevents changes"
    }
    $response = New-WslEgressResponse -Action Status -Outcome not_run
    $json = $response | ConvertTo-Json -Compress
    Assert-Equal ($json.Contains('endpoint_ipv4')) $false 'public status excludes endpoint'
    Assert-Equal ($json.Contains('private_key')) $false 'public status excludes credentials'
    Assert-Equal $response.schema_version 1 'response schema version'
    $linuxFixture = [pscustomobject]@{
        schema = 1; schema_version = 1; generation = 7; action = 'audit-config'
        outcome = 'succeeded'; protection = 'Unverified'; phase = 'Running'
        backend = 'wireguard'; message = 'fixture'
        checks = @([pscustomobject]@{ name = 'owned-config'; outcome = 'Passed' })
        facts = [pscustomobject]@{ owned_config_matches = $true; interop_runtime_disabled = $true; shared_netns = 'net:[1]' }
    }
    $converted = ConvertFrom-WslEgressLinuxEvent $linuxFixture 'audit-config' 7 'WireGuard' '00000000-0000-0000-0000-000000000001'
    Assert-Equal $converted.schema_version 1 'Linux event translates to the desktop schema'
    Assert-Equal $converted.operation_id '00000000-0000-0000-0000-000000000001' 'Linux event receives operation identity'
    Assert-Equal $converted.action 'audit-config' 'Linux event preserves action'
    Assert-Equal $converted.checks[0].id 'owned-config' 'Linux check names translate'
    Assert-Equal $converted.checks[0].result 'PASSED' 'Linux check outcomes translate'
    Assert-Equal $converted.facts.shared_netns 'net:[1]' 'Linux audit facts remain available to Windows'
    $profileState = [ordered]@{ endpoint_ipv4 = '203.0.113.8'; endpoint_port = 51820; manager_distro = 'COR-Egress'; backend = 'WireGuard' }
    $profile = [pscustomobject]@{ endpoint_ipv4 = '203.0.113.8'; endpoint_port = 51820; manager_distro = 'COR-Egress'; backend = 'WireGuard' }
    Assert-WslEgressProfileForState $profile $profileState
    $script:TestCount++
    $profile.endpoint_ipv4 = '203.0.113.9'
    $rejected = $false
    try { Assert-WslEgressProfileForState $profile $profileState } catch { $rejected = $true }
    Assert-Equal $rejected $true 'start refuses a profile that differs from the installed endpoint'
    Assert-Equal (New-WslEgressUnixPath 'C:\Private\egress.json') '/mnt/c/Private/egress.json' 'profile path maps to WSL mount path'
    $streamRejected = $false
    try { $null = New-WslEgressUnixPath 'C:\Private\egress.json:ads' } catch { $streamRejected = $true }
    Assert-Equal $streamRejected $true 'an alternate-stream profile path is refused'
    $networkRejected = $false
    try { $null = New-WslEgressUnixPath '\\server\share\egress.json' } catch { $networkRejected = $true }
    Assert-Equal $networkRejected $true 'a network profile path is refused'
    $old = "[wsl2]`n# keep memory preference`nmemory=8GB`n[experimental]`nnetworkingMode=mirrored # legacy`nautoProxy=true`ndnsTunneling=true`nignoredPorts=3000`n"
    $updated = ConvertTo-WslEgressConfig $old
    Assert-Equal ($updated.Contains('memory=8GB')) $true 'merge preserves unrelated values'
    Assert-Equal ($updated.Contains('# keep memory preference')) $true 'merge preserves comments'
    Assert-Equal ($updated.Contains('ignoredPorts=3000')) $true 'merge preserves unrelated experimental option'
    Assert-Equal ([regex]::Matches($updated,'(?im)^networkingMode=').Count) 1 'merge removes legacy duplicate'
    Assert-Equal ([regex]::Matches($updated,'(?im)^autoProxy=').Count) 1 'merge has one proxy setting'
    Assert-Equal ($updated.Contains('networkingMode=nat')) $true 'NAT declared'
    Assert-Equal ($updated.Contains('dnsTunneling=false')) $true 'no host DNS tunnel fallback'
    Assert-Equal ((Get-WslEgressConfigValue $updated 'wsl2' 'networkingMode')) 'nat' 'NAT is in wsl2'
    Assert-Equal ((Get-WslEgressConfigValue $updated 'wsl2' 'localhostForwarding')) 'false' 'localhost forwarding is in wsl2'
    Assert-Equal ((Get-WslEgressConfigValue $updated 'experimental' 'dnsTunneling')) 'false' 'DNS tunneling is experimental'
    Assert-Equal ((Get-WslEgressConfigValue $updated 'experimental' 'autoProxy')) 'false' 'auto proxy is experimental'
    Assert-Equal ((Get-WslEgressConfigValue $updated 'experimental' 'firewall')) 'true' 'firewall is experimental'
    Assert-Equal ((Get-WslEgressConfigValue $updated 'wsl2' 'dnsTunneling')) $null 'DNS tunneling is not in wsl2'
    Assert-Equal (ConvertTo-WslEgressConfig $updated) (ConvertTo-WslEgressConfig (ConvertTo-WslEgressConfig $updated)) 'merge idempotent'
    function script:Get-WslEgressSettings {
        [ordered]@{Enabled='True';DefaultInboundAction='Block';DefaultOutboundAction='Block';AllowHostPolicyMerge='False';LoopbackEnabled='False'}
    }
    $script:RuleFixture = [pscustomobject]@{
        Name='ClashOfRust-WslEgress-Endpoint';Enabled='True';Direction='Outbound';Action='Allow'
        VMCreatorId='{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
        RemoteAddresses='203.0.113.8';RemotePorts='51820';Protocol='UDP'
    }
    function script:Get-NetFirewallHyperVRule { $script:RuleFixture }
    $auditState = [ordered]@{endpoint_ipv4='203.0.113.8';endpoint_port=51820;endpoint_enabled=$true}
    Assert-Equal (Get-WslEgressGuardAudit $auditState).valid $true 'Hyper-V scalar address and port audit matches the complete tuple'
    $script:RuleFixture.RemoteAddresses = @('203.0.113.8')
    $script:RuleFixture.RemotePorts = @('51820')
    Assert-Equal (Get-WslEgressGuardAudit $auditState).valid $true 'Hyper-V array address and port audit also matches'
    $script:RuleFixture.RemotePorts = '51821'
    Assert-Equal (Get-WslEgressGuardAudit $auditState).valid $false 'different scalar endpoint port is rejected'
    Assert-Equal (Get-WslEgressClosureAudit $null).confirmed $false 'absent state cannot establish endpoint closure'
    Assert-Equal (Get-WslEgressClosureAudit $auditState).confirmed $false 'enabled endpoint is not reported closed'
    $script:RuleFixture.Enabled = 'False'
    $auditState.endpoint_enabled = $false
    Assert-Equal (Get-WslEgressClosureAudit $auditState).confirmed $true 'disabled endpoint and effective deny establish static closure'
    function script:Get-WslEgressSettings { throw 'Fixture effective-policy read failure.' }
    Assert-Equal (Get-WslEgressClosureAudit $auditState).confirmed $false 'failed policy readback cannot claim closure'
    $upgradePath = Join-Path $PSScriptRoot '../Update-LiveWslPayload.ps1'
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($upgradePath, [ref]$tokens, [ref]$errors)
    Assert-Equal @($errors).Count 0 'live payload upgrade script parses'
    $upgradeText = Get-Content -LiteralPath $upgradePath -Raw
    Assert-Equal ($upgradeText.Contains('repair-config')) $true 'live upgrade reruns the manager repair path'
    Assert-Equal ($upgradeText.Contains('-ReviewedUpgrade')) $true 'live upgrade uses the atomic reviewed upgrade gate'
    Assert-Equal ($upgradeText.Contains('Set-WslEgressEndpoint $state $true')) $false 'live upgrade never opens the endpoint'
    Assert-Equal ($upgradeText.Contains('$Progress.stage')) $true 'live upgrade records the exact failure stage through caller-owned state'
    Assert-Equal ($upgradeText.Contains('$StatusFile')) $true 'live upgrade durably records the exact failure stage across module scope'
    $stageFixture = Join-Path ([IO.Path]::GetTempPath()) ('cor-egress-stage-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $script = {
            param($StatusPath)
            $stageModule = New-Module -ScriptBlock {
                function Set-Stage([string]$Path) {
                    [ordered]@{ stage = 'manager_repair' } | ConvertTo-Json -Compress |
                        Set-Content -LiteralPath $Path -Encoding ASCII
                }
                Export-ModuleMember -Function Set-Stage
            } | Import-Module -PassThru
            & $stageModule { param($Path) Set-Stage $Path } $StatusPath
        }
        & $script $stageFixture
        $stageRecord = Get-Content -LiteralPath $stageFixture -Raw | ConvertFrom-Json
        Assert-Equal $stageRecord.stage 'manager_repair' 'module failure stage survives caller scope'
    } finally {
        Remove-Item -LiteralPath $stageFixture -Force -ErrorAction SilentlyContinue
    }
    # Use the real local SID/account mapping without touching Task Scheduler.
    # On the regression host this is XUAN\xuan; resolving bare "xuan" fails,
    # which exercises the short-name readback fallback used by Task Scheduler.
    $renewalOwner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $renewalAccount = $renewalOwner.Translate([Security.Principal.NTAccount]).Value
    $renewalShortName = ($renewalAccount -split '\\')[-1]
    $renewalDefinition = [pscustomobject]@{
        name = 'ClashOfRust-WslEgress-Renew'; path = '\'
        executable = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        arguments = '-NoLogo -NoProfile -NonInteractive -File "C:\Program Files\Clash of Rust WSL\Renew-ScopeAttestation.ps1"'
        owner_sid = $renewalOwner.Value; owner_account = $renewalAccount
    }
    $renewalTask = [pscustomobject]@{
        TaskName = $renewalDefinition.name; TaskPath = $renewalDefinition.path
        Principal = [pscustomobject]@{ UserId = $renewalShortName; LogonType = 'Interactive'; RunLevel = 'Highest' }
        Actions = @([pscustomobject]@{
            Execute = $renewalDefinition.executable; Arguments = $renewalDefinition.arguments
            WorkingDirectory = ''
        })
    }
    $renewalXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><URI>\ClashOfRust-WslEgress-Renew</URI></RegistrationInfo>
  <Principals><Principal id="Author">
    <UserId>$($renewalOwner.Value)</UserId>
    <LogonType>InteractiveToken</LogonType>
    <RunLevel>HighestAvailable</RunLevel>
  </Principal></Principals>
  <Actions Context="Author"><Exec>
    <Command>$($renewalDefinition.executable)</Command>
    <Arguments>$($renewalDefinition.arguments)</Arguments>
  </Exec></Actions>
</Task>
"@
    function script:Invoke-WslEgressRenewalTaskQuery { $renewalXml }
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $renewalTask $renewalDefinition) $true 'real local short owner name is accepted for renewal task readback'
    foreach ($identity in @($renewalOwner.Value, $renewalAccount)) {
        $renewalTask.Principal.UserId = $identity
        Assert-Equal (Test-WslEgressRenewalTaskIdentity $renewalTask $renewalDefinition) $true 'the same renewal owner is accepted by SID and qualified account'
    }
    $renewalTask.Principal.UserId = 'S-1-5-18'
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $renewalTask $renewalDefinition) $false 'a different valid principal SID is refused'
    $renewalTask.Principal.UserId = $renewalShortName + '-not-the-owner'
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $renewalTask $renewalDefinition) $false 'a different unqualified principal is refused'
    $renewalTask.Principal.UserId = $renewalShortName
    $renewalTask.Principal.RunLevel = 'Limited'
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $renewalTask $renewalDefinition) $false 'a renewal task without Highest run level is refused'
    $renewalTask.Principal.RunLevel = 'Highest'
    $renewalTask.Principal.LogonType = 'Password'
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $renewalTask $renewalDefinition) $false 'a noninteractive renewal principal is refused'
    $renewalTask.Principal.LogonType = 'Interactive'
    $renewalTask.Actions[0].Arguments = $renewalDefinition.arguments.Replace('Renew-ScopeAttestation.ps1', 'another-script.ps1')
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $renewalTask $renewalDefinition) $false 'a different renewal script path is refused'
    $renewalTask.Actions[0].Arguments = $renewalDefinition.arguments
    $renewalTask.Actions[0].Execute = 'C:\untrusted\powershell.exe'
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $renewalTask $renewalDefinition) $false 'a different renewal interpreter path is refused'
    $renewalTask.Actions[0].Execute = $renewalDefinition.executable
    $renewalTask.Actions[0].WorkingDirectory = 'C:\untrusted'
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $renewalTask $renewalDefinition) $false 'an unexpected renewal working directory is refused'
    $renewalTask.Actions[0].WorkingDirectory = ''
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $renewalTask $renewalDefinition) $true 'restored renewal fixture retains the intended identity'
    $renewalTask.Principal.UserId = $renewalShortName
    $renewalTask.Actions[0].Arguments = $renewalDefinition.arguments
    function script:Invoke-WslEgressRenewalTaskQuery { $renewalXml.Replace($renewalOwner.Value, 'S-1-5-18') }
    Assert-Equal (Test-WslEgressRenewalTaskIdentity $renewalTask $renewalDefinition) $false 'short principal is refused when fixed task XML proves another SID'
    $uninstallCheckPath = Join-Path $PSScriptRoot '../Uninstall-Check.ps1'
    $uninstallTokens = $null
    $uninstallErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($uninstallCheckPath, [ref]$uninstallTokens, [ref]$uninstallErrors)
    Assert-Equal @($uninstallErrors).Count 0 'installer uninstall gate parses'
    # Uninstall must recognise the documented helper-package service location;
    # comparing against this script's own copy blocked every real uninstall.
    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    $helperGuardian = Join-Path $programFiles 'Clash of Rust WSL\clash-wsl-guardian.exe'
    $appGuardian = Join-Path $programFiles 'Clash of Rust\clash-wsl-guardian.exe'
    Assert-Equal (Test-WslEgressGuardianServicePath ('"' + $helperGuardian + '" --service')) $true 'helper-package guardian service location is accepted'
    Assert-Equal (Test-WslEgressGuardianServicePath ('"' + $appGuardian + '" --service')) $true 'application-package guardian service location is accepted'
    Assert-Equal (Test-WslEgressGuardianServicePath ('"' + (Join-Path $PSScriptRoot '../../clash-wsl-guardian.exe') + '" --service')) $false 'guardian service outside Program Files is refused'
    Assert-Equal (Test-WslEgressGuardianServicePath ($helperGuardian + ' --service')) $false 'unquoted service command line is refused'
    Assert-Equal (Test-WslEgressGuardianServicePath ('"' + $helperGuardian + '"')) $false 'service command line without the service switch is refused'
    Assert-Equal (Test-WslEgressGuardianServicePath ('"' + (Join-Path $programFiles 'Clash of Rust WSL\clash-wsl-guardian-other.exe') + '" --service')) $false 'a different binary in the helper directory is refused'
    # Install must adopt a guardian service that another canonical package
    # already registered; both layouts share the fixed service name.
    $script:MockPackageBinary = $appGuardian
    $script:MockService = $null
    $script:MockCreatedBinary = $null
    $script:MockStarted = 0
    function script:Get-WslEgressGuardianPackageBinary { $script:MockPackageBinary }
    function script:Get-CimInstance { if ($script:MockService) { $script:MockService } }
    function script:New-Service {
        param($Name, $DisplayName, $BinaryPathName, $StartupType, $Description)
        $script:MockCreatedBinary = [string]$BinaryPathName
    }
    function script:Start-Service { param($Name) $script:MockStarted++ }
    Assert-Equal (Get-WslEgressGuardianServiceCommand $appGuardian) ('"' + $appGuardian + '" --service') 'the created service command line is the pinned form'
    Assert-Equal (Test-WslEgressGuardianServicePath (Get-WslEgressGuardianServiceCommand $appGuardian)) $true 'the created command line is an accepted canonical location'
    Assert-Equal (Test-WslEgressGuardianServiceIdentity ([pscustomobject]@{ PathName = ('"' + $helperGuardian + '" --service'); StartName = 'LocalSystem' })) $true 'a helper-package system service is owned'
    Assert-Equal (Test-WslEgressGuardianServiceIdentity ([pscustomobject]@{ PathName = ('"' + $appGuardian + '" --service'); StartName = 'NT AUTHORITY\SYSTEM' })) $true 'an application-package system service is owned'
    Assert-Equal (Test-WslEgressGuardianServiceIdentity ([pscustomobject]@{ PathName = ('"' + (Join-Path $PSScriptRoot '../../clash-wsl-guardian.exe') + '" --service'); StartName = 'LocalSystem' })) $false 'a service outside Program Files is not owned'
    Assert-Equal (Test-WslEgressGuardianServiceIdentity ([pscustomobject]@{ PathName = ('"' + $helperGuardian + '" --service'); StartName = 'NT AUTHORITY\LocalService' })) $false 'a non-system account is not owned'
    Assert-Equal (Test-WslEgressGuardianServiceIdentity $null) $false 'an absent service is not owned'
    $script:MockService = [pscustomobject]@{ PathName = ('"' + $helperGuardian + '" --service'); StartName = 'LocalSystem'; StartMode = 'Auto' }
    $guardianState = [ordered]@{}
    Install-WslEgressGuardian $guardianState
    $script:TestCount++
    Assert-Equal $script:MockCreatedBinary $null 'an existing canonical service is adopted instead of recreated'
    Assert-Equal $script:MockStarted 1 'the adopted service is started'
    $script:MockService = [pscustomobject]@{ PathName = ('"' + (Join-Path $PSScriptRoot '../../clash-wsl-guardian.exe') + '" --service'); StartName = 'LocalSystem'; StartMode = 'Auto' }
    $script:MockStarted = 0
    $foreignRejected = $false
    try { Install-WslEgressGuardian ([ordered]@{}) } catch { $foreignRejected = $true }
    Assert-Equal $foreignRejected $true 'a foreign service image keeps installation closed'
    Assert-Equal $script:MockStarted 0 'a refused service is never started'
    # Exercise the real archive writer and filesystem operations in a private
    # temporary state root; the protected ProgramData state is never selected.
    Set-Item -LiteralPath Function:script:Save-WslEgressJson -Value $saveJsonImplementation
    $originalStateRoot = $script:StateRoot
    $temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('cor-egress-archive-test-' + [guid]::NewGuid().ToString('N'))))
    New-Item -ItemType Directory -Path $temporaryRoot -ErrorAction Stop | Out-Null
    try {
        foreach ($scenario in @('valid', 'retained-live-state', 'tampered-snapshot', 'missing-snapshot')) {
            $script:StateRoot = Join-Path $temporaryRoot $scenario
            New-Item -ItemType Directory -Path $script:StateRoot -ErrorAction Stop | Out-Null
            $snapshot = Join-Path $script:StateRoot 'wslconfig.before'
            [IO.File]::WriteAllText($snapshot, "[wsl2]`nnetworkingMode=mirrored`n")
            $archiveState = [ordered]@{
                schema_version = 1; owner = 'ClashOfRust.WslEgress'
                phase = 'restored'; generation = 67; endpoint_enabled = $false
                wslconfig = [ordered]@{ existed = $true; before_hash = (Get-WslEgressFileHash $snapshot) }
                before_persistent_settings = [ordered]@{ DefaultOutboundAction = 'Allow' }
            }
            Save-WslEgressJson $archiveState (Join-Path $script:StateRoot 'state.json')
            foreach ($name in @('scope-renewal.json', 'guardian-audit.json', 'unrelated-recovery.json')) {
                [IO.File]::WriteAllText((Join-Path $script:StateRoot $name), ('{"fixture":"' + $name + '"}'))
            }
            $liveStateHash = Get-WslEgressFileHash (Join-Path $script:StateRoot 'state.json')
            $unrelatedHash = Get-WslEgressFileHash (Join-Path $script:StateRoot 'unrelated-recovery.json')
            if ($scenario -eq 'tampered-snapshot') { [IO.File]::AppendAllText($snapshot, "# later edit`n") }
            if ($scenario -eq 'missing-snapshot') { Remove-Item -LiteralPath $snapshot -ErrorAction Stop }
            $archiveRejected = $false
            try { $archive = Save-WslEgressRestoredGeneration $archiveState -RetainLiveState:($scenario -eq 'retained-live-state') }
            catch {
                if ($_.Exception.Message -notlike '*snapshot failed verification*') { throw }
                $archiveRejected = $true
            }
            Assert-Equal $archiveRejected ($scenario -in @('tampered-snapshot', 'missing-snapshot')) "$scenario archive accepts only the recorded snapshot"
            Assert-Equal (Get-WslEgressFileHash (Join-Path $script:StateRoot 'unrelated-recovery.json')) $unrelatedHash "$scenario archive preserves unrelated recovery data"
            if ($archiveRejected) {
                Assert-Equal (Get-WslEgressFileHash (Join-Path $script:StateRoot 'state.json')) $liveStateHash "$scenario archive preserves the live journal after failed verification"
                Assert-Equal (Test-Path -LiteralPath (Join-Path $script:StateRoot 'scope-renewal.json')) $true "$scenario archive does not retire live proof before verification"
                Assert-Equal (Test-Path -LiteralPath (Join-Path $script:StateRoot 'guardian-audit.json')) $true "$scenario archive does not retire live audit before verification"
                continue
            }
            Assert-Equal ([IO.Path]::GetDirectoryName($archive)) $script:StateRoot 'verified archive stays inside the test state root'
            $readback = [IO.File]::ReadAllText((Join-Path $archive 'state.json')) | ConvertFrom-Json
            Assert-Equal $readback.phase 'restored' 'real archived journal readback retains the restored phase'
            Assert-Equal $readback.generation 67 'real archived journal readback retains its generation'
            Assert-Equal $readback.before_persistent_settings.DefaultOutboundAction 'Allow' 'real archived journal retains its recovery settings'
            Assert-Equal (Get-WslEgressFileHash (Join-Path $archive 'wslconfig.before')) $archiveState.wslconfig.before_hash 'real archived snapshot matches its recorded SHA256'
            foreach ($name in @('state.json', 'wslconfig.before', 'scope-renewal.json', 'guardian-audit.json')) {
                Assert-Equal (Test-Path -LiteralPath (Join-Path $archive $name) -PathType Leaf) $true "verified archive retains $name"
                Assert-Equal (Test-Path -LiteralPath (Join-Path $script:StateRoot $name)) ($scenario -eq 'retained-live-state') "verified archive retires live $name only when requested after readback"
            }
            if ($scenario -eq 'retained-live-state') {
                Assert-Equal (Get-WslEgressFileHash (Join-Path $script:StateRoot 'state.json')) $liveStateHash 'reinstall archive leaves the exact restored journal available until generation cutover'
                $nextState = [ordered]@{ phase = 'preparing'; generation = 68; endpoint_enabled = $false }
                Save-WslEgressJson $nextState (Join-Path $script:StateRoot 'state.json')
                $nextStateHash = Get-WslEgressFileHash (Join-Path $script:StateRoot 'state.json')
                Complete-WslEgressGenerationCutover
                Assert-Equal (Get-WslEgressFileHash (Join-Path $script:StateRoot 'state.json')) $nextStateHash 'real generation cutover preserves the newly saved journal'
                foreach ($name in @('wslconfig.before', 'scope-renewal.json', 'guardian-audit.json')) {
                    Assert-Equal (Test-Path -LiteralPath (Join-Path $script:StateRoot $name)) $false "real generation cutover retires old $name"
                    Assert-Equal (Test-Path -LiteralPath (Join-Path $archive $name) -PathType Leaf) $true "real generation cutover preserves archived $name"
                }
                Assert-Equal (Get-WslEgressFileHash (Join-Path $script:StateRoot 'unrelated-recovery.json')) $unrelatedHash 'real generation cutover preserves unrelated recovery data'
            }
        }
    } finally {
        $script:StateRoot = $originalStateRoot
        $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
        $expectedTemporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($resolvedTemporaryRoot) -ne $expectedTemporaryParent -or
            [IO.Path]::GetFileName($resolvedTemporaryRoot) -notmatch '^cor-egress-archive-test-[0-9a-f]{32}$') {
            throw 'Refusing cleanup outside the exact archive test directory.'
        }
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force -ErrorAction Stop
    }
    [pscustomobject]@{ suite = 'windows-offline'; result = 'PASS'; assertions = $script:TestCount
        network_tests = 'NOT_RUN'; wsl_started = $false; firewall_modified = $false } | ConvertTo-Json -Compress
}
