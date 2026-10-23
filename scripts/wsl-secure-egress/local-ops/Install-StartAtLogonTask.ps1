#Requires -Version 5.1
<#
.SYNOPSIS
  Installs the logon autostart script and its scheduled task.

.DESCRIPTION
  Copies Start-AtLogon.ps1 from this directory into a stable ProgramData
  location (the task must not point at a temp or repository path) and registers
  'ClashOfRust-WslEgress-Autostart': AtLogOn for the current user, highest
  privileges, 30 s delay.

  Run elevated. Idempotent: re-running replaces the script and re-registers the
  task with the same name.

  Removing it:
    Unregister-ScheduledTask -TaskName 'ClashOfRust-WslEgress-Autostart' -Confirm:$false
    Remove-Item 'C:\ProgramData\ClashOfRust\WslEgress-Autostart' -Recurse
#>
[CmdletBinding()]
param(
    [string]$Source = (Join-Path $PSScriptRoot 'Start-AtLogon.ps1'),
    [string]$DestDir = 'C:\ProgramData\ClashOfRust\WslEgress-Autostart',
    [string]$TaskName = 'ClashOfRust-WslEgress-Autostart'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principalCheck = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principalCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This installer must run elevated.'
}

$LogPath = Join-Path $DestDir 'install.log'
function Write-Log([string]$Text) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    $line | Out-File -FilePath $LogPath -Append -Encoding utf8
    Write-Host $line
}

if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Source script missing: $Source" }
New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
$Dest = Join-Path $DestDir 'Start-AtLogon.ps1'
Copy-Item -LiteralPath $Source -Destination $Dest -Force
Write-Log ("script installed: " + $Dest)

$me = $identity.Name
$action = New-ScheduledTaskAction `
    -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
    -Argument ('-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Dest + '"')

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
try { $trigger.Delay = 'PT30S' } catch { Write-Log ('delay not applied: ' + $_.Exception.Message) }

$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force `
    -Description 'Restores the WSL Secure Egress WireGuard transport once at user logon. Does nothing when the tunnel is already open.' | Out-Null
Write-Log ("task registered: " + $TaskName + " user=" + $me)

$task = Get-ScheduledTask -TaskName $TaskName
Write-Log ("state=" + $task.State + " principal=" + $task.Principal.UserId + "/" +
    $task.Principal.LogonType + "/" + $task.Principal.RunLevel + " delay=" + $task.Triggers[0].Delay)
Write-Log 'done'
exit 0
