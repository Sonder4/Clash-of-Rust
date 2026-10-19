#Requires -Version 5.1
[CmdletBinding()]
param([string]$BridgeDirectory = "$PSScriptRoot\..\..\..\..\uac-bridge")
$worker = Join-Path $PSScriptRoot 'Cor-UacWorker.ps1'
if(-not (Test-Path $worker)){ throw "worker missing: $worker" }
$ready=Join-Path $BridgeDirectory 'WORKER-READY.txt'
if(Test-Path $ready){ Write-Output 'worker already ready'; exit 0 }
& sudo.exe --new-window pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $worker -BridgeDirectory $BridgeDirectory