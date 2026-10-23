# WSL 3.0 网络更新与 Clash of Rust 全流量方案

日期：2026-10-15，Asia/Taipei。性质：公开资料核查、决策依据与待实施设计；不是运行验收或网络修改记录。

## 1. 结论先行

WSL 3.0 系列有网络兼容性修复与平台更新，但**不是新的“WSL 3”虚拟化架构，也没有自动把全部 Linux 流量交给任意 Windows Clash 端口的开关**。WSL 软件包的 3.0.x 版本和发行版使用的 WSL 1/WSL 2 架构是不同维度。当前目标仍应基于 WSL 2 的网络能力设计。[S1][S2][S3]

对本项目，推荐保留“Windows 正式 Clash of Rust 的同一核心连接 VPS”，按以下依赖顺序实施，而不是先批量修改 `.wslconfig`：

1. **先过 Clash 固定策略闸门**：同一核心中有持久、固定 VPS、支持 TCP 与标准 SOCKS5 UDP 的受管入口；普通节点/模式/profile 切换不得使 WSL 变成 DIRECT 或其他出口。
2. **再做 Linux 透明数据面**：TUN-to-SOCKS 转换器、精确上游通道、双栈路由与 Linux 失败关闭。
3. **独立控制 DNS**：受管 resolver/stub 的引导、普通解析、应用内 DoH/DoT/DoQ 和容器 DNS 都不能回退宿主直连。
4. **需要减少接口信息暴露时加入 netns**：工作负载真实只看到自己的 lo/TUN/veth；不篡改 `ip addr`，不宣称 WSL 拥有 VPS 公网地址。
5. **纳管所有入口后才称全 WSL**：交互 shell、systemd、定时任务、后台子进程、容器与 Windows interop 分别验收。单个受管 shell 成功不是全 WSL 成功。

`mirrored + dnsTunneling + autoProxy` 是互通/兼容功能组合，**不是上述 1–5 的替代品**。全 TCP/UDP 功能与无旁路安全分开验收；阻断 UDP/IPv6 只能是标注清楚的安全降级，不算相应功能完成。

协议边界必须明确：本路线通过标准 SOCKS5 承载 TCP/UDP，不是把任意 IP 协议完整封装到 VPS 的三层 VPN。ICMP/其他不支持的协议不得直连回退；某些透明器提供的本地 ICMP Echo 回复也不代表 ping 已经到达 VPS 或目标。若必须端到端承载任意 IP 协议，需要另行评估真正的 L3 隧道及其与“同一 Clash 核心”要求的兼容性，不能把它当成本路线已经实现的能力。[S13]

相关既有文档：[需求 R01–R13](wsl-vps-requirements-and-plan-2026-10-15.md)、[架构及同核心限制](wsl-vps-network-architecture-2026-10-15.md)、[身份威胁模型](wsl-vps-identity-threat-model-2026-10-15.md)、[GitHub 候选调查](wsl-vps-github-project-survey-2026-10-15.md)、[接续缺口](wsl-vps-followup-assessment-2026-10-15.md)。本文补充版本相关判断，不覆盖既有安全约束。

## 2. 版本、证据与本轮范围

- 截至 2026-10-15 本轮核查，Microsoft GitHub `releases/latest` 返回 **3.0.3**（稳定版，发布时间 `2026-10-09T18:21:40Z`）；对应 tag commit 为 `15ea3b3846c5f18318722d1381186b2ff6ed72eb`。[S1]
- 既有 10:28:45 本机只读记录为 WSL `3.0.3.0`、内核 `6.18.54.1-1`、WSLg `1.0.79`，Ubuntu-22.04 与 docker-desktop 均 Stopped。**本轮没有再次启动发行版或刷新这份运行快照**。
- 既有 GitHub HTTP Date 与本机时间有约 8 小时偏差。本文以本轮页面/API 返回及固定 tag 描述版本，不依据相对时间推断刚发布、系统时钟正确或必须升级；没有改时钟。
- Microsoft Learn 是滚动文档，字段、默认值和名称可能比历史教程新；具体落地须与实际安装 tag 的解析器一致。文件存在、字段被接受和最终有效运行状态是三个不同证据。
- 本轮只读取资料和写 Markdown，不启动 WSL/Claude，不 SSH，不安装组件，不操作核心 API，不改 DNS、代理、TUN、路由、防火墙、网卡、任务或 CC Switch。

## 3. 3.0 系列到底更新了什么

### 3.1 不要把早已存在的功能列成 3.0 首创

mirrored、DNS tunneling、HTTP autoProxy、Hyper-V firewall 在 WSL 2.x 时期已经存在：2.0.0（2023-09-18）的官方介绍已列出这组实验功能。官方文档还明确 Hyper-V firewall 从 WSL 2.0.9 起在满足 Windows 条件时默认启用。这些功能可以继续使用，但不是升级到 3.0 才新增的透明代理引擎。[S2][S3][S10]

### 3.2 已核查的 3.0 版本变化

- **3.0.1（2026-09-29，稳定版）**：发布说明宣布 WSL containers（WSLc）正式可用；主要是容器产品化、SDK/STDIN、配置非 ASCII 与生命周期等变化。容器管理能力不等于 Ubuntu 规则自动接管所有容器网络。[S4]
- **3.0.2（2026-10-05，预发布）**：网络相关包括 IPv4/IPv6 同时监听时的 IPv4 转发修复、IPv6 禁用时不让 consommé loopback 配置失败、没有 IPv4 gateway 时的 consommé fallback，以及端口/生命周期测试修复。这些有助兼容性，但不是 SOCKS 全流量强制策略。[S5]
- **3.0.3（2026-10-09，稳定版）**：内核升级到 `6.18.54.1`，包含 consommé 测试临时端口范围、port relay 端口释放等待、WSLc 事件匹配与生命周期等修复；发布说明没有宣告新的全流量 Clash 接管功能。[S1]
- **3.0.0 tag**：Git tag 存在，但本轮 `releases/tags/3.0.0` API 返回 404，不能给它编造 GitHub Release 说明，也不能单凭主版本号推导新的网络隔离或代理架构。面向用户的完整系列变化应结合 3.0.1–3.0.3 与此前 2.9.x 的实际发布链阅读。[S6]

### 3.3 当前模式名称

当前 Learn 列出 `none`、`nat`、`mirrored`、`consomme`，并将过去称为 `virtioproxy` 的模式称作 consommé；2.9.3 已记载这项改名，3.0.3 固定源码仍接受 VirtioProxy 别名。`bridged` 自 2.4.5 起被标记弃用。文档还说明从 2.3.25 起 NAT 创建失败会回落到该用户态网络模式。[S3][S9][S11]

这里的 `proxy`/consommé 是 WSL 网络实现，不是自动连接本项目 VPS 的 Clash/SOCKS 代理。必须核验实际有效模式与回落情况；不能只靠配置字符串证明路由路径。

## 4. 与目标相关的 WSL 开关及真实边界

### 4.1 `networkingMode=mirrored`

官方目标是将 Windows 网络接口镜像到 Linux；收益包括 IPv6、VPN 兼容、组播、LAN 访问，以及 Linux 使用 `127.0.0.1` 连接 Windows 服务。文档明确跨宿主的 IPv6 localhost `::1` 不在该项支持范围内。[S2]

对本项目的价值是更容易触达正式核心当前仅绑定 Windows loopback 的入口，避免为了 NAT 连通而直接扩大到 `0.0.0.0`。但它不是隐私隔离：根网络命名空间可能列出镜像的本地地址；本轮没有启动发行版逐项确认本机枚举结果。若不希望普通 CLI 看到这些接口，应隔离工作负载视图，而不是宣称 mirrored 自动隐藏 Windows。

`localhostForwarding` 主要是 NAT 下 Windows 到 Linux 的便利转发；在 mirrored 下该设置被忽略。它不等于任意 TCP/UDP 双向 SOCKS relay，不能用来证明 UDP 已接管。[S3]

### 4.2 `autoProxy=true`

这是 Windows **HTTP 代理信息的自动导入**，不是 IP 层 TUN、标准 UDP 转发或失败关闭。不能假定任意原生 Linux socket、后台服务和容器读取该信息，也不能假定它指向 WSL 专属固定 VPS 策略。[S2][S3]

设计建议：第一轮盘点只记录其有效值，保持现状。未来受管透明环境建立后，显式管理其代理环境，防止旧 18001/12345 或普通 17890 环境变量绕过预期身份/规则；可关闭自动继承，但须先审计所有发行版影响，不能现在全局切换。关闭变量继承本身也不是防旁路边界。

### 4.3 `dnsTunneling=true`

官方说明它通过虚拟化机制将 WSL DNS 请求交由 Windows 回答，而非发送普通网络数据包。其目的是兼容 VPN/复杂网络，不是保证境外解析或保证经 VPS。[S2]

因此，**不能只在 Linux nftables 里挡住 UDP/TCP 53，就宣称已经约束 DNS tunneling**。Windows 上层可能应用自己的解析策略；仅在 Linux TUN 抓包没有 DNS，也不能反证未发生 DNS 查询。DNS tunneling 与本项目“Linux 受管 stub → 固定入口 → VPS → 核实的境外 resolver”的默认解析路径应明确择一，不应并存不受控 fallback。[S2][S7]

设计选择有两种，按隔离层级决定，不直接覆盖宿主配置：

- 受管 namespace 使用独立挂载的 `resolv.conf`、受管 stub，并约束应用可见配置及出口；其余发行版可暂时保留 Windows DNS tunneling。须证明没有把 tunneling nameserver、宿主解析 IPC 或备用 NSS resolver 留给受管工作负载。
- 若最终将整个发行版默认网络也纳管，可在所有消费者完成迁移后评估关闭 DNS tunneling。但 `.wslconfig` 是 WSL 2 全局配置，可能影响 Docker/其他发行版；`generateResolvConf=false` 还涉及每发行版的 `/etc/wsl.conf`。先准备本地受控解析与失败关闭，不能先关再补 DNS。[S3][S7]

两者都不能以把 DNS 改成 `1.1.1.1` 就宣布成功；须证明到解析器的传输确实走 VPS，证书验证、bootstrap、重试、冷缓存和应用内 DNS 都符合要求。

### 4.4 `firewall=true`

它允许 Windows Firewall 及 Hyper-V 特定规则过滤 WSL 流量；不是自动生成 WSL 只准代理的 kill switch。应保留防火墙能力，再以 Linux OUTPUT/FORWARD 等适用链和精确 Windows/Hyper-V 规则形成分层控制。版本专家及主代理均核实 3.0.3 固定源码在 mirrored 模式强制启用 Hyper-V firewall；所以不能从配置写着 `firewall=false` 推断实际没有该过滤层，落地仍须核验有效状态。[S3][S9]

不照抄官方连通性示例中的“允许全部入站”。本项目不需要为此把 WSL 暴露到校园 LAN。不得以 Windows 全局 DNS 锁定、封锁 Dnscache、清空防火墙或停共享核心弥补设计缺口。

### 4.5 `hostAddressLoopback=true`

该选项仅用于 mirrored，允许通过宿主额外 IPv4 地址进行 host/guest 连接；`127.0.0.1` 的基本互通不依赖开启它。不代表支持所有宿主 IPv6 地址，也不代表可隐藏宿主 IP。[S3]

设计建议：若只需要 loopback 固定入口，**默认不额外开启此能力**；已有 true 值先盘点依赖，再在批准的窗口评估关闭。不能把它当作全流量代理的必需开关。

## 5. `.wslconfig` 修订原则：先改语义正确性，再谈模式迁移

既有历史记录的 network 相关键放在 `[experimental]`，不应据此断言它们已生效或完全无效：版本专家核实 3.0.3 源码仍兼容相应旧 experimental 键，而当前文档对正式键给出了新的位置。落地时需核对安装 tag 的兼容路径及告警，再归一化为唯一字段，不保留跨节冲突。[S3][S9]

当前官方文档定义：

- `[wsl2]`：`networkingMode`、`dnsTunneling`、`autoProxy`、`firewall`。
- `[experimental]`：`hostAddressLoopback`、`ignoredPorts`、`dnsTunnelingIpAddress`、`bestEffortDnsParsing`、`initialAutoProxyTimeout`。

以下只是**键位置示例，不是完整防漏配置，更不是本轮写入建议**：

```ini
[wsl2]
networkingMode=mirrored
firewall=true

[experimental]
hostAddressLoopback=false
```

`dnsTunneling` 和 `autoProxy` 需要在解析/数据面迁移方案确定后明确赋值；示例故意不替用户决定其全局值。正式修改应保留内存、磁盘、WSLg 等既有无关项，不整份替换文件。

`.wslconfig` 影响所有 WSL 2 发行版，修改通常需要实例真正停止后重新启动才应用。`wsl --shutdown` 会关闭所有运行发行版，影响 Docker 和后台任务；**不是无害的“刷新配置”命令，本轮不执行**。[S3]

## 6. 推荐技术组合与模式取舍

### 6.1 近期优先：核实并尽量保留现有承载，隔离受管工作负载

最小变更方向是先核实当前有效网络承载：若实际已为 mirrored，则优先保留作原型候选；若文件中的 mirrored 未生效，不因本报告自动切换。不要因为版本升级或接口隐私目标直接切 NAT：Windows 固定入口能否原生持久化是第一闸门；跨宿主 loopback 的 TCP、标准 SOCKS5 UDP relay 均需隔离实测。成功后才设计 Linux 内部 TUN、netns、受管 broker 与权限降级。

正确建立的 workload netns 不移入 NAT/mirrored 外层接口，两种承载都可以减少该工作负载的接口枚举视图。NAT 不天然比“mirrored 外层 + 受限 netns”更安全；底层应由实际可达性、UDP 回程、双栈和管理成本决定，而非模式名字决定。

netns 的 `127.0.0.1` 是它自己的回环，**不是自动可用的 Windows loopback**。透明器取得宿主入口连接必须经受审 broker、位于外层的受限转发器或其他精确通道。该通道必须同时处理 TCP、UDP ASSOCIATE、UDP relay 返回地址、认证、源身份和禁止其他目的地；不是随便开一个 TCP relay 就完成。

候选工具沿用已固定版本的 [GitHub 调查](wsl-vps-github-project-survey-2026-10-15.md)：

- `tun2proxy/tun2proxy`：优先研究原生 namespace/TUN-fd 集成；其 socket transfer 交出的未连接 socket 使适配进程仍是受信边界，需补固定代理目的约束，不能直接视为强沙箱。
- `heiher/hev-socks5-tunnel`：标准 SOCKS UDP 与 relay 地址控制的对照候选；其扩展 UDP-in-TCP 不能假定 Mihomo 支持。
- `xjasonlyu/tun2socks`：标准 SOCKS5 TCP/UDP 和双栈对照候选；Unix-domain SOCKS 不能替代该版本的 UDP 通道。
- `nsjail` / `bubblewrap`：可作 network/UTS/mount/env 隔离骨架，不提供 VPS 出口，不抵御宿主或 WSL root。
- `nftables`、策略路由、systemd：负责范围限制、启动顺序、服务身份与失败关闭；规则需包括 OUTPUT/FORWARD、容器和必要回程，不以一个 shell 的环境变量代替。

这些是待验证组件，不是已安装或相互兼容的组合；不在 Linux 再启动连接 VPS 的 Mihomo。

### 6.2 NAT：条件备选，不是天然“更隐身”

NAT 常让 Linux 主要看到自己的虚拟私网接口，但不消除内核、挂载、环境、IPC 与 interop 信息，也不强制 VPS 出口。Windows 服务在 NAT 下通常需要宿主 IP 可达；当前应用 loopback-only 固定入口与标准 UDP relay 的可达性必须重新设计。[S2]

只有 Clash of Rust 支持受约束的 WSL 专用监听/安全网关，并完成 TCP/UDP、认证和精确 Windows 防火墙设计后，才值得比较 NAT。不得简单设置 `allow-lan=true`、绑定 `0.0.0.0` 或对整个 LAN 放行；不得以仅转发 TCP 的 portproxy 冒充完整 SOCKS UDP 接管。

### 6.3 不优先的方案

- 只设 `HTTP_PROXY`/`ALL_PROXY`：仅覆盖遵循代理的应用，不是透明全流量。
- 只依赖 Windows TUN：是否捕获 WSL 的各类流量、DNS tunneling 和容器路径需实测；普通规则仍可能 DIRECT，不能由 TUN 开启推导全部固定 VPS。
- 将全 Windows 改 GLOBAL：会扩大影响，可能破坏 Windows 校园/API，且不解决本地接口隔离。
- 新开 Linux Mihomo：违反同核心目标。
- 直接 WireGuard/Tailscale 到 VPS：更适合真正 L3 虚拟子网，但通常是另一路隧道，不自动经过正式 Clash 同核心；属需另行同意的架构变更。
- 改成 consommé 或 WSLc：不自动获得固定 VPS、专属策略、德国指纹或失败关闭。

WSLc 官方架构说明 consommé 经 virtio 将网络交给 Windows 用户态进程，有助 VPN/防火墙兼容；不等于自动遵循本项目代理设置。3.0.3 `ConsommeNetworking.cpp` 仍从宿主派生 preferred IPv4/IPv6 生成/更新 guest 配置，因此也不能无测试地把 consommé 叫作“自动隐藏宿主地址”的模式。WSLc 的 network create/connect/disconnect 可作为未来隔离载体研究，但现有 Ubuntu 不会因软件包升级自动变成 WSLc 容器。[S12]

## 7. Clash 与 VPS 端必须先解决的事

既有已审计的 Clash of Rust 0.5.9 生成器清除自定义 `listeners`/`authentication`；此前调查的 0.5.10 tag 也未解除该限制。仅将 WSL 指向普通 17890、不受支持地写 runtime YAML、复用旧维护任务，都不足以提供可持续固定策略。实际安装/运行版本仍须实施前重新确认，本文不升级它。[S8]

首选原生产品能力是：应用持久化管理的 WSL 专属 listener/流量身份，严格绑定合格 VPS，无 DIRECT/PASS、无泛化自动选入其他节点，入口缺失时拒绝；普通模式、订阅、原生保护、节点切换和应用重启都不能悄悄改变 WSL 路径。已发布 fork Issue 仅登记需求，不证明功能已实现，见 [需求留档](issues/wsl-managed-network-feature-request.md)。

当前旧维护器在 live TUN 下拒绝重载的条件保持不动。不能为试 listener 重载生产核心、关共享 TUN，或通过补端口脚本掩盖多个配置写入者的竞争。若原生能力暂时没有，应先停留在隔离原型/文档阶段，而不是先迁移真实工作负载。

VPS 侧必须分清：**客户端用 IPv6 连接 VPS**、**目标最终使用 IPv4/IPv6 出站**、**目标如何判定地区**。既有特定域名 IPv4-only 规则不代表未来所有域名都如此。要固定全部 WSL 出口，还须评估服务端是否能辨识 WSL 流量身份、对相关出站明确指定 IPv4/IPv6 策略；不直接扩大或覆盖现有服务端规则。地区标签冲突的 IPv6 不能仅因属于同一 VPS 就算合格德国出口。

## 8. 时区、语言、地理位置与可见信息

WSL 新网络模式不修改浏览器语言、时区、地理定位权限、字体、GPU、TLS/HTTP 行为或账号历史；VPS 出口不是整台设备复制。

后续盘点应保留既有 Europe/Berlin 与用户原语言选择，检查启动后是否被 Windows 时区同步覆盖。当前官方 `/etc/wsl.conf` 的 `[time] useWindowsTimezone` 默认 true；若需要 Linux 独立 Berlin 时区，可在备份和范围确认后评估 false，再正确配置 tzdata。该项按发行版配置，不修改 Windows 时区，不把单个进程的 `TZ` 当作整个发行版都已一致。[S3]

公网查询应在批准的中立服务上返回经核验的 VPS 出站地址；本地 `ip addr`/路由命令应如实返回受管 namespace 的私网/TUN 地址，不应被伪装成 VPS 公网。netns 只减少接口视图，`uname`、`/proc`、WSLg、共享目录和 Windows interop 仍有独立边界。若真正要求与 VPS 相同内核/硬件执行环境，实际在 VPS 上运行工作负载更接近该语义，但这是不同架构，并不自动保证网站判定德国。

不随机生成浏览器指纹、不替换命令输出、不清理账号资料、不引入 HTTPS 中间人、不跳过证书验证；不保证任何平台永久认定德国。

## 9. 分阶段修改与验收

### P1：唯一实施者与安全盘点

阅读根约束、[故障记录 12](../../XUAN_VPS/docs/12-Windows-Clash-DNS-incident-2026-10-15.md) 和 [DNS 修复脚本](../../XUAN_VPS/scripts/repair-clash-system-dns.ps1)，但不例行运行修复。确认 Windows 日常通路的 `ipgw.neu.edu.cn` 与 `api.okinto.com` 的 DNS、TLS、HTTP 基线；异常时先诊断恢复，不扩大修改。用户已明确 **WSL 不需要校园服务**，不在 WSL 加校园/LAN/宿主 DNS 直连例外；Windows 保障不变。

备份本轮拟改对象并准备逐项回滚；协调其他 Codex 会话，只有一个网络写入者。先读取 Windows/WSL版本、`.wslconfig`、有效模式、核心归属、监听与旧任务；启动 Stopped 发行版需单独安排，因 systemd 可能启动旧网络服务。端口以 [单一清单](../../XUAN_VPS/docs/10-端口使用清单.md) 为准，不把 18001/1053/17892 视作现成可用入口。

### P2：隔离证明同核心固定入口

先证明入口存在、身份、认证、TCP/UDP、无 DIRECT、固定合格 VPS、配置重生持久化，以及与 Windows TUN/原生保护不冲突。只测一个 HTTP 请求或发现 UDP socket 均不足以通过。没有安全产品支持或隔离证据时，不改生产核心。

### P3：建立透明数据面与 DNS

在隔离/受管范围验证 TUN、双栈、策略路由、受限 broker、受管 DNS、Linux 默认拒绝及启动顺序；然后才归一化 `.wslconfig` 的节与选项。检测 NAT/consommé 意外回落。保留 Windows 普通网络，不封锁宿主系统 DNS，不全局禁用 Windows IPv6。

### P4：完整纳管进程和环境

覆盖 wsl.exe/终端/IDE 启动的 shell、system/user services、cron/timer、后台子进程。受管 netns 外的默认 namespace 同样不能成为普通用户出公网的后门；不把 launcher 当最终全覆盖。

Docker Desktop、原生 Docker、WSLc、容器 build/pull、host-network、rootless/privileged 容器和 socket 权限分别分类；不要假定 Ubuntu OUTPUT 管住其他 VM/daemon。Windows exe interop 或共享 socket 可启动宿主联网，受限环境需按授权禁用或最小共享，保留必要 WSLg/IDE 功能时记录例外。宿主管理员/WSL root 属明确不防御边界。

### P5：验收与定向回退

至少覆盖以下结果，所有功能均需实际证据，不能仅凭配置存在：

- 无代理变量、忽略代理的原生 TCP、标准 UDP、QUIC；IPv4/IPv6 目标、字面量、AAAA-only、Happy Eyeballs。
- DNS 冷启动、bootstrap、system/NSS、重试/fallback、应用内 DoH/DoT/DoQ、容器解析；绑定 resolver 目的和 VPS 路径证据，不仅是“未见 53”。
- CLI 公网 IP 与真实接口视图分别检查；时区 DST、语言和浏览器权限逐项对照，仍不运行 Claude 或模型请求。
- 核心/透明器/入口异常、启动竞态、profile/模式/节点切换、恢复与换网。失败场景只能在隔离环境或已有验证的独立关键通路时执行，禁止停用户共享核心、禁网卡或切 DNS 注入故障。
- Windows 两关键地址在每次真实网络改变前后，以及回退/交付前重新验证；不临时绕开日常通路、不忽略 TLS 验证。

正式验收延续 [VR-01–VR-17](wsl-vps-validation-and-review-2026-10-15.md)，补充 WSL 3.0 字段解析、有效模式/回落、DNS tunneling 非普通包路径、配置全局影响和新增 WSLc 范围。只拒绝不支持的 UDP/IPv6 应报告“安全降级、功能未完成”。

回退使用**本轮紧邻修改前**快照，只撤销本轮更改且当前仍归属本轮的对象；不恢复旧全局 NRPT/DNS 封锁，不覆盖后来的用户修改，不删除 CC Switch 或历史备份。

## 10. 专家评估与本轮验证

本轮有三条独立只读工作流：

- **版本研究专家**：核对 3.0.1–3.0.3 Release/API、3.0.0 tag 与 Release 404 的区别、历史功能时序和 3.0.3 固定源码。补充 mirrored 强制 Hyper-V firewall、旧 experimental 键兼容、Consommé 别名及 host-derived 地址边界。
- **架构专家**：比较 NAT/mirrored、独立 netns、标准 UDP、DNS tunneling 与全 WSL 生命周期。草稿早期曾偏向 NAT；进一步评估后明确不因接口隐私直接切 NAT，netns 才是工作负载接口视图的关键边界，主文采用修订结论。
- **独立复核专家**：审查新报告的版本/架构区分、DNS 虚拟化、字段节名、同核心闸门、systemd/容器/interop 范围及安全约束。未发现阻断性交付问题；提出“保留 mirrored”不能暗示已验有效模式，主代理已改成先核实有效状态再保留。

主代理另直接读取官方发布 API、Microsoft Learn 与 3.0.3 `WslCoreConfig.cpp` 对照关键结论，保留既有 Git 未提交文件。这是资料/方案审查，不是部署兼容性测试或安全认证。

只有 Markdown 变更，不需要网络回滚。本轮不为文档验证重新测试业务网址，不把历史关键地址响应、WSL版本或核心状态写成新实时验收。已完成严格 UTF-8 解码、相对链接、来源编号、代码围栏和行尾空白检查，`git diff --check` 无错误；字段节名已对照文档及固定源码。保留既有未提交文件，不提交、不推送。这些检查仅验证文档，不替代部署与运行验收。

## 11. 来源

- [S1：Microsoft WSL 3.0.3 发布](https://github.com/microsoft/WSL/releases/tag/3.0.3)；[发布列表](https://github.com/microsoft/WSL/releases)。
- [S2：Microsoft Learn — WSL Networking](https://learn.microsoft.com/en-us/windows/wsl/networking)。
- [S3：Microsoft Learn — .wslconfig / wsl.conf](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)。
- [S4：Microsoft WSL 3.0.1 发布](https://github.com/microsoft/WSL/releases/tag/3.0.1)。
- [S5：Microsoft WSL 3.0.2 发布](https://github.com/microsoft/WSL/releases/tag/3.0.2)。
- [S6：Microsoft WSL 3.0.0 Git tag](https://github.com/microsoft/WSL/tree/3.0.0)；[对应 Release API](https://api.github.com/repos/microsoft/WSL/releases/tags/3.0.0)（本轮返回 404，不是发布说明）。
- [S7：Microsoft Learn — Troubleshooting / DNS tunneling](https://learn.microsoft.com/en-us/windows/wsl/troubleshooting#networking-considerations-with-dns-tunneling)。
- [S8：Clash of Rust v0.5.9 配置生成器](https://github.com/Fu021/Clash-of-Rust/blob/v0.5.9/src/config.rs)；[v0.5.10 同文件](https://github.com/Fu021/Clash-of-Rust/blob/v0.5.10/src/config.rs)。本地对应结论见既有架构与 GitHub 调查；安装二进制与 tag 仍分开说明。
- [S9：Microsoft WSL 3.0.3 配置定义](https://github.com/microsoft/WSL/blob/3.0.3/src/windows/common/WslCoreConfig.h#L263-L294)；[旧节兼容解析](https://github.com/microsoft/WSL/blob/3.0.3/src/windows/common/WslCoreConfig.cpp#L115-L128)；[mirrored 强制 firewall](https://github.com/microsoft/WSL/blob/3.0.3/src/windows/common/WslCoreConfig.cpp#L152-L157)；[策略校验](https://github.com/microsoft/WSL/blob/3.0.3/src/windows/common/WslCoreConfig.cpp#L394-L403)；[非 mirrored 下的字段校验](https://github.com/microsoft/WSL/blob/3.0.3/src/windows/common/WslCoreConfig.cpp#L481-L485)；[Consommé/VirtioProxy 别名](https://github.com/microsoft/WSL/blob/3.0.3/src/windows/common/WslCoreConfig.h#L121-L128)。
- [S10：WSL 2.0.0 官方介绍](https://github.com/microsoft/WSL/discussions/10487)；[2.0.0 发布](https://github.com/microsoft/WSL/releases/tag/2.0.0)；[2.2.1 DNS tunneling 默认变化](https://github.com/microsoft/WSL/releases/tag/2.2.1)。
- [S11：2.9.3 Consommé 改名记录](https://github.com/microsoft/WSL/releases/tag/2.9.3)；[2.3.25 NAT fallback 记录](https://github.com/microsoft/WSL/releases/tag/2.3.25)；[2.4.5 bridged 弃用](https://github.com/microsoft/WSL/releases/tag/2.4.5)。
- [S12：WSLc 官方架构](https://devblogs.microsoft.com/commandline/wslc-architecture-deep-dive/)；[3.0.3 宿主派生 guest 配置](https://github.com/microsoft/WSL/blob/3.0.3/src/windows/common/ConsommeNetworking.cpp#L109-L123)；[地址/DNS/路由更新](https://github.com/microsoft/WSL/blob/3.0.3/src/windows/common/ConsommeNetworking.cpp#L333-L418)。
- [S13：IETF RFC 1928 — SOCKS Protocol Version 5](https://datatracker.ietf.org/doc/html/rfc1928)；[HevSocks5Tunnel：本地 ICMP Echo 回复说明](https://github.com/heiher/hev-socks5-tunnel#features)。后者仅说明候选工具的本地回复能力，不代表本机已启用或远端 ICMP 已转发。
- 补充固定证据：[Windows DNS resolver](https://github.com/microsoft/WSL/blob/3.0.3/src/windows/common/DnsResolver.cpp#L228-L257)；[HTTP proxy 读取](https://github.com/microsoft/WSL/blob/3.0.3/src/windows/service/exe/LxssHttpProxy.cpp#L102-L127)；[按模式处理 proxy](https://github.com/microsoft/WSL/blob/3.0.3/src/windows/service/exe/LxssHttpProxy.cpp#L305-L437)；[官方 WSL 1/2 版本命令](https://learn.microsoft.com/en-us/windows/wsl/basic-commands#list-installed-linux-distributions)。

技术候选的固定版本、许可证、源码局限与原始链接统一沿用 [GitHub 项目调查](wsl-vps-github-project-survey-2026-10-15.md)，不把动态 main 的说明当成本机已验证能力。
