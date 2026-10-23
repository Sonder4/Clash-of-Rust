#Requires -Version 5.1
# Runs one product action elevated and captures its JSON response to a file.
param(
    [Parameter(Mandatory=$true)][string]$Action,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Package = 'C:\Program Files\Clash of Rust\resources\wsl-secure-egress\Manage-WslSecureEgress.ps1'
$LogDir = (Join-Path $env:TEMP 'clash-of-rust-wsl-egress')
$OutFile = Join-Path $LogDir ('action-' + $Action.ToLowerInvariant() + '.json')

# Array splatting binds POSITIONALLY, so "-Action","Stop" would arrive as the
# value of the first parameter. Named splatting needs a hashtable.
$params = @{ Action = $Action }
if ($Execute) { $params['Execute'] = $true }
$raw = & $Package @params
$text = ($raw | Out-String).Trim()
[IO.File]::WriteAllText($OutFile, $text, (New-Object Text.UTF8Encoding($false)))
Write-Host ($Action + ' -> ' + $OutFile)
Write-Host $text
