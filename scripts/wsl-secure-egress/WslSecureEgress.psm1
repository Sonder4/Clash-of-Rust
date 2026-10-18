# Windows host operations are deliberately separate from the existing Mihomo
# service. Persistent Hyper-V policy is the guard; no GUI/watchdog opens it.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Creator = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$script:Prefix = 'ClashOfRust-WslEgress-'
$script:StateRoot = Join-Path $env:ProgramData 'ClashOfRust\WslEgress'
$script:LinuxHelper = '/usr/local/lib/cor-egress/manager'

function New-WslEgressResponse {
    param([string]$Action, [string]$Backend = 'WireGuard',
        [string]$Outcome = 'not_run', [string]$Phase = 'uninstalled',
        [string]$Protection = 'unknown', [string]$Message = '', [long]$Generation = 0)
    [ordered]@{
        schema_version = 1; operation_id = [guid]::NewGuid().ToString('N')
        generation = $Generation; action = $Action; outcome = $Outcome
        protection = $Protection; phase = $Phase; backend = $Backend
        message = $Message; distributions = @(); checks = @(); logs = @()
    }
}

function ConvertFrom-WslEgressLinuxEvent {
    param([object]$Value, [string]$Action, [long]$Generation,
        [string]$Backend, [string]$OperationId)
    $checks = @()
    foreach ($check in @($Value.checks)) {
        $name = [string]$check.name
        $result = [string]$check.outcome
        if ($name) {
            $checks += [ordered]@{
                id = $name
                result = $result.ToUpperInvariant()
                detail = 'Linux helper local invariant result.'
            }
        }
    }
    $converted = [ordered]@{
        schema_version = 1
        operation_id = $OperationId
        generation = $Generation
        action = $Action
        outcome = $(if ([string]$Value.outcome -in @('Succeeded','succeeded')) { 'succeeded' } else { 'blocked' })
        protection = $(if ([string]$Value.protection -eq 'Blocked') { 'blocked' } else { 'unknown' })
        phase = [string]$Value.phase
        backend = $Backend
        message = [string]$Value.message
        distributions = @()
        checks = @($checks)
        logs = @()
    }
    if ($null -ne $Value.PSObject.Properties['facts']) {
        $converted['facts'] = $Value.facts
    }
    $converted
}

function New-WslEgressUnixPath([string]$Path) {
    if (-not $Path -or $Path.Length -gt 65536 -or $Path.IndexOf([char]0) -ge 0 -or
        $Path -notmatch '^[A-Za-z]:\\') { throw 'An absolute local Windows profile path is required.' }
    $full = [IO.Path]::GetFullPath($Path)
    # The drive colon sits at index 1 after the absolute-path check above. Any
    # further colon is an alternate data stream, which WSL cannot address.
    if ($full -match '^\\\\' -or $full.Substring(2).IndexOf(':') -ge 0) {
        throw 'Network and alternate-stream profile paths are unsupported.'
    }
    $relative = $full.Substring(3).Replace('\', '/')
    if ($relative -notmatch '^[^/]+(?:/[^/]+)*$') { throw 'Profile path cannot be represented safely in WSL.' }
    '/mnt/' + $full.Substring(0, 1).ToLowerInvariant() + '/' + $relative
}

function Assert-WslEgressProfileForState([object]$Profile, [object]$State) {
    if ([string]$Profile.endpoint_ipv4 -ne [string]$State.endpoint_ipv4 -or
        [int]$Profile.endpoint_port -ne [int]$State.endpoint_port -or
        [string]$Profile.manager_distro -ne [string]$State.manager_distro -or
        [string]$Profile.backend -ne [string]$State.backend) {
        throw 'Private profile does not match the installed endpoint and manager distribution.'
    }
}

function Assert-WslEgressRequestedConfiguration {
    param([object]$Configuration, [string]$Backend, [string]$Distro,
        [string]$EndpointIPv4, [int]$EndpointPort, [bool]$PortSpecified)
    if ($Backend -and $Backend -ne [string]$Configuration.backend) {
        throw 'The requested backend does not match the protected installed configuration.'
    }
    if ($Distro -and $Distro -ne [string]$Configuration.manager_distro) {
        throw 'The requested manager distribution does not match the private configuration.'
    }
    if ($EndpointIPv4 -and $EndpointIPv4 -ne [string]$Configuration.endpoint_ipv4) {
        throw 'The requested endpoint does not match the private configuration.'
    }
    if ($PortSpecified -and $EndpointPort -ne [int]$Configuration.endpoint_port) {
        throw 'The requested endpoint port does not match the private configuration.'
    }
}

function Get-WslEgressInstalledIdentity([object]$State, [object]$SuppliedProfile = $null) {
    # Recover only the lifetime identity from the root-owned Linux profile.
    # Neither private keys nor endpoint values are returned by this process.
    $readIdentity = @'
import json,os,pathlib,stat,sys
p=pathlib.Path('/etc/cor-egress/profile.json')
for ancestor in (pathlib.Path('/etc'),p.parent,p):
    st=ancestor.lstat()
    if stat.S_ISLNK(st.st_mode) or st.st_uid!=0 or st.st_mode&0o022:
        raise RuntimeError('unsafe installed profile')
st=p.stat()
if not stat.S_ISREG(st.st_mode) or st.st_size>65536 or st.st_mode&0o077 or st.st_nlink!=1:
    raise RuntimeError('unsafe installed profile')
profile=json.loads(p.read_bytes());request=json.load(sys.stdin)
profile['backend']=str(profile.get('backend','')).lower()
request['expected']['backend']=str(request['expected'].get('backend','')).lower()
if request.get('profile') is not None:
    request['profile']['backend']=str(request['profile'].get('backend','')).lower()
for field in ('backend','endpoint_ipv4','endpoint_port','manager_distro'):
    if profile.get(field)!=request['expected'].get(field):
        raise RuntimeError('installed profile differs from protected state')
if request.get('profile') is not None and profile!=request['profile']:
    raise RuntimeError('supplied profile differs from the installed profile')
uid=profile.get('uid');gid=profile.get('gid')
if type(uid) is not int or type(gid) is not int or uid<1000 or gid<1000:
    raise RuntimeError('invalid installed identity')
print(json.dumps({'uid':uid,'gid':gid,'profile_matches':True}))
'@
    $expected = [ordered]@{}
    foreach ($name in @('backend','endpoint_ipv4','endpoint_port','manager_distro')) {
        $expected[$name] = $State[$name]
    }
    $request = [ordered]@{ expected = $expected; profile = $SuppliedProfile }
    $response = Invoke-WslEgressProcess -Arguments @('--distribution',[string]$State.manager_distro,
        '--user','root','--exec','/usr/bin/python3','-I','-S','-c',$readIdentity) `
        -InputText ($request | ConvertTo-Json -Depth 12 -Compress)
    if ($response.ExitCode -ne 0) { throw 'The root-owned installed profile does not match the requested configuration.' }
    $identity = $response.Output | ConvertFrom-Json
    if (-not $identity.profile_matches -or [int]$identity.uid -lt 1000 -or [int]$identity.gid -lt 1000) {
        throw 'The installed lifetime identity could not be verified.'
    }
    [pscustomobject]@{ uid = [int]$identity.uid; gid = [int]$identity.gid }
}

function Test-WslEgressAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-WslEgressUser {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($sid -in @('S-1-5-18','S-1-5-19','S-1-5-20')) {
        throw 'The per-user WSL broker cannot run under a service identity.'
    }
    $sid
}

function Get-WslEgressFileHash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Protect-WslEgressDirectory([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $owner = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl.SetOwner($owner)
    $reader = New-Object Security.AccessControl.FileSystemAccessRule(
        ([Security.Principal.WindowsIdentity]::GetCurrent().User), 'ReadAndExecute',
        'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($reader)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function ConvertTo-WslEgressConfig([string]$Text) {
    $ownedBySection = @{
        wsl2 = @('networkingmode', 'localhostforwarding')
        experimental = @('dnstunneling', 'autoproxy', 'firewall')
    }
    $settingsBySection = [ordered]@{
        wsl2 = @('networkingMode=nat', 'localhostForwarding=false')
        experimental = @('dnsTunneling=false', 'autoProxy=false', 'firewall=true')
    }
    $owned = @($ownedBySection.Values | ForEach-Object { $_ }) | Select-Object -Unique
    $lines = New-Object 'Collections.Generic.List[string]'
    $section = ''
    $written = @{ wsl2 = $false; experimental = $false }
    function Add-WslEgressSectionSettings([string]$Name) {
        if ($Name -in $settingsBySection.Keys -and -not $written[$Name]) {
            foreach ($setting in $settingsBySection[$Name]) { $lines.Add($setting) }
            $written[$Name] = $true
        }
    }
    foreach ($line in ($Text.TrimEnd([char[]]"`r`n") -split '\r?\n')) {
        if ($line -match '^\s*\[([^]]+)\]') {
            Add-WslEgressSectionSettings $section
            $section = $Matches[1].ToLowerInvariant()
        }
        if ($section -in @('wsl2', 'experimental') -and $line -match '^\s*([^#;=]+?)\s*=') {
            if ($owned -contains $Matches[1].Trim().ToLowerInvariant()) { continue }
        }
        $lines.Add($line)
    }
    Add-WslEgressSectionSettings $section
    foreach ($targetSection in $settingsBySection.Keys) {
        if (-not $written[$targetSection]) {
            $lines.Add("[$targetSection]")
            foreach ($setting in $settingsBySection[$targetSection]) { $lines.Add($setting) }
        }
    }
    ($lines -join "`r`n") + "`r`n"
}

function Install-WslEgressConfig([object]$State) {
    $path = Join-Path $env:USERPROFILE '.wslconfig'
    $State.wslconfig = [ordered]@{ existed = (Test-Path -LiteralPath $path); before_hash = $null; after_hash = $null }
    $text = ''
    if ($State.wslconfig.existed) {
        if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'WSL config reparse points require manual review.' }
        $State.wslconfig.before_hash = Get-WslEgressFileHash $path
        [IO.File]::WriteAllBytes((Join-Path $script:StateRoot 'wslconfig.before'), [IO.File]::ReadAllBytes($path))
        $text = [IO.File]::ReadAllText($path)
    }
    $replacement = ConvertTo-WslEgressConfig $text
    $replacementBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($replacement)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $State.wslconfig.after_hash = ([BitConverter]::ToString($sha.ComputeHash($replacementBytes))).Replace('-', '') }
    finally { $sha.Dispose() }
    $State.wslconfig_write_started = $true
    Save-WslEgressJson $State (Join-Path $script:StateRoot 'state.json')
    [IO.File]::WriteAllBytes($path, $replacementBytes)
    if ((Get-WslEgressFileHash $path) -ne $State.wslconfig.after_hash) { throw 'WSL config write readback failed.' }
    Save-WslEgressJson $State (Join-Path $script:StateRoot 'state.json')
    Assert-WslEgressBaseline @(Get-WslEgressBaseline)
}

function Restore-WslEgressConfig([object]$State) {
    $wslconfig = Get-WslEgressStateValue $State 'wslconfig'
    $afterHash = Get-WslEgressStateValue $wslconfig 'after_hash'
    if (-not $wslconfig -or -not $afterHash) { return }
    $path = Join-Path $env:USERPROFILE '.wslconfig'
    $currentHash = Get-WslEgressFileHash $path
    $beforeHash = Get-WslEgressStateValue $wslconfig 'before_hash'
    if ($currentHash -eq $beforeHash) { return }
    if ($currentHash -ne $afterHash) { throw 'WSL config changed after installation; targeted restore refused.' }
    if ([bool](Get-WslEgressStateValue $wslconfig 'existed' $false)) {
        $snapshot = Join-Path $script:StateRoot 'wslconfig.before'
        if ((Get-WslEgressFileHash $snapshot) -ne $beforeHash) { throw 'WSL config snapshot hash mismatch.' }
        [IO.File]::WriteAllBytes($path, [IO.File]::ReadAllBytes($snapshot))
    } else { Remove-Item -LiteralPath $path -ErrorAction Stop }
    Assert-WslEgressBaseline @(Get-WslEgressBaseline)
}

function Install-WslEgressPayload {
    param([object]$State, [string]$Distro, [switch]$ReviewedUpgrade)
    $runtimeNames = @('manager', 'manager.py', 'secure-egress', 'cor-egress-manager')
    $source = Join-Path $PSScriptRoot 'linux'
    $installer = Join-Path $source 'install-payload.py'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'Linux payload installer is missing.' }
    $files = @()
    foreach ($name in @($runtimeNames + 'install-payload.py')) {
        $path = Join-Path $source $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Linux payload file is missing: $name" }
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -gt 1048576 -or [Array]::IndexOf($bytes, [byte]13) -ge 0) {
            throw "Linux payload is oversized or not LF-normalized: $name"
        }
        $files += [ordered]@{
            name = $name
            content = [Convert]::ToBase64String($bytes)
            sha256 = (Get-WslEgressFileHash $path).ToLowerInvariant()
        }
    }
    if (@($files).Count -ne 5) { throw 'Linux payload must contain exactly five reviewed files.' }
    $stage = '/root/.cor-egress-stage-' + [guid]::NewGuid().ToString('N')
    # This fixed bootstrap only stages the reviewed payload. It never executes
    # payload code, changes networking, or accepts a caller-selected path.
    $bootstrap = @'
import base64,hashlib,json,os,pathlib,re,stat,sys,tempfile
stage=pathlib.Path(sys.argv[1])
root=pathlib.Path('/root')
for path in (root,stage):
    if path.is_symlink(): raise RuntimeError('unsafe staging path')
st=root.stat()
if st.st_uid!=0 or st.st_mode&0o022: raise RuntimeError('unsafe root directory')
if not re.fullmatch(r'/root/\.cor-egress-stage-[0-9a-f]{32}',str(stage)): raise RuntimeError('invalid staging path')
if stage.exists() or stage.is_symlink(): raise RuntimeError('staging path collision')
data=json.load(sys.stdin)
allowed={'manager','manager.py','secure-egress','cor-egress-manager','install-payload.py'}
records=data.get('files') if data.get('schema')==1 else None
if not isinstance(records,list) or len(records)!=len(allowed) or {x.get('name') for x in records}!=allowed:
    raise RuntimeError('payload manifest differs from reviewed runtime files')
decoded={}
for record in records:
    name=record['name']
    if not re.fullmatch(r'[a-z][a-z0-9_.-]+',name): raise RuntimeError('unsafe payload name')
    blob=base64.b64decode(record['content'],validate=True)
    if len(blob)>1048576 or b'\r' in blob or hashlib.sha256(blob).hexdigest()!=record['sha256']:
        raise RuntimeError('payload hash/format mismatch')
    decoded[name]=blob
stage.mkdir(mode=0o700)
for name,blob in decoded.items():
    target=stage/name
    fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o755 if name!='manager.py' else 0o644)
    with os.fdopen(fd,'wb') as stream:
        stream.write(blob); stream.flush(); os.fsync(stream.fileno())
manifest={name:hashlib.sha256(decoded[name]).hexdigest() for name in decoded if name!='install-payload.py'}
fd=os.open(stage/'sha256.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,'w') as stream:
    json.dump(manifest,stream,sort_keys=True); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
os.chmod(stage/'install-payload.py',0o755)
print(json.dumps({'schema':1,'schema_version':1,'action':'stage-payload','outcome':'succeeded','stage':str(stage)}))
'@
    $staged = Invoke-WslEgressProcess -Arguments @('--distribution',$Distro,'--user','root','--exec','/usr/bin/python3','-I','-c',$bootstrap,$stage) `
        -InputText (ConvertTo-Json -InputObject ([ordered]@{ schema = 1; files = @($files) }) -Depth 6 -Compress) -TimeoutSeconds 60
    if ($staged.ExitCode -ne 0) { throw 'Linux payload staging failed; no transport permission opened.' }
    try {
        $stageResult = $staged.Output | ConvertFrom-Json
        if ($stageResult.outcome -ne 'succeeded' -or $stageResult.stage -ne $stage) { throw 'Linux staging response mismatch.' }
        $installArguments = @('--distribution',$Distro,'--user','root','--exec',
            '/usr/bin/python3','-I',($stage + '/install-payload.py'),'--payload',$stage,'--manifest',($stage + '/sha256.json'))
        if ($ReviewedUpgrade) { $installArguments += '--reviewed-upgrade' }
        $install = Invoke-WslEgressProcess -Arguments $installArguments `
            -TimeoutSeconds 60
        if ($install.ExitCode -ne 0) { throw 'Hash-pinned Linux payload installation failed.' }
        $installResult = $install.Output | ConvertFrom-Json
        if ($installResult.outcome -ne 'succeeded' -or $installResult.action -ne 'install-payload') {
            throw 'Linux payload installer returned an invalid result.'
        }
    } finally {
        # Exact, non-recursive cleanup. A failed cleanup leaves a private stage
        # for diagnosis and does not weaken the persistent host deny.
        $cleanup = @'
import os,pathlib,sys
stage=pathlib.Path(sys.argv[1])
names=['manager','manager.py','secure-egress','cor-egress-manager','install-payload.py','sha256.json']
for name in names:
    path=stage/name
    if path.is_symlink(): raise RuntimeError('unsafe staged file')
    if path.exists(): path.unlink()
for entry in stage.iterdir(): raise RuntimeError('unexpected staged entry')
stage.rmdir()
'@
        $removed = Invoke-WslEgressProcess -Arguments @('--distribution',$Distro,'--user','root','--exec','/usr/bin/python3','-I','-c',$cleanup,$stage) -TimeoutSeconds 30
        if ($removed.ExitCode -ne 0) { throw 'Reviewed Linux staging directory could not be removed safely.' }
    }
    Assert-WslEgressBaseline @(Get-WslEgressBaseline)
}

function Save-WslEgressJson([object]$Value, [string]$Path) {
    $directory = [IO.Path]::GetDirectoryName($Path)
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30),
        (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-WslEgressState {
    $path = Join-Path $script:StateRoot 'state.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $state = ConvertTo-WslEgressOrderedState (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    if ($state.schema_version -ne 1 -or $state.owner -ne 'ClashOfRust.WslEgress') { throw 'Unknown state owner.' }
    # Older broker versions serialized an empty JSON array as {} on reread.
    # Recover only the known empty distro list; the scope audit still compares
    # it with the complete current set of ordinary distributions.
    if ($state.distro_configs -is [Collections.IDictionary] -and $state.distro_configs.Count -eq 0) {
        $state.distro_configs = @()
    }
    $state
}

function ConvertTo-WslEgressOrderedState([object]$Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) { $result[[string]$key] = ConvertTo-WslEgressOrderedState $Value[$key] }
        return $result
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = New-Object 'Collections.Generic.List[object]'
        foreach ($item in $Value) { $items.Add((ConvertTo-WslEgressOrderedState $item)) }
        return ,($items.ToArray())
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-WslEgressOrderedState $property.Value
        }
        return $result
    }
    $Value
}

function ConvertTo-WslEgressProcessArgument([string]$Argument) {
    if ($Argument.IndexOf([char]0) -ge 0) { throw 'Invalid argument.' }
    # WSL parses its own options before using Windows argv rules for --exec.
    # Quoting an option such as "--list" makes WSL treat it as a Linux command.
    if ($Argument -and $Argument -notmatch '[\s"]') { return $Argument }
    '"' + ([regex]::Replace(([regex]::Replace($Argument, '(\\*)"', '$1$1\"')), '(\\+)$', '$1$1')) + '"'
}

function Invoke-WslEgressProcess {
    param([string[]]$Arguments, [string]$InputText, [int]$TimeoutSeconds = 45,
        [switch]$UnicodeOutput)
    $executable = Join-Path $env:SystemRoot 'System32\wsl.exe'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $executable; $start.UseShellExecute = $false
    $start.CreateNoWindow = $true; $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true; $start.RedirectStandardInput = $true
    # Windows PowerShell lacks ArgumentList. Quote each argument using the
    # CommandLineToArgvW backslash rules; never use cmd /c or a shell command.
    $quoted = foreach ($argument in $Arguments) { ConvertTo-WslEgressProcessArgument $argument }
    $start.Arguments = $quoted -join ' '
    if ($UnicodeOutput) { $start.StandardOutputEncoding = [Text.Encoding]::Unicode }
    else { $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false) }
    $start.StandardErrorEncoding = $start.StandardOutputEncoding
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'WSL process did not start.' }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        # .NET Framework (Windows PowerShell 5.1) has no
        # ProcessStartInfo.StandardInputEncoding. Write UTF-8 directly and close
        # the underlying pipe without the framework writer adding a preamble.
        if ($InputText) {
            $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        }
        $process.StandardInput.BaseStream.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Killing this Windows broker does NOT certify Linux task exit.
            $process.Kill()
            throw 'WSL operation timed out; protection must remain installed.'
        }
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.GetAwaiter().GetResult() }
        $null = $errors.GetAwaiter().GetResult() # Never log stderr containing secrets.
    } finally { $process.Dispose() }
}

function Get-WslEgressDistributions {
    $registered = @()
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (Test-Path -LiteralPath $key) {
        $registered = @(Get-ChildItem -LiteralPath $key | ForEach-Object {
            $item = Get-ItemProperty -LiteralPath $_.PSPath
            [pscustomobject]@{ name = [string]$item.DistributionName; state = 'unknown'; coverage = 'not_enrolled' }
        })
    }
    $registered
}

function Get-WslEgressRunningDistributions {
    $running = Invoke-WslEgressProcess -Arguments @('--list','--running','--quiet') -UnicodeOutput
    if ($running.ExitCode -ne 0) { throw 'WSL running-state enumeration failed.' }
    @($running.Output -split '[\r\n]+' | ForEach-Object { $_.Trim([char]0).Trim() } | Where-Object { $_ })
}

function ConvertFrom-WslEgressConnections([string]$Text) {
    $connections = ConvertFrom-Json -InputObject $Text
    foreach ($connection in $connections) { $connection }
}

function Get-WslEgressBaseline {
    $results = @()
    # Availability obligations are private deployment data, not upstream defaults.
    $path = Join-Path $env:LOCALAPPDATA 'ClashOfRust\WslEgress\protected-connections.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Configure the private mandatory-connection baseline before network deployment.' }
    # Windows PowerShell 5.1 emits a JSON array as one pipeline object. Assign
    # first, then enumerate the value, so each URL is checked independently.
    $connections = @(ConvertFrom-WslEgressConnections ([IO.File]::ReadAllText($path)))
    if ($connections.Count -eq 0 -or $connections.Count -gt 16) { throw 'Invalid mandatory connection list.' }
    foreach ($connection in $connections) {
        $uri = [uri]$connection.url
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
            @($connection.accepted_statuses).Count -eq 0) { throw 'Baseline must use credential-free HTTPS and explicit accepted HTTP statuses.' }
        $hostName = $uri.DnsSafeHost
        $entry = [ordered]@{ host = $hostName; observed_at = (Get-Date -Format o)
            expected_statuses = @($connection.accepted_statuses)
            dns = 'FAIL'; tls = 'NOT_RUN'; http_status = 0; path = 'Windows default proxy; certificate validation enabled' }
        try {
            $null = Resolve-DnsName -Name $hostName -DnsOnly -ErrorAction Stop
            $entry.dns = 'PASS'
            Add-Type -AssemblyName System.Net.Http
            $handler = New-Object Net.Http.HttpClientHandler
            $handler.AllowAutoRedirect = $false
            $client = New-Object Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromSeconds(20)
            try {
                $response = $client.GetAsync($uri,
                    [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                $entry.tls = 'PASS'; $entry.http_status = [int]$response.StatusCode
                $response.Dispose()
            } finally { $client.Dispose(); $handler.Dispose() }
        } catch { $entry.tls = 'FAIL' }
        $results += [pscustomobject]$entry
    }
    $results
}

function Assert-WslEgressBaseline([object[]]$Baseline) {
    if ($Baseline.Count -eq 0) { throw 'Mandatory connection results are absent.' }
    foreach ($entry in $Baseline) {
        if ($entry.dns -ne 'PASS' -or $entry.tls -ne 'PASS' -or
            $entry.http_status -notin @($entry.expected_statuses)) {
            throw 'A mandatory Windows connection is unhealthy. Further network changes are blocked.'
        }
    }
}

function Read-WslEgressProfile([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'A private profile is required.' }
    $item = Get-Item -LiteralPath $Path
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Profile reparse points are not accepted.' }
    if ($item.Length -gt 65536) { throw 'Profile is too large.' }
    $profile = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not $profile.PSObject.Properties['schema'] -or $profile.schema -ne 1) { throw 'Profile schema must be 1.' }
    $address = $null
    if (-not [Net.IPAddress]::TryParse([string]$profile.endpoint_ipv4, [ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        [string]$address -ne [string]$profile.endpoint_ipv4 -or
        [Net.IPAddress]::IsLoopback($address) -or $address.GetAddressBytes()[0] -ge 224 -or
        $address.GetAddressBytes()[0] -eq 0) { throw 'An explicit unicast IPv4 endpoint is required.' }
    if ([int]$profile.endpoint_port -lt 1 -or [int]$profile.endpoint_port -gt 65535) { throw 'Invalid endpoint port.' }
    if ([string]$profile.manager_distro -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'Invalid manager distro.' }
    if ($profile.backend -notin @('WireGuard','Tailscale')) { throw 'Unknown backend.' }
    if ($profile.backend -eq 'WireGuard') {
        foreach ($keyName in @('private_key','peer_public_key')) {
            if ([Convert]::FromBase64String([string]$profile.$keyName).Length -ne 32) { throw 'WireGuard key length is invalid.' }
        }
        if (-not $profile.PSObject.Properties['tunnel_address'] -or
            -not $profile.PSObject.Properties['resolver_ipv4'] -or
            -not $profile.PSObject.Properties['uid'] -or -not $profile.PSObject.Properties['gid']) { throw 'Incomplete Linux profile.' }
    }
    if ($profile.PSObject.Properties['expected_egress_ipv4']) {
        $egress = $null
        if (-not [Net.IPAddress]::TryParse([string]$profile.expected_egress_ipv4, [ref]$egress) -or
            $egress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            [string]$egress -ne [string]$profile.expected_egress_ipv4) { throw 'Expected egress must be an explicit IPv4 address.' }
    }
    $profile
}

function Get-WslEgressSettings {
    Get-WslEgressSettingsFromStore -PolicyStore ActiveStore
}

function Get-WslEgressSettingsFromStore([string]$PolicyStore) {
    $setting = Get-NetFirewallHyperVVMSetting -PolicyStore $PolicyStore -Name $script:Creator -ErrorAction Stop
    [ordered]@{
        Enabled = $setting.Enabled
        DefaultInboundAction = $setting.DefaultInboundAction
        DefaultOutboundAction = $setting.DefaultOutboundAction
        AllowHostPolicyMerge = $setting.AllowHostPolicyMerge
        LoopbackEnabled = $setting.LoopbackEnabled
    }
}

function Get-WslEgressPersistentSettings {
    Get-WslEgressSettingsFromStore -PolicyStore PersistentStore
}

function Get-WslEgressGuardAudit([object]$State) {
    $issues = @()
    $setting = Get-WslEgressSettings
    if ([string]$setting.Enabled -ne 'True' -or [string]$setting.DefaultOutboundAction -ne 'Block' -or
        [string]$setting.DefaultInboundAction -ne 'Block' -or [string]$setting.AllowHostPolicyMerge -ne 'False' -or
        [string]$setting.LoopbackEnabled -ne 'False') { $issues += 'effective_settings_differ' }
    $allows = @(Get-NetFirewallHyperVRule -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {
        [string]$_.Enabled -eq 'True' -and [string]$_.Direction -eq 'Outbound' -and
        [string]$_.Action -eq 'Allow' -and [string]$_.VMCreatorId -eq $script:Creator
    })
    foreach ($rule in $allows) {
        if ($rule.Name -ne ($script:Prefix + 'Endpoint')) { $issues += 'foreign_outbound_allow'; continue }
        if (@($rule.RemoteAddresses).Count -ne 1 -or
            [string]@($rule.RemoteAddresses)[0] -notin @([string]$State.endpoint_ipv4, ([string]$State.endpoint_ipv4 + '/32')) -or
            [string]$rule.Protocol -notin @('UDP','17') -or
            @($rule.RemotePorts).Count -ne 1 -or [string]@($rule.RemotePorts)[0] -ne [string]$State.endpoint_port) {
            $issues += 'endpoint_rule_differ'
        }
    }
    if ($State.endpoint_enabled -and @($allows | Where-Object { $_.Name -eq ($script:Prefix + 'Endpoint') }).Count -ne 1) {
        $issues += 'endpoint_rule_missing'
    }
    if (-not $State.endpoint_enabled -and @($allows | Where-Object { $_.Name -eq ($script:Prefix + 'Endpoint') }).Count -ne 0) {
        $issues += 'endpoint_enabled_while_closed'
    }
    [pscustomobject]@{ valid = ($issues.Count -eq 0); issues = @($issues | Select-Object -Unique) }
}

function Invoke-WslEgressGuardianAudit {
    # This fixed audit is the only function used under SYSTEM. It neither
    # repairs external policy nor launches wsl.exe in the wrong user's context.
    $state = Read-WslEgressState
    if (-not $state -or $state.phase -eq 'restored') { return }
    $audit = Get-WslEgressGuardAudit $state
    $record = [ordered]@{ schema_version = 1; observed_at = (Get-Date -Format o)
        generation = $state.generation; policy_matches = $audit.valid
        issues = @($audit.issues); runtime_acceptance = 'NOT_RUN' }
    Save-WslEgressJson $record (Join-Path $script:StateRoot 'guardian-audit.json')
}

function Get-WslEgressClosureAudit([object]$State) {
    $confirmed = $false
    if ($State) {
        try { $confirmed = -not $State.endpoint_enabled -and (Get-WslEgressGuardAudit $State).valid }
        catch { $confirmed = $false }
    }
    [pscustomobject]@{ confirmed = [bool]$confirmed }
}

function Get-WslEgressStateValue {
    param([object]$State, [string]$Name, [object]$Default = $null)
    if ($null -eq $State) { return $Default }
    if ($State -is [Collections.IDictionary]) {
        if ($State.Contains($Name)) { return $State[$Name] }
        return $Default
    }
    $property = $State.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    $Default
}

function Set-WslEgressStateValue {
    param([object]$State, [string]$Name, [object]$Value)
    if ($State -is [Collections.IDictionary]) {
        $State[$Name] = $Value
        return
    }
    $property = $State.PSObject.Properties[$Name]
    if ($property) { $property.Value = $Value }
    else { $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Test-WslEgressPartialInstall([object]$State) {
    # Older journals predate the manager-install markers. A preparing journal
    # without either marker is recoverable on Windows only. Once Linux install
    # may have started, only the Linux manager can safely decide what it owns.
    if (-not $State) { return $false }
    return [string]$State.phase -in @('preparing','failed_closed_requested') -and
        -not [bool](Get-WslEgressStateValue $State 'linux_manager_install_started' $false) -and
        -not [bool](Get-WslEgressStateValue $State 'linux_manager_installed' $false)
}

function Remove-WslEgressGuardianIfOwned {
    $service = Get-CimInstance Win32_Service -Filter "Name='ClashOfRust.WslEgress'" -ErrorAction SilentlyContinue
    if (-not $service) { return }
    if (-not (Test-WslEgressGuardianServiceIdentity $service)) {
        throw 'The guardian service changed ownership; preserving it for manual review.'
    }
    Stop-Service -Name 'ClashOfRust.WslEgress' -Force -ErrorAction Stop
    & (Join-Path $env:SystemRoot 'System32\sc.exe') delete 'ClashOfRust.WslEgress' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The owned guardian service could not be removed.' }
    if (Get-CimInstance Win32_Service -Filter "Name='ClashOfRust.WslEgress'" -ErrorAction SilentlyContinue) {
        throw 'The guardian service remains after removal.'
    }
}

function Restore-WslEgressPartialInstall([object]$State) {
    if (-not (Test-WslEgressPartialInstall $State)) {
        throw 'The journal is not a recoverable partial installation.'
    }
    if ((Get-WslEgressStateValue $State 'linux_manager_install_started' $false) -or
        (Get-WslEgressStateValue $State 'linux_manager_installed' $false)) {
        throw 'A Linux manager installation may have started and cannot use Windows-only recovery.'
    }
    # Restore host objects only when this transaction recorded writing them.
    # Endpoint creation precedes settings_written; its exact tuple is verified
    # by Set-WslEgressEndpoint before any object is changed.
    if (Get-WslEgressStateValue $State 'endpoint_rule_written' $false) {
        Set-WslEgressEndpoint $State $false
    }
    $wslconfig = Get-WslEgressStateValue $State 'wslconfig'
    if ($wslconfig -and (Get-WslEgressStateValue $wslconfig 'after_hash')) {
        Restore-WslEgressConfig $State
    }
    $dockerBackends = @(Get-WslEgressStateValue $State 'docker_backends' @())
    if ((Get-WslEgressStateValue $State 'docker_guard_write_started' $false) -or
        (Get-WslEgressStateValue $State 'docker_guard_written' $false) -or
        $dockerBackends.Count -gt 0) {
        Set-WslEgressDockerGuard $State $true
    }
    if ((Get-WslEgressStateValue $State 'settings_write_started' $false) -or
        (Get-WslEgressStateValue $State 'settings_written' $false)) {
        $before = Get-WslEgressStateValue $State 'before_persistent_settings'
        if (-not $before) { $before = Get-WslEgressStateValue $State 'before_settings' }
        if (-not $before) { throw 'The partial journal has no Hyper-V settings snapshot.' }
        Set-NetFirewallHyperVVMSetting -PolicyStore PersistentStore -Name $script:Creator `
            -Enabled $before.Enabled -DefaultInboundAction $before.DefaultInboundAction `
            -DefaultOutboundAction $before.DefaultOutboundAction -AllowHostPolicyMerge $before.AllowHostPolicyMerge `
            -LoopbackEnabled $before.LoopbackEnabled -ErrorAction Stop
        $restoredSettings = Get-WslEgressSettingsFromStore -PolicyStore PersistentStore
        if (($restoredSettings | ConvertTo-Json -Compress) -ne ($before | ConvertTo-Json -Compress)) {
            throw 'Persistent Hyper-V settings restore readback failed; fail-closed policy retained.'
        }
    }
    if (Get-WslEgressStateValue $State 'guardian_service_installed' $false) {
        Remove-WslEgressGuardianIfOwned
    }
    Set-WslEgressStateValue $State 'phase' 'restored'
    Set-WslEgressStateValue $State 'endpoint_enabled' $false
    Save-WslEgressJson $State (Join-Path $script:StateRoot 'state.json')
    Assert-WslEgressBaseline @(Get-WslEgressBaseline)
}

function Save-WslEgressRestoredGeneration([object]$State) {
    if (-not $State -or [string]$State.phase -ne 'restored') {
        throw 'Only a verified restored journal can be archived.'
    }
    $archive = Join-Path $script:StateRoot ('restored-' + [string]$State.generation + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $archive -ErrorAction Stop | Out-Null
    $snapshot = Join-Path $script:StateRoot 'wslconfig.before'
    if (Test-Path -LiteralPath $snapshot -PathType Leaf) {
        Copy-Item -LiteralPath $snapshot -Destination (Join-Path $archive 'wslconfig.before') -ErrorAction Stop
    }
    $archiveState = Join-Path $archive 'state.json'
    Save-WslEgressJson $State $archiveState
    foreach ($name in @('scope-renewal.json', 'guardian-audit.json')) {
        $path = Join-Path $script:StateRoot $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $archive $name) -ErrorAction Stop
        }
    }
    try {
        $readback = [IO.File]::ReadAllText($archiveState) | ConvertFrom-Json
    } catch {
        throw 'The archived recovery journal is unreadable; live recovery state was preserved.'
    }
    if ([string]$readback.phase -ne 'restored' -or
        [string]$readback.generation -ne [string]$State.generation) {
        throw 'The archived recovery journal failed verification; live recovery state was preserved.'
    }
    $wslconfig = Get-WslEgressStateValue $State 'wslconfig'
    if ($wslconfig -and $wslconfig.existed) {
        $archivedSnapshot = Join-Path $archive 'wslconfig.before'
        if (-not (Test-Path -LiteralPath $archivedSnapshot -PathType Leaf) -or
            (Get-WslEgressFileHash $archivedSnapshot) -ne [string]$wslconfig.before_hash) {
            throw 'The archived WSL config snapshot failed verification; live recovery state was preserved.'
        }
    }
    Remove-Item -LiteralPath (Join-Path $script:StateRoot 'state.json') -ErrorAction Stop
    foreach ($name in @('scope-renewal.json', 'guardian-audit.json', 'wslconfig.before')) {
        $path = Join-Path $script:StateRoot $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -ErrorAction Stop
        }
    }
    $archive
}

function Get-WslEgressGuardianServiceCommand([string]$Binary) { '"' + $Binary + '" --service' }

function Get-WslEgressGuardianPackageBinary {
    # The service image must come from the protected package that ships next to
    # this module; a checkout, user directory or junction is never acceptable.
    $binary = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../clash-wsl-guardian.exe'))
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'The packaged WSL guardian binary is missing.' }
    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    if (-not $binary.StartsWith($programFiles.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A service may only be installed from the protected Program Files package.'
    }
    $binary
}

function Test-WslEgressGuardianServiceIdentity([object]$Service) {
    # The helper package and the application package are both canonical Program
    # Files layouts, so a service created by either copy is owned: rewriting the
    # image of a live service is riskier than running the other audited copy,
    # and each canonical copy pins the resources of its own package. Only a
    # foreign account or an image outside Program Files is refused.
    if (-not $Service) { return $false }
    if ([string]$Service.StartName -notin @('LocalSystem', 'NT AUTHORITY\SYSTEM')) { return $false }
    return (Test-WslEgressGuardianServicePath ([string]$Service.PathName))
}

function Install-WslEgressGuardian([object]$State) {
    $expected = Get-WslEgressGuardianServiceCommand (Get-WslEgressGuardianPackageBinary)
    $service = Get-CimInstance Win32_Service -Filter "Name='ClashOfRust.WslEgress'"
    if (-not $service) {
        $State.guardian_service_installed = $true
        Save-WslEgressJson $State (Join-Path $script:StateRoot 'state.json')
    }
    if ($service) {
        if (-not (Test-WslEgressGuardianServiceIdentity $service)) {
            throw 'WSL guardian service identity differs from the owned service.'
        }
    } else {
        New-Service -Name 'ClashOfRust.WslEgress' -DisplayName 'Clash of Rust WSL Egress Audit' `
            -BinaryPathName $expected -StartupType Automatic -Description 'Audits persistent WSL egress policy; never opens the guard or launches user WSL.' | Out-Null
    }
    # Cold-boot enforcement needs a persisted automatic start. An adopted service
    # that already reports Auto is left untouched and verified by the readback
    # below; anything else is reconfigured and re-read.
    if (-not $service -or [string]$service.StartMode -ne 'Auto') {
        & (Join-Path $env:SystemRoot 'System32\sc.exe') config 'ClashOfRust.WslEgress' start= auto | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'The WSL guardian service startup mode could not be persisted.' }
        $service = Get-CimInstance Win32_Service -Filter "Name='ClashOfRust.WslEgress'"
    }
    if (-not $service -or [string]$service.StartMode -ne 'Auto') {
        throw 'The WSL guardian service is not configured to start automatically.'
    }
    Start-Service -Name 'ClashOfRust.WslEgress' -ErrorAction Stop
}

function Test-WslEgressGuardianServicePath([string]$PathName) {
    # The guardian service may only run from a protected package directory. The
    # reviewed helper package normally installs it, but an application package
    # installed under Program Files is equally canonical. Accept exactly those
    # two locations so a foreign or relocated service is never removed.
    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    if (-not $programFiles) { return $false }
    $match = [regex]::Match([string]$PathName, '^"([^"]+)" --service$')
    if (-not $match.Success) { return $false }
    try { $binary = [IO.Path]::GetFullPath($match.Groups[1].Value) } catch { return $false }
    foreach ($root in @('Clash of Rust WSL', 'Clash of Rust')) {
        $expected = [IO.Path]::GetFullPath((Join-Path $programFiles ($root + '\clash-wsl-guardian.exe')))
        if ($binary -ieq $expected) { return $true }
    }
    return $false
}

function Get-WslEgressDockerPaths {
    $candidates = @((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'Docker\Docker\resources\com.docker.backend.exe'))
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop')) {
        if (Test-Path -LiteralPath $key) {
            $item = Get-ItemProperty -LiteralPath $key
            if ($item.PSObject.Properties['InstallLocation'] -and $item.InstallLocation) {
                $candidates += Join-Path $item.InstallLocation 'resources\com.docker.backend.exe'
            }
        }
    }
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='com.docker.backend.exe'")) {
        if (-not $process.ExecutablePath) { throw 'Docker backend identity cannot be inspected.' }
        $candidates += [string]$process.ExecutablePath
    }
    @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object {
        $path = [IO.Path]::GetFullPath($_)
        $current = $path
        while ($current) {
            if ((Get-Item -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Docker executable uses a redirected path.' }
            $current = [IO.Path]::GetDirectoryName($current)
        }
        $path
    } | Select-Object -Unique)
}

function Get-WslEgressDockerContainerProcesses {
    $backend = Get-CimInstance Win32_Process -Filter "Name='com.docker.backend.exe'"
    if (-not $backend) { return @() }
    $ids = @($backend.ProcessId)
    $descendants = [Collections.Generic.HashSet[uint32]]::new()
    foreach ($id in $ids) { $null = $descendants.Add([uint32]$id) }
    # Docker backend containers can be grandchildren (backend -> helper ->
    # container shim). Traverse the complete descendant tree without accepting
    # arbitrary user processes.
    do {
        $added = $false
        foreach ($process in @(Get-CimInstance Win32_Process)) {
            if ($descendants.Contains([uint32]$process.ParentProcessId) -and
                $descendants.Add([uint32]$process.ProcessId)) { $added = $true }
        }
    } while ($added)
    @(Get-CimInstance Win32_Process | Where-Object { $descendants.Contains([uint32]$_.ProcessId) } |
        ForEach-Object { [string]$_.ExecutablePath } | Where-Object { $_ } | Select-Object -Unique)
}

function Import-WslEgressDockerGuard {
    if (-not ('CorDockerEgressGuard' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'DockerEgressGuard.cs') }
    [CorDockerEgressGuard]::ValidateLayout()
}

function Set-WslEgressDockerGuard([object]$State, [bool]$Remove = $false) {
    $paths = @($State.docker_backends)
    if (-not $Remove) {
        $paths += @(Get-WslEgressDockerContainerProcesses)
        $paths = @($paths | Where-Object { $_ } | Select-Object -Unique)
        $State.docker_backends = @($paths)
        Save-WslEgressJson $State (Join-Path $script:StateRoot 'state.json')
    }
    if ($paths.Count -eq 0) { return }
    if ($Remove -and @(Get-Process -Name 'com.docker.backend' -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Stop Docker Desktop before restoring its external network.'
    }
    Import-WslEgressDockerGuard
    if ($Remove) {
        # The runtime descendant set is intentionally not durable. Remove both
        # the recorded identities and any current descendants using the same
        # exact path, then verify that the owned provider is empty.
        $removePaths = @($paths + @(Get-WslEgressDockerContainerProcesses) |
            Where-Object { $_ } | Select-Object -Unique)
        [CorDockerEgressGuard]::Apply([string[]]$removePaths, $true)
    } else {
        [CorDockerEgressGuard]::Apply([string[]]$paths, $false)
        if (-not [CorDockerEgressGuard]::Verify([string[]]$paths)) { throw 'Docker WFP readback failed.' }
    }
    Assert-WslEgressBaseline @(Get-WslEgressBaseline)
}

function Invoke-WslEgressLinux {
    param([object]$State, [string]$Action, [string]$InputText,
        [string[]]$AdditionalArguments = @(), [string]$Distribution = '',
        [string]$OperationId = '', [string]$LinuxProfilePath = '/etc/cor-egress/profile.json')
    $arguments = @('--distribution',[string]$State.manager_distro,'--user','root','--exec',
        $script:LinuxHelper,$Action,'--profile',$LinuxProfilePath,
        '--generation',[string]$State.generation)
    if ($Distribution) { $arguments[1] = $Distribution }
    $arguments += @($AdditionalArguments)
    $result = Invoke-WslEgressProcess -Arguments $arguments -InputText $InputText -TimeoutSeconds 60
    if ($result.Output.Length -gt 1048576) { throw 'Oversized Linux response.' }
    try { $response = $result.Output | ConvertFrom-Json } catch {
        $response = [pscustomobject]@{
            schema = 1; generation = [long]$State.generation; action = $Action
            outcome = 'blocked'; protection = 'Blocked'; phase = 'Blocked'
            message = 'Linux helper failed without a valid structured response.'
            checks = @()
        }
    }
    if ($response.schema -ne 1 -or $response.generation -ne $State.generation -or
        $response.action -ne $Action) { throw 'Linux response contract or generation mismatch.' }
    if (-not $OperationId) { $OperationId = [guid]::NewGuid().ToString() }
    $converted = ConvertFrom-WslEgressLinuxEvent $response $Action ([long]$State.generation) ([string]$State.backend) $OperationId
    if ($result.ExitCode -ne 0 -and $converted.outcome -ne 'blocked') {
        throw 'Linux helper exit status conflicts with its structured response.'
    }
    $converted
}

function Stop-WslEgressDistribution([string]$Name) {
    if (-not $Name -or $Name -match '[\r\n\0]') { throw 'Invalid distribution name.' }
    $result = Invoke-WslEgressProcess -Arguments @('--terminate',$Name) -TimeoutSeconds 45
    if ($result.ExitCode -ne 0) { throw 'WSL distribution termination failed.' }
}

function Get-WslEgressConfigValue([string]$Text, [string]$Section, [string]$Key) {
    $current = ''
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*\[([^]]+)\]\s*(?:[#;].*)?$') {
            $current = $Matches[1].Trim().ToLowerInvariant()
            continue
        }
        if ($current -eq $Section.ToLowerInvariant() -and
            $line -match '^\s*([^#;=]+?)\s*=\s*([^#;]*?)\s*(?:[#;].*)?$' -and
            $Matches[1].Trim().ToLowerInvariant() -eq $Key.ToLowerInvariant()) {
            return $Matches[2].Trim().ToLowerInvariant()
        }
    }
    $null
}

function Get-WslEgressWindowsConfigAudit([object]$State) {
    $path = Join-Path $env:USERPROFILE '.wslconfig'
    $currentHash = Get-WslEgressFileHash $path
    $expectedHash = $State.wslconfig.after_hash
    $text = if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::ReadAllText($path) } else { '' }
    $values = [ordered]@{
        networking_mode = Get-WslEgressConfigValue $text 'wsl2' 'networkingMode'
        dns_tunneling = Get-WslEgressConfigValue $text 'experimental' 'dnsTunneling'
        auto_proxy = Get-WslEgressConfigValue $text 'experimental' 'autoProxy'
        firewall = Get-WslEgressConfigValue $text 'experimental' 'firewall'
        localhost_forwarding = Get-WslEgressConfigValue $text 'wsl2' 'localhostForwarding'
    }
    $valid = $currentHash -eq $expectedHash -and
        $values.networking_mode -eq 'nat' -and $values.dns_tunneling -eq 'false' -and
        $values.auto_proxy -eq 'false' -and $values.firewall -eq 'true' -and
        $values.localhost_forwarding -eq 'false'
    [pscustomobject]@{ valid = $valid; hash_matches = $currentHash -eq $expectedHash; values = $values }
}

function Get-WslEgressOrdinaryDistributions([object[]]$Distributions) {
    @($Distributions | Where-Object { $_.name -notmatch '^docker-desktop(?:-data)?$' } |
        ForEach-Object { [string]$_.name })
}

function Get-WslEgressDockerBlocked([object]$State) {
    $current = @(Get-WslEgressDistributions)
    $dockerDistros = @($current | Where-Object { $_.name -match '^docker-desktop(?:-data)?$' })
    if ($dockerDistros.Count -eq 0) { return @($State.docker_backends).Count -eq 0 }
    $paths = @($State.docker_backends)
    try { $paths += @(Get-WslEgressDockerContainerProcesses) } catch { return $false }
    $paths = @($paths | Where-Object { $_ } | Select-Object -Unique)
    if ($paths.Count -eq 0) { return $false }
    Import-WslEgressDockerGuard
    foreach ($path in $paths) {
        try {
            if (-not [CorDockerEgressGuard]::Verify([string[]]@($path))) { return $false }
        } catch {
            return $false
        }
    }
    $true
}

function Get-WslEgressScopeAttestation([object]$State) {
    $distributions = @(Get-WslEgressDistributions)
    $currentNames = @($distributions | ForEach-Object { [string]$_.name })
    $recordedNames = @($State.distributions | ForEach-Object { [string]$_ })
    $sameScope = (@($currentNames | Sort-Object) -join "`n") -eq (@($recordedNames | Sort-Object) -join "`n")
    $configured = @($State.distro_configs)
    $expectedManaged = @($recordedNames | Where-Object {
        $_ -ne $State.manager_distro -and $_ -notmatch '^docker-desktop(?:-data)?$'
    } | Sort-Object)
    $allManaged = (@($configured | Sort-Object) -join "`n") -eq ($expectedManaged -join "`n") -and $sameScope
    $managerAudit = $null
    try { $managerAudit = Invoke-WslEgressLinux $State 'audit-config' }
    catch { $allManaged = $false }
    $netns = @()
    if ($managerAudit -and $managerAudit.facts.owned_config_matches -and
        $managerAudit.facts.interop_runtime_disabled) {
        $netns += [string]$managerAudit.facts.shared_netns
    } else { $allManaged = $false }
    foreach ($name in $configured) {
        try {
            $audit = Invoke-WslEgressLinux $State 'audit-config' -Distribution $name
            if (-not $audit.facts.owned_config_matches -or -not $audit.facts.interop_runtime_disabled) {
                $allManaged = $false
            } else { $netns += [string]$audit.facts.shared_netns }
        } catch { $allManaged = $false }
    }
    if ($allManaged -and (@($netns | Select-Object -Unique).Count -ne 1)) { $allManaged = $false }
    $hostAudit = Get-WslEgressGuardAudit $State
    $windowsConfig = Get-WslEgressWindowsConfigAudit $State
    $dockerBlocked = Get-WslEgressDockerBlocked $State
    $effective = $allManaged -and $hostAudit.valid -and $windowsConfig.valid -and $dockerBlocked
    [ordered]@{
        schema = 1
        generation = [long]$State.generation
        issued_at_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        all_distros_managed = [bool]$allManaged
        hyperv_default_deny = [bool]$hostAudit.valid
        dns_tunneling_disabled = [bool]$windowsConfig.valid
        interop_disabled = [bool]($managerAudit -and $managerAudit.facts.interop_runtime_disabled)
        docker_desktop_blocked = [bool]$dockerBlocked
        effective_audit_passed = [bool]$effective
    }
}

function Get-WslEgressRenewalTaskDefinition([object]$State) {
    $package = [IO.Path]::GetFullPath($PSScriptRoot)
    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    if (-not $package.StartsWith($programFiles.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The renewal task requires the protected installed package.'
    }
    $parent = [IO.DirectoryInfo]$package
    while ($parent) {
        if ((Get-Item -LiteralPath $parent.FullName).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Redirected renewal package refused.'
        }
        $parent = $parent.Parent
    }
    foreach ($item in @((Join-Path $package 'Renew-ScopeAttestation.ps1'), (Join-Path $package 'WslSecureEgress.psm1'))) {
        if (-not (Test-Path -LiteralPath $item -PathType Leaf)) { throw 'The fixed renewal package is missing.' }
        foreach ($ancestor in @((Get-Item -LiteralPath $item), (Get-Item -LiteralPath $package))) {
            if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Redirected renewal package refused.' }
        }
    }
    $executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -NonInteractive -File "' +
        (Join-Path $package 'Renew-ScopeAttestation.ps1') + '"'
    [pscustomobject]@{
        name = 'ClashOfRust-WslEgress-Renew'
        path = '\'
        executable = $executable
        arguments = $arguments
        owner_sid = [string]$State.owner_sid
    }
}

function Test-WslEgressRenewalTaskIdentity([object]$Task, [object]$Definition) {
    if (-not $Task -or @($Task.Actions).Count -ne 1) { return $false }
    $action = @($Task.Actions)[0]
    try {
        $identity = [string]$Task.Principal.UserId
        if ($identity -match '^S-1-\d+(?:-\d+)+$') {
            $actualSid = (New-Object Security.Principal.SecurityIdentifier($identity)).Value
        } else {
            $account = New-Object Security.Principal.NTAccount($identity)
            $actualSid = $account.Translate([Security.Principal.SecurityIdentifier]).Value
        }
    } catch { return $false }
    [string]$Task.TaskName -eq [string]$Definition.name -and
        [string]$Task.TaskPath -eq [string]$Definition.path -and
        $actualSid -eq [string]$Definition.owner_sid -and
        [string]$Task.Principal.LogonType -eq 'Interactive' -and
        [string]$Task.Principal.RunLevel -eq 'Highest' -and
        [string]$action.Execute -eq [string]$Definition.executable -and
        [string]$action.Arguments -eq [string]$Definition.arguments -and
        -not [string]$action.WorkingDirectory
}

function Install-WslEgressRenewalTask([object]$State) {
    $definition = Get-WslEgressRenewalTaskDefinition $State
    $existing = Get-ScheduledTask -TaskName $definition.name -TaskPath $definition.path -ErrorAction SilentlyContinue
    if ($existing -and -not (Test-WslEgressRenewalTaskIdentity $existing $definition)) {
        throw 'A different task uses the owned renewal task name; preserving it.'
    }
    $action = New-ScheduledTaskAction -Execute $definition.executable -Argument $definition.arguments
    $principal = New-ScheduledTaskPrincipal -UserId $definition.owner_sid -LogonType Interactive -RunLevel Highest
    $trigger = @(
        (New-ScheduledTaskTrigger -AtLogOn -User $definition.owner_sid),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1))
    )
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Seconds 55) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $definition.name -TaskPath $definition.path -Action $action `
        -Principal $principal -Trigger $trigger -Settings $settings `
        -Description 'Renews current-user WSL scope proofs after full audits; never opens the endpoint.' `
        -Force | Out-Null
    $readback = Get-ScheduledTask -TaskName $definition.name -TaskPath $definition.path -ErrorAction Stop
    if (-not (Test-WslEgressRenewalTaskIdentity $readback $definition)) {
        throw 'The renewal task identity readback failed.'
    }
    $State['renewal_task'] = [ordered]@{ name = $definition.name; path = $definition.path; owner_sid = $definition.owner_sid }
}

function Remove-WslEgressRenewalTask([object]$State) {
    $definition = Get-WslEgressRenewalTaskDefinition $State
    $existing = Get-ScheduledTask -TaskName $definition.name -TaskPath $definition.path -ErrorAction SilentlyContinue
    if (-not $existing) { return }
    if (-not (Test-WslEgressRenewalTaskIdentity $existing $definition)) {
        throw 'The renewal task changed; preserving it for manual review.'
    }
    Unregister-ScheduledTask -TaskName $definition.name -TaskPath $definition.path -Confirm:$false -ErrorAction Stop
}

function Invoke-WslEgressScopeRenewal {
    # The interactive-token task is intentionally separate from the SYSTEM
    # guardian. A scheduled audit never starts any stopped user distribution.
    $sid = Assert-WslEgressUser
    if (-not (Test-WslEgressAdministrator)) { throw 'Scope renewal requires the installed owner administrator token.' }
    $mutex = New-Object Threading.Mutex($false, 'Global\ClashOfRust.WslEgress.Operation')
    if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); return }
    $state = $null
    $record = [ordered]@{ schema_version = 1; observed_at = (Get-Date -Format o)
        generation = 0; outcome = 'not_run'; stage = 'state'; expires_after_seconds = 300 }
    try {
        $state = Read-WslEgressState
        if (-not $state -or $state.owner_sid -ne $sid) { throw 'Renewal owner does not match installed state.' }
        $record.generation = [long]$state.generation
        if (-not $state.endpoint_enabled -or $state.phase -notin @('connected_unverified','verified')) { return }
        $record.stage = 'running_distribution_inventory'
        $running = @(Get-WslEgressRunningDistributions)
        $required = @(Get-WslEgressOrdinaryDistributions @(Get-WslEgressDistributions))
        if (@($required | Where-Object { $running -notcontains $_ }).Count -gt 0) {
            throw 'A required distribution is stopped; renewal will not start it.'
        }
        $record.stage = 'scope_audit'
        $proof = Get-WslEgressScopeAttestation $state
        if (-not $proof.effective_audit_passed) { throw 'Current scope audit did not pass.' }
        $record.stage = 'linux_attestation'
        $renewed = Invoke-WslEgressLinux $state 'attest' ($proof | ConvertTo-Json -Depth 8 -Compress)
        if ($renewed.outcome -ne 'succeeded') { throw 'Linux refused the renewed proof.' }
        $record.outcome = 'succeeded'; $record.stage = 'complete'
    } catch {
        $record.outcome = 'failed'
        if ($state -and $state.owner_sid -eq $sid -and $state.endpoint_enabled) {
            try { Set-WslEgressEndpoint $state $false } catch { }
            $state.phase = 'blocked'
            Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
        }
    } finally {
        if ($state -and $state.owner_sid -eq $sid) {
            Save-WslEgressJson $record (Join-Path $script:StateRoot 'scope-renewal.json')
        }
        $mutex.ReleaseMutex(); $mutex.Dispose()
    }
    [pscustomobject]$record
}

function Invoke-WslEgressDistroConfiguration([object]$State, [object]$Profile, [object[]]$Distributions) {
    $ordinary = @(Get-WslEgressOrdinaryDistributions $Distributions)
    if ($ordinary -notcontains [string]$State.manager_distro) {
        throw 'The manager distribution disappeared during installation.'
    }
    $profileText = $Profile | ConvertTo-Json -Depth 12 -Compress
    $configured = @()
    foreach ($name in $ordinary) {
        if ($name -ne $State.manager_distro) {
            Install-WslEgressPayload $State $name
            $result = Invoke-WslEgressLinux $State 'configure' -InputText $profileText -Distribution $name
            if ($result.outcome -ne 'succeeded') { throw "Linux distro configuration failed: $name" }
            $configured += $name
            Stop-WslEgressDistribution $name
        }
    }
    Stop-WslEgressDistribution ([string]$State.manager_distro)
    # The WSL VM can outlive distro termination. Reload global networking and
    # shared interop state after the complete set of distro files is ready.
    $shutdown = Invoke-WslEgressProcess -Arguments @('--shutdown') -TimeoutSeconds 45
    if ($shutdown.ExitCode -ne 0) { throw 'WSL VM shutdown failed; host guard remains closed.' }
    $State.distro_configs = @($configured)
    Save-WslEgressJson $State (Join-Path $script:StateRoot 'state.json')
    # Restart after all wsl.conf changes, then collect runtime facts. The host
    # default deny is already active, so this restart cannot open fallback egress.
    $managerAudit = Invoke-WslEgressLinux $State 'audit-config'
    if ($managerAudit.outcome -ne 'succeeded') { throw 'Runtime configuration audit failed: manager distribution.' }
    foreach ($name in @($configured)) {
        $audit = Invoke-WslEgressLinux $State 'audit-config' -Distribution $name
        if ($audit.outcome -ne 'succeeded') { throw "Runtime configuration audit failed: $name" }
    }
}

function Set-WslEgressPersistentGuard([object]$State) {
    # No blanket Block rule: it would override a later Endpoint Allow.
    $State.settings_write_started = $true
    Save-WslEgressJson $State (Join-Path $script:StateRoot 'state.json')
    Set-NetFirewallHyperVVMSetting -PolicyStore PersistentStore -Name $script:Creator `
        -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Block `
        -AllowHostPolicyMerge False -LoopbackEnabled False -ErrorAction Stop
    $State.settings_written = $true
    Save-WslEgressJson $State (Join-Path $script:StateRoot 'state.json')
    $State.after_settings = Get-WslEgressSettings
    Save-WslEgressJson $State (Join-Path $script:StateRoot 'state.json')
    Assert-WslEgressBaseline @(Get-WslEgressBaseline)
    $audit = Get-WslEgressGuardAudit $State
    if (-not $audit.valid) { throw 'Effective host rules contain unowned allowances; no endpoint is opened.' }
}

function Set-WslEgressEndpoint([object]$State, [bool]$Enabled) {
    $existing = @(Get-NetFirewallHyperVRule -PolicyStore PersistentStore -Name ($script:Prefix + 'Endpoint') -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 1) { throw 'Multiple owned endpoint rules exist; preserving them for manual review.' }
    if ($existing.Count -gt 0) {
        # Verify ownership against the exact tuple before changing an object.
        $rule = $existing[0]
        if ($rule.DisplayName -ne 'Clash of Rust WSL managed endpoint' -or
            [string]$rule.VMCreatorId -ne $script:Creator -or [string]$rule.Action -ne 'Allow' -or
            [string]$rule.Direction -ne 'Outbound' -or [string]$rule.Protocol -notin @('UDP','17') -or
            (@($rule.RemoteAddresses) -join ',') -notin @([string]$State.endpoint_ipv4, ([string]$State.endpoint_ipv4 + '/32')) -or
            (@($rule.RemotePorts) -join ',') -ne [string]$State.endpoint_port) { throw 'Owned rule was changed externally.' }
        Set-NetFirewallHyperVRule -PolicyStore PersistentStore -Name ($script:Prefix + 'Endpoint') `
            -Enabled $(if ($Enabled) { 'True' } else { 'False' }) -ErrorAction Stop
    } else {
        New-NetFirewallHyperVRule -PolicyStore PersistentStore -Name ($script:Prefix + 'Endpoint') `
            -DisplayName 'Clash of Rust WSL managed endpoint' -Direction Outbound `
            -VMCreatorId $script:Creator -Protocol UDP -RemoteAddresses ([string]$State.endpoint_ipv4) `
            -RemotePorts ([string]$State.endpoint_port) -Action Allow `
            -Enabled $(if ($Enabled) { 'True' } else { 'False' }) -ErrorAction Stop | Out-Null
    }
    $State.endpoint_enabled = $Enabled
    $State.endpoint_rule_written = $true
    Save-WslEgressJson $State (Join-Path $script:StateRoot 'state.json')
    Assert-WslEgressBaseline @(Get-WslEgressBaseline)
    if (-not (Get-WslEgressGuardAudit $State).valid) { throw 'Endpoint effective policy verification failed.' }
}

function Start-WslEgressLifetime([object]$State, [object]$Profile) {
    # systemd/kernel tunnel objects do not themselves keep a WSL session alive.
    # A fixed, unprivileged sleep command supplies liveness only. Its death is
    # never permission to bypass either persistent firewall boundary.
    if ([string]$State.manager_distro -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or
        [int]$Profile.uid -lt 1000 -or [int]$Profile.gid -lt 1000) { throw 'Invalid lifetime identity.' }
    $executable = Join-Path $env:SystemRoot 'System32\wsl.exe'
    $arguments = @('--distribution',[string]$State.manager_distro,'--user','root','--exec',
        '/usr/bin/setpriv','--no-new-privs','--reuid',[string][int]$Profile.uid,
        '--regid',[string][int]$Profile.gid,'--clear-groups','--inh-caps=-all',
        '--ambient-caps=-all','--bounding-set=-all','/usr/bin/sleep','infinity') -join ' '
    if ($State.Contains('lifetime') -and $State.lifetime) {
        $old = Get-Process -Id ([int]$State.lifetime.pid) -ErrorAction SilentlyContinue
        if ($old) {
            try {
                if (-not $old.HasExited -and
                    $old.StartTime.ToUniversalTime().Ticks -eq [long]$State.lifetime.started_ticks -and
                    [string]$old.Path -eq $executable -and
                    [string]$State.lifetime.arguments -eq $arguments) { return }
            } finally { $old.Dispose() }
        }
    }
    # Give the native WSL client its own hidden console. Redirecting it to
    # pipes owned by this short-lived broker would close its stdio on exit.
    $process = Start-Process -FilePath $executable -ArgumentList $arguments `
        -WorkingDirectory (Join-Path $env:SystemRoot 'System32') -WindowStyle Hidden -PassThru
    try {
        if ($process.WaitForExit(300)) { throw 'WSL lifetime command exited; transport remains closed.' }
        $State['lifetime'] = [ordered]@{
            pid = $process.Id; started_ticks = $process.StartTime.ToUniversalTime().Ticks
            arguments = $arguments; generation = [long]$State.generation
        }
        Save-WslEgressJson $State (Join-Path $script:StateRoot 'state.json')
    } finally {
        # Disposing the local handle does not kill the independent WSL session.
        $process.Dispose()
    }
}

function Add-WslEgressInspection([object]$Result, [object]$State, [object[]]$Distributions) {
    $Result.checks += [ordered]@{ id = 'administrator'
        result = $(if (Test-WslEgressAdministrator) { 'PASS' } else { 'NOT_RUN' })
        detail = 'Network writes require an administrator.' }
    if (-not $State -or $State.phase -eq 'restored') {
        $Result.message = 'Not installed; no protection is claimed.'
        $Result.checks += [ordered]@{ id = 'wsl_runtime'; result = 'NOT_RUN'
            detail = 'Read-only enumeration does not start stopped distributions.' }
        return
    }
    try {
        $audit = Get-WslEgressGuardAudit $State
        $Result.checks += [ordered]@{ id = 'host_policy'
            result = $(if ($audit.valid) { 'PASS' } else { 'FAIL' })
            detail = 'Effective settings and endpoint rules only; not a cold-boot proof.' }
    } catch {
        $Result.checks += [ordered]@{ id = 'host_policy'; result = 'BLOCKED'
            detail = 'Host policy inspection requires a readable effective policy.' }
    }
    try {
        $running = @(Get-WslEgressRunningDistributions)
        $Result.distributions = @($Distributions | ForEach-Object {
            $name = [string]$_.name
            [ordered]@{ name = $name
                state = $(if ($running -contains $name) { 'running' } else { 'stopped' })
                coverage = $(if (@($State.distributions) -notcontains $name) { 'not_enrolled' }
                    elseif ($name -match '^docker-desktop(?:-data)?$') { 'blocked' } else { 'unknown' }) }
        })
        if ($running -contains [string]$State.manager_distro) {
            $linux = Invoke-WslEgressLinux $State 'status'
            $healthy = $linux.outcome -eq 'succeeded' -and $linux.phase -eq 'Running'
            $Result.checks += [ordered]@{ id = 'wsl_runtime'; result = $(if ($healthy) { 'PASS' } else { 'FAIL' })
                detail = 'Running manager local guard and interface invariants; no stopped distribution was started.' }
            if (-not $healthy -and $State.endpoint_enabled) { $Result.phase = 'blocked' }
        } else {
            $Result.checks += [ordered]@{ id = 'wsl_runtime'; result = 'NOT_RUN'
                detail = 'The manager distribution is stopped; no runtime command was executed.' }
            if ($State.endpoint_enabled) { $Result.phase = 'blocked' }
        }
    } catch {
        $Result.checks += [ordered]@{ id = 'wsl_runtime'; result = 'BLOCKED'
            detail = 'The running manager did not return a valid current-generation status.' }
        if ($State.endpoint_enabled) { $Result.phase = 'blocked' }
    }
    $proofPath = Join-Path $script:StateRoot 'scope-renewal.json'
    $fresh = $false
    if (Test-Path -LiteralPath $proofPath -PathType Leaf) {
        try {
            $proof = [IO.File]::ReadAllText($proofPath) | ConvertFrom-Json
            $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$proof.observed_at)).TotalSeconds
            $fresh = $proof.generation -eq $State.generation -and $proof.outcome -eq 'succeeded' -and $age -ge 0 -and $age -lt 300
        } catch { $fresh = $false }
    }
    $Result.checks += [ordered]@{ id = 'scope_attestation'; result = $(if ($fresh) { 'PASS' } else { 'NOT_RUN' })
        detail = 'Current-user full-scope proof renewal; expires after five minutes and is not end-to-end acceptance.' }
    $Result.message = 'Installed policy inspected; end-to-end and cold-boot acceptance are separate.'
}

function Invoke-WslEgressFunctionalProbe([object]$State) {
    # This fixed probe runs through the same unprivileged launcher as an
    # isolated application. It emits booleans only; no address is exported.
    $probe = @'
import ipaddress,json,os,pathlib,socket,ssl,subprocess,sys,urllib.request
request=json.load(sys.stdin);checks={}
def https_json(url):
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(url,timeout=12) as response:
        if response.status!=200: raise RuntimeError('unexpected status')
        return json.loads(response.read(65537))
try:
    echo=https_json('https://api.ipify.org?format=json')
    address=ipaddress.IPv4Address(echo['ip'])
    checks['functional_egress']=str(address)==request['expected_ipv4']
except Exception: checks['functional_egress']=False
try:
    location=https_json('https://ipinfo.io/json')
    checks['german_exit']=(location.get('country')=='DE' and location.get('ip')==request['expected_ipv4'])
except Exception: checks['german_exit']=False
try:
    sock=socket.socket(socket.AF_INET6,socket.SOCK_STREAM);sock.settimeout(4)
    sock.connect(('2606:4700:4700::1111',443));sock.close()
    checks['ipv4_only']=False
except OSError: checks['ipv4_only']=True
try:
    interfaces=json.loads(subprocess.check_output(['/usr/sbin/ip','-j','address','show'],timeout=5))
    names={item['ifname'] for item in interfaces}
    checks['virtual_interfaces']=names=={'lo','wg0','cor-bg0'}
    checks['host_mount_hidden']=not pathlib.Path('/mnt/c').exists() and not pathlib.Path('/init').exists()
except Exception:
    checks['virtual_interfaces']=False;checks['host_mount_hidden']=False
checks['interop_guarded']=not pathlib.Path('/mnt/c/Windows/System32/ipconfig.exe').exists()
checks['proxy_environment_clear']=not any(name.lower().endswith('proxy') for name in os.environ)
print(json.dumps({'schema':1,'generation':request['generation'],'checks':checks}))
'@
    $expected = if ($State.Contains('expected_egress_ipv4')) { [string]$State.expected_egress_ipv4 } else { [string]$State.endpoint_ipv4 }
    $request = [ordered]@{ generation = [long]$State.generation; expected_ipv4 = $expected }
    $response = Invoke-WslEgressProcess -Arguments @('--distribution',[string]$State.manager_distro,
        '--user','root','--exec',$script:LinuxHelper,'run','--generation',[string]$State.generation,
        '--','/usr/bin/python3','-I','-S','-c',$probe) `
        -InputText ($request | ConvertTo-Json -Compress) -TimeoutSeconds 55
    if ($response.ExitCode -ne 0 -or $response.Output.Length -gt 65536) {
        throw 'The isolated functional probe did not complete.'
    }
    $result = $response.Output | ConvertFrom-Json
    $names = @('functional_egress','german_exit','ipv4_only','virtual_interfaces','host_mount_hidden','interop_guarded','proxy_environment_clear')
    if ($result.schema -ne 1 -or $result.generation -ne $State.generation -or
        @($result.checks.PSObject.Properties).Count -ne $names.Count) { throw 'Invalid isolated functional probe response.' }
    foreach ($name in $names) {
        if (-not $result.checks.PSObject.Properties[$name] -or $result.checks.$name -isnot [bool]) {
            throw 'Invalid isolated functional probe check.'
        }
        [ordered]@{ id = $name; result = $(if ($result.checks.$name) { 'PASS' } else { 'FAIL' })
            detail = 'Executed in the strict unprivileged application namespace with TLS validation enabled.' }
    }
    $handshakeScript = @'
import json,subprocess,time
r=subprocess.run(['/usr/sbin/ip','netns','exec','cor-egress-gw','/usr/bin/wg','show','wg0','latest-handshakes'],capture_output=True,text=True,timeout=5)
times=[int(line.split()[1]) for line in r.stdout.splitlines() if len(line.split())==2]
print(json.dumps({'connected':r.returncode==0 and len(times)==1 and 0<=time.time()-times[0]<180}))
'@
    $handshake = Invoke-WslEgressProcess -Arguments @('--distribution',[string]$State.manager_distro,'--user','root',
        '--exec','/usr/bin/python3','-I','-S','-c',$handshakeScript) -TimeoutSeconds 10
    $connected = $handshake.ExitCode -eq 0 -and ($handshake.Output | ConvertFrom-Json).connected -eq $true -and
        $result.checks.functional_egress -eq $true
    [ordered]@{ id = 'wireguard_connected'; result = $(if ($connected) { 'PASS' } else { 'FAIL' })
        detail = 'A recent WireGuard handshake and a successful strict-launcher IPv4 egress request were both observed.' }
}

function Get-WslEgressPreflight([object]$State, [object[]]$Distributions, [string]$Backend,
    [string]$Distro, [string]$ProfilePath, [string]$EndpointIPv4, [int]$EndpointPort, [bool]$PortSpecified) {
    $buildSupported = [Environment]::OSVersion.Version.Build -ge 22621
    [ordered]@{ id = 'windows_compatibility'; result = $(if ($buildSupported) { 'PASS' } else { 'BLOCKED' })
        detail = 'Windows 11 build 22621 or later with supported Hyper-V Firewall cmdlets is required.' }
    $missing = @(@('Get-NetFirewallHyperVVMSetting','Set-NetFirewallHyperVVMSetting',
        'Get-NetFirewallHyperVRule','New-NetFirewallHyperVRule','Set-NetFirewallHyperVRule','Remove-NetFirewallHyperVRule') |
        Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    [ordered]@{ id = 'hyperv_api'; result = $(if ($missing.Count -eq 0) { 'PASS' } else { 'BLOCKED' })
        detail = 'Install supported Windows and WSL updates when Hyper-V Firewall cmdlets are unavailable.' }
    [ordered]@{ id = 'wsl_available'
        result = $(if (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\wsl.exe') -PathType Leaf) { 'PASS' } else { 'BLOCKED' })
        detail = 'WSL is required. Use the official wsl --install workflow and complete any requested restart before deployment.' }
    $configuration = $State
    if (-not $configuration) {
        try {
            $configuration = Read-WslEgressProfile $ProfilePath
            [ordered]@{ id = 'private_profile'; result = 'PASS'; detail = 'Private profile schema and key sizes validated; values are not exported.' }
        } catch {
            [ordered]@{ id = 'private_profile'; result = 'BLOCKED'
                detail = 'Choose a valid private WireGuard profile before the first installation; endpoint fields alone do not supply tunnel keys.' }
        }
    } else {
        [ordered]@{ id = 'private_profile'; result = 'PASS'; detail = 'The existing protected installation is reused; no private profile re-entry is required.' }
    }
    if ($configuration) {
        $matches = $true
        try { Assert-WslEgressRequestedConfiguration $configuration $Backend $Distro $EndpointIPv4 $EndpointPort $PortSpecified }
        catch { $matches = $false }
        [ordered]@{ id = 'configuration_match'; result = $(if ($matches) { 'PASS' } else { 'BLOCKED' })
            detail = 'Explicit backend, distribution, endpoint and port overrides must match the protected profile.' }
        $manager = [string]$configuration.manager_distro
        $registered = @($Distributions | Where-Object { $_.name -eq $manager }).Count -eq 1
        [ordered]@{ id = 'manager_distribution'; result = $(if ($registered) { 'PASS' } else { 'BLOCKED' })
            detail = 'The private profile manager must be an existing WSL2 distribution; prepare it with the official WSL installation workflow.' }
        if ($registered) {
            try {
                $running = @(Get-WslEgressRunningDistributions)
                if ($running -contains $manager) {
                    $scriptText = 'import json,shutil;print(json.dumps({"available":all(shutil.which(x) for x in ("ip","nft","wg","bwrap","setpriv","python3"))}))'
                    $probe = Invoke-WslEgressProcess -Arguments @('--distribution',$manager,'--user','root','--exec',
                        '/usr/bin/python3','-I','-S','-c',$scriptText) -TimeoutSeconds 15
                    $available = $probe.ExitCode -eq 0 -and ($probe.Output | ConvertFrom-Json).available -eq $true
                    [ordered]@{ id = 'linux_dependencies'; result = $(if ($available) { 'PASS' } else { 'BLOCKED' })
                        detail = 'Required Linux tools: python3, iproute2, nftables, wireguard-tools, bubblewrap and util-linux.' }
                } else {
                    [ordered]@{ id = 'linux_dependencies'; result = 'NOT_RUN'
                        detail = 'The manager is stopped; dependency inspection does not start it. Install dependencies before the initial cutover.' }
                }
            } catch {
                [ordered]@{ id = 'linux_dependencies'; result = 'BLOCKED'
                    detail = 'The running manager dependency probe did not return a valid result.' }
            }
        }
    }
    [ordered]@{ id = 'strict_tailscale_boot'; result = $(if ($Backend -eq 'WireGuard') { 'NOT_SUPPORTED' } else { 'BLOCKED' })
        detail = 'Tailscale dynamic control and relay endpoints do not satisfy the fixed-endpoint host allowlist; strict installation uses WireGuard.' }
}

function Get-WslEgressRecoveryInstruction([string]$Stage) {
    switch ($Stage) {
        'private_profile_validation' { 'Choose a valid private WireGuard profile matching the requested endpoint and manager distribution.' }
        'stopped_distribution_gate' { 'Save work and stop all WSL distributions before the initial network cutover.' }
        'host_guard_audit' { 'Run Doctor and review effective Hyper-V policy before reconnecting; do not reset the global firewall.' }
        'installed_profile_identity' { 'Use the root-owned installed profile; an optional supplied profile must match it exactly.' }
        'wsl_lifetime' { 'Check manager distribution startup, Linux lifetime identity and required tools.' }
        'scope_audit' { 'Review current distribution coverage, Hyper-V policy, NAT and DNS settings, disabled interop and Docker isolation.' }
        'linux_start' { 'Inspect the protected Linux journal and current generation; repair owned configuration before retrying.' }
        'endpoint_enable' { 'Endpoint policy readback failed; inspect effective policy and the endpoint closure check.' }
        'scope_renewal_task' { 'Review Task Scheduler permissions and the exact owned renewal task identity before reconnecting.' }
        'guardian_service' { 'Review the installed guardian service executable, service account and automatic startup mode.' }
        'distro_configuration' { 'Review each recorded distribution configuration and its adjacent rollback snapshot.' }
        default { 'Inspect the protected local journal at the reported failure stage; preserve owned guard rules and backups.' }
    }
}

function Invoke-WslEgressOperation {
    [CmdletBinding()]
    param([string]$Action = 'Doctor', [string]$Backend = 'WireGuard', [string]$Distro = '',
        [string]$ProfilePath, [string]$EndpointIPv4, [int]$EndpointPort = 51820,
        [switch]$Execute, [switch]$RestoreOriginalNetwork)
    $result = New-WslEgressResponse -Action $Action -Backend $Backend
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $result.outcome = 'blocked'; $result.message = 'This host is not Windows.'; return $result
    }
    $sid = Assert-WslEgressUser
    $distributions = @(Get-WslEgressDistributions)
    $registeredOnly = $distributions
    $result.distributions = $distributions
    $state = Read-WslEgressState
    if ($state) {
        if ($state.owner_sid -ne $sid) { throw 'State belongs to a different Windows user.' }
        $result.generation = $state.generation; $result.backend = $state.backend; $result.phase = $state.phase
    }
    $result.operation_id = [guid]::NewGuid().ToString()
    $result.distributions = @($registeredOnly | ForEach-Object {
        [ordered]@{ name = [string]$_.name; state = 'unknown'; coverage = 'not_enrolled' }
    })
    if ($Action -in @('Doctor','Status')) {
        $result.outcome = 'succeeded'
        Add-WslEgressInspection $result $state $distributions
        return $result
    }
    if ($Action -eq 'Test') {
        $result.outcome = 'not_run'; $result.phase = 'acceptance_pending'
        Add-WslEgressInspection $result $state $distributions
        if ($state -and $state.phase -ne 'restored' -and $state.endpoint_enabled) {
            $runtime = @($result.checks | Where-Object { $_.id -eq 'wsl_runtime' -and $_.result -eq 'PASS' })
            if ($runtime.Count -eq 1) {
                try {
                    $checks = @(Invoke-WslEgressFunctionalProbe $state)
                    $result.checks += $checks
                    $result.outcome = if (@($checks | Where-Object { $_.result -ne 'PASS' }).Count -eq 0) { 'succeeded' } else { 'failed' }
                    $result.phase = 'connected_unverified'
                } catch {
                    $result.outcome = 'blocked'; $result.phase = 'blocked'
                    $result.checks += [ordered]@{ id = 'functional_egress'; result = 'BLOCKED'
                        detail = 'The strict launcher probe could not execute; inspect current scope proof renewal and Linux health.' }
                }
            }
        }
        foreach ($check in @('dns_via_exit','docker_runtime','cold_boot','failure_closed','network_switch','sleep_resume')) {
            $result.checks += [ordered]@{ id = $check; result = 'NOT_RUN'
                detail = 'No executed production acceptance evidence supplied.' }
        }
        $result.message = 'Functional checks and full fail-closed acceptance are separate; unexecuted scenarios remain NOT_RUN.'
        return $result
    }
    if (-not $Execute) {
        $result.phase = 'preflight'; $result.message = 'Preview only. No files, network settings, or WSL runtime changed.'
        if ($Action -eq 'Install') {
            $result.checks += @(Get-WslEgressPreflight $state $distributions $Backend $Distro $ProfilePath `
                $EndpointIPv4 $EndpointPort ($PSBoundParameters.ContainsKey('EndpointPort')))
            if (@($result.checks | Where-Object { $_.result -in @('BLOCKED','FAIL') }).Count -gt 0) {
                $result.outcome = 'blocked'
            }
        }
        return $result
    }
    if (-not (Test-WslEgressAdministrator)) {
        $result.outcome = 'blocked'; $result.message = 'Run the fixed installed broker as administrator; no automatic elevation performed.'; return $result
    }
    if ($Action -in @('Install','Start') -and $state) {
        try {
            Assert-WslEgressRequestedConfiguration $state $Backend $Distro $EndpointIPv4 $EndpointPort `
                ($PSBoundParameters.ContainsKey('EndpointPort'))
        } catch {
            $result.outcome = 'blocked'
            $result.message = 'Requested configuration differs from the protected installation; refresh status and use the installed backend and profile.'
            $result.checks += [ordered]@{ id = 'configuration_match'; result = 'BLOCKED'
                detail = 'Explicit backend, distribution, endpoint and port overrides must match the protected profile.' }
            return $result
        }
    }
    if ($Action -in @('Install','Start') -and (($state -and $state.backend -eq 'Tailscale') -or (-not $state -and $Backend -eq 'Tailscale'))) {
        $result.outcome = 'blocked'; $result.phase = 'blocked'
        $result.message = 'Tailscale strict all-WSL cold-boot protection is not verified. Use the separately configured WireGuard backend.'
        return $result
    }
    $mutex = New-Object Threading.Mutex($false, 'Global\ClashOfRust.WslEgress.Operation')
    if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); throw 'Another operation is active.' }
    $completionWritten = $false
    $stage = 'baseline'
    try {
        Assert-WslEgressBaseline @(Get-WslEgressBaseline)
        $stage = 'running_distribution_inventory'
        $runningNames = @(Get-WslEgressRunningDistributions)
        foreach ($item in $distributions) {
            $item.state = if ($runningNames -contains $item.name) { 'running' } else { 'stopped' }
        }
        if ($Action -eq 'Install') {
            if ($state) {
                if ($state.phase -eq 'restored') {
                    # Retain the old journal and Windows snapshots in a new
                    # protected generation directory before starting over.
                    $null = Save-WslEgressRestoredGeneration $state
                    $state = $null
                } elseif ($state.phase -eq 'preparing') {
                    # The previous cutover stopped before a manager existed. A
                    # journal cannot prove how far it got, so recover only the
                    # recorded host changes before a fresh, fully stopped start.
                    Restore-WslEgressPartialInstall $state
                    $state = $null
                }
            }
            if ($state) {
                if (-not (Get-WslEgressGuardAudit $state).valid) { throw 'Existing host policy drift requires targeted recovery before installation can be adopted.' }
                $result.outcome = 'succeeded'
                Add-WslEgressInspection $result $state $distributions
                $result.message = 'Existing protected installation adopted; original snapshots were preserved.'
                return $result
            }
            $stage = 'private_profile_validation'
            $profile = Read-WslEgressProfile $ProfilePath
            if ($profile.backend -ne 'WireGuard') { throw 'Only the strict fixed-endpoint profile can be installed.' }
            Assert-WslEgressRequestedConfiguration $profile $Backend $Distro $EndpointIPv4 $EndpointPort `
                ($PSBoundParameters.ContainsKey('EndpointPort'))
            if (@($distributions | Where-Object { $_.name -eq $profile.manager_distro }).Count -ne 1) { throw 'Prepare the declared manager distribution before installation.' }
            $stage = 'stopped_distribution_gate'
            if ($runningNames.Count -ne 0) { throw 'Save work and stop all WSL distributions manually before the initial cutover.' }
            $stage = 'docker_inventory'
            $dockerPaths = @(Get-WslEgressDockerPaths)
            $dockerRegistered = @($distributions | Where-Object { $_.name -match '^docker-desktop(?:-data)?$' }).Count -gt 0
            if (@($distributions | Where-Object { $_.name -match '^docker-desktop' }).Count -gt 0 -and $dockerPaths.Count -eq 0) {
                throw 'Docker Desktop is registered but its host backend identity is unknown; no protection is claimed.'
            }
            if (-not $dockerRegistered) { $dockerPaths = @() }
            $stage = 'state_directory'
            Protect-WslEgressDirectory $script:StateRoot
            $state = [ordered]@{ schema_version = 1; owner = 'ClashOfRust.WslEgress'; owner_sid = $sid
                generation = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); backend = 'WireGuard'; phase = 'preparing'
                manager_distro = [string]$profile.manager_distro; endpoint_ipv4 = [string]$profile.endpoint_ipv4
                endpoint_port = [int]$profile.endpoint_port; endpoint_enabled = $false
                expected_egress_ipv4 = $(if ($profile.PSObject.Properties['expected_egress_ipv4']) { [string]$profile.expected_egress_ipv4 } else { [string]$profile.endpoint_ipv4 })
                uid = [int]$profile.uid; gid = [int]$profile.gid
                linux_profile_path = (New-WslEgressUnixPath ([string]$ProfilePath))
                before_persistent_settings = (Get-WslEgressPersistentSettings)
                before_effective_settings = (Get-WslEgressSettings)
                after_settings = $null
                created_at = (Get-Date -Format o); distributions = @($distributions.name)
                docker_backends = $dockerPaths; wslconfig = $null; distro_configs = @()
                settings_written = $false; endpoint_rule_written = $false
                docker_guard_written = $false; guardian_service_installed = $false
                linux_manager_installed = $false
                operation_id = [string]$result.operation_id
            }
            Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
            $stage = 'hyperv_guard'
            Set-WslEgressPersistentGuard $state
            $stage = 'docker_guard'
            $state.docker_guard_write_started = $true
            Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
            Set-WslEgressDockerGuard $state
            $state.docker_guard_written = @($state.docker_backends).Count -gt 0
            Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
            $stage = 'guardian_service'
            Install-WslEgressGuardian $state
            $stage = 'windows_config'
            Install-WslEgressConfig $state
            $stage = 'linux_payload'
            Install-WslEgressPayload $state ([string]$state.manager_distro)
            # Only start Linux after the host is already closed. Install receives
            # secrets through stdin, never argv, stdout, or an exported report.
            $linuxProfile = [ordered]@{}
            foreach ($property in $profile.PSObject.Properties) { $linuxProfile[$property.Name] = $property.Value }
            $linuxProfile['manager_distro'] = [string]$state.manager_distro
            $stage = 'linux_install'
            $state.linux_manager_install_started = $true
            Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
            $linux = Invoke-WslEgressLinux $state 'install' ($linuxProfile | ConvertTo-Json -Depth 12 -Compress) `
                -AdditionalArguments @('--acknowledge-shared-guard')
            if ($linux.outcome -ne 'succeeded') { throw 'Linux install did not complete; the host guard remains closed.' }
            $state.linux_manager_installed = $true
            Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
            $stage = 'distro_configuration'
            Invoke-WslEgressDistroConfiguration $state $profile $distributions
            $state.phase = 'installed_closed'
        } elseif ($Action -in @('Rollback','Uninstall') -and (Test-WslEgressPartialInstall $state) -and $RestoreOriginalNetwork) {
            # A failure before the manager was installed has no Linux rollback
            # endpoint. Restore the recorded Windows objects directly.
            if ($runningNames.Count -gt 0) {
                throw 'All WSL processes must be stopped manually before restoring host access.'
            }
            Restore-WslEgressPartialInstall $state
            $result.outcome = 'succeeded'
            $result.phase = 'restored'
            $result.generation = [long]$state.generation
            $result.backend = [string]$state.backend
            $result.message = 'Partial installation recovered; original Windows network configuration restored.'
            return $result
        } elseif (-not $state) { throw 'Not installed.' }
        elseif ($Action -eq 'Start') {
            $stage = 'host_guard_audit'
            if (-not (Get-WslEgressGuardAudit $state).valid) { throw 'Host guard is not effective.' }
            $stage = 'installed_profile_identity'
            $profile = $null
            if ($ProfilePath) {
                $profile = Read-WslEgressProfile $ProfilePath
                Assert-WslEgressProfileForState $profile $state
            }
            $identity = Get-WslEgressInstalledIdentity $state $profile
            $stage = 'wsl_lifetime'
            Start-WslEgressLifetime $state $identity
            $stage = 'scope_audit'
            $attestation = Get-WslEgressScopeAttestation $state
            foreach ($mapping in @(
                @('all_wsl_coverage','all_distros_managed'), @('host_policy','hyperv_default_deny'),
                @('dns_tunneling_disabled','dns_tunneling_disabled'), @('interop_guarded','interop_disabled'),
                @('docker_desktop_isolated','docker_desktop_blocked'))) {
                $result.checks += [ordered]@{ id = $mapping[0]
                    result = $(if ($attestation[$mapping[1]]) { 'PASS' } else { 'FAIL' })
                    detail = 'Current effective scope invariant audit; separate packet-level acceptance is required.' }
            }
            if (-not $attestation.effective_audit_passed) {
                throw 'Current WSL distro, Hyper-V, DNS-tunneling or Docker audit is incomplete; endpoint remains closed.'
            }
            $stage = 'linux_start'
            $linux = Invoke-WslEgressLinux $state 'start' ($attestation | ConvertTo-Json -Depth 8 -Compress)
            if ($linux.outcome -ne 'succeeded') { throw 'Linux start failed; endpoint remains closed.' }
            try {
                $stage = 'endpoint_enable'
                Set-WslEgressEndpoint $state $true
            } catch {
                # Enabling and its mandatory readbacks are one transaction. If
                # any post-enable check fails, restore the closed endpoint and
                # verify that state before surfacing the original failure.
                try {
                    Set-WslEgressEndpoint $state $false
                    if (-not (Get-WslEgressGuardAudit $state).valid) {
                        throw 'Endpoint compensation did not produce a verified closed state.'
                    }
                } catch {
                    throw 'Start failed after opening the endpoint, and automatic close verification also failed.'
                }
                throw
            }
            $state.phase = 'connected_unverified'
            $state['operation_id'] = [string]$result.operation_id
            Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
            $stage = 'scope_renewal_task'
            Install-WslEgressRenewalTask $state
            Save-WslEgressJson ([ordered]@{ schema_version = 1; generation = [long]$state.generation
                observed_at = (Get-Date -Format o); outcome = 'succeeded'; stage = 'start'
                expires_after_seconds = 300 }) (Join-Path $script:StateRoot 'scope-renewal.json')
        } elseif ($Action -eq 'Stop') {
            Set-WslEgressEndpoint $state $false
            $state.phase = 'installed_closed'
            Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
            Remove-WslEgressRenewalTask $state
            if ($runningNames -contains $state.manager_distro) {
                $null = Invoke-WslEgressLinux $state 'stop'
            }
        } elseif ($Action -in @('Rollback','Uninstall') -and (Test-WslEgressPartialInstall $state)) {
            # An install failure before the Linux manager exists cannot use a
            # Linux rollback command. Keep the host closed unless the caller
            # explicitly requests the verified Windows snapshot restore.
            Set-WslEgressEndpoint $state $false
            if (-not $RestoreOriginalNetwork) {
                $state.phase = 'failed_closed_requested'
                Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
                $result.outcome = 'blocked'; $result.phase = $state.phase
                $result.message = 'Partial installation remains fail-closed. Use -RestoreOriginalNetwork after stopping all WSL distributions to recover Windows-only objects.'
                return $result
            }
            if ($runningNames.Count -gt 0) { throw 'All WSL processes must be stopped manually before restoring host access.' }
            Restore-WslEgressPartialInstall $state
            $result.outcome = 'succeeded'; $result.phase = 'restored'
            $result.generation = [long]$state.generation; $result.backend = [string]$state.backend
            $result.message = 'Partial installation recovered; original Windows network configuration restored.'
            return $result
        } elseif ($Action -in @('Rollback','Uninstall')) {
            Set-WslEgressEndpoint $state $false
            Remove-WslEgressRenewalTask $state
            if (-not $RestoreOriginalNetwork) {
                $state.phase = 'installed_closed'
                Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
                $result.outcome = 'blocked'; $result.phase = 'installed_closed'
                $result.message = 'Transport closed. Restoring original networking requires -RestoreOriginalNetwork and no running WSL distribution.'
                return $result
            }
            if ($runningNames.Count -gt 0) { throw 'All WSL processes must be stopped manually before restoring host access.' }
            $current = Get-WslEgressSettings
            if (($current | ConvertTo-Json -Compress) -ne ($state.after_settings | ConvertTo-Json -Compress)) { throw 'Host settings changed since installation; automatic restore refused.' }
            $before = if ($state.PSObject.Properties['before_persistent_settings']) {
                $state.before_persistent_settings
            } else {
                $state.before_settings
            }
            # Close the outer transport before asking the manager to remove its
            # owned namespaces and guard. Then restore every per-distro file while
            # the host default deny is still active.
            if ($null -ne $state.distro_configs -and @($state.distro_configs).Count -gt 0) {
                foreach ($name in @($state.distro_configs)) {
                    $restored = Invoke-WslEgressLinux $state 'restore-config' -Distribution $name
                    if ($restored.outcome -ne 'succeeded') { throw "Distro restore failed: $name" }
                    Stop-WslEgressDistribution $name
                }
            }
            $linuxRollback = Invoke-WslEgressLinux $state 'rollback' -AdditionalArguments @('--release-guard')
            if ($linuxRollback.outcome -ne 'succeeded') { throw 'Linux guard rollback did not complete.' }
            Stop-WslEgressDistribution ([string]$state.manager_distro)
            Restore-WslEgressConfig $state
            Set-WslEgressDockerGuard $state $true
            if ($state.settings_written) {
                Set-NetFirewallHyperVVMSetting -PolicyStore PersistentStore -Name $script:Creator `
                    -Enabled $before.Enabled -DefaultInboundAction $before.DefaultInboundAction `
                    -DefaultOutboundAction $before.DefaultOutboundAction -AllowHostPolicyMerge $before.AllowHostPolicyMerge `
                    -LoopbackEnabled $before.LoopbackEnabled -ErrorAction Stop
            }
            Assert-WslEgressBaseline @(Get-WslEgressBaseline)
            if ($state.endpoint_rule_written -or
                @(Get-NetFirewallHyperVRule -PolicyStore PersistentStore -Name ($script:Prefix + 'Endpoint') -ErrorAction SilentlyContinue).Count -gt 0) {
                # Verify ownership against the journal before removal.
                $owned = @(Get-NetFirewallHyperVRule -PolicyStore PersistentStore -Name ($script:Prefix + 'Endpoint') -ErrorAction SilentlyContinue)
                if ($owned.Count -gt 1 -or ($owned.Count -eq 1 -and
                    ($owned[0].DisplayName -ne 'Clash of Rust WSL managed endpoint' -or
                     [string]$owned[0].VMCreatorId -ne $script:Creator))) {
                    throw 'Owned endpoint rule changed; preserving it for manual review.'
                }
                if ($owned.Count -eq 1) {
                    Remove-NetFirewallHyperVRule -PolicyStore PersistentStore -Name ($script:Prefix + 'Endpoint') -ErrorAction Stop
                }
            }
            Assert-WslEgressBaseline @(Get-WslEgressBaseline)
            $state.phase = 'restored'
        }
        $state['operation_id'] = [string]$result.operation_id
        Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
        Assert-WslEgressBaseline @(Get-WslEgressBaseline)
        $result.outcome = 'succeeded'; $result.phase = $state.phase
        $result.operation_id = [string]$state.operation_id
        $result.generation = $state.generation; $result.backend = $state.backend
        $result.distributions = @($state.distributions | ForEach-Object {
            [ordered]@{
                name = $_
                state = 'unknown'
                coverage = $(if ($_ -match '^docker-desktop') { 'blocked' } else { 'enrolled' })
            }
        })
        $result.message = 'Operation completed. Packet-level, exit-location, and reboot verification remain separate.'
        $completion = [ordered]@{
            schema_version = 1; operation_id = [string]$result.operation_id
            generation = [long]$state.generation; action = $Action
            outcome = 'succeeded'; phase = [string]$state.phase; backend = [string]$state.backend
            completed_at = (Get-Date -Format o)
        }
        Save-WslEgressJson $completion (Join-Path $env:LOCALAPPDATA ('ClashOfRust\WslEgress\results\' + [string]$result.operation_id + '.json'))
        $completionWritten = $true
        return $result
    } catch {
        if ($stage -eq 'baseline') {
            $result.outcome = 'blocked'
            $result.message = 'A mandatory Windows connection is unhealthy; no network change was started.'
            $result.checks += [ordered]@{ id = 'windows_network_preserved'; result = 'FAIL'
                detail = 'Check the private mandatory-connection list and Windows DNS, TLS and HTTP availability before retrying.' }
            return $result
        }
        if ($state -and $Action -eq 'Start' -and $stage -ne 'baseline') {
            try { Set-WslEgressEndpoint $state $false } catch { }
        }
        $closure = Get-WslEgressClosureAudit $state
        $failurePhase = if ($closure.confirmed) { 'failed_closed_requested' } else { 'closure_unverified' }
        if ($state) {
            $state.phase = $failurePhase
            Save-WslEgressJson $state (Join-Path $script:StateRoot 'state.json')
            $result.generation = [long]$state.generation
            $result.backend = [string]$state.backend
        }
        $result.outcome = 'failed'
        $result.phase = $failurePhase
        $result.message = if ($closure.confirmed) {
            'Operation failed. Effective host policy confirms the endpoint is disabled; Linux acceptance remains separate.'
        } else {
            'Operation failed. Endpoint closure could not be confirmed; inspect the protected journal before further use.'
        }
        $result.checks += [ordered]@{
            id = 'endpoint_closure'; result = $(if ($closure.confirmed) { 'PASS' } else { 'FAIL' })
            detail = 'Effective default-deny and disabled endpoint readback; no packet-level inference.'
        }
        $result.checks += [ordered]@{ id = 'failure_stage'; result = 'FAIL'; detail = $stage }
        $result.checks += [ordered]@{ id = 'recovery_action'; result = 'BLOCKED'
            detail = (Get-WslEgressRecoveryInstruction $stage) }
        $result.checks += [ordered]@{
            id = 'exception_class'; result = 'FAIL'
            detail = $_.Exception.GetType().Name + ':line=' + [string]$_.InvocationInfo.ScriptLineNumber
        }
        if ($state -and -not $completionWritten) {
            $completion = [ordered]@{
                schema_version = 1; operation_id = [string]$result.operation_id
                generation = [long]$state.generation; action = $Action
                outcome = 'failed'; phase = $failurePhase; backend = [string]$state.backend
                completed_at = (Get-Date -Format o)
            }
            try {
                Save-WslEgressJson $completion (Join-Path $env:LOCALAPPDATA ('ClashOfRust\WslEgress\results\' + [string]$result.operation_id + '.json'))
            } catch { }
        }
        return $result
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

Export-ModuleMember -Function Invoke-WslEgressOperation,New-WslEgressResponse,Invoke-WslEgressGuardianAudit,Test-WslEgressGuardianServicePath,Invoke-WslEgressScopeRenewal
