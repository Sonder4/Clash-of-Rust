#Requires -Version 5.1
# Offline: parse only definitions, with no UAC, WSL, network or filesystem writes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '../Invoke-WslSecureEgressElevated.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    [IO.Path]::GetFullPath($source), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Elevated helper contains PowerShell parse errors.' }
$addType = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Add-Type'
}, $true)
Add-Type -TypeDefinition $addType.CommandElements[2].Value
$definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Convert-BridgeArguments'
}, $true)
Invoke-Expression $definition.Extent.Text

$script:Assertions = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:Assertions++
}
function Assert-Rejected([object[]]$Values, [string]$Name) {
    $rejected = $false
    try { $null = Convert-BridgeArguments $Values } catch { $rejected = $true }
    Assert-True $rejected $Name
}
$valid = @('-Action','Start','-Backend','WireGuard','-Execute')
$parsed = Convert-BridgeArguments $valid
Assert-True ($parsed.Action -ceq 'Start' -and $parsed.Execute) 'allowlisted start accepted'
Assert-Rejected @('-Action','Doctor','-Backend','WireGuard','-Execute') 'readonly request rejected'
Assert-Rejected @('-Action','Start','-Backend','WireGuard') 'missing execute rejected'
$testing = Convert-BridgeArguments @('-Action','Test','-Backend','WireGuard')
Assert-True ($testing.Action -ceq 'Test' -and -not $testing.ContainsKey('Execute')) 'explicit privileged test accepted without execute'
Assert-Rejected @('-Action','Test','-Backend','WireGuard','-Execute') 'test cannot masquerade as mutation'
Assert-Rejected ($valid + @('-Command','Get-Process')) 'arbitrary command flag rejected'
Assert-Rejected ($valid + @('-Execute')) 'duplicate switch rejected'
Assert-Rejected ($valid + @('-Backend','WireGuard')) 'duplicate value flag rejected'
Assert-Rejected ($valid + @('-ProfilePath','\\server\share\profile.json')) 'UNC credential surface rejected'
Assert-Rejected ($valid + @('-ProfilePath','C:\private\..\profile.json')) 'profile traversal rejected'
Assert-Rejected ($valid + @('-ProfilePath','C:\private\profile.json:stream')) 'alternate stream rejected'
Assert-Rejected ($valid + @('-ProfilePath','C:\private\$injected.json')) 'interpolation rejected'
Assert-Rejected ($valid + @('-EndpointPort','65536')) 'invalid port rejected'
Assert-Rejected ($valid + @('-EndpointIPv4','127.0.0.1')) 'loopback endpoint rejected'
Assert-Rejected ($valid + @('-EndpointIPv4','10.0.0.1')) 'private endpoint rejected'
Assert-Rejected ($valid + @('-Distro','Ubuntu;calc')) 'invalid distro rejected'
$parsed = Convert-BridgeArguments ($valid + @('-ProfilePath','C:\private folder\profile.json'))
Assert-True ($parsed.ProfilePath -ceq 'C:\private folder\profile.json') 'local profile with spaces preserved'

$memory = New-Object IO.MemoryStream
[CorWslUacPeer]::WriteFrame($memory, '{"outcome":"blocked"}')
$memory.Position = 0
$bytes = [CorWslUacPeer]::ReadFrame($memory, 1024)
Assert-True ([Text.Encoding]::UTF8.GetString($bytes) -ceq '{"outcome":"blocked"}') 'length framed response roundtrip'
$memory.Dispose()
foreach ($frame in @(
    [byte[]]@(0,0,0,0),
    [byte[]]@(1,0,16,0),
    [byte[]]@(4,0,0,0,1)
)) {
    $memory = New-Object IO.MemoryStream(,$frame)
    $rejected = $false
    try { $null = [CorWslUacPeer]::ReadFrame($memory, 1048576) } catch { $rejected = $true }
    Assert-True $rejected 'zero oversized or truncated frame rejected'
    $memory.Dispose()
}
[pscustomobject]@{
    suite = 'elevation-offline'
    result = 'PASS'
    assertions = $script:Assertions
    uac = 'NOT_RUN'
    network = 'NOT_RUN'
    wsl_started = $false
} | ConvertTo-Json -Compress
exit 0
