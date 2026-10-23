# WSL 经 Clash of Rust / 德国 VPS：独立验收与红队设计评审

记录时间：2026-10-15，Asia/Taipei。官方资料读取时间约 10:27–10:29（UTC+08:00）。

**状态：分析与验收设计，不是已部署方案，不是实机验收通过。** 本文作者仅阅读本地交接、旧审计与公开官方资料；没有启动 WSL、SSH、运行 Claude/浏览器探针、停止共享核心、改变 DNS/防火墙/代理/路由或应用配置。本文中的测试均为未来协调窗口的验收要求，不是已执行结果。

## 1. 评审输入、需求与证据等级

已阅读 [本项目操作约束](../AGENTS.md)、[本机交接](local-network-handoff-2026-10-15.md) 以及 [旧项目 WSL 迁移只读审计](../../XUAN_VPS/docs/14-WSL-ClashOfRust-migration-audit-2026-10-15.md)。历史实测只能支持其记录时刻，不证明现在仍相同。方案以主报告的需求为准，本文统一使用以下需求 ID：

- R01：WSL 对公网服务的可见出口为受控德国 VPS，不是宿主真实公网地址。
- R02：无代理意识程序的 TCP/UDP 也能透明经 VPS 成功通信；不能只支持代理环境变量。
- R03：IPv6、IPv6 字面量和 AAAA 路径受控；不支持时拒绝而不直连，功能缺口须单列。
- R04：WSL DNS 经 VPS 到受控境外解析服务，启动引导、备用及应用自带解析不得泄漏。
- R05：指定受保护范围内失败关闭，不以普通 Windows 联网被切断为代价。
- R06：使用 Clash of Rust 管理的同一核心，入口与固定出口策略可持久再生且无 DIRECT 回退。
- R07：时区、语言、地理位置、浏览器与 CLI/应用身份一致，保留既有用户数据。
- R08：Docker、Windows interop、子进程及动态第三方 MCP 分别界定与约束。
- R09：保护 `https://ipgw.neu.edu.cn/` 与 `https://api.okinto.com/` 的日常通路。
- R10：本轮不访问实际 Claude/Anthropic，不用账号、模型请求或第三方全量检测作测试。
- R11：区分公网 IP 与本地接口可见性；不谎称隐藏 `ip addr`、`hostname -I` 的真实私网信息。
- R12：详细文档与部署边界明确，不把设计、配置文件或静态测试当作部署完成。
- R13：VPS 地区判断、客户端到 VPS 地址族与 VPS 到目标的实际出站地址族分别核验。

每个未来测试至少分别记录：功能结果、泄漏安全结果、覆盖边界、证据时间、软件版本、配置代次、所用路径。结果枚举为 `PASS`、`FAIL`、`BLOCKED`、`NOT-RUN`、`NOT-SUPPORTED`。本文作者未执行实机测试；主报告另有根代理执行的 Windows 部分基线。当前没有完整矩阵项目通过，WSL 测试均为 `NOT-RUN`。

- 功能通过：计划要求成功的协议/应用确实成功，且接收端观测到正确 VPS 出口。
- 安全通过：同轮抓包、计数器、关联日志和接收端证据支持没有通过非授权出口发送测试流量。
- `UDP 被拒绝` 可以是局部安全通过，但不能算 R02 完整功能通过。
- 仅超时、`curl` 返回码、规则存在、进程存活、GeoIP 显示 DE、环境变量存在，均不是完整链路证明。
- 不能通过有限采样证明未来所有网络、内核、应用版本下绝对零泄漏；应报告经验证的不变量及适用版本/边界。

## 2. 官方证据及其设计后果

### 2.1 WSL 网络与 Windows 边界

Microsoft [WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking) 与 [.wslconfig](https://learn.microsoft.com/en-us/windows/wsl/wsl-config) 明确：

- 默认 NAT 与 mirrored 是不同架构。mirrored 下 Linux 可经 `127.0.0.1` 连接 Windows；不能从这一事实推断其他地址、IPv6 回环或 UDP 都已按预期受到过滤。
- `autoProxy` 镜像 Windows HTTP 代理信息，不是任意 IP 协议隧道。Windows 系统代理未启用时，更不能认为它能自动发现当前 TUN 或固定 VPS 组。
- `dnsTunneling` 通过虚拟化机制回答 Linux DNS，而不是普通网络报文。因此仅抓 Linux UDP/53、仅设置 Linux OUTPUT 拒绝，可能看不到或拦不到它委托 Windows 的解析。
- mirrored 可支持 IPv6、多播、直接 LAN 访问。这些是能力，非隐私保证；开启 mirrored 本身会引入需要单独验证的 LAN/IPv6 路径。
- `.wslconfig` 影响 WSL2 全局 VM 行为，不应当作单一 Ubuntu 服务的无影响设置。配置生效可能需要退出/重启 WSL，本轮不得为查看而启动或重启。

Microsoft [WSL troubleshooting](https://learn.microsoft.com/en-us/windows/wsl/troubleshooting) 的 `Considerations when using autoProxy` / `Networking considerations with DNS tunneling` 进一步说明：

- 自动代理会生成大小写代理变量与 `NO_PROXY`；用户通过 WSLENV 指定的变量可优先于镜像值。PAC 仅提供 `WSL_PAC_URL`，Linux 应用通常不会自动解释 PAC。
- DNS tunneling 可应用 Windows DNS 后缀、NRPT 与系统加密策略，不能因此认定已满足“WSL DNS 必经 VPS”。若要在 Linux 内自行实施 DoH/DoT，官方说明需要禁用 DNS tunneling；这属于将来的受控变更，不是当前操作建议。
- Docker Desktop 管理的容器 DNS 绕过 WSL DNS tunneling，Docker Desktop 有自己的宿主 DNS 策略应用机制。

Microsoft [Hyper-V firewall](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/hyper-v-firewall) 明确按 `VMCreatorId` 管理 WSL，且 `LoopbackEnabled` 可无需 Hyper-V 规则允许主机/容器回环通信。由此：

- 不可把普通 Windows 出站应用规则、Linux OUTPUT、Hyper-V 规则三者混同。
- 有效策略须看 ActiveStore、网络 profile 和合并关系，而不是只看创建成功的规则。
- 若多个 WSL2 发行版/工作负载处在共同策略范围，不能以封锁全部 WSL VM 的方式顺手影响 Docker 或其他发行版。
- 默认允许宿主回环不等于只允许指定核心入口；其他本机代理、转发器和控制端口是独立逃逸面。

### 2.2 Mihomo 入口、TUN 与 DNS

Mihomo 官方 [listeners](https://wiki.metacubex.one/en/config/inbound/listeners/)：入口 `proxy` 可以直接使用指定代理/组；空值使用普通 rules。入口 `rule` 引用不存在时会落回普通 rules。这支持“入口强绑定受控组”优于依赖全局最终规则，但不证明 Clash of Rust 会保留该入口。

Mihomo 官方 [mixed](https://wiki.metacubex.one/en/config/inbound/listeners/mixed/) / [socks](https://wiki.metacubex.one/en/config/inbound/listeners/socks/)：`udp` 控制 UDP 监听；`users` 空值继承全局认证。未来须测试认证的实际效果，不能只看到字段。没有认证、LAN 暴露或可从其他路径连接的入口，会扩大宿主出口共享范围。

Mihomo 官方 [TUN](https://wiki.metacubex.one/en/config/inbound/tun/)：

- `dns-hijack` 未指定协议默认是 UDP；TCP DNS 需要对应设置。
- Windows/macOS 不能自动劫持发往本地网络的 DNS。TUN 开启不能代替 DNS tunneling、宿主 LAN DNS、Docker DNS 的逐项验证。
- `strict-route` 是与 `auto-route` 联动的路由行为，不是“核心退出后仍存在的 WSL 专用断网边界”。
- route exclusion、接口与 UID 过滤都会形成覆盖边界；代理内部 DIRECT 决策仍须核查。

Mihomo 官方 [DNS](https://wiki.metacubex.one/en/config/dns/) 区分 `default-nameserver`、`proxy-server-nameserver`、`direct-nameserver` 与业务 `nameserver` / `fallback`；`respect-rules` 还要求配置节点解析，避免循环引导。必须逐类审计，不能只看主 nameserver 是 DoH。

**版本门槛：** 上述是读取时在线官方文档的能力，不保证安装核心全部支持。实现前须对安装文件的真实版本及其匹配版本配置语义进行验证。旧审计已指出 Clash of Rust v0.5.9 生成逻辑会移除 `listeners`、`authentication`；内核支持与 GUI 持久管理是两个不同条件，不能用一次 API 写入冒充解决。

### 2.3 SOCKS、HTTP 与“全部数据”

[RFC 1928](https://www.rfc-editor.org/rfc/rfc1928.txt) 第 1、4、6、7 节：

- SOCKS5 是传输层代理，不提供网络层网关服务，例如 ICMP 转发。
- UDP 必须建立 `UDP ASSOCIATE`，保持其 TCP 控制连接；TCP 连接结束，UDP association 也结束。
- 客户端必须向返回的 `BND.ADDR/BND.PORT` 发送有 SOCKS UDP 头的数据。只允许固定 TCP 代理端口，通常不足以支持 UDP relay。
- 需验证实际返回的 relay 地址对 WSL 可达、源地址匹配与分片策略；不得通过开放任意目的 UDP 来“修好”relay。

[RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.txt) 第 9.3.6 节定义 CONNECT 隧道；普通 HTTP CONNECT 不能自动提供任意 UDP/ICMP。HTTP/3 本身基于 QUIC/UDP，浏览器回退 TCP 不能算已证明 QUIC 经 VPS。

因此“全部数据”需先定为可验证的目标：全部允许的公网 TCP/UDP 经 VPS，未支持 IP 协议在受保护范围拒绝；或进一步要求 ICMP 等三层包也可用。后者是额外三层能力门槛，现有 HTTP/SOCKS 入口不能直接承诺。若用户要求 ICMP 成功，ICMP 拒绝必须标为功能未满足，不能悄悄缩小需求。

### 2.4 DNS 地址、加密与地理位置不可混同

[RFC 4786](https://www.rfc-editor.org/rfc/rfc4786.txt) 将 anycast 描述为同一服务地址在多个离散位置提供服务。一个知名公网 DNS IP 不足以证明实际响应节点在德国或境外，更不能证明解析请求先经 VPS。

[RFC 8484](https://www.rfc-editor.org/rfc/rfc8484.txt) 定义 DoH；[RFC 7858](https://www.rfc-editor.org/rfc/rfc7858.txt) 定义 DoT。TLS 加密与证书正确可保护到解析服务的链路，但不决定链路从哪里出站，也不证明解析器的上游处理地点。DoT 规范允许按隐私策略选择失败处理；本项目必须明确禁止降级到大陆/宿主明文 DNS，而不是继承软件默认回退。

R04 应拆成：请求经 VPS、解析服务可信/非大陆、实际服务点境外证据、递归上游位置证据。可用解析器运营商文档、诊断接口与受控权威区日志支持其中一些层次；客户端通常无法完整证明递归器所有内部上游的物理位置。没有证据时记录“未证实”，不能用 `1.1.1.1`、HTTPS 或 GeoIP 一次结果代替。

## 3. 威胁模型与评审结论

### 3.1 必须守住的边界

受保护发行版的非特权进程、继承/不继承代理的应用及受保护浏览器不能绕过受控出口。承载代理连接的 Windows 只作为本地转发节点：目标服务不应看到其真实公网源地址，也不应从测试 HTTP 头、WebRTC 候选或应用遥测中得到宿主本地身份字段。

这并不隐藏以下事实：本机管理员可见网络架构；WSL `root` 若能改防火墙/网络或通过挂载执行宿主程序，就不在普通非特权隔离假设内；VPS 与代理运营方可见连接元数据；本地 `ip addr`、路由表、私网地址、虚拟化标记、GPU/字体/CPU/内核不能靠出口代理改造成 VPS 的硬件。R07 是地区配置一致与减少矛盾，不是完整复刻服务器设备或绝对不可识别。

公网 IP 探针通过不代表 `hostname -I` 不再返回 WSL 私网地址；后一命令本来就不是公网出口查询。若隐藏 Windows interop 或宿主挂载，需要额外产品/使用方式决策，不能伪造 CLI 输出充当实现。

### 3.2 初步红队发现（设计阶段，非运行漏洞断言）

1. **阻断项：同核心专用入口的持久化未解决。** v0.5.9 配置生成会移除自定义入口。必须先确定正式支持的持久方案、单写入者与代次校验；不允许“临时可连就完成”。关联 R06。
2. **高风险：只配置环境变量/普通 mixed-port 会保留透明流量直连和普通规则 DIRECT。** 需要 WSL 自身强制边界及入口固定组；绕过变量的 TCP/UDP 必须实测。关联 R01/R02/R05。
3. **高风险：SOCKS UDP relay 与回环白名单不匹配。** TCP 入站端口、UDP relay 端口、BND 地址、控制连接寿命、IPv6/IPv4 源校验都必须纳入，不能一律放开 UDP 或全回环端口。关联 R02/R03/R05。
4. **高风险：DNS tunneling、Docker 与 Windows interop 是 Linux 抓包/OUTPUT 的覆盖外通路。** 不应以 Ubuntu nftables 成功推导全范围成功。关联 R04/R08。
5. **高风险：以 IPv6 连接 VPS 不决定目标侧 IPv6 出口。** 历史 VPS IPv6 已出现地区库冲突。未知第三方 MCP/共享域可能不在既有 IPv4-only 分类范围内。关联 R03/R08/R13。
6. **高风险：启动、配置再生与网络切换存在规则暂态。** 默认拒绝须先于不可信应用运行；保存设置/订阅更新/原生保护恢复/核心自动恢复不能暴露无绑定入口。关联 R05/R06。
7. **限制：地理位置 API、地区库、语言与硬件指纹不能由 VPN 全部同步。** 固定旧 EXIT_IP、旧浏览器 GeoIP 数据、夏令时、容器 UTC 都可能产生不一致。关联 R07/R11/R13。
8. **禁止的“修复”：全局 NRPT 或封死 Windows Dnscache、停共享核心测试。** 这些会把 WSL保护扩大成全宿主故障，违反关键通路要求。关联 R09/R10/R12。

## 4. 验收证据设计

每轮测试使用随机 nonce、明确的开始/结束 UTC 时间和配置代次。中立受控测试端分别提供 IPv4/IPv6 HTTPS、TCP echo、UDP echo、可控 A/AAAA/权威 DNS 日志；不使用 Claude/Anthropic、用户账户、模型调用或可能自动请求目标站的检测页。

理想的关联链为：WSL 测试进程/UID或cgroup及nonce → WSL透明入口 → Windows核心的入口名和固定组/节点 → VPS该流源路由/出站观测 → 接收端源地址与nonce。对 DNS，还需解析器或受控权威区的同轮记录。仅拿另一条“相似”连接、另一进程或另一时刻的地址不能替代该请求。

抓包位置至少包含 WSL 出站边界与宿主物理出口；必要时另加 VPS 出站。Windows 物理网卡正常应看到到 VPS 的加密隧道，而不是可归因于受保护测试的目标直连或 DNS 查询。Windows 自己合法的校园 DNS/其他应用流量不能误判为 WSL 泄漏，需用nonce、进程及时间关联。抓包会包含隐私数据，只保存在用户控制的私密恢复/证据目录，文档仅写脱敏结果、证据文件摘要和哈希，不提交真实 IP、主机名、认证头或配置。

超时不是封锁的充分证据：需要测试端在正对照中能收到同类包，再结合受保护边界拒绝计数/事件及接收端未收到指定nonce。抓包缺包、权限不足或接收端异常都标为证据不足。

## 5. 测试矩阵（WSL 未测；VR-01 有 Windows 部分基线）

### VR-01 关键地址与日常通路基线（R09/R12）

对象：Windows 现有正常通路。核验系统域名解析、TLS 正常校验证书链/主机名和 HTTP 响应，校园认证重定向可正常；API 401/403 等需结合服务语义及变更前基线，不当作 DNS/TLS 失败。用户已明确 WSL 不需要访问校园服务，不将校园可达性列入 WSL 验收或增加校园直连例外；未来获准启动后，WSL 的 API 等获准公网目标另按最终受控 VPS 通路验收。不能用 `-k`、临时代理绕过或仅控制器端口成功代替。通过证据：每次变更前后有时间、路径、解析/TLS/HTTP结果；不得记录凭据。

当前部分证据：见[主报告](wsl-vps-requirements-and-plan-2026-10-15.md)中根代理于 10:28:45（UTC+08:00）的 Windows 日常通路验证，两域名系统 DNS 成功、TLS 校验值 0、跟随重定向最终 HTTP 200；没有临时绕开日常路由/TUN。此证据不是本文作者执行，也不包括 WSL 通路，不足以将 VR-01 整体标为 PASS；未来实际变更前后仍需新基线。

### VR-02 普通代理 CLI、大小写变量与 NO_PROXY（R01/R06）

对象：使用受控本地入口的中立 HTTP/HTTPS CLI，验证大小写 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY` 及 WSLENV/自动代理的优先级。使用代理远端解析语义与本地解析语义分别测试，避免把 `socks5h` 和 `socks5` 混为一谈。通过证据：实际请求关联到同一正式核心的专用入口、固定 VPS 组与接收端 VPS 地址，不仅是 env 输出。

### VR-03 清空代理环境的普通 TCP（R01/R02/R05）

对象：从命令环境中移除全部大小写代理变量、WSL_PAC_URL，设置应用忽略代理，分别连接测试域名、IPv4 字面量、非 80/443 TCP端口；检查 systemd服务、交互shell、后台子进程。通过证据：透明成功且端到端为 VPS；如果只是拒绝，记录安全通过/功能失败，不宣称全TCP迁移完成。

### VR-04 UDP、SOCKS association 与 QUIC（R02/R03/R05）

对象：无代理 UDP echo、显式 SOCKS5 UDP、UDP不同目的端口、多包/大包、association TCP关闭、认证失败、地址族切换；分别验证 relay 返回地址和端口的真实可达性。QUIC 必须由中立 HTTP/3 测试端证明协商的是 HTTP/3，而非浏览器悄悄降级为 TCP。通过证据：接收端nonce和VPS源地址、relay关联生命周期、宿主无直发；协议不支持单列，不用UDP Send成功当作到达证明。

### VR-05 IPv6 字面量、AAAA 与 Happy Eyeballs（R01/R03/R13）

对象：IPv6-only目的、`[IPv6]:port`、AAAA-only域名、A+AAAA双栈及连接竞速；域名和字面量分别测。通过证据：目标实际看到合格VPS地址族；策略IPv4-only时，AAAA-only/IPv6字面量明确拒绝且无回退直连，并单列功能限制。节点名含 IPv4、宿主到VPS使用IPv6、DNS返回A，三者都不能单独证明VPS到目标IPv4。

### VR-06 系统 DNS、TCP/UDP53、fake-IP（R04/R05）

对象：libc/NSS、systemd-resolved、`resolv.conf`、本地转发器，直接指定非授权公共/校园解析器的 UDP53 与TCP53，A/AAAA/HTTPS/SVCB、NXDOMAIN、截断转TCP、缓存未命中及搜索后缀。通过证据：授权请求经受控路径；任意外部解析尝试仅能经VPS或按明确策略拒绝；Windows宿主无可归因的受保护DNS直出。fake-IP返回值不作为真实公网IP或DNS上游地址。

### VR-07 DNS tunneling、DoH、DoT、应用解析（R04/R08）

对象：确认运行时DNS tunneling是否启用；不得只根据文件值判断。分别测试应用自带DoH、DoT/853、DoH-over-HTTP3和非标准端口，bootstrap、备用resolver、缓存清空后首次查询。通过证据：DNS tunneling若仍启用有可信Windows委托路径证据；自主DoH/DoT经VPS且TLS校验正常、没有降级。若要求只允许指定resolver，需另外的目的约束；端口53封锁不能识别所有HTTPS内加密DNS。权威DNS看到的递归源通常是resolver而非VPS，不能要求两者必相同。

### VR-08 ICMP、非TCP/UDP、本地发现（R02/R05/R11）

对象：ICMPv4/v6、raw socket（需要单独授权/隔离权限）、多播、mDNS/LLMNR、广播、LAN访问及邻居发现。通过证据：未经批准的公网/LAN旁路明确拒绝，局部邻居发现等必要控制流量有精确范围。若要求ICMP成功，需额外层3机制与真实echo证据；不能用`ping`失败宣称全协议完成。禁止为测试全局关闭宿主IPv6或网卡。

### VR-09 动态第三方 MCP、CLI子进程与应用身份（R01/R02/R07/R08/R10）

对象：用户批准的中立测试MCP，动态生成不在域名台账中的HTTPS/WS/SSE目标、重定向、IP字面量、子进程和自带解析库；不启动Claude本体。通过证据：即便无既有AI域名规则也经固定VPS；验证服务管理器环境与终端环境一致。静态Claude端点清单只作为范围输入，不可证明未知MCP或真实Claude运行全部受控。

### VR-10 Docker daemon、容器与特权边界（R01/R04/R05/R08）

对象：先确认Ubuntu原生Engine或Docker Desktop；分别检查daemon拉取、普通bridge容器、容器DNS、host network、build阶段、代理环境为空的容器。通过证据：每种网络命名空间各自关联到VPS，镜像拉取不因daemon绕过而泄漏。特权/NET_ADMIN容器与宿主root属于高权限威胁，须明确禁用/隔离或单列未覆盖，不能写Ubuntu OUTPUT一次结果覆盖Docker VM。

### VR-11 Windows interop、回环代理与宿主服务（R05/R08/R11）

对象：`curl.exe`、`powershell.exe`及其他Windows可执行文件由WSL启动的路径；宿主其他回环代理、WSL本地适配器、Windows核心控制器、宿主LAN地址。通过证据：若纳入保护必须有Windows侧独立限制与进程归属；否则禁止该interop路径或明确未覆盖。不能允许所有127/8端口并称“仅核心入口”，不能把控制器9090当代理入口。

### VR-12 启动与配置代次再生（R05/R06/R09）

隔离验证对象：首次发行版启动、systemd前后、shell启动前、登录、宿主重启、应用启动慢、核心自动恢复、订阅更新、保存设置、切换原生保护、运行配置重生。通过证据：默认拒绝先存在，受控入口及组校验通过后才开放业务；每个配置代次保留入口/认证/绑定，不出现暂态DIRECT。不能在用户活跃共享通路上执行这些状态改变作测试。

### VR-13 失败关闭、认证与上游不可用（R05/R06/R09）

隔离验证对象：模拟专用入口不可达、错误认证、代理组全部不可用、DNS不可用、透明转发器退出、controller失联、组名变化/节点删除、写入失败、无效配置、reload失败、UDP控制连接断开。通过证据：受保护工作负载不能转用普通入口、DIRECT或宿主DNS；恢复后需重新校验而非自动放宽。只失败相关组件的隔离副本，不停止正在服务用户的共享核心；本机关键网址持续可用。

### VR-14 网络切换、休眠与地址变化（R03/R05/R06/R09）

隔离验证对象：模拟NAT/镜像地址变化、宿主网络profile变化、IPv6前缀变化、Wi-Fi切换、VPN新增路由、休眠恢复、默认接口变化。通过证据：短暂窗口中仍无旁路，新入口/relay只授予精确最小范围；新旧规则切换原子化或先拒绝。禁止在用户正在用的校园通路直接切Wi-Fi或断网注入。

### VR-15 地区、时区、语言与浏览器一致性（R07/R11/R13）

对象：Linux与容器`Europe/Berlin`时区、tzdata夏令时、locale、应用`TZ/LANG/LC_*`、浏览器JS时区与navigator语言、Accept-Language、geolocation权限/值、WebRTC候选、GeoIP来源、旧EXIT_IP及profile持久性。通过证据：本地中立测试页与获准中立公网页面一致；现有en-US不擅改成de-DE，也不把英语判为德国目标失败。WSLg/Linux浏览器的CPU/GPU/字体/内核仍可能不同于VPS，报告限制；不重建用户profile或CC Switch数据库。

### VR-16 地区库冲突与目标真实源路由（R01/R03/R10/R13）

对象：同一精确出口地址的至少两个独立地理来源及登记/运营商资料；另外核对VPS到中立IPv4/IPv6目标的真实源路由。通过证据：地址、时间与路径一致，不能把ASN注册country当物理地点证明。出现CN/DE冲突或目标路径不明即保留未通过状态；不靠实际Claude请求去试地区门槛。未来若获授权验目标，必须另立同目标实时路由核验门槛，本文不提供该访问授权。

### VR-17 本地接口可见性与数据保全（R07/R11/R12）

对象：公网IP查询结果与本地接口命令结果分别记录语义；验证没有通过包装命令伪造输出。配置迁移不删除keyring、浏览器profile、CLI/Desktop设置、Docker数据；完全不操作`C:\Users\xuan\.cc-switch\`。通过证据：公网为VPS，本地私网仍如实显示，用户数据未受影响；不以重装应用掩盖网络缺口。

若采用身份报告 §2.3 的独立 netns/UTS 候选，另验证普通负载及子进程、后台服务确实留在受管 namespace；`ip addr`/`hostname -I` 返回其真实 `lo` 与私有 TUN/veth，而非宿主 mirrored 接口；独立 hostname 生效但内核不被谎称改变。验证 namespace 句柄、capability、sudo/Docker socket、宿主挂载与 interop 不能意外恢复超出已声明范围的视图或旁路。对精确桥接的 12345/18001、GUI/IDE socket 分别检查调用者和用途，不能为恢复回环而重新开放宿主默认网络。此项当前仍是候选及 NOT-RUN，不以命令视图更窄推导 R02 透明流量已经成功。

## 6. 安全执行分层与回退门槛

### A. 本轮可执行：只读资料与文档校验

检查已有交接、源代码语义和官方公开资料，核对Markdown相对链接及需求覆盖。不启动停止WSL、不运行CLI/Desktop或用户/业务浏览器、不SSH、不访问业务目标、不执行旧安装/恢复脚本。可以使用独立临时 headless 浏览器，仅渲染离线自包含本地 HTML 图解做文档布局 QA；不加载外部资源、不复用用户 profile、不作业务网络探针。此类离线文档渲染不代表浏览器网络或指纹验收。本轮没有网络状态改动，因而没有需要执行的网络回退。

### B. 后续经协调的只读现场探测

只有主负责人确认另一个会话无冲突、当前授权允许后，才查询当前进程归属/端口、核心认证只读API、有效规则、WSL状态和正常通路。启动已停止的WSL会触发旧systemd/防火墙/适配器，不能当作无副作用的读取。抓包、测试请求与服务探测可能暴露隐私或启动状态，也需按现场授权安排；本轮未执行。

开始任何可能影响网络的操作前，先阅读 [故障记录12](../../XUAN_VPS/docs/12-Windows-Clash-DNS-incident-2026-10-15.md) 和 [DNS定向修复脚本](../../XUAN_VPS/scripts/repair-clash-system-dns.ps1)。阅读不等于执行授权；不把修复/恢复脚本当例行检查。

### C. 未来部署的定向备份与回退

1. 先取VR-01主机基线，记录将改变的精确对象与操作；WSL未能安全启动时先解决审计门槛，不强开取得所谓基线。
2. 在私密位置备份紧邻变更前的应用设置/有效profile/覆盖层、`.wslconfig`、相关Linux网络/服务文件、将改的规则/任务及版本摘要。只备份本轮对象，保留既有用户配置，记录由谁管理生成过程。
3. 预置比较当前值/配置代次后的定向回退：只撤回本轮新增规则或恢复本轮确实改过且未被别人后来修改的字段；不恢复早期整个网络快照、不清空防火墙、不重置Windows网络。
4. 串行执行单个网络步骤，立刻复验关键两网址。任一异常立刻停止后续改动；仅撤回本轮已证实致因对象，再复验恢复。基线已异常时不得扩大变更。
5. 关键网址恢复、业务功能及安全证据全部达到目标后才讨论验收。没有独立、经验证的关键网址持续通路时，不开展共享核心/主机网络的故障验证。

### D. 隔离故障验证

用测试VM/专门隔离的网络命名空间和测试工作负载复刻配置生成及失败行为；它不必是第二个生产客户端，更不得把隔离副本接管当前宿主通路。只读源代码推演和离线规则测试是预审，不替代真实过滤/路由。隔离副本与正式版本、配置语义有差异时必须标注，不把实验室结果无条件外推。

## 7. 交付与结论边界

本文完成的是需求关联、官方资料核查、端到端测试设计和独立初步红队评审。本文作者没有运行实机验收；主报告记录根代理本轮 10:28:45 的 Windows 关键网址部分基线，不应被忽略，也不能推导 VR-01 整体、WSL 或其余矩阵项目通过。旧审计中的 Windows 历史通过同样不能转记为本轮 WSL 通过。

进入实施至少要先决定并审查：官方EXE“不改上游源码”约束下的入口持久化机制、单一配置管理者、透明转发层实际TCP/UDP/IPv6能力、DNS虚拟化路径、Windows interop/Docker范围、是否需要ICMP成功，以及服务端未知目标的IPv4/IPv6出站策略。解决前只能称详细候选方案，不可称“WSL已经完整接管”或“所有指纹已经复刻德国设备”。

最终验收须逐项回填VR-01至VR-17及R01至R13，附脱敏时间/版本/路径证据、通过与未覆盖内容、定向回退位置。没有证据的项目保持NOT-RUN/BLOCKED/NOT-SUPPORTED；不能以文档完成推导部署完成。

## 8. 跨文件独立复审记录

本节是文档一致性审查，不是网络实机验收。已只读审查[主总纲](wsl-vps-requirements-and-plan-2026-10-15.md)、[离线图解](wsl-vps-design-overview-2026-10-15.html)、[身份报告](wsl-vps-identity-threat-model-2026-10-15.md)与[网络架构报告](wsl-vps-network-architecture-2026-10-15.md)。

- 已发现并由身份报告作者修正：原先把“透明 TCP/UDP”表述成更高可选阶段，容易使 R02 被降为仅 TCP/DNS 成功、UDP 拒绝。修订后的 Scope N 与后续决策明确：拒绝 UDP 只是未完成的临时过渡，最终仍须透明 TCP/UDP 均成功，只有用户明确改需求才可减少最终范围。问题已解决。
- 作者测试边界与全团队证据已统一：本文作者/身份作者没有启动业务应用；根代理 Windows 主机部分基线与独立临时 headless 离线文档渲染分别记录，不外推为 WSL、浏览器网络或指纹验收通过。
- 已复核的主总纲/图解/身份报告在 R01 公网与本地接口区别、R02 功能和失败关闭区别、同核心持久化缺口、DNS并行解析、未知目标IPv6风险、interop/root覆盖边界、关键网址保护与定向回退方面未发现剩余实质矛盾。
- 图解内联资源及 CSP 符合离线文档定位；本结论仅基于静态内容，不替代根代理的布局渲染 QA。
- 身份报告补充的 netns/UTS 候选已复核：它提供普通负载真实、最小化的本地接口/hostname 视图，不是伪造 CLI 输出或完整复制 VPS；宿主 IPC、能力、子进程进入和透明转发的独立门槛均有保留。VR-17 已加入对应验收要求，当前未部署。
- 已发现并由架构报告作者修正：原先“全流量可验收定义”将承载或拒绝并列，可能让全部 UDP 拒绝被当作最终完成。修订后第 2 节明确这是无旁路安全不变量，R02 功能仍要求透明 TCP/UDP 实际成功；第 11 节 DNS 负例也从泛指公共 DNS 限定为未授权解析器或 DNS 直出，与经 VPS 使用获准公网解析器的正例区分。问题已解决。
- 架构报告第 5 节没有把 `force=false`、TUN 配置相等或公开源码推导成生产无损更新；全局 suspend、DNS/provider 副作用、实际二进制与 Mips 差异、原生生成覆盖及旧 guard 条件均作为实施硬闸门保留。A/C/E 与普通入口/独立 Linux 直连备选的合规取舍，没有暗中替换同核心路径。
- 架构报告第 6.4 节与身份报告 netns 候选相符，补充 relay 两侧、无 WAN forwarding、UDP返回地址/关联生命周期、权限与GUI精确例外；未将新建 namespace 当作已解决固定入口或全部指纹隔离。

最终文档交叉审查结论：上述实质范围歧义均已定向修正，当前五份交付文件之间未发现剩余实质矛盾。此结论仅为设计阶段一致性与风险表述审查；同核心入口持久化、具体透明适配器能力、DNS真实路径、WSL/容器/interop现场状态及所有生命周期故障验证仍未实现或未核验，不因此成为运行 PASS。
