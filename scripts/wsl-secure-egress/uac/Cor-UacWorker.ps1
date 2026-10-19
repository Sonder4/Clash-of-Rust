#Requires -Version 5.1
[CmdletBinding()]
param([string]$BridgeDirectory = "$PSScriptRoot\..\..\..\..\uac-bridge")
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Inbox = Join-Path $BridgeDirectory 'inbox'
$Staging = Join-Path $BridgeDirectory 'staging'
$Outbox = Join-Path $BridgeDirectory 'outbox'
$Ready = Join-Path $BridgeDirectory 'WORKER-READY.txt'
$Stop = Join-Path $BridgeDirectory 'STOP'
$Log = Join-Path $BridgeDirectory 'worker.log'
function Log([string]$m) { Add-Content -LiteralPath $Log -Value ((Get-Date -Format o)+' '+$m) }
function IsElevated {
  $who = (& whoami.exe /groups 2>&1 | Out-String)
  $admin = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  return $admin -and ($who -match 'S-1-16-(12288|1688)')
}
if (-not (IsElevated)) { Log 'refused: high-integrity administrator token required'; exit 1 }
foreach($d in @($Inbox,$Outbox)) { New-Item -ItemType Directory -Force -Path $d | Out-Null; & icacls.exe $d /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' /T /C | Out-Null }
New-Item -ItemType Directory -Force -Path $Staging | Out-Null
$me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& icacls.exe $Staging /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' ($me+':(OI)(CI)M') /T /C | Out-Null
Remove-Item -LiteralPath $Stop -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath $Ready -Value (Get-Date -Format o)
Log ('online pid='+$PID)
try {
  while(-not (Test-Path -LiteralPath $Stop)) {
    foreach($s in @(Get-ChildItem -LiteralPath $Staging -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Where-Object Name -match '^[0-9a-f]{32}\.ps1$')) {
      $job = Join-Path $Inbox $s.Name; Move-Item -LiteralPath $s.FullName -Destination $job -Force
      $id=$s.BaseName; $out=Join-Path $Outbox ($id+'.stdout.txt'); $err=Join-Path $Outbox ($id+'.stderr.txt'); $done=Join-Path $Outbox ($id+'.done')
      Log ('start '+$s.Name); $p=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$job) -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -Wait -WindowStyle Hidden
      $doc=[ordered]@{job=$s.Name;exit_code=[int]$p.ExitCode;succeeded=([int]$p.ExitCode -eq 0);stdout=(Get-Content $out -Raw -ErrorAction SilentlyContinue);stderr=(Get-Content $err -Raw -ErrorAction SilentlyContinue);finished_at=(Get-Date -Format o)}
      [IO.File]::WriteAllText($done,($doc|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false))); Log ('finish '+$s.Name+' exit='+$p.ExitCode)
    }
    Start-Sleep -Milliseconds 700
  }
} finally { Remove-Item -LiteralPath $Ready -Force -ErrorAction SilentlyContinue; Log 'offline' }