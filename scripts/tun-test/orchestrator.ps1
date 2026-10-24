param([string]$TestName = "baseline", [string]$PatchJson = "")
$ErrorActionPreference = "Continue"
$data = "$env:LOCALAPPDATA\clash-of-rust\ClashOfRust\data"
function Set-ProxyMode([string]$mode){
  $f = "$data\settings.json"
  $raw = [IO.File]::ReadAllText($f)
  $fixed = [regex]::Replace($raw, '"proxy_mode"\s*:\s*"[a-z]+"', ('"proxy_mode": "' + $mode + '"'))
  [IO.File]::WriteAllText($f, $fixed, (New-Object System.Text.UTF8Encoding($false)))
}
function Stop-Clash {
  Stop-Process -Name clash-of-rust -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  Stop-Process -Name mihomo -Force -ErrorAction SilentlyContinue
  Get-Process -Name clash-tun-launcher -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
}
$sec = (Get-Content "$data\settings.json" -Raw | ConvertFrom-Json).secret
$H = @{ Authorization = "Bearer $sec" }
$samples = "$env:TEMP\tun30\samples_$TestName.csv"
"time,metaAdapter,metaHasIP,metaV4Def,metaV6Def,ctrlTun,ctrlStack" | Out-File $samples -Encoding ascii
try {
  Stop-Clash
  Set-ProxyMode "tun"
  Remove-Item "$env:TEMP\tun30\core_debug.log" -ErrorAction SilentlyContinue
  # log capture: start after core is down, before new core starts
  $tmpF = $env:TEMP.Replace([char]92, [char]47)
  $cfg = $tmpF + '/tun30/curl.cfg'
  $cfgLines = @(
    'silent',
    'no-buffer',
    'max-time = 75',
    'retry = 20',
    'retry-delay = 1',
    'retry-connrefused',
    ('header = "Authorization: Bearer ' + $sec + '"'),
    'url = "http://127.0.0.1:9090/logs?level=debug"',
    ('output = "' + $tmpF + '/tun30/core_debug.log"')
  )
  [IO.File]::WriteAllLines($cfg, $cfgLines)
  Start-Process curl.exe -ArgumentList @('--config', $cfg) -WindowStyle Hidden
Start-Process "D:\Clash\Clash of Rust\clash-of-rust.exe"
  $t0 = Get-Date
  $patched = $false
  for($i=0; $i -lt 11; $i++){
    Start-Sleep -Seconds 3
    $meta = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "Meta" }).Count
    $ip = @(Get-NetIPAddress -InterfaceAlias Meta -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like "198.18.*" }).Count
    $v4 = @(Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -eq "Meta" }).Count
    $v6 = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -eq "Meta" }).Count
    $tun = ""; $stack = ""
    try { $c = Invoke-RestMethod "http://127.0.0.1:9090/configs" -Headers $H -TimeoutSec 2; $tun = $c.tun.enable; $stack = $c.tun.stack } catch {}
    ("{0},{1},{2},{3},{4},{5},{6}" -f (Get-Date -Format "HH:mm:ss"),$meta,$ip,$v4,$v6,$tun,$stack) | Out-File $samples -Append -Encoding ascii
    if(-not $patched -and $PatchJson -ne "" -and $tun -ne ""){
      try {
        Invoke-RestMethod -Method Patch -Uri "http://127.0.0.1:9090/configs" -Headers $H -ContentType "application/json" -Body '{"tun":{"enable":false}}' -TimeoutSec 3 | Out-Null
        Start-Sleep -Seconds 1
        Invoke-RestMethod -Method Patch -Uri "http://127.0.0.1:9090/configs" -Headers $H -ContentType "application/json" -Body $PatchJson -TimeoutSec 3 | Out-Null
        "PATCHED at t+$($i*3)s: $PatchJson" | Out-File $samples -Append -Encoding ascii
        $patched = $true
      } catch { "patch failed: $($_.Exception.Message)" | Out-File $samples -Append -Encoding ascii }
    }
  }
  try {
    $u1 = (Invoke-WebRequest -Uri "https://ipgw.neu.edu.cn/" -UseBasicParsing -TimeoutSec 6 -Proxy "http://127.0.0.1:17890").StatusCode
  } catch { $u1 = "ERR" }
  try {
    $u2 = (Invoke-WebRequest -Uri "https://api.okinto.com/" -UseBasicParsing -TimeoutSec 6 -Proxy "http://127.0.0.1:17890").StatusCode
  } catch { $u2 = "ERR" }
  "URLCHECK ipgw=$u1 okinto=$u2" | Out-File $samples -Append -Encoding ascii
} finally {
  Stop-Clash
  Set-ProxyMode "system"
  Start-Process "D:\Clash\Clash of Rust\clash-of-rust.exe"
  Start-Sleep -Seconds 14
  $pe = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings").ProxyEnable
  $pm = (Get-Content "$data\settings.json" -Raw | ConvertFrom-Json).proxy_mode
  try { $r1 = (Invoke-WebRequest -Uri "https://ipgw.neu.edu.cn/" -UseBasicParsing -TimeoutSec 8 -Proxy "http://127.0.0.1:17890").StatusCode } catch { $r1 = "ERR" }
  "ROLLED-BACK proxy_mode=$pm ProxyEnable=$pe ipgw=$r1" | Out-File $samples -Append -Encoding ascii
}
