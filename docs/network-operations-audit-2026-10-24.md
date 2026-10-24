# 2026-10-24 网络操作与脚本审计记录

> 范围：2026-10-22 15:01 至 2026-10-24 01:2x 的本机会话（含 `F:\Codex\Clash-of-Rust-work`
> 与 `E:\Desktop\workspace\Project\Clash-of-Rust` 两个工作目录），重点记录所有网络相关
> 操作、探测命令、脚本执行和观察到的状态变化。会话历史由本机 JSONL transcript 解析，
> 并与仓库文档、系统状态和日志交叉核对。本文档由用户明确要求创建；创建文档本身
> 不改变任何网络配置。
>
> 脱敏：不记录真实 VPS/主机端点、WireGuard 密钥、控制器 secret、完整订阅 URL。
> 命令中的 `<VPS-IPv4-ENDPOINT>`、`<VPS-IPv6-ENDPOINT>`、`<CAMPUS-IP>`、
> `<OKINTO-IP>`、`<CONTROLLER-SECRET>` 均为占位符，真实值只在根私有配置或本机
> 安全位置读取，不得回填到本文档或提交到 Git。

## 1. 结论摘要

1. **本次诊断轮（2026-10-24 01:0x–01:2x）没有修改任何网络配置。** 实际执行的都是
   `Get-*` 查询、文件/日志读取、mihomo 控制器 `GET`、`curl` 连通性探测、WSL 内
   `ip`/`wg show`/`nft list` 只读命令，以及只读的 UI 截图。没有 `Set-*`、`New-*`、
   `Remove-*`，没有控制器 `PUT/POST`，没有点击 UI，没有重启服务，没有改
   防火墙/路由/DNS/代理，没有执行 `ipconfig /flushdns`。
   **但会话历史中确有网络写入：** 2026-10-23 20:41:58（本地）把 Clash
   `settings.json` 的 `run_mode` 从 `global` 改为 `rule`，备份为
   `%TEMP%\wsl-egress-migration-20261023T\clash-settings.before.json`。这是与
   DeepSeek/TUN 现象最相关的历史写入；详见 §10、§11。§2 的“本轮无写入”仅指
   01:0x–01:2x 的诊断轮，不代表整个会话。
2. **最后一次读取到的应用状态是“系统代理”模式，TUN 关闭**：
   - 控制器：`tun.enable=False`，`mode=rule`；
   - Windows：`Meta` 适配器已消失，默认路由只剩 WLAN；
   - UI：`系统代理` 高亮，`TUN` 未选中。
   因此“通过 TUN 访问 DeepSeek”在当前状态下必然失败——TUN 没有开启；这不是本轮
   命令造成的。
3. **观察到一次模式切换，但本会话没有对应的写操作**：01:14 控制器
   `tun.enable=True`、两个关键地址 302/200；01:16 变为 `tun.enable=False`、Meta
   适配器/默认路由消失、UI 显示系统代理；`settings.json` 的修改时间为 01:20:05，
   由应用侧写入。Chrome 维护器日志没有应用 overlay（其 `state.json`/`overlay.yaml`
   仍是 10/15 的旧文件），WSL 代码没有对 Clash 控制器的写操作。具体是界面操作还是
   应用自动切换，现有日志无法进一步归因；但可以排除 01:0x–01:2x 诊断轮的命令写入。
   更早的 `run_mode` 写入是另一件事，见 §10。
4. **Clash of WSL 不是主机 TUN 回环的原因**：其 Windows 侧变更仅限 `.wslconfig`
   （WSL 范围）和 Hyper-V 防火墙设置/单条 endpoint 规则；没有主机路由、主机防火墙、
   DNS/NRPT、系统代理或网卡修改。它唯一的 Clash 变更是手动脚本插入的一条
   `IP-CIDR ... DIRECT`，用途是防止 VPS 端点被代理规则再次捕获，属于反回环措施。
5. **DeepSeek 经当前系统代理可达**：`chat.deepseek.com` 返回 429（WAF/限流），
   `www.deepseek.com` 返回 200，`api.deepseek.com` 返回 401（需要鉴权）。这证明
   代理链路可达；TUN 模式未开启，不能据此判断 TUN 路径。**注意：** 10/23 的
   `run_mode` 从 `global` 改为 `rule` 后，DeepSeek 按 `GeoSite CN -> DIRECT`
   走直连；历史 `global` 模式下它走所选节点。这是 DeepSeek 路由变化的直接候选
   原因，详见 §11。
6. **WSL 隧道当前是活的**：最近一次 WireGuard 握手在 1 分钟内，双向计数正常，
   nft forward 链有对应 accept 计数。没有证据表明 WSL 功能造成主机 TUN 回环。

## 2. 本次诊断轮（2026-10-24 01:0x–01:2x）

### 2.1 系统状态只读查询

| 类别 | 代表命令 | 目的 | 改变状态 |
| --- | --- | --- | --- |
| Windows 防火墙 | `Get-NetFirewallRule`、`Get-NetFirewallAddressFilter`、`Get-NetFirewallApplicationFilter`、`Get-NetFirewallPortFilter`、`Get-NetFirewallProfile` | 读取 `ClashOfRust-*` 规则、程序路径、方向、动作、Profile | 否 |
| Hyper-V 防火墙 | `Get-NetFirewallHyperVRule`、`Get-NetFirewallHyperVVMSetting`、`Get-NetFirewallHyperVProfile` | 读取 WSL VM creator 策略和 endpoint 规则 | 否 |
| 网卡/路由/IP | `Get-NetAdapter`、`Get-NetAdapterStatistics`、`Get-NetIPAddress`、`Get-NetRoute`、`Get-NetIPInterface`、`Find-NetRoute` | 读取 Meta/WLAN/WSL 适配器、默认路由、接口 metric | 否 |
| 连接/端口 | `Get-NetTCPConnection -OwningProcess <pid>`、`Get-Process`、`Get-CimInstance Win32_Process` | 读取 mihomo/launcher/app 连接与启动时间 | 否 |
| DNS | `Get-DnsClientServerAddress`、`Get-DnsClientNrptRule`、`Resolve-DnsName`、`[System.Net.Dns]::GetHostAddresses()`、`Get-DnsClientCache` | 读取 DNS 服务器、NRPT、解析结果和缓存 | 否（查询可能刷新缓存条目） |
| 代理 | 读取 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings`、`system-proxy.json`、`netsh winhttp show proxy`、Chrome 策略注册表 | 读取系统代理、WinHTTP、Chrome 代理/DoH 策略 | 否 |
| 服务/任务 | `Get-CimInstance Win32_Service`、`Get-ScheduledTask`、`Get-ScheduledTaskInfo` | 读取 Clash/WSL 服务、计划任务及最近结果 | 否 |
| 文件/日志 | `Get-Content`、`Test-Path`、`Get-Item` | 读取 `settings.json`、`config.yaml`、`.wslconfig`、WSL `state.json`、Chrome 维护器日志 | 否 |
| 源码检索 | `rg`、`sed`、`Read` | 审查 WSL 功能是否写主机路由/防火墙/DNS/代理 | 否 |
| UI | CUA `list_windows`、`get_window_state` | 截图查看代理模式；无点击、无按键 | 否 |

代表性命令（均为只读）：

```powershell
Get-NetFirewallRule | Where-Object { $_.Group -like 'ClashOfRust*' } |
  ForEach-Object {
    $app = $_ | Get-NetFirewallApplicationFilter
    $addr = $_ | Get-NetFirewallAddressFilter
    [pscustomobject]@{ Name=$_.Name; Enabled=$_.Enabled; Direction=$_.Direction;
      Action=$_.Action; Program=$app.Program; Remote=$addr.RemoteAddress }
  }

Get-NetAdapter -Name Meta -ErrorAction SilentlyContinue |
  Get-NetAdapterStatistics |
  Format-List ReceivedBytes,SentBytes

Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
  Select-Object ifIndex,NextHop,RouteMetric,Protocol

Resolve-DnsName api.okinto.com
[System.Net.Dns]::GetHostAddresses('api.okinto.com')
Get-DnsClientCache | Where-Object { $_.Entry -match 'deepseek|okinto|ipgw' }
```

读取到的关键规则/状态（不包含真实远端地址）：

- `ClashOfRust-Strict-Core-VpsOnly`：Enabled，Outbound，Block，Program =
  `D:\Clash\resources\mihomo.exe`（该路径已不存在）；RemoteAddresses 为“除两个已配置
  VPS 端点外的全部地址”的取反集合。当前核心位于
  `C:\Program Files\Clash of Rust Network\mihomo.exe`，因此该规则当前不匹配当前核心。
- `ClashOfRust-Chrome-NoDirect-Physical`、`ClashOfRust-Strict-Chrome-Remote`、
  `ClashOfRust-Strict-Chrome-LoopbackTCP`、`ClashOfRust-Strict-Chrome-LoopbackUDP`：
  Enabled；只针对 `chrome.exe`；阻断非 loopback，只允许 loopback TCP 17890，
  loopback UDP 全阻断。
- 四条 `ClashOfRust-Strict-DNS-*`：Disabled。
- `ClashOfRust-WslEgress-Endpoint`（Hyper-V）：Enabled，Outbound，Allow；
  VM creator 策略为 `DefaultInbound=Block`、`DefaultOutbound=Block`、
  `LoopbackEnabled=False`、`AllowHostPolicyMerge=False`。
- Windows 防火墙三个 Profile 均 Enabled，默认动作 `NotConfigured`。
- DNS：TUN 开启时 Meta 使用 `198.18.0.2`，WLAN 使用校园 DNS；TUN 关闭后只剩 WLAN
  的校园 DNS。无 NRPT 规则。
- 系统代理：`ProxyEnable=1`，`ProxyServer=127.0.0.1:17890`；WinHTTP 为直接访问；
  Chrome 策略为 `fixed_servers`、`127.0.0.1:17890`、DoH secure、QUIC 禁用。
- 服务：`ClashOfRust.Network` 运行中；`ClashOfRust.WslEgress`（`clash-wsl-guardian.exe`）
  运行中。
- 计划任务：`ClashOfRust-Chrome-Listener` 运行中（Python Chrome 维护器）；
  `ClashOfRust-S-1-5-...` 指向已不存在的 `D:\Clash\clash-of-rust.exe`（失败）；
  `ClashOfRust-WslEgress-Autostart` 已运行（00:55，结果 0）；
  `ClashOfRust-WslEgress-Renew` 指向主包 `Renew-ScopeAttestation.ps1`（01:14，结果 0）。

### 2.2 网络连通性探测

探测只产生瞬时连接和 DNS 查询，不改变配置。

| 时间/状态 | 目标/命令 | 结果 | 说明 |
| --- | --- | --- | --- |
| 01:14，TUN 开启 | `curl -sS -o NUL -w '%{http_code}' https://ipgw.neu.edu.cn/` | 302 | 关键校园地址正常 |
| 01:14，TUN 开启 | 同上，`https://api.okinto.com/` | 200 | 关键 API 正常 |
| 01:16，TUN 关闭 | 同两条直连 `curl` | 000，TLS/连接超时 | 详见 2.3 的 fake-IP 缓存说明 |
| TUN 关闭后 | `curl -v https://api.okinto.com/` | 解析到 `198.18.0.22`，连接超时 | 旧 TUN 会话留下的 fake-IP 缓存；当时 Meta 路由已消失 |
| 系统代理模式 | `curl -x http://127.0.0.1:17890 https://ipgw.neu.edu.cn/` | 302 | 经当前系统代理正常 |
| 系统代理模式 | 同上，`https://api.okinto.com/` | 200 | 经当前系统代理正常 |
| 绕过 DNS | `curl --resolve ipgw.neu.edu.cn:443:<CAMPUS-IP> ...` | 302 | 证明底层直连路径可用 |
| 绕过 DNS | `curl --resolve api.okinto.com:443:<OKINTO-IP> ...` | 200 | 证明底层直连路径可用 |
| 系统代理模式 | `curl -x http://127.0.0.1:17890 https://chat.deepseek.com/` | 429 | WAF/限流；链路可达 |
| 系统代理模式 | 同上，`https://www.deepseek.com/` | 200 | 链路可达 |
| 系统代理模式 | 同上，`https://api.deepseek.com/` | 401 | 需要鉴权；链路可达 |
| 系统代理模式 | `Test-NetConnection <CAMPUS-IP> -Port 443` | True，经 WLAN | 直连 TCP 可达 |
| 系统代理模式 | `Test-NetConnection <OKINTO-IP> -Port 443` | True，经 WLAN | 直连 TCP 可达 |
| 系统代理模式 | `Test-NetConnection <CAMPUS-GATEWAY> -Port 443` | False | 该端口本来不应开放，属预期 |
| 01:22 左右 | `Resolve-DnsName` / `Get-DnsClientCache` | 真实地址 | 缓存中已无 198.18.x 的 okinto/ipgw 记录；DeepSeek 为真实 WAF 地址 |

说明：01:16 的 000 不是“WSL 改了主机网络”，而是 TUN 关闭后 Windows DNS 缓存仍保留
旧的 fake-IP，应用继续连接 `198.18.x` 而无路由。该缓存后来恢复为真实地址；本轮没有
执行 `flushdns`。

### 2.3 mihomo 控制器只读查询

命令（只读；secret 不打印）：

```powershell
$s = Get-Content "$env:LOCALAPPDATA\clash-of-rust\ClashOfRust\data\settings.json" -Raw |
     ConvertFrom-Json
$base = "http://127.0.0.1:$($s.controller_port)"
$headers = @{ Authorization = "Bearer $($s.secret)" }   # 仅内存使用，不输出
Invoke-RestMethod "$base/configs"      -Headers $headers
Invoke-RestMethod "$base/connections"  -Headers $headers
Invoke-RestMethod "$base/rules"        -Headers $headers
```

观测值：

| 时间 | `mode` | `tun.enable` | `tun.stack` | 连接数/流量 | 备注 |
| --- | --- | --- | --- | --- | --- |
| 01:14 左右 | rule | True | Mips | 43 条，约 25.7 MB 上行 / 236.5 MB 下行 | 关键地址 302/200；Meta 适配器 Up |
| 01:16 左右 | rule | False | Mixed | 125 条，约 48.9 MB / 311.5 MB | Meta 适配器消失；系统代理模式 |
| 01:20 左右 | rule | False | — | — | DeepSeek 经系统代理测试 |

规则表（10 条，按顺序，远端地址脱敏）：

```text
GeoSite category-ads-all -> REJECT
GeoSite CN               -> DIRECT
GeoIP cn                 -> DIRECT
IPCIDR <VPS-IPv4-ENDPOINT>/32   -> DIRECT
IPCIDR <VPS-IPv6-ENDPOINT>/128  -> DIRECT
DomainSuffix neu.edu.cn  -> DIRECT
DomainSuffix neu.edu     -> DIRECT
DomainSuffix okinto.com  -> DIRECT
DomainSuffix ckff.dev    -> DIRECT
Match                    -> XUAN-VPS
```

没有 DeepSeek 专用规则；DeepSeek 属于 CN 分类，落到 `GeoSite CN -> DIRECT`。
没有对控制器发过 `PUT`/`POST`/`PATCH`。

### 2.4 WSL 只读查询

命令（只读；`wg show` 会打印公钥，本文档不记录）：

```powershell
wsl.exe -d Ubuntu-26.04 -u root -- sh -c '
  ip netns list
  ip netns exec cor-egress-gw ip -brief addr
  ip netns exec cor-egress-gw ip route
  ip netns exec cor-egress-gw wg show
  ip netns exec cor-egress-transport ip route
  nft list ruleset
  cat /var/lib/cor-egress/state.json
'
```

观测值：

- 命名空间：`cor-egress-gw`、`cor-egress-transport` 存在。
- `wg0` 在 `cor-egress-gw`，地址 `<WIREGUARD-TUNNEL-ADDRESS>`；peer endpoint 为
  `<VPS-IPv4-ENDPOINT>:51820`。
- 最近握手：第一次读取约 22 秒前，最终复查约 1 分钟内；transfer 约 59.34 KiB 接收、
  78.38 KiB 发送。
- `cor-egress-gw` 的 `default dev wg0` 是命名空间内的默认路由，不是外层 UDP 的实际
  路径；外层 UDP socket 位于 `cor-egress-transport`，其路由把
  `<VPS-IPv4-ENDPOINT>` 指向 `cor-ut0`，再由根命名空间 `cor-et0` → `eth0` 转发。
- nft `forward` 链有精确的 accept 计数：约 386 包 / 91,064 字节出，190 包 / 66,088
  字节入；配套 masquerade。
- Linux `state.json` 的 `phase=Running`，`forward_sources=[]`，无 Docker 字段。
- 未执行 `Start`/`Stop`/`wg set`/`nft` 写操作；没有重启 WSL。

### 2.5 UI 只读

- 使用 CUA `list_windows(pid=62460)` 和 `get_window_state(..., include_screenshot=true)`
  读取窗口；没有 `click`、`type_text`、`press_key`。
- 01:16 左右截图显示：`系统代理` 高亮，`TUN` 未选中；顶部“系统代理已连接”；
  当前节点 `XUAN-VLESS-IPV4`；80 条活跃连接；累计流量约 58.7 MiB 上行 / 302.5 MiB 下行。
- 该截图是状态证据，不是操作。

### 2.6 文件/日志读取

读取但未修改：

- `C:\Users\xuan\AppData\Local\clash-of-rust\ClashOfRust\data\settings.json`
- 同目录 `system-proxy.json`、`runtime\config.yaml`
- `C:\Users\xuan\.wslconfig`
- `C:\Users\xuan\AppData\Local\ClashOfRust-chrome\maintain-chrome-clash.py`
  及其 `runtime\maintainer.log`、`runtime\state.json`、`runtime\overlay.yaml`
- `C:\Users\xuan\AppData\Local\ClashOfRust\WslEgress\*` 下的只读状态/结果
- WSL `/var/lib/cor-egress/state.json`、`/etc/cor-egress/profile.json` 的字段名（未复制
  私钥/peer 公钥值）
- 仓库内 WSL 脚本、文档、`apps/desktop/src/platform/windows/service/*.rs`、
  `crates/client-core/src/config/mod.rs` 等

## 3. 观察到的状态变化与归因

| 时间（+08:00） | 事件 | 证据 | 归因/说明 |
| --- | --- | --- | --- |
| 10-24 00:45:50 | `clash-tun-launcher` 的一个进程启动 | `Win32_Process.CreationDate` | 应用/服务侧；不是本轮命令 |
| 00:55:00 | `ClashOfRust-WslEgress-Autostart` 运行，结果 0 | `Get-ScheduledTaskInfo` | 登录任务；调用产品 Start |
| 00:55:18（会话记录） | 产品 Start 成功，`phase=connected_unverified`，端点 Enabled | 会话历史摘要；当前状态以实时读取为准 | 见 4.2；不是本轮诊断命令 |
| 01:01:56 | GUI `clash-of-rust.exe` 启动 | 进程 CreationDate | 应用重启 |
| 01:01:59 | `clash-tun-launcher.exe --windows-bridge` 启动 | 进程命令行 | 应用桥接 |
| 01:02:00 | `mihomo.exe` 启动 | 进程 CreationDate | 内核 |
| 01:03:12 | `system-proxy.json` 写入 | 文件 mtime | 应用侧启用系统代理 |
| 01:14 左右 | 控制器 `tun.enable=True`；关键地址 302/200；43 条连接 | 控制器 `GET /configs`、`/connections`；curl | TUN 当时可用 |
| 01:16 左右 | 控制器 `tun.enable=False`；Meta 适配器/默认路由消失；UI 系统代理 | 控制器 GET；`Get-NetAdapter`/`Get-NetRoute`；CUA 截图 | 模式切换；不是本轮命令 |
| 01:17:05 | Chrome 维护器日志 `controller-not-owned-by-installed-clash` | `maintainer.log` | 维护器未应用 overlay；其 state/overlay 仍是 10/15 |
| 01:20:05 | `settings.json` 写入 | 文件 mtime | 应用侧写入；本轮只读取过该文件 |
| 01:20–01:22 | DeepSeek 经系统代理 429/200/401；DNS 缓存恢复真实地址 | curl、`Get-DnsClientCache` | 代理链路可达 |

归因结论：

- 本会话没有对 mihomo 控制器执行 `PUT`/`POST`，没有调用 `Set-*`/`New-*`/`Remove-*`，
  没有 UI 点击，没有服务重启；`settings.json` 和 `system-proxy.json` 的写入来自应用侧。
- Chrome 维护器明确拒绝在 TUN 开启时应用 overlay
  （`live-tun-enabled-no-overlay-reload`），日志中也没有成功应用记录；其状态文件未更新。
- WSL 功能代码没有对 Clash 控制器的写操作；只有 `Set-WslEgressClashDirectRule.ps1`
  会编辑当前订阅的规则文件，且需要操作者手动运行、应用重启后生效。
- 现有日志无法证明 01:14→01:16 的模式切换具体由谁触发（界面、应用自动策略或其他）；
  但可以确认不是本会话的诊断命令。

## 4. 本会话较早的授权操作（历史）

> 以下操作发生在本次诊断之前；细节以对应文档和会话记录为准。它们不会被本记录重新
> 执行，也不代表当前状态。

### 4.1 Ubuntu-22.04 空间清理（2026-10-24，非网络配置）

命令/结果详见
[ubuntu22-cleanup-plan-2026-10-23.md](wsl-secure-egress/ubuntu22-cleanup-plan-2026-10-23.md) §8。
概要：

```bash
rm -rf /root/quarantine-root-repo-copy-20261018/target
journalctl --vacuum-size=100M
apt-get clean
rm -rf ~/.cache/pip ~/.cache/fontconfig ~/.cache/camoufox ~/.rustup ~/.cargo
apt-get purge -y llvm-14-dev
```

- 结果：`/` 已用约 30 GB 降至约 6.6 GB，回收约 23.4 GB。
- 保留：`claude-desktop`、`llvm-14`/`clang-14`、`/var/lib/cor-egress`、
  `/etc/cor-egress`、`/usr/local/lib/cor-egress`。
- 清理前隧道已处于 fail-closed（`phase=blocked`、端点规则 `Enabled=False`）；清理项
  不涉及 cor-egress。清理本身不是网络配置变更，但改变了 WSL 文件系统。

### 4.2 Plan B：WSL 重启 + 登录自动恢复

1. 安装登录任务：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-StartAtLogonTask.ps1
   ```
   - 复制 `Start-AtLogon.ps1` 到
     `C:\ProgramData\ClashOfRust\WslEgress-Autostart\`。
   - 注册计划任务 `ClashOfRust-WslEgress-Autostart`（AtLogOn、当前用户、最高权限、
     30 秒延迟）。
   - 该脚本本身只注册任务，不立即改网络；任务运行时才调用产品 `Start`。

2. 重启 WSL：
   ```powershell
   wsl.exe --shutdown
   ```
   - 影响：所有 WSL 发行版停止，WSL 网络命名空间消失；属于网络状态变更。
   - 之后由登录任务/手动任务重新启动 manager 和隧道。

3. 产品 `Start` 尝试（通过 `Invoke-ProductAction.ps1`）：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-ProductAction.ps1 -Action Start -Execute
   ```
   - 第 1 次：`outcome=blocked`，提示强制 Windows 连接不健康，未开始网络变更。
   - 第 2 次：通过基线后失败在 `scope_renewal_task`，`RuntimeException` 约
     `WslSecureEgress.psm1:520`（基线抛错）。
   - 第 3 次：失败在 `endpoint_enable`，`RuntimeException` 约 `WslSecureEgress.psm1:2005`
     （启用后基线/补偿），端点被留在禁用状态。
   - 最终在 00:55:18 成功：基线 5/5 通过，`phase=connected_unverified`，
     `endpoint_enabled=True`，检查项 PASS，刷新任务结果 0。
   - 详细记录见 [DIAGNOSIS_2026-10-23.md](wsl-secure-egress/DIAGNOSIS_2026-10-23.md)、
     [TEST_STATUS.md](wsl-secure-egress/TEST_STATUS.md) 和交接文档 §24。

4. 成功后的数据面异常（历史观察）：
   - WSL 出网 000、Windows 关键地址 000、WireGuard 握手变旧、应用 0.6.0 TUN 节点
     0 B/s。
   - 当时系统代理记录曾变为 `ProxyEnable=0`、`ProxyServer=127.0.0.1:7897`；应用随后
     在 01:01:56 重启。
   - 该异常与当前的系统代理/TUN 状态不同；本节只记录历史，不据此下结论。

5. 当前计划任务（本次只读读取）：
   - `ClashOfRust-WslEgress-Autostart`：Ready，00:55 运行，结果 0。
   - `ClashOfRust-WslEgress-Renew`：Ready，指向主包
     `C:\Program Files\Clash of Rust\resources\wsl-secure-egress\Renew-ScopeAttestation.ps1`，
     01:14 运行，结果 0，下一次约 01:15。
   - `ClashOfRust-Chrome-Listener`：Running，Python 维护器，日志显示
     `controller-not-owned-by-installed-clash` / `waiting-for-clash-owned-core`。
   - `ClashOfRust-S-1-5-...`：Ready，指向已不存在的 `D:\Clash\clash-of-rust.exe`，
     失败码 `0x80070002`；旧安装残留。

### 4.3 Ubuntu-26.04 manager 迁移（2026-10-23，历史）

- run 1 执行到 `04-rollback` 成功，随后进程冻结；journal 停在 `restored`、
  `endpoint_enabled=false`，发行版停止，关键地址 302/200。该管理员进程是安全残留，
  没有与新 Install 竞争。
- run 2 脚本已通过语法检查/plan-only 演练，但两次 UAC 提权均被取消，未执行。
- 迁移是否完成、当前 manager 归属，以迁移文档和实时状态为准；本节只记录操作历史，
  不重新宣称验收完成。详见
  [DIAGNOSIS_2026-10-23.md](wsl-secure-egress/DIAGNOSIS_2026-10-23.md) §9。

## 5. 脚本清单

| 脚本/文件 | 路径 | 本轮是否执行 | 是否改网络 | 结果/回退 |
| --- | --- | --- | --- | --- |
| `Install-StartAtLogonTask.ps1` | `scripts/wsl-secure-egress/local-ops/` | 会话较早执行过 | 否（只注册任务） | 任务已安装；回退：`Unregister-ScheduledTask` + 删除目录 |
| `Start-AtLogon.ps1` | 同上（安装到 `C:\ProgramData\ClashOfRust\WslEgress-Autostart\`） | 由任务在 00:55 执行 | 是（调用产品 `Start`） | 结果 0；回退：产品 `Stop`/`Rollback` |
| `Invoke-ProductAction.ps1` | 同上 | 会话较早多次执行 `Start` | 是（取决于 Action） | 见 4.2；回退：产品 `Stop`/`Rollback` |
| `Start-WslEgressAndVerify.ps1` | 同上 | 本轮未执行 | 是（`-Execute` 时） | 未运行，无结果 |
| `Migrate-ManagerDistro.ps1` | 同上 | 历史迁移使用过同源脚本 | 是（破坏性） | run 1 到 rollback 后冻结；run 2 未执行 |
| `Set-WslEgressClashDirectRule.ps1` | `scripts/wsl-secure-egress/` | 本轮未执行 | 改 Clash 订阅规则（需重启应用） | 规则已存在于当前运行配置；回退：用脚本备份/恢复订阅 |
| `wsl-diag.sh`、`verify-egress.sh`、`post-restart-check.sh`、`payload-diag.sh`、`hostip-discovery-check.sh`、`mnt-c-leak-check.sh`、`exposure-check.sh` | `scripts/wsl-secure-egress/local-ops/diagnostics/` | 本轮未执行（只读审阅） | 否（除 `failclosed-test.sh`） | 只读脚本；不改变主机配置 |
| `failclosed-test.sh` | 同上 | 未执行 | 是（删除 WSL guard 表） | 未运行；不应在他人使用窗口执行 |
| `maintain-chrome-clash.py` | `C:\Users\xuan\AppData\Local\ClashOfRust-chrome\` | 非本会话编写/执行；由计划任务运行 | 否（只经控制器加 listener；TUN 开启时拒绝 overlay） | 日志显示当前无法识别核心；无状态文件更新 |
| `Renew-ScopeAttestation.ps1` | 安装包主包 `resources\wsl-secure-egress\` | 由计划任务在 01:14 执行 | 审计/可能关闭端点 | 结果 0；不是主机 TUN 操作 |
| `Start-AtLogon` 产品包 `Manage-WslSecureEgress.ps1` | `C:\Program Files\Clash of Rust\resources\wsl-secure-egress\` | 通过上述包装脚本间接调用 | 是（Start） | 见 4.2 |

内联一次性脚本（本次诊断，全部只读）：

- 防火墙规则/地址/程序/端口查询
- 网卡、路由、IP metric、TCP 连接、进程启动时间查询
- DNS 服务器、NRPT、`Resolve-DnsName`、`.NET Dns`、DNS 缓存查询
- 系统代理/WinHTTP/Chrome 策略读取
- mihomo `GET /configs`、`GET /connections`、`GET /rules`
- WSL `ip netns`、`ip route`、`wg show`、`nft list ruleset`、`state.json` 读取
- CUA 只读窗口截图

## 6. 未执行/禁止项

- 没有执行 `ipconfig /flushdns`。
- 没有在 UI 上点击/切换 TUN、系统代理或任何按钮。
- 没有执行 `Set-NetFirewallRule`、`New-NetFirewallRule`、`Remove-NetFirewallRule`、
  `New-NetRoute`、`Remove-NetRoute`、`Set-DnsClient*`、`netsh` 写操作、注册表写操作。
- 没有对 mihomo 控制器发 `PUT`/`POST`/`PATCH`。
- 没有启动/停止/重启 Clash、mihomo、WSL 服务或发行版。
- 没有创建/删除防火墙规则、Hyper-V 规则、计划任务。
- 没有提交或推送 Git。
- 外部 `curl`/DNS 查询只用于状态审查；会产生瞬时连接和 DNS 缓存条目，但不改变配置。
  自用户要求“只做历史/状态审查”后，未再发起新的外部探测。

## 7. 只读复查命令（安全）

以下命令只读，可用于复核当前状态；不要把输出中的真实地址、密钥或 secret 粘贴到
文档/Git：

```powershell
# 代理模式与 TUN 状态（secret 不打印）
$s = Get-Content "$env:LOCALAPPDATA\clash-of-rust\ClashOfRust\data\settings.json" -Raw |
     ConvertFrom-Json
$h = @{ Authorization = "Bearer $($s.secret)" }
Invoke-RestMethod "http://127.0.0.1:$($s.controller_port)/configs" -Headers $h |
  Select-Object mode,@{n='tun';e={$_.tun.enable}},@{n='stack';e={$_.tun.stack}}

# 默认路由与 Meta 适配器
Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
  Select-Object ifIndex,NextHop,RouteMetric,Protocol
Get-NetAdapter -Name Meta -ErrorAction SilentlyContinue

# 关键规则（只输出名称/状态，不输出远端地址）
Get-NetFirewallRule | Where-Object { $_.Group -like 'ClashOfRust*' } |
  Select-Object Name,Enabled,Direction,Action

# DNS 缓存
Get-DnsClientCache | Where-Object { $_.Entry -match 'deepseek|okinto|ipgw' }
```

```powershell
# WSL 隧道只读（输出中的公钥请自行脱敏）
wsl.exe -d Ubuntu-26.04 -u root -- sh -c '
  ip netns exec cor-egress-gw wg show
  ip netns exec cor-egress-gw ip route
  nft list ruleset
'
```

## 8. 限制与结论

- 本记录基于系统状态、控制器 API、进程/文件时间戳和日志，没有抓包；不能据此宣称
  任意网络、任意时刻的零泄漏或端到端验收。
- 01:14→01:16 的模式切换只能确定“不是 01:0x–01:2x 诊断轮的命令”，无法从现有日志
  确定具体触发者；更早的 `run_mode` 写入见 §10。
- 当前 TUN 关闭、系统代理模式；DeepSeek 经系统代理可达（429/200/401）。但在
  `run_mode=rule` 下 DeepSeek 走 `GeoSite CN -> DIRECT`，与历史 `global` 模式的
  “全量代理”不同；这是 DeepSeek 路由变化的直接候选原因，见 §11。若要测试 TUN，
  需要由用户在应用界面切换；切换后可能仍需处理旧 fake-IP DNS 缓存。本轮未做
  这些修改。
- `ClashOfRust-Strict-Core-VpsOnly` 当前指向不存在的旧核心路径，属于应用旧版保护
  残留；Chrome 严格规则仍会影响 Chrome。是否清理需另行授权，不能在本轮自动删除。
- Clash of WSL 的 Windows 侧变更不包含主机路由/防火墙/DNS/代理；其唯一 Clash 变更
  （VPS 端点 DIRECT 规则）是反回环措施。当前 WSL 握手/nft 计数正常，不支持“WSL 功能
  导致主机 TUN 回环”的结论。

## 9. 会话历史补充：2026-10-22 的网络与系统操作

> 以下时间均为本地 UTC+8；transcript 原始时间为 UTC。该日主要工作目录是
> `F:\Codex\Clash-of-Rust-work`（另一个 checkout），不是当前项目目录。该日的
> 操作是本次会话历史的一部分，不能与 2026-10-24 的只读诊断轮混为一谈。

### 9.1 状态变更表

| 本地时间 | 操作 | 结果/影响 | 回退或备注 |
| --- | --- | --- | --- |
| 20:12–20:38 | 通过 UAC 执行 `ClashOfWsl.ps1 -Action Install -Execute` 与 `-Action Start -Execute` 多次 | 20:24:10 `Install` 以 adoption 方式成功（`phase=installed_closed`）；随后 `Start` 失败（`phase=failed_closed_requested`，端点 `Enabled=False`）；期间有安装被 blocked、UAC 取消 | 产品 `Stop`/`Rollback`；端点保持关闭 |
| 20:20–20:22 | 两个发行版内修改 DNS/resolver：`systemctl disable --now systemd-resolved`、`systemctl mask systemd-resolved`、`ln -sfn /mnt/wsl/resolv.conf /etc/resolv.conf`，随后写静态 `/mnt/wsl/resolv.conf` 与 `/etc/resolv.conf` | 首次 `audit-config` 报 `owned_config_matches=False`；改为静态文件后 20:22:31 报 `outcome=succeeded`、`owned=True`。WSL 的 DNS 路径被改变 | 操作前有 resolv.conf/resolved 状态备份；可恢复备份并重新启用 resolved。产品也会在自身生命周期内管理该文件 |
| 20:30 | 删除 `inet cor_egress_boot_emergency` 表；执行 `/usr/local/lib/cor-egress/manager stop` | `manager stop` 成功，`phase=Guarded`；隧道停止，共享 deny guard 保留 | 需要恢复时由产品 `Start` 或 boot hook/manager guard 重建 |
| 21:32–21:36 | WSL 26.04 内配置 Chrome 与 Claude Desktop 的 APT 源：下载签名 key、写 `/etc/apt/sources.list.d`、执行包管理操作 | 安装/配置了 WSL 内软件源；不是 Windows 主机代理/DNS/路由设置。期间访问了 Google/Anthropic 相关下载域 | 删除对应 sources/key 文件即可撤销；本轮未重新访问这些域 |
| 22:37 | `wsl.exe --terminate Ubuntu-26.04` 后冷启动，测试 boot guard | WSL 网络命名空间/接口重建；用于验证 boot hook 行为 | 再次启动发行版；不需要主机网络回滚 |
| 22:53–00:01 | WSL 内 `wg set wg0 listen-port 51821`、`wg set wg0 peer ... endpoint ...`、`persistent-keepalive`，并强制握手/抓包 | 修改的是 WSL 内 WireGuard 运行时参数，不是持久 profile；用于定位握手路径 | 重新 `wg set` 回原值或由 manager 重建 wg0；本轮未重新核验所有临时值 |
| 23:21–23:50 | SSH 到 VPS 做临时诊断：读取 `wg`/`ufw`/`nft`；设置 peer `persistent-keepalive 25`；添加临时 nft 计数链；临时监听 53/443/444/500/1194/8080/10443/51820/51997 UDP；临时 UFW 放行 | 用于判断 VPS 是否收到握手；随后执行了清理/恢复，恢复 444/udp 与 51820/udp，检查服务健康 | 会话内已清理临时监听/规则并检查；本轮未重新 SSH 复核。`persistent-keepalive` 是否仍保留需单独核对 |
| 23:57–23:58 | `Set-NetFirewallHyperVRule -Name 'ClashOfRust-WslEgress-Endpoint' -PolicyStore PersistentStore -Enabled True`（手动测试） | 打开仅允许固定 VPS 端点的 Hyper-V 出站规则，用于握手实验 | 可改回 `Enabled False`，或由产品 `Stop`/恢复流程关闭 |
| 10/23 02:23 | `Manage-WslSecureEgress.ps1 -Action Stop -Execute` | 关闭旧 WSL egress generation；端点关闭，进入 fail-closed | 产品 `Start`/`Rollback`；详见 §4.2 |

### 9.2 该日明确没有做的事

- 没有用 `New-NetFirewallRule`/`Set-NetFirewallRule`/`Remove-NetFirewallRule` 修改
  Windows Defender 主机防火墙规则；只有 Hyper-V 防火墙规则（§9.1 最后两行）。
- 没有用 `New-NetRoute`/`Set-NetRoute`/`Remove-NetRoute` 修改 Windows 主机路由。
- 没有用 `Set-DnsClient`/`Register-DnsClient` 修改 Windows 主机 DNS；DNS 改动发生在
  WSL 发行版内部（resolv.conf/systemd-resolved）。
- 没有写系统代理注册表；没有执行 `ipconfig /flushdns`。
- 没有修改 Clash 的 `run_mode`/`proxy_mode`（那是 10/23 的事，见 §10）。

## 10. 会话历史补充：2026-10-23 的关键写入（含 run_mode）

### 10.1 `run_mode` 从 `global` 改为 `rule`（最重要的一处）

**修改前**（备份 `clash-settings.before.json`，文件 mtime 19:36:36）：

```text
run_mode   = global
proxy_mode = tun
```

**修改时间**：2026-10-23 20:41:58（本地）。
**修改对象**：`C:\Users\xuan\AppData\Local\clash-of-rust\ClashOfRust\data\settings.json`。
**备份**：`C:\Users\xuan\AppData\Local\Temp\wsl-egress-migration-20261023T\clash-settings.before.json`。

执行的命令（没有输出 secret）：

```powershell
$src = 'C:\Users\xuan\AppData\Local\clash-of-rust\ClashOfRust\data\settings.json'
$bak = 'C:\Users\xuan\AppData\Local\Temp\wsl-egress-migration-20261023T\clash-settings.before.json'
Copy-Item -LiteralPath $src -Destination $bak -Force
$text = [IO.File]::ReadAllText($src)
if ($text -notmatch '(?m)^  "run_mode": "global",\r?\n') { throw 'run_mode line not found; aborting.' }
$updated = [regex]::Replace($text, '(?m)^  "run_mode": "global",', '  "run_mode": "rule",')
[IO.File]::WriteAllText($src, $updated, (New-Object Text.UTF8Encoding($false)))
```

**结果**：`run_mode now = rule`，`proxy_mode = tun`，文件 723 → 721 字节。
**当前状态**：`run_mode=rule`；`proxy_mode=system`（这是之后应用/界面侧的变化，
不是这条命令改的）；最近一次读取 TUN 为关闭。

**为什么改**：WSL 的 WireGuard 端点需要在 Clash 里保持一条
`IP-CIDR <VPS-端点>/32,DIRECT` 直连规则；`global` 模式会绕过规则，端点和 SSH
可能被再次投进代理节点，导致隧道无法建立。`rule` 模式是让 WSL 直连规则生效的
前提。现有规则表的第一条直连规则就是这条反回环措施。

**回退**：把备份文件恢复回 `settings.json` 会回到 `global`，但会破坏 WSL 的
端点直连规则，可能导致 WSL 隧道/SSH 再次失败。不要在没有替代方案时直接回退。
更精确的做法是保留 `rule`，只为需要代理的域名加一条定向规则（见 §11）。

### 10.2 10/23 的其他状态变更

| 本地时间 | 操作 | 结果/影响 | 回退/备注 |
| --- | --- | --- | --- |
| 20:00 | 迁移 run 1：`wsl --shutdown`、安装/迁移、`04-rollback` | 执行到 rollback 成功后进程冻结；journal 停在 `restored`、端点关闭；系统保持安全 | 详见 [DIAGNOSIS_2026-10-23.md](wsl-secure-egress/DIAGNOSIS_2026-10-23.md) §9；run 2 两次 UAC 被取消，未执行 |
| 20:04 / 20:44 / 20:52 | `wsl.exe --shutdown`，随后重启 26.04/执行 autostart | WSL 网络重建；用于测试 boot guard、autostart 和握手恢复 | 重新启动发行版；不涉及主机路由/DNS |
| 21:13 | 在 26.04 内执行 `failclosed-test.sh`（删除 guard 表） | 验证 fail-closed；随后通过 manager guard/autostart 恢复 | 该脚本是破坏性诊断；只应在隔离窗口使用 |
| 21:14 | `Set-NetFirewallHyperVRule ... -Enabled True`（endpoint-only 测试） | 打开固定端点 Hyper-V 出站规则 | 改回 `Enabled False` 或产品 `Stop` |
| 00:39–00:55（10/24） | 多次 `Start-ScheduledTask ClashOfRust-WslEgress-Autostart`，其间 `wsl --shutdown`、基线复验 | 00:55:18 产品 `Start` 成功：`phase=connected_unverified`、端点 Enabled、检查 PASS | 产品 `Stop`/`Rollback`；当前任务仍在，最近结果 0 |
| 00:29–00:34（10/24） | Ubuntu-22.04 空间清理（`rm -rf`、journal vacuum、apt clean、camoufox/rustup/llvm-14-dev 删除） | 非网络配置；释放约 23.4 GB | 详见 [ubuntu22-cleanup-plan](wsl-secure-egress/ubuntu22-cleanup-plan-2026-10-23.md) §8 |
| 01:0x–01:2x（10/24） | 本次诊断：只读查询/探测 | 未改配置；详见 §2 | 无回退项 |

## 11. DeepSeek 与 `run_mode` 专项

### 11.1 路由差异

| 模式 | DeepSeek 的路由 | 结果 |
| --- | --- | --- |
| 修改前：`run_mode=global`、`proxy_mode=tun` | 所有流量走当前节点 `XUAN-VLESS-IPV4` → VPS | DeepSeek 被代理；不依赖校园到中国的直连路径 |
| 修改后：`run_mode=rule` | 规则表 `GeoSite CN -> DIRECT`，DeepSeek 属于 CN 分类 | DeepSeek 走 DIRECT；在 TUN 下走直连，在系统代理下也按规则走直连 |
| 当前 | `run_mode=rule`、`proxy_mode=system`、TUN 关闭 | 经系统代理访问 DeepSeek：`chat` 429（WAF/限流）、`www` 200、`api` 401（鉴权）；网络可达 |

### 11.2 结论

1. **`run_mode` 的修改是 DeepSeek 路由变化的直接原因候选。** 它把 DeepSeek 从
   “全局代理”改成了“按 CN 规则直连”。如果直连路径（校园 → 中国境内目标）在某个
   时刻不通，TUN 下就会表现为无法访问；这不需要 WSL 功能参与。
2. **不能简单改回 `global`。** `global` 会绕过 WSL 的 VPS 端点直连规则，可能让
   WireGuard 外层 UDP 被投进代理节点，导致隧道/SSH 失败。这是两个目标之间的冲突。
3. **更精确的修复（未执行）**：保持 `rule`，为 DeepSeek 增加定向代理规则，例如
   `DOMAIN-SUFFIX,deepseek.com,XUAN-VPS`（以及实际使用的子域），并在修改前备份
   `settings.json`/当前订阅、确认规则顺序、重启核心后验证。任何此类修改都需要
   用户明确授权；本轮不执行。
4. **当前 TUN 是关闭的**（系统代理模式）。因此现在无法用“TUN 访问”复现；若要
   测试，需要在应用界面切到 TUN。切换后可能需要处理旧 fake-IP DNS 缓存。本轮
   未做这两件事。
5. `chat.deepseek.com` 的 429 是 WAF/限流响应，不等于链路不通；`www` 200、
   `api` 401 已证明当前代理路径可达。TUN 路径的失败需要单独的实时 `/connections`
   和规则命中证据，不能从当前系统代理结果推断。

## 12. 完整状态变更清单（按本地时间，节选汇总）

| 本地时间 | 类型 | 操作 | 结果 | 回退/引用 |
| --- | --- | --- | --- | --- |
| 10/22 20:12–20:38 | Hyper-V/WSL | product Install/Start 多次（UAC） | Install adoption 成功；Start 失败、端点关闭 | §9.1；产品 Stop/Rollback |
| 10/22 20:20–20:22 | WSL DNS | disable/mask systemd-resolved；重写 resolv.conf | 最终 audit owned=True | §9.1；恢复备份/resolved |
| 10/22 20:30 | WSL nft/manager | 删除 emergency 表；manager stop | phase=Guarded | §9.1；产品 Start/guard |
| 10/22 21:32–21:36 | WSL 软件源 | Chrome/Claude Desktop APT key/source | WSL 软件源变更 | §9.1；删除 sources/key |
| 10/22 22:37 | WSL | `wsl --terminate 26.04` 冷启动 | 网络重建 | §9.1 |
| 10/22 22:53–00:01 | WSL WireGuard | `wg set` 临时端口/端点/keepalive | 运行时参数变化 | §9.1；manager 重建 |
| 10/22 23:21–23:50 | VPS | SSH 临时 UFW/监听/nft/keepalive | 临时探测后清理/恢复 | §9.1；本轮未重新 SSH 复核 |
| 10/22 23:57–23:58 | Hyper-V | 手动启用 endpoint 规则 | 固定端点被放行 | §9.1；改回 False/产品 Stop |
| 10/23 02:23 | WSL/Hyper-V | 产品 `Stop -Execute` | 旧 generation 关闭 | §4.2/§9.1；产品 Start/Rollback |
| 10/23 20:00 | WSL | 迁移 run 1 + rollback | 停在 restored，安全 | DIAGNOSIS §9；run 2 未执行 |
| 10/23 20:41 | Clash 设置 | `run_mode` global → rule | DeepSeek 改为 DIRECT | §10–§11；备份可恢复但会破坏 WSL 直连 |
| 10/23 21:13 | WSL nft | `failclosed-test.sh` 删除 guard | 验证 fail-closed 后恢复 | §10.2；manager guard/autostart |
| 10/23 21:14 | Hyper-V | endpoint 规则 Enabled True | 端点放行 | §10.2；改回 False/产品 Stop |
| 10/23 20:04/20:44/20:52；10/24 00:39 | WSL | `wsl --shutdown` 多次 | 网络重建 | §10.2 |
| 10/24 00:39–00:55 | WSL/Hyper-V | autostart 重试；产品 Start | 00:55:18 成功，connected_unverified | §4.2/§10.2；产品 Stop/Rollback |
| 10/24 00:29–00:34 | 非网络 | Ubuntu-22.04 清理 | 释放约 23.4 GB | 清理文档 §8 |
| 10/24 01:0x–01:2x | 只读 | 本次诊断查询/探测 | 未改配置 | §2 |

> 本表是状态变更的汇总；完整命令与证据见 §9、§10 和各引用文档。没有列出的
> `Get-*`、`curl`、DNS、控制器 `GET`、WSL `show/list` 等只读操作见 §2 与 §13。

## 13. 分析方法、统计与限制

### 13.1 分析对象

- 本机会话 transcript：41,305,553 字节、16,506 行 JSON、2,224 次 `Bash` 工具调用；
  另有 169 次 `Edit`、132 次 `Read`、83 次 `Write`、7 次 `Agent`。
- 时间范围：2026-10-22 15:01 至 2026-10-24 01:28（本地 UTC+8）。
- 两个工作目录：`F:\Codex\Clash-of-Rust-work`（较早）与
  `E:\Desktop\workspace\Project\Clash-of-Rust`（当前）。
- 网络相关行：2,153 条；强变更候选：111 条（人工筛选后，排除 `grep`/`sed` 查看、
  `rm _dbg*.ps1` 等非网络操作）；脚本执行候选：61 条；UI 点击：3 次（1 次因截图
  会话不匹配被拒绝、1 次侧栏导航、1 次“断开·留保护”尝试；应用因受信资源检查拒绝，
  未发送 Stop、未改变网络）。
- 只读探测类别（按命令关键字匹配，允许重叠）：`Get-Net*`/路由/DNS 129；WSL
  `ip`/`wg`/`nft`/manager 读取 214；`curl`/HTTP 197；DNS 查询 17；
  `Test-NetConnection` 11；mihomo 控制器 `GET` 46；SSH 只读 44；进程/服务/任务
  106。详细分类见 §2。
- 外部请求：2 次 `WebFetch`（Anthropic 支持页、wsl-vpnkit README）；1 次终端
  `pwsh` 版本查询；若干 `curl`/DNS/控制器 `GET` 探测。
- SSH：读取了 `~/.ssh/config` 的 Host/HostName/User/Port 结构；未读取私钥正文；
  VPS 操作只使用既有 host 别名和 BatchMode。

### 13.2 限制

- transcript 的命令/结果可能被截断；本文档是人工汇总，不是逐字转录。
- 时间统一换算为本地 UTC+8；个别操作可能跨越午夜，表中已尽量按本地日期标注。
- 历史操作的结果以会话记录和现有文档为准；本轮没有重新执行或重新登录 VPS 复核
  每一个历史步骤（尤其是 VPS 临时 UFW/keepalive 的最终残留状态）。
- 没有抓包和完整链路验收；不能把本文档当作“零泄漏”或端到端验收结论。
- 真实 VPS/校园地址、WireGuard 私钥、控制器 secret、订阅 URL 均未写入本文档；
  命令中的占位符不得回填。
- 2026-10-22 的操作在另一个 checkout 中完成，源码/脚本版本可能与当前项目不同；
  以当时的 transcript 和对应文档为准。

### 13.3 仍需单独授权的后续项

1. 若要让 DeepSeek 在 TUN 下走代理而保留 WSL 直连：评估并测试
   `DOMAIN-SUFFIX,deepseek.com,XUAN-VPS` 类定向规则；需要备份、规则顺序检查、
   应用重启和 TUN 实测。本轮未执行。
2. 若要清理旧的应用保护残留：评估 `ClashOfRust-Strict-Core-VpsOnly`（指向不存在的
   `D:\Clash\resources\mihomo.exe`）与 Chrome 严格规则；需要确认它们是否仍被使用，
   不能在本轮自动删除。
3. 若要复核 VPS 临时诊断的最终状态：需要单独 SSH 只读检查 UFW、nft、wg keepalive；
   本轮未执行。
4. 若要把 `run_mode` 恢复为 `global`：不建议在 WSL 端点直连规则仍需要时执行；
   这会破坏隧道/SSH 的前提。应先设计替代规则。
