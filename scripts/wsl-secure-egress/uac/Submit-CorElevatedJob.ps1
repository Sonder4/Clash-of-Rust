#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path,[string]$BridgeDirectory = "$PSScriptRoot\..\..\..\..\uac-bridge",[int]$TimeoutSeconds=1800)
if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){throw "job missing: $Path"}
$ready=Join-Path $BridgeDirectory 'WORKER-READY.txt'; if(-not(Test-Path $ready)){throw 'worker is not ready; run Start-CorElevatedWorker.ps1'}
$staging=Join-Path $BridgeDirectory 'staging'; New-Item -ItemType Directory -Force -Path $staging | Out-Null
$id=[guid]::NewGuid().ToString('N'); Copy-Item -LiteralPath $Path -Destination (Join-Path $staging ($id+'.ps1')) -Force
$done=Join-Path (Join-Path $BridgeDirectory 'outbox') ($id+'.done'); $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
while((Get-Date)-lt $deadline){if(Test-Path $done){$r=Get-Content $done -Raw|ConvertFrom-Json; $r; if($r.succeeded){exit 0}else{exit [int]$r.exit_code}};Start-Sleep -Milliseconds 800}; throw 'timeout waiting for elevated worker'