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
    [string]$PackageStage = 'F:\Codex\cor-package-stage',
    [string]$ManifestDirectory = 'F:\Codex\cor-upload-manifest',
    [string]$Repository = 'F:\Codex\Clash-of-Rust-work',
    [string]$JobDirectory = 'F:\Codex\admin-job',
    [string]$InstallationRoot = "$env:ProgramFiles\Clash of Rust WSL",
    [string]$ProfilePath = "$env:LOCALAPPDATA\ClashOfRust\WslEgress\profile.json",
    [string]$TestDistro = 'Ubuntu-26.04',
    [switch]$NoSelfElevation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    $tokenText = (& whoami.exe /groups 2>&1 | Out-String)
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
        '-InstallationRoot', $InstallationRoot,
        '-ProfilePath', $ProfilePath,
        '-TestDistro', $TestDistro,
        '-NoSelfElevation'
    )
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
        $sudoArguments = @('--new-window', 'powershell.exe') + $args
        $sudoOutput = @(& 'C:\Windows\System32\sudo.exe' @sudoArguments 2>&1)
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
    $result = @(& icacls.exe $Path /inheritance:r /grant:r @rules /T /C 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ('ACL repair failed for {0}: {1}' -f $Path, (($result | Out-String).Trim()))
    }
}

function Assert-Readable {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Expected file is not readable: $Path"
    }
    $null = [IO.File]::OpenRead($Path)
}

function Invoke-Wsl {
    param([Parameter(Mandatory)][string]$Command)
    $out = @(& wsl.exe -d $TestDistro -u root --exec /bin/sh -c $Command 2>&1)
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
    $start.FileName = (Join-Path $env:SystemRoot 'System32\wsl.exe')
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
        vps_ipv4 = '62.84.164.122'
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
    $nft = Invoke-Wsl '/usr/sbin/nft list tables'
    if ($nft.ExitCode -ne 0 -or
        (($nft.Output -join "`n") -notmatch 'cor_egress_guard')) {
        throw 'Linux fail-closed nftables guard is missing.'
    }
}

try {
    $proof = Test-HighIntegrity
    Write-JobLog ('identity user={0} high={1} administrator={2}' -f
        $proof.User, $proof.High, $proof.Administrator)
    if (-not $proof.High -or -not $proof.Administrator) {
        Start-SelfElevated
    }

    Write-JobLog 'stage 1a: restore the protected WireGuard profile'
    $profileRestore = Invoke-Native -FilePath 'powershell.exe' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $Repository 'scripts\wsl-secure-egress\Restore-WslEgressProfile.ps1'),
        '-ProfilePath', $ProfilePath, '-Execute'
    ) -StageName 'RestoreProfile'
    $profileResponse = (($profileRestore | Out-String).Trim() | ConvertFrom-Json)
    if ([string]$profileResponse.outcome -ne 'succeeded' -or
        -not [bool]$profileResponse.hash_matches -or
        -not [bool]$profileResponse.schema_valid) {
        throw 'The protected WireGuard profile restore did not pass validation.'
    }
    Write-JobLog 'stage 1a: profile restored with hash, schema and ACL checks'

    Write-JobLog 'stage 1: repair repository and staging ACLs'
    Set-ProtectedDirectoryAcl -Path $Repository -KeepUserAccess
    $adminHost = Join-Path (Split-Path -Parent $PSScriptRoot) 'admin-host'
    if (Test-Path -LiteralPath $adminHost -PathType Container) {
        Set-ProtectedDirectoryAcl -Path $adminHost -KeepUserAccess
    }
    Set-ProtectedDirectoryAcl -Path $PackageStage
    Set-ProtectedDirectoryAcl -Path $ManifestDirectory
    Assert-Readable (Join-Path $Repository '.git\HEAD')
    Write-JobLog 'stage 1: ACL and repository readback passed'

    Write-JobLog 'stage 2a: rebuild the stage from the reviewed repository'
    $stageBuilder = Join-Path $Repository 'scripts\wsl-secure-egress\Prepare-PackageStage.ps1'
    $stageBuild = Invoke-Native -FilePath 'powershell.exe' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $stageBuilder,
        '-Repository', $Repository, '-PackageStage', $PackageStage,
        '-Execute', '-Replace'
    ) -StageName 'PreparePackageStage'
    $stageResponse = (($stageBuild | Out-String).Trim() | ConvertFrom-Json)
    if ([string]$stageResponse.outcome -ne 'succeeded' -or
        [string]$stageResponse.package_stage -ne $PackageStage -or
        -not (Test-Path -LiteralPath (
            Join-Path $PackageStage 'resources\wsl-secure-egress\WslSecureEgress.psm1') -PathType Leaf)) {
        throw 'The reviewed package stage was not built and verified.'
    }
    Write-JobLog 'stage 2a: package stage rebuilt and receipt verified'

    Write-JobLog 'stage 2b: create and apply the protected package manifest'
    $upgrade = Join-Path $Repository 'scripts\wsl-secure-egress\Upgrade-Package.ps1'
    $manifest = Join-Path $ManifestDirectory 'cor-upgrade-manifest.json'
    $create = Invoke-Native -FilePath 'powershell.exe' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
        '-Action', 'CreateManifest', '-PackagePath', $PackageStage,
        '-ManifestPath', $manifest
    ) -StageName 'CreateManifest'
    Assert-Readable $manifest
    $digest = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
    $null = Invoke-Native -FilePath 'powershell.exe' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
        '-Action', 'Apply', '-InstallationPath', $InstallationRoot,
        '-PackagePath', $PackageStage, '-ManifestPath', $manifest,
        '-ExpectedManifestSha256', $digest
    ) -StageName 'Apply'
    $null = Invoke-Native -FilePath 'powershell.exe' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
        '-Action', 'Commit', '-InstallationPath', $InstallationRoot,
        '-PackagePath', $PackageStage
    ) -StageName 'Commit'
    Write-JobLog 'stage 2: package apply and commit passed'

    Write-JobLog 'stage 3: start the installed WireGuard egress broker'
    $manage = Join-Path $InstallationRoot 'resources\wsl-secure-egress\Manage-WslSecureEgress.ps1'
    $start = Invoke-Native -FilePath 'powershell.exe' -Arguments @(
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
    $checks.Add('public_ipv4=62.84.164.122')
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
