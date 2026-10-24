# 系统网络配置、防火墙、依赖、Tailscale 与 WSL 审计

- 日期：2026-10-24
- 审计时间：02:16–02:27（+08:00）
- 状态：现行（只读快照；审计期间未修改任何系统设置、服务、防火墙或网络）
- 关联分析：[Clash TUN 无法使用与 9090 端口错误分析](clash-tun-failure-analysis-2026-10-24.md)
- 说明：审计过程中应用/用户切换过代理模式，02:19 左右系统代理可用，02:24:20 重新开启 TUN 后关键地址再次失败；本文以 02:26–02:27 的快照为准，并保留 02:19/02:23 的对比。

## 1. 当前快照（02:26–02:27）

| 项目 | 值 |
| --- | --- |
| 应用 | Clash of Rust 0.6.1，PID 52840，`D:\Clash\Clash of Rust\clash-of-rust.exe` |
| 网络助手服务 | `ClashOfRust.Network` **Running**（02:24:20 启动） |
| 服务侧 launcher | `clash-tun-launcher.exe` PID 53416，父进程 services.exe |
| 应用侧 bridge | `clash-tun-launcher.exe` PID 4212，父进程 52840 |
| 内核 | `mihomo.exe` PID 63332，父进程 53416；监听 `127.0.0.1:9090`、`127.0.0.1:17890` |
| 设置 `proxy_mode` | **tun** |
| live `tun.enable` | **true**，`stack=Mips`，`auto-route=true`，`auto-detect-interface=true` |
| `Meta` 适配器 | **Up**（`Get-NetAdapter` 默认不显示，需 `-IncludeHidden`） |
| IPv4 默认路由 | Meta `198.18.0.2` metric 0 与 WLAN `172.22.255.254` metric 0 并存 |
| IPv6 默认路由 | Meta `fdfe:dcba:9876::2` metric 0 与 WLAN `fe80::...` metric 256 并存 |
| 系统代理 | `ProxyEnable=0`（TUN 模式已关闭系统代理） |
| `https://ipgw.neu.edu.cn/` | 直连 `000` TLS 握手失败；17890 代理 `000` TLS 握手失败 |
| `https://api.okinto.com/` | 直连 `000` TLS 握手失败；17890 代理 `000` TLS 握手失败 |

**当前结论**：TUN 确实已开启并接管 IPv4/IPv6 默认路由，但内核自身到代理节点的出站没有正常离开主机；Chrome/系统代理此时没有回退路径（系统代理已关闭），因此关键地址不可用。审计期间未修改任何内容。

### 1.1 02:29 复核

- 应用已切回系统代理：`proxy_mode=system`，默认路由仅 WLAN，Meta 适配器与 Meta 路由均已消失；17890/9090 仍由 PID 63332 监听。
- `https://ipgw.neu.edu.cn/` 直连/17890 代理均 **302**；`https://api.okinto.com/` 直连/17890 代理均 **200**。
- 这说明 02:24–02:27 的故障是 **TUN 开启后的路径问题**，不是主机 DNS、WLAN、Tailscale 或 WSL 的基础连通性问题；切回系统代理后恢复。
- 02:23 曾观察到 TUN 关闭后 IPv6 Meta 地址/路由短暂残留；02:29 复核时已清理。切换时序仍需继续观察。

## 2. 主机网络

### 2.1 活动接口

| 接口 | 状态 | 地址/说明 |
| --- | --- | --- |
| WLAN | Up | `172.22.0.0/16` 私网地址，网关 `172.22.255.254`；IPv6 通过 RA 获得 `2001:da8:.../64`；接口 metric 45 |
| Meta | Up（隐藏） | TUN，IPv4 `198.18.0.1/30`，IPv6 `fdfe:dcba:9876::1/126`；接口 metric 9000；实际 `Find-NetRoute` 仍把公网目标选到 Meta（见 §2.2） |
| vEthernet (WSL (Hyper-V firewall)) | Up | `172.19.96.1/20`，metric 5000，MTU 1500；无默认路由 |
| VirtNet Network Adapter (NDIS 6.0) | Up | `169.254.185.185/16`（link-local），metric 35；无默认路由；驱动 `virtnet60.sys` |
| TAP-Windows Adapter V9 | Disconnected | `172.20.252.161/24`、`169.254.149.152/16`；无默认路由；驱动 `tap0901.sys` |
| 本地连接* 3（Wi-Fi Direct） | Up | `192.168.137.1/24`；无默认路由 |
| NEU-有线 / 以太网 2 / 蓝牙 | Disconnected | 无有效默认路径 |

- 没有 Tailscale 适配器。
- `VirtNet` 和 `TAP-Windows` 都没有默认路由，当前不参与主路径；但它们的驱动/虚拟网卡仍在，属于历史或第三方依赖，后续若被启用可能改变路由优先级。
- Wi-Fi Direct 的 `192.168.137.1/24` 也没有默认路由，但属于额外暴露面。

### 2.2 路由选择

- IPv4：`Find-NetRoute` 对 `1.1.1.1`、`api.okinto.com` 解析地址、校园地址都选择 **Meta**（`198.18.0.2`）。
- IPv6：`Find-NetRoute` 对 `api.okinto.com` 的 IPv6 地址选择 **Meta**（`fdfe:dcba:9876::2`）；对校园 IPv6 地址选择 **WLAN**（`fe80::...`）。
- Meta 的接口 metric 查询显示 9000，WLAN 45，但 IPv4/IPv6 的默认路由 metric 均为 0/256；实际 `Find-NetRoute` 仍把公网目标选到 Meta。这说明 **route metric 与实际接口 metric 的组合行为**使 TUN 默认路由优先，不能只用“Meta metric 9000”推断流量会走 WLAN。
- 当 TUN 关闭时（02:23 快照），IPv4 Meta 默认路由消失，但 **IPv6 Meta 地址和 `::/0` 路由仍存在**；这是残留状态，可能在 TUN 关闭后继续影响 IPv6。02:24 重新开启 TUN 后 IPv4 路由恢复。
- 系统中没有 `100.64.0.0/10` 的 Tailscale 路由；Tailscale 未安装。

### 2.3 DNS、hosts、代理

| 项目 | 当前值 |
| --- | --- |
| WLAN DNS | `202.118.1.29`、`202.118.1.53`（校园 DNS） |
| IPv6 DNS | WLAN 无 IPv6 DNS；其他断开接口只有 `fec0::` 占位 |
| NRPT | 无 |
| WinHTTP | 直接访问，无代理 |
| IE/系统代理 | TUN 模式下 `ProxyEnable=0`；02:23 系统代理模式时 `ProxyEnable=1`、`127.0.0.1:17890` |
| 环境变量代理 | 未设置 |
| hosts | 43 条有效条目，均为 GitHub 相关域名固定解析；无本地劫持条目 |
| fake-IP DNS 缓存 | `198.18.*` 缓存条目 0 |
| 关键域名解析 | `ipgw.neu.edu.cn` → 校园 IPv4；`api.okinto.com` → 多个 A/AAAA |

结论：DNS/NRPT/hosts 没有发现会单独导致当前 TUN 失败的异常；关键域名能解析到真实地址。当前失败发生在 TUN 接管后的 TCP/TLS 路径。

## 3. 防火墙

### 3.1 Windows 防火墙配置

- Domain/Private/Public 三个配置文件均 `Enabled=True`。
- `DefaultInboundAction`、`DefaultOutboundAction` 均为 `NotConfigured`，即使用 Windows 默认（入站阻止、出站允许）。
- 没有发现针对当前 `mihomo.exe` 路径的启用阻断规则。

### 3.2 ClashOfRust 规则（9 条）

| 规则 | 状态 | 方向/动作 | 程序 |
| --- | --- | --- | --- |
| `ClashOfRust-Chrome-NoDirect-Physical` | Enabled | Outbound / Block | `C:\Program Files\Google\Chrome\Application\chrome.exe` |
| `ClashOfRust-Strict-Chrome-Remote` | Enabled | Outbound / Block | Chrome |
| `ClashOfRust-Strict-Chrome-LoopbackTCP` | Enabled | Outbound / Block | Chrome |
| `ClashOfRust-Strict-Chrome-LoopbackUDP` | Enabled | Outbound / Block | Chrome |
| `ClashOfRust-Strict-Core-VpsOnly` | Enabled | Outbound / Block | `D:\Clash\resources\mihomo.exe` |
| `ClashOfRust-Strict-DNS-Wireless` | **Disabled** | Outbound / Block | `svchost.exe` |
| `ClashOfRust-Strict-DNS-OtherInterfaces` | **Disabled** | Outbound / Block | `svchost.exe` |
| `ClashOfRust-Strict-DNS-NoLocalHelperTCP` | **Disabled** | Outbound / Block | `svchost.exe` |
| `ClashOfRust-Strict-DNS-NoLocalHelperUDP` | **Disabled** | Outbound / Block | `svchost.exe` |

关键发现：

- `ClashOfRust-Strict-Core-VpsOnly` 的目标是 **`D:\Clash\resources\mihomo.exe`**，该文件不存在；当前服务内核在 `D:\Clash\Clash of Rust Network\mihomo.exe`，应用自带内核在 `D:\Clash\Clash of Rust\resources\mihomo.exe`。因此这条“只允许核心出站到 VPS”的规则**对当前内核不生效**。它既没有造成本轮 SynSent，也不能起到预期的限制作用。
- 4 条 Chrome 出站阻止规则处于启用状态：Chrome 被限制为只能使用本地代理路径，不能直连。当前 TUN 模式关闭了系统代理而 TUN 又不通，Chrome 会因此没有可用路径（fail-closed）。
- 4 条 DNS 严格规则均已禁用，不构成当前 DNS 阻断。

### 3.3 Hyper-V / WSL 防火墙

- WSL VM creator `{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}` 的策略：
  - `Enabled=NotConfigured`
  - `DefaultInboundAction=Allow`
  - `DefaultOutboundAction=NotConfigured`
  - `LoopbackEnabled=NotConfigured`
- 没有找到 `ClashOfRust-WslEgress-Endpoint` 规则；只有 `WslCore-Allow-Inbound-*` 默认允许规则和大量 HNS/容器 GUID 入站允许规则。
- 与 2026-10-15/10-23 的 WSL 出口启用态相比，当前 **WSL egress 的 Hyper-V 端点与默认拒绝策略已不存在**，与 `state.json phase=restored` 一致。
- 结论：当前 WSL 防火墙不是 TUN 失败的原因，也没有在实施 WSL 出口封锁；WSL 默认策略偏宽松。

## 4. 服务、驱动、依赖与 Tailscale

### 4.1 服务

| 服务 | 状态 | 说明 |
| --- | --- | --- |
| `ClashOfRust.Network` | Running（TUN 模式） | 网络助手，LocalSystem，Demand Start；`D:\Clash\Clash of Rust Network\clash-tun-launcher.exe --windows-service` |
| `ClashOfRust.WslEgress` | Running | WSL 出口审计服务，`D:\Clash\Clash of Rust WSL\clash-wsl-guardian.exe --service`；产品状态已 `restored`，属于遗留运行 |
| `WslService` | Running | WSL 服务 |
| `vmcompute` / `HvHost` / `WinNat` | Running | Hyper-V/WSL 网络依赖 |
| `BFE` / `mpssvc` / `Dnscache` / `iphlpsvc` | Running | 防火墙、DNS 客户端、IP 辅助 |
| `Docker` / `com.docker.service` | Stopped | Docker Desktop 未运行 |

### 4.2 驱动

| 驱动 | 状态 | 说明 |
| --- | --- | --- |
| `wintun` | Stopped（查询时） | Meta TUN 驱动；适配器在 02:26 仍显示 Up，驱动 State 与适配器状态并非完全同步，不能只凭 State 判断 TUN |
| `tap0901` | Running | TAP-Windows（OpenVPN 兼容） |
| `virtnet60` | Running | VirtNet NDIS 6.0 虚拟网卡 |
| `npcap` | Running | Npcap 抓包驱动 |
| `SdpVnic` | Stopped | Sangfor aTrust VNIC |
| `WFPLWFS` | Running | Windows Filtering Platform |

### 4.3 Tailscale

- `tailscale` 命令不存在，未安装 Tailscale。
- 没有 `Tailscale` 服务、没有 Tailscale 适配器、没有 `100.64.0.0/10`/`100.100.*` 路由。
- 因此 Tailscale 不是当前 TUN 失败的冲突源；当前也没有 Tailscale 出口节点或 MagicDNS 接管。

### 4.4 其他 VPN / 虚拟网络

- TAP-Windows Adapter V9：Disconnected，无默认路由；`tap0901` 驱动运行。
- VirtNet Network Adapter (NDIS 6.0)：Up，但只有 `169.254.0.0/16` link-local，无默认路由；`virtnet60` 驱动运行。
- Sangfor aTrust VNIC：驱动 Stopped；没有发现活动的 aTrust 服务。
- `Get-VpnConnection -AllUserConnection` 没有返回现有 VPN 连接。
- 这些虚拟网卡当前不改变默认路由，但属于额外依赖/历史组件；后续启用时需重新检查路由优先级。

### 4.5 计划任务与遗留入口

| 任务 | 状态 | 说明 |
| --- | --- | --- |
| `ClashOfRust-Chrome-Listener` | Ready | 当前无 pythonw 进程；登录触发，可能维护 Chrome 监听器 |
| `ClashOfRust-WslEgress-Autostart` | Ready | 状态 `restored` 时应在登录后直接退出，不会重建出口 |
| `ClashOfRust-WslEgress-Renew` | **Disabled** | 之前关闭的每分钟审计任务 |
| `XUAN-VPS Mihomo TUN` | **Disabled** | 旧 XUAN VPS 入口，未运行 |
| `XUAN-VPS Orca SSH Tunnel` | Ready | 登录触发；Action 为 `ssh.exe`，上次运行 2026-10-23 11:38:34，结果 `4294967295`（失败/异常），当前无 ssh 进程、无 16768 监听 |

`XUAN-VPS Orca SSH Tunnel` 仍是登录触发的旧遗留项；当前未建立连接，但下次登录/触发时可能尝试打开 SSH 反向隧道。本文只记录状态，未修改任务。

## 5. WSL 网络配置

### 5.1 版本与运行状态

- WSL 版本：3.0.3.0
- 内核：6.18.54.1-1
- 默认发行版：Ubuntu-22.04
- 当前发行版状态：Ubuntu-22.04 `Stopped`、Ubuntu-26.04 `Stopped`、docker-desktop `Stopped`
- `wslservice` 进程存在；没有 `vmmemWSL` 进程。

### 5.2 `.wslconfig`

```ini
[wsl2]
memory=10GB
processors=8
localhostForwarding=false

[experimental]
autoMemoryReclaim=gradual
networkingMode=nat
dnsTunneling=true
autoProxy=false
firewall=true
sparseVhd=true
```

- 使用 WSL2 NAT，不使用 mirrored 网络。
- `localhostForwarding=false`：WSL 监听端口不会自动发布到 Windows localhost。
- `dnsTunneling=true`：WSL DNS 走 WSL 自己的隧道。
- `autoProxy=false`：不自动导入 Windows 代理。
- `firewall=true`：WSL Hyper-V 防火墙集成启用；但当前 VM 策略是默认 Allow/NotConfigured，且没有 ClashOfRust 端点规则。
- `sparseVhd=true`、`autoMemoryReclaim=gradual`：磁盘/内存回收策略。

### 5.3 主机侧 WSL 网络

| 项目 | 值 |
| --- | --- |
| 适配器 | `vEthernet (WSL (Hyper-V firewall))`，Up，ifIndex 66 |
| IPv4 | `172.19.96.1/20` |
| 接口 metric | 5000，MTU 1500 |
| 默认路由 | 无（只有 `172.19.96.0/20`、广播/组播/本地路由） |
| DNS | 接口本身无 DNS 地址 |
| `Get-NetNat` | 无返回条目（WSL3/HNS 可能不通过传统 NetNat 暴露） |
| portproxy | 空 |
| Hyper-V 端点规则 | 无 `ClashOfRust-WslEgress-Endpoint` |
| VM 默认策略 | Inbound Allow，Outbound NotConfigured，Loopback NotConfigured |

### 5.4 WSL 出口产品状态

- `state.json`：`phase=restored`、`endpoint_enabled=false`、`manager_distro=Ubuntu-26.04`、`distro_configs=Ubuntu-22.04`。
- `ClashOfRust.WslEgress` 服务仍在运行；`autostart.log` 最后成功记录是 00:55:18，之后没有新的 start。
- `ClashOfRust-WslEgress-Autostart` 为 Ready；`Renew` 为 Disabled。
- 当前没有启用的 WSL 出口端点，也没有 Hyper-V 默认拒绝策略；WSL 不参与当前 TUN 失败。

### 5.5 发行版内部配置（上次运行读取，当前未启动）

在 2026-10-24 较早的运行中，Ubuntu-22.04 的 `/etc/wsl.conf` 为：

```ini
[user]
default = xuan

[boot]
systemd = true
command = /usr/local/lib/cor-egress/manager guard

[network]
generateResolvConf = false
generateHosts = false

[time]
useWindowsTimezone = false

[interop]
enabled = false
appendWindowsPath = false
```

说明：当前两个发行版都是 `Stopped`，上述内容来自上一次运行读取的持久文件，不是当前 live 状态；本轮没有启动发行版，因此以下项目均为 **NOT_RUN**：

- `ip addr` / `ip route` / `ip rule`
- `/etc/resolv.conf` 的实际内容
- `nft list ruleset` / `wg show`
- `resolvectl` / DNS 实际解析
- WSL 内部到 VPS、校园网、API 的连通性

如果需要，我可以另行获得授权后启动 Ubuntu-22.04/26.04 做一次只读 `ip/nft/wg` 快照，然后停止；本轮按“检查”约束未启动。

## 6. 02:24 TUN 复现与关键证据

### 6.1 复现过程

| 时间 | 事件 |
| --- | --- |
| 02:19:09 | 应用 PID 52840 启动；随后以系统代理模式运行，02:23 时 `proxy_mode=system`，17890/9090 正常，关键地址直连/代理均 302/200 |
| 02:24:20 | 用户/应用开启 TUN；`ClashOfRust.Network` 服务启动；服务侧 launcher PID 53416、应用侧 bridge PID 4212、mihomo PID 63332 启动 |
| 02:24:20+ | live `tun.enable=true`、`ProxyEnable=0`；Meta Up；IPv4/IPv6 默认路由指向 Meta |
| 02:26 | 关键地址直连与 17890 代理均为 `000`，TLS 握手失败；`Find-NetRoute` 对 API IPv4/IPv6 均选择 Meta |
| 02:27 | 多次连接采样：一次总览 Bound 24 / SynSent 20 / Established 8 / Listen 2；另一次按地址族/端口分解：SynSent IPv6 8（7 条远端 10443）+ IPv4 2，Established IPv4 11；连接在持续重试 |

### 6.2 连接层证据

- 连接数在采样间变化，说明内核在快速重试。一次总览：`Bound 24`、`SynSent 20`、`Established 8`、`Listen 2`。
- 另一次按地址族/端口分解：
  - `SynSent` IPv6：8 条（其中 7 条远端端口 **10443**，VLESS Reality）
  - `SynSent` IPv4：2 条（远端端口 80/8080）
  - `Established`：IPv4 11 条（包含 443/80 及若干高位端口）
- 远端地址没有出现 `198.18.*` fake-IP，说明内核是在向**真实代理节点地址**发起连接，但 IPv6 10443 的 SYN 没有得到响应。

结合：

- 当前节点在此前 UI 中显示为 IPv6 VLESS 节点；
- 项目记录的 VLESS Reality 端口为 10443/tcp；
- IPv6 `::/0` 同时存在 Meta metric 0 和 WLAN metric 256；
- `Find-NetRoute` 对 `api.okinto.com` 的 IPv6 选择 Meta；

可以判断：**内核自身到 IPv6 代理节点 10443 的出站没有走物理 WLAN，而是被 TUN 的 IPv6 默认路由捕获；TUN 栈没有把这条出站正确送出，形成回环/黑洞，导致 IPv6 节点不可达，进而所有经该节点的代理流量失败。** 这是当前 02:24 复现的最强解释，标记为 **LIKELY / 强证据**；由于内核已运行、无法在不修改的前提下抓包，尚未达到抓包级证明。

### 6.3 与 9090 错误的关系

- 02:10:53 的 9090 `10048` 是**上一次重启的端口释放时序问题**；02:24:20 服务成功启动，9090/17890 正常绑定，当前没有再出现该错误。
- 因此 9090 错误和 TUN 回环是两个独立问题：前者是启动竞态，后者是运行期 IPv6 出站路由/回环。

### 6.4 当前系统影响

- TUN 已开启，系统代理已关闭；Chrome 的 4 条出站阻止规则仍然启用，Chrome 没有直连回退。
- 关键地址当前不可用；这不是 DNS 失败（域名解析正常），而是 TUN 接管后 TCP/TLS 失败。
- 当前内核为服务侧 launcher 的子进程，助手路径/哈希正常；不是助手缺失或 UAC 问题。

## 7. 风险与待确认项

1. **当前 TUN 处于“已开启但不可用”状态**，且系统代理已关闭；用户侧会表现为整机浏览器/代理流量失败。
2. **IPv6 TUN 残留（切换时序）**：02:23 观察到 TUN 关闭后 IPv4 Meta 路由消失，但 IPv6 `fdfe:dcba:9876::1/126` 与 `::/0` 路由短暂仍然存在；02:29 复核时已清理。仍需确认 TUN 关闭时是否每次都完整清理，避免残留 IPv6 路由影响后续连接。
3. **严格核心防火墙规则目标失效**：`ClashOfRust-Strict-Core-VpsOnly` 指向不存在的 `D:\Clash\resources\mihomo.exe`，当前两个真实内核路径均未被覆盖；该规则既不能限制当前内核，也不是当前失败的原因。
4. **Chrome 严格规则与 TUN/系统代理耦合**：4 条 Chrome 出站阻止规则启用；TUN 失败时 Chrome 没有直连回退，属于 fail-closed 设计但会放大故障。
5. **WSL 出口服务遗留运行**：`ClashOfRust.WslEgress` 仍 Running，但 `phase=restored`、endpoint 不存在；当前不 enforcing，属于遗留状态。
6. **旧计划任务**：`XUAN-VPS Orca SSH Tunnel` Ready at logon，上次运行失败；下次登录可能尝试建立旧 SSH 隧道。
7. **虚拟网卡/驱动**：VirtNet、TAP-Windows、Npcap、Sangfor aTrust VNIC 驱动存在；当前无默认路由，但后续启用可能改变路由/防火墙行为。
8. **WSL 发行版 live 网络未检查**：两个发行版 Stopped；`ip/nft/wg`/DNS 实际状态为 NOT_RUN。
9. **Tailscale**：未安装，无服务/适配器/100.64 路由；不是当前冲突源。

## 8. 建议（需另行授权，本轮未执行）

### 8.1 立即恢复可用性

- 当前 TUN 不通且系统代理已关闭。若需要恢复上网，建议先在应用内切回“系统代理”或“关闭”并确认 17890 可用；这属于修改操作，本轮未执行。
- 如果继续保留 TUN，需要修复内核自身 IPv6 出站绕开 TUN，而不是只切换节点。

### 8.2 针对 TUN 回环的修复方向

1. 在 TUN 开启时为内核到代理节点的出站使用物理接口绑定/fwmark/路由排除，IPv4 与 IPv6 都要覆盖。
2. TUN 关闭时清理 Meta 的 IPv6 地址/路由，避免残留 `fdfe:dcba:9876::1/126` 和 `::/0`。
3. 在启用 TUN 后记录 `Find-NetRoute` 对代理节点地址的选择，以及内核到 10443 的连接状态；当前 7 条 IPv6 SynSent 是最直接的回归指标。
4. 产品侧 Windows 端口预检增加等待/重试，避免 9090 重启竞态。
5. 修正或删除已失效的 `ClashOfRust-Strict-Core-VpsOnly`，使其明确覆盖当前内核路径，或明确不再使用。

### 8.3 WSL/依赖清理方向

- 若不再使用 WSL 出口：停止/卸载 `ClashOfRust.WslEgress` 服务，禁用 `ClashOfRust-WslEgress-Autostart`，清理旧 WSL egress 规则；本轮未执行。
- 若继续使用 WSL：启动发行版后做一次只读 `ip/nft/wg` 快照，确认 NAT、DNS tunneling、interop 与 boot guard 的实际状态。
- 检查 `XUAN-VPS Orca SSH Tunnel` 是否仍需登录触发；当前只记录状态，未修改。
- Tailscale 未安装；如未来安装，需要重新检查 100.64/10 路由、MagicDNS 与 TUN 的优先级冲突。

## 9. 只读核查命令

```powershell
# 接口、地址、路由、DNS
Get-NetAdapter -IncludeHidden
Get-NetIPAddress -AddressFamily IPv4
Get-NetIPAddress -AddressFamily IPv6
Get-NetRoute -DestinationPrefix '0.0.0.0/0'
Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0'
Find-NetRoute -RemoteIPAddress 1.1.1.1
Get-DnsClientServerAddress
Get-DnsClientNrptPolicy
netsh winhttp show proxy
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' |
  Select-Object ProxyEnable,ProxyServer,AutoConfigURL

# 防火墙
Get-NetFirewallProfile
Get-NetFirewallRule -PolicyStore ActiveStore |
  Where-Object { $_.Name -like 'ClashOfRust*' -or $_.Name -like 'ClashOfWSL*' } |
  Select-Object Name,Enabled,Direction,Action,Profile
Get-NetFirewallHyperVVMSetting
Get-NetFirewallHyperVRule |
  Select-Object Name,Enabled,Direction,Action,Protocol

# 服务/驱动/Tailscale
Get-Service ClashOfRust.Network,ClashOfRust.WslEgress,WslService,vmcompute,HvHost,WinNat,Dnscache,mpssvc
Get-CimInstance Win32_SystemDriver |
  Where-Object { $_.Name -match 'wintun|tap|virtnet|npcap|tailscale|wfp' }
Get-Command tailscale -ErrorAction SilentlyContinue

# 内核连接分类（不打印远端地址）
$c = Get-NetTCPConnection -OwningProcess 63332 -ErrorAction SilentlyContinue
$c | Group-Object State | Select-Object Name,Count
Get-NetTCPConnection -OwningProcess 63332 -State SynSent |
  Group-Object RemotePort | Select-Object Name,Count
```

## 10. 限制

- 审计期间应用/用户切换过 TUN/系统代理，状态是动态的；本文以 02:26–02:27 为准。
- 没有抓包，没有读取内核 stderr/应用日志页；TUN 回环结论来自路由选择、适配器计数、核心连接状态（SynSent IPv6 10443）和 TLS 失败，属于强证据但非抓包级证明。
- 没有启动 WSL 发行版，因此发行版内部网络为 NOT_RUN。
- 没有修改任何设置、防火墙、服务、任务或 WSL 配置；没有提交 Git。
- 本文不记录控制器 secret、订阅 URL、VPS 地址、节点名或 Tailscale 私密信息。
