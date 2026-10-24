# 2026-10-24 本机网络环境清点

> 范围：本机 Windows 11（26100）当前生效的网络配置、Clash of Rust / Clash of WSL
> 在本机留下的全部组件，以及准备迁移到 `D:\Clash` 的目标布局。
>
> 采集方式：只读查询（`Get-*`、`netsh ... show`、`sc qc`、`Get-ScheduledTask`、
> 控制器 `GET`、`curl` 探测）。写本文档不改变任何网络状态。
>
> 脱敏约定：VPS 端点记为 `<VPS-IPv4>` / `<VPS-IPv6>`，控制器 secret 不落文档。
> 校园网私网地址按原值记录（私网，非凭据）。

## 1. 当前状态摘要

| 项目 | 当前值 | 采集时间 |
| --- | --- | --- |
| 主程序 | Clash of Rust **0.6.1**（本地编译），`D:\Clash\Clash of Rust` | 2026-10-24 02:2x（迁移后） |
| 内核 | mihomo v1.19.32（随安装包） | 同上 |
| 运行模式 | `run_mode=rule`，`proxy_mode=system`（系统代理） | 同上 |
| TUN | 关闭（`tun.enable=false`）；开启方式与已知缺陷见 §19 | 同上 |
| 当前节点 | `XUAN-VPS` → `XUAN-VLESS-IPV6` | 同上 |
| 规则数 | 10 条 | 同上 |
| 出口 | 系统代理 `127.0.0.1:17890`，控制器 `127.0.0.1:9090` | 同上 |
| 关键连通性 | `ipgw.neu.edu.cn` = 302，`api.okinto.com` = 200 | 同上 |

## 2. 主机与链路

| ifIndex | 名称 | 类型 | 状态 | 说明 |
| --- | --- | --- | --- | --- |
| 12 | WLAN | Intel Wi-Fi 6 AX101 | Up 287 Mbps | 主用链路（校园网），默认路由 |
| 28 | 以太网 2 | VirtNet Network Adapter (NDIS 6.0) | Up 100 Mbps | 手机 USB 网络共享（Xiaomi） |
| 29 | 本地连接* 3 | Microsoft Wi-Fi Direct Virtual Adapter #4 | Up | 移动热点，`192.168.137.1/24` |
| 30 | 本地连接 | TAP-Windows Adapter V9 | Disconnected | 遗留虚拟网卡，未启用 |
| 66 | vEthernet (WSL (Hyper-V firewall)) | Hyper-V Virtual Ethernet | Up | WSL NAT，`172.19.96.1/20` |
| 14 | NEU-宽带 | Realtek PCIe GbE | Disconnected | 有线口未接 |
| 11 | 蓝牙网络连接 | Bluetooth PAN | Disconnected | — |

IPv4 关键地址：

- WLAN `172.22.94.221/16`（DHCP，校园网）
- 移动热点 `192.168.137.1/24`（手工）
- TAP 虚拟网卡 `172.20.252.161/24`（手工，遗留）
- WSL `172.19.96.1/20`（手工）

IPv6：WLAN 有 RA 地址（`2001:da8:9000:a835::/64` 段），校园网提供原生 IPv6。

## 3. DNS / 路由 / MTU / 指标

- **DNS**：仅 WLAN 配置了真实 DNS `202.118.1.29`、`202.118.1.53`（校园 DNS）；其余
  虚拟网卡是 `fec0:0:0:ffff::1-3` 占位。
- **NRPT**：无任何规则（`Get-DnsClientNrptRule` 为空）。历史上没有把 `.` 绑定到
  Clash 虚拟 DNS，这一点保持未变。
- **默认路由**：IPv4 仅 `0.0.0.0/0 → 172.22.255.254 (WLAN, metric 0/45)`；
  IPv6 仅 `::/0 → fe80::8205:88ff:feca:2df5 (WLAN, 256/45)`。
  TUN 关闭时无 `Meta` 适配器、无 TUN 路由残留。
- **MTU**：WLAN 1500；WSL 1500；启用 TUN 时 `Meta` 适配器为 9000（mihomo 默认，
  实测不影响代理下载，2 MB 下载 1.2 MB/s）。
- **接口指标**：本地连接 25、以太网 2 35、本地连接*3 45、WLAN 45、蓝牙 65、
  NEU-宽带 75、Loopback 75、WSL 5000。

## 4. 代理配置

| 层 | 值 |
| --- | --- |
| WinHTTP（`netsh winhttp`） | 直连，未设代理 |
| WinINET（当前用户） | `ProxyEnable=1`，`ProxyServer=127.0.0.1:17890`，`ProxyOverride=localhost;127.*;[::1];<local>`，无 PAC |
| 应用模式 | `proxy_mode=system`，由应用写入/维护 |

Chrome 额外由 WFP 强制（见 §8），系统代理不是唯一约束。

## 5. 已安装组件

| 路径 | 内容 | 版本 / 大小 | 来源 |
| --- | --- | --- | --- |
| `C:\Program Files\Clash of Rust` | 主程序、资源、内核、卸载器 | 0.6.0 / 142 MB | NSIS 安装包 |
| `C:\Program Files\Clash of Rust Network` | `clash-tun-launcher.exe`、`mihomo.exe`、`core.json` | 3 个文件 / 59.3 MB | 主程序运行时创建（`security.rs` 计算 `%ProgramFiles%\Clash of Rust Network`） |
| `C:\Program Files\Clash of Rust WSL` | `clash-wsl-guardian.exe` + `wsl-secure-egress` 模块 | 50 个文件 / 1.3 MB | Clash of WSL 独立安装器 |
| `C:\Users\xuan\AppData\Local\clash-of-rust\ClashOfRust\data` | 订阅、设置、运行时配置、日志 | 35.8 MB | 应用数据目录 |
| `C:\Users\xuan\AppData\Local\ClashOfRust-chrome` | Chrome 守护脚本、`ChromeProxyWfp.cs/.exe`、探针 | 0.1 MB | 2026-10-15 Chrome 修复轮 |
| `C:\ProgramData\ClashOfRust` | WSL 日志、状态、迁移快照 | 0.1 MB | Clash of WSL |

注册表卸载项：`HKLM\...\Uninstall\ClashOfRust`，`DisplayVersion=0.6.0`，
`InstallLocation=C:\Program Files\Clash of Rust`。

## 6. Windows 服务

| 服务名 | 显示名 | 启动 | 状态 | 二进制 |
| --- | --- | --- | --- | --- |
| `ClashOfRust.Network` | Clash of Rust Network | 手动 | 运行中 | `C:\Program Files\Clash of Rust Network\clash-tun-launcher.exe --windows-service` |
| `ClashOfRust.WslEgress` | Clash of Rust WSL Egress Audit | 自动 | 运行中 | `C:\Program Files\Clash of Rust WSL\clash-wsl-guardian.exe --service` |
| `WSLService` | — | 自动 | 运行中 | `C:\Program Files\WSL\wslservice.exe` |

`ClashOfRust.Network` 是主程序自己的提权宿主（命名管道
`\\.\pipe\ClashOfRust.Network.v1`），不是 WSL 功能的产物。

## 7. 计划任务

| 任务名 | 状态 | 触发 | 动作 | 备注 |
| --- | --- | --- | --- | --- |
| `ClashOfRust-S-1-5-21-...-1002` | Ready | 登录 | `D:\Clash\clash-of-rust.exe --background` | **失效**：指向已删除的旧 0.5.x 安装 |
| `ClashOfRust-Chrome-Listener` | 运行中 | 登录 | `pythonw ...\ClashOfRust-chrome\maintain-chrome-clash.py` | 维护 Chrome 的 4 条 WFP 规则 |
| `ClashOfRust-WslEgress-Autostart` | Ready | 登录 +30s | `%ProgramData%\ClashOfRust\WslEgress-Autostart\Start-AtLogon.ps1` | 2026-10-24 00:55 成功打开 WSL 隧道 |
| `ClashOfRust-WslEgress-Renew` | Ready | 登录 + 定时 | `...\Clash of Rust\resources\wsl-secure-egress\Renew-ScopeAttestation.ps1` | 最近一次 01:32 |
| `XUAN-VPS Orca SSH Tunnel` | Ready | 登录 | `ssh -4 -N -T -i C:\Users\xuan\.ssh\id_ed25519 ... -R 127.0.0.1:16768:127.0.0.1:6768 root@<VPS-IPv4>` | 旧 XUAN_VPS 轮次遗留，登录即建反向隧道 |
| `XUAN-VPS Mihomo TUN` | 禁用 | 登录 | `...\XUAN_VPS\runtime\start-mihomo-tun-task.ps1` | 旧轮次遗留，已禁用 |

## 8. Windows 防火墙（主机级）

Clash / Chrome 相关共 6 条出站规则，全部启用：

| 规则名 | 动作 | 程序 | 远端 |
| --- | --- | --- | --- |
| `Clash of Rust: block Chrome direct connections on physical adapters` | 阻止 | `chrome.exe` | 任意 |
| `Chrome: block every non-loopback destination on every network` | 阻止 | `chrome.exe` | 除回环外全部 |
| `Chrome: loopback TCP only to Clash proxy` | 阻止 | `chrome.exe` | `127.0.0.1`，端口 1-17889、17891-65535 |
| `Chrome: block loopback UDP and local DNS helper` | 阻止 | `chrome.exe` | `127.0.0.1` |
| `Mihomo: outbound only to configured German VPS addresses` | 阻止 | `D:\Clash\resources\mihomo.exe` | 除 `<VPS-IPv4>` / `<VPS-IPv6>` 外全部 |
| `DNS Client: block existing non-Clash interfaces` | 阻止（**已禁用**） | `svchost.exe` | 除回环外全部 |

前四条只作用于 `chrome.exe`，与主程序路径无关，但把 Chrome 回环代理端口写死为
**17890**。第五条目标程序 `D:\Clash\resources\mihomo.exe` 已不存在，属于永久不匹配的
死规则。第六条处于禁用状态。

入站放行（与本环境相关）：`sing-tun (…\Clash of Rust Network\mihomo.exe)`、
`mihomo-windows-amd64.exe`（WinGet 版）、`ClashMi` 两条、Playwright/ShardX 的
`chrome.exe`。这些是历史安装留下的放行项。

## 9. Hyper-V 防火墙与 WSL 策略

- 自定义规则：`ClashOfRust-WslEgress-Endpoint`（显示名 *Clash of Rust WSL managed
  endpoint*），**启用**，出站 Allow，作用域仅 WSL 虚机（UDP 51820 → `<VPS-IPv4>`）。
- WSL VM 策略 `{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}`：默认入站 Block、默认出站
  Block、Loopback 关闭。
- 以上两项只影响 WSL 虚机流量，**不改变宿主机路由、DNS、网卡或主机防火墙**。

## 10. 进程与监听端口

| PID | 进程 | 说明 |
| --- | --- | --- |
| 62460 | `clash-of-rust.exe` | 主程序（`C:\Program Files\Clash of Rust`） |
| 54240 | `clash-tun-launcher.exe --windows-bridge` | 提权宿主，来自 `Clash of Rust Network` |
| 58120 | `mihomo.exe` | 内核，监听 `127.0.0.1:17890`、`127.0.0.1:9090` |
| 8212 | `clash-tun-launcher.exe` | 辅助实例 |
| 6256 | `clash-wsl-guardian.exe` | WSL 守护服务 |
| 25988 | `vmmemWSL` | WSL 虚拟机 |

无 17891/17892 监听；`0.0.0.0` 无代理端口暴露。

## 11. Clash 运行配置摘要

- `tun.enable=false`，`tun.stack` 在生成配置里被写成 `mips`。源码
  `crates/client-core/src/config/mod.rs` 明确写入 `mips`，0.5.5 发布说明也使用
  mips；profile 写 `mixed` 是应用映射，不是“非法值”。此前“非法值/gVisor 回退”
  的判断已由 [TUN 分析](clash-tun-failure-analysis-2026-10-24.md) 更正。
- `strict-route: false`。**本机实测 `strict-route: true` 会让内核自身出站被 WFP
  拦截，全部流量超时**，必须保持 false。
- 规则（10 条）：`GEOSITE,category-ads-all,REJECT`、`GEOSITE,CN,DIRECT`、
  `GEOIP,CN,DIRECT,no-resolve`、`IP-CIDR,<VPS-IPv4>/32,DIRECT`、
  `IP-CIDR6,<VPS-IPv6>/128,DIRECT`、`neu.edu.cn`、`neu.edu`、`okinto.com`、
  `ckff.dev` 直连、`MATCH,XUAN-VPS`。
- 代理组：`XUAN-VPS`(Selector) → `XUAN-VPS-AUTO`(Fallback) → IPv6/IPv4 Fallback
  → `VLESS-*` / `HY2-*`。
- **TUN 实测行为**：开启后约 75–90 秒内，直连类规则（GeoSite/GEOIP CN、直连域名）
  全部超时；超过该窗口后稳定全部 200（`neu`/`baidu`/`okinto`/`ipinfo`）。
  经代理的流量从第一秒起就正常。

## 12. WSL

| 发行版 | 状态 | 版本 |
| --- | --- | --- |
| Ubuntu-22.04 | Running | WSL 2 |
| Ubuntu-26.04 | Running | WSL 2 |
| docker-desktop | Stopped | WSL 2 |

`C:\Users\xuan\.wslconfig` 目前只有 `[wsl2]` 段，无自定义网络项。WSL 出口管理器
（`cor-egress-manager`）受 `ClashOfRust.WslEgress` 与两个计划任务驱动。

## 13. hosts 与其他

- `hosts`：43 条有效条目，全部是 GitHub 相关域名固定解析（`140.82.x`、`185.199.x`
  等），无本地劫持条目。
- 端口转发（`netsh interface portproxy`）：空。
- 系统代理绕过表：`localhost;127.*;[::1];<local>`（2026-10-15 修复 Chrome 本机
  页面 502 时改为含 `<loopback>`，当前已无该条目，以现值准）。

## 14. 备份清单

| 位置 | 内容 |
| --- | --- |
| `C:\Users\xuan\AppData\Local\ClashOfRust-install-backups\legacy-0.5.8-20261015-083310-847961c6.zip` | 旧 `D:\Clash` 0.5.8 完整归档（19 文件） |
| `...\ClashOfRust-network-backups\` | `chrome-20261015-040446`、`local-page-admin-20261015-084234`、`strict-20261015-011253`、`wsl-nat-20261017-223227`、`desktop-vless-fix-20261021-161301` 等 |
| `C:\ProgramData\ClashOfRust\WslEgress\` | WSL 日志、`state.json`、`scope-renewal.json`、`wslconfig.before` |
| `%TEMP%\clash-of-rust-rule-backups\` | 订阅规则快照（易被清理，迁移前需另行归档） |

## 15. 已知风险与待办

1. **TUN 前 75–90 秒不可用**：期间所有直连规则超时，容易被误判为"TUN 坏了"。
2. **`strict-route` 不能开**：开启即全网中断，泄漏防护因此弱于设计目标。
3. **失效任务** `ClashOfRust-S-1-5-21-...-1002` 指向 `D:\Clash\clash-of-rust.exe`。
4. **死防火墙规则** 指向 `D:\Clash\resources\mihomo.exe`；迁移到 `D:\Clash` 后若
   路径恰好相同，这条规则会**重新生效**，必须迁移前处理。
5. **Chrome 回环端口写死 17890**：迁移后必须保持该端口。
6. 遗留 `XUAN-VPS Orca SSH Tunnel` 登录即连接，`XUAN-VPS Mihomo TUN` 已禁用。
7. 第三方 Clash 客户端残留：WinGet 版 `mihomo-windows-amd64.exe`、`ClashMi v1.0.30`。
8. `Clash of Rust Network` 与 `Clash of Rust WSL` 目录被源码/脚本白名单硬编码为
   `%ProgramFiles%`，迁到 `D:\Clash` 必须改源码。

## 16. 目标布局（`D:\Clash`）

```
D:\Clash\
├─ Clash of Rust\            主程序（NSIS InstallDir）
├─ Clash of Rust Network\    TUN 提权宿主（源码改路径）
├─ Clash of Rust WSL\        WSL 守护与模块（源码改路径白名单 + 卸载重装）
├─ tools\                    Chrome 守护脚本、诊断脚本
├─ backups\                  迁移前归档
└─ logs\                     迁移与验收日志
```

应用数据仍保留在 `%LOCALAPPDATA%\clash-of-rust`（用户选择）。

## 17. 回滚要点

- 迁移前对三个 `Program Files` 目录做逐字节归档，并导出服务/任务/防火墙定义。
- 任何一步后立即验证 `ipgw.neu.edu.cn`（期望 302）与 `api.okinto.com`（期望 200）；
  异常则停止并回滚当前步骤。
- Clash of WSL 的卸载必须走 `-Uninstall -Execute -RestoreOriginalNetwork`，且先停
  所有 WSL 发行版；不能直接删目录或改服务路径。
- 迁移后若需回到旧安装，用归档恢复目录并以 `clash-tun-launcher.exe
  --windows-service-install` 重建 `ClashOfRust.Network`。

---

## 18. 2026-10-24 迁移到 `D:\Clash` 的执行记录

### 18.1 备份

`D:\Clash\backups\pre-migration-20261024\`：

- `app-files/`（37 文件 / 142 MB）、`app-network-files/`（3 文件 / 59.3 MB）、
  `app-wsl-files/`（50 文件 / 1.3 MB）、`chrome-tools-files/`（15 文件）
- `appdata.tar`（35.8 MB）、`programdata.tar`、`app-network.tar`、`app-wsl.tar`
- `svc-*.txt`、`task-*.xml`、`firewall-rules.csv`、`nrpt.csv`、`hosts.txt`、
  `uninstall-key.reg`、`wininet-proxy.json`
- `wsl-state-before-finalize.json`、`abandoned-package-update.tar`（8 MB）

### 18.2 源码改动（6 个文件）

| 文件 | 改动 |
| --- | --- |
| `apps/desktop/src/platform/windows/service/security.rs` | `installed_directory()` 优先从可执行文件推导：`<root>\Clash of Rust` → `<root>\Clash of Rust Network`；开发构建仍回退 `%ProgramFiles%` |
| `apps/desktop/src/application/wsl/runner.rs` | `protected_installation()` 接受 `%ProgramFiles%` 或已安装的应用根目录，仍逐级校验受保护 ACL |
| `scripts/wsl-secure-egress/WslSecureEgress.psm1` | 新增 `Get-WslEgressProtectedRoots` / `Test-WslEgressProtectedPath`；守卫二进制与服务路径改为按受信任根校验 |
| `scripts/wsl-secure-egress/Invoke-WslSecureEgressElevated.ps1` | C# `ProtectedInstallation` 支持迁移后的受信任根，保留受保护 ACL 逐级检查 |
| `clash-of-wsl/Install-ClashOfWsl.ps1` | 新增 `-PackageRoot`；`Test-Elevated` 增加 `whoami /groups` 回退（本机 `WindowsIdentity.Groups` 不暴露完整性 SID） |
| `scripts/build_support.py` | `opener()` 支持 `CLASH_BUILD_PROXY`，便于受限网络下解析构建元数据 |

NSIS 脚本未改：安装时用 `/S /D=D:\Clash\Clash of Rust`。

### 18.3 构建

- `cargo build -p clash-of-rust --release --locked --bins` → 2m27s，PE 版本 0.6.1。
- `scripts/prepare-resources.py --proxy http://127.0.0.1:17890` 重新校验内核与四个 Geo 库。
- 安装包：`dist\Clash-of-Rust-0.6.1-windows-x64-setup.exe`（39,843,413 字节，
  PE 版本 0.6.1）。因本机没有 Go、且 `build_inputs.py resolve` 会触发 `cargo update`，
  未走 CI 的 manifest 导出链，改为直接调用 `makensis`（同一 NSIS 脚本与参数）。

### 18.4 迁移步骤与结果

1. 关闭应用，临时关闭系统代理；`wsl --shutdown`。
2. Clash of WSL 产品级回滚在 `running_distribution_inventory` 阶段反复失败
   （Linux 步骤单独执行均成功）。改为逐项执行模块内部函数完成 Windows 侧恢复：
   `Restore-WslEgressConfig`、`Set-WslEgressDockerGuard`、恢复 Hyper-V VM 设置、
   删除 `ClashOfRust-WslEgress-Endpoint`；并把 journal 置为 `restored`。
   `Uninstall-Check.ps1 -Execute` 返回 0。
3. 旧 0.6.0 静默卸载成功（exit 0）；`ClashOfRust.Network` 服务已随迁移删除后重建。
4. 新 0.6.1 安装到 `D:\Clash\Clash of Rust`（exit 0）。
   `ClashOfRust.Network` 服务指向 `D:\Clash\Clash of Rust Network\clash-tun-launcher.exe`。
5. Clash of WSL 辅助包安装到 `D:\Clash\Clash of Rust WSL`（102 文件），
   `ClashOfRust.WslEgress` 服务指向该目录，状态 Running / Auto。
6. Chrome 守护脚本移到 `D:\Clash\tools\ChromeGuard`，任务 `ClashOfRust-Chrome-Listener`
   参数改为 `--app "D:\Clash\Clash of Rust\clash-of-rust.exe"`。
7. 失效的 `ClashOfRust-S-1-5-21-…` 登录任务已删除；`C:\Program Files\Clash of Rust`
   与 `Clash of Rust Network` 已清理。

### 18.5 `D:\Clash` 权限

- 所有者 `BUILTIN\Administrators`，关闭继承；`SYSTEM` 与 `Administrators` 完全控制，
  `BUILTIN\Users` 只读+执行。这样 WSL 组件的受保护安装检查仍然成立。
- `tools`、`logs`、`backups` 额外授予当前用户 SID `(OI)(CI)M`。

### 18.6 迁移后验证

- 进程：`clash-of-rust.exe`（D:\Clash\…）、`mihomo.exe`；`127.0.0.1:9090`、`17890` 监听。
- 控制器：`mode=rule`，规则 10 条，`proxy_mode=system` 生效。
- 连通性连续 90 秒：`ipgw=302`、`okinto=200`、`baidu=200`、经代理 `ipinfo=200`。

## 19. TUN 现状与结论（迁移后）

1. **TUN 只能由提权内核创建。** 应用自己拉起的 `mihomo.exe` 是非提权的，
   `PATCH /configs {"tun":{"enable":true}}` 不会生成 `Meta` 适配器；
   只有通过 `ClashOfRust.Network` 服务启动的内核才能创建。
   因此必须用界面上的 TUN 开关触发提权重启，控制器 PATCH 不能代替。
2. **提权内核创建 TUN 后存在约 50–90 秒的全断窗口**：期间直连与经代理均超时，
   之后恢复稳定（旧 0.6.0 与新 0.6.1 均可复现）。
3. **`interface-name: WLAN` 会让情况更糟**：强制绑定后全程 000，已回退。
4. **`strict-route: true` 仍然不可用**：会导致内核自身出站被 WFP 拦截，全网中断。
5. **手机 USB 共享是重要嫌疑**：`以太网 2`（VirtNet，ifIndex 28）在未开共享时仍为
   Up，只有 `169.254.x` 链路本地地址，接口跃点 35，低于 WLAN 的 45。
   这类"有链路、无网络、跃点更低"的网卡正是 `auto-detect-interface` 误判的来源。
   在它禁用时的对照测试因内核未提权（`Meta` 未生成）而不成立，尚未完成有效 A/B。
6. 下一步验证建议：拔掉手机（或禁用 `以太网 2`）后，从界面开启 TUN，观察 90 秒；
   若仍有全断窗口，再对比 `tun.mtu`、`auto-detect-interface` 与 `dns-hijack` 组合。

---

相关文档：`docs/network-operations-audit-2026-10-24.md`（会话操作审计，未跟踪）、
`docs/local-network-handoff-2026-10-15.md`（历史交接）、
`docs/wsl-secure-egress/OPERATIONS.md`（WSL 组件运维）。
