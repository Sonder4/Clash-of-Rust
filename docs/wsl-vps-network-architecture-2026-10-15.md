# WSL 经 Windows Clash of Rust 同一核心接入 VPS：架构专家报告

日期：2026-10-15，Asia/Taipei。性质：只读调查与待审设计，不是部署记录。

## 1. 决策结论与证据等级

推荐的目标架构是：**WSL 发行版内部透明 TCP/UDP 适配与失败关闭，交给 Windows 官方 Clash of Rust 所管理的同一 Mihomo 的固定 VPS 入口，由该核心建立 VPS 隧道。** WSL 不直接持有 VPS 节点凭据，不另启连接 VPS 的 Mihomo，也不借迁移修改 Windows 全局 DNS。

但这个推荐目前是有硬闸门的设计，不是可立即执行的安装方案：

1. 官方 Clash of Rust 0.5.9 仍会删除订阅中的自定义 `listeners`；原生 Claude 保护不是 WSL 专用全目标出口。
2. 对应版本 Mihomo 的公开源码未提供独立 named listener CRUD API；完整配置更新会经过全局配置应用与 TUN 路径。不能把 `force=false` 理解为完全不影响 TUN/路由。
3. 现有旧维护器拒绝 live TUN 开启时重载。必须保留该安全条件；不能改路径、删判断后在现用网络试验。
4. 需要先在隔离环境证明与实际安装二进制相符的更新方式，或等待官方受支持的原生专用入口。没有通过该闸门时，交付应写“设计完成、部署未授权/未满足条件”，不能以普通17890、全局模式或另启Linux直连VPS核心冒充达标。

本报告区分三类证据：**现场**是主调查会话提供的带时间只读结果；**源码**是本地官方 v0.5.9 `f8a1379` 及公开 Mihomo v1.19.32 的静态语义；**设计**是尚未部署、必须授权与隔离验证的候选。公开版本字符串不证明安装二进制逐字等同上游。

相关文档：[需求与主计划](wsl-vps-requirements-and-plan-2026-10-15.md)、[身份威胁模型](wsl-vps-identity-threat-model-2026-10-15.md)、[验收与独立审查](wsl-vps-validation-and-review-2026-10-15.md)、[可视化总览](wsl-vps-design-overview-2026-10-15.html)。它们由同一轮其他工作流维护；本文不修改既有交接、源码、活动配置或计划任务。另一个用户 Codex 会话仍在管理活动客户端，后续必须明确单一网络写入所有者，不能并发重载。

## 2. 需求定义与诚实的“全流量”边界

需求编号用于与主报告对齐：

- **R01 出口**：WSL 对公网连接只经指定 VPS；禁止普通分流规则回退到本地直连或其他节点。
- **R02 全 TCP/UDP**：不依赖应用读取代理变量；透明TCP与UDP均须实际成功承载并验收。不支持时失败关闭只满足安全不变量，属于功能未完成，不得据此宣布R02通过。
- **R03 IPv6**：同时约束目标IPv6和隧道IPv6；不能只做IPv4透明转发后放任原生IPv6旁路。
- **R04 DNS**：普通解析与应用自带DNS均不得绕出；“地址是境外DNS”不等于“到DNS的连接经VPS”。
- **R05 失败关闭**：入口缺失、适配器退出、核心不可用时阻断WSL受控公网，不牵连Windows普通联网。
- **R06 同核持久**：最终只有官方Windows客户端管理的那一个核心连接VPS，配置重生/重启后机制有明确所有者和可验证恢复。
- **R07 身份**：保留并逐项检查既有时区、语言、地理位置、浏览器与CLI/Desktop环境，不把改IP等同改指纹。
- **R08 容器与interop**：区分发行版进程、Docker Desktop daemon/容器、Linux原生Docker、Windows exe互操作，分别证明覆盖或标为例外。
- **R09 关键网址**：持续保留 `https://ipgw.neu.edu.cn/` 与 `https://api.okinto.com/` 的日常DNS、TLS及HTTP访问。
- **R10 无目标在线测试**：本轮不启动Claude CLI/Desktop、不开其页面、不登录、不运行检测、不作模型调用。
- **R11 本地CLI可见性边界**：远端网站可不再直接看到本地公网出口；Windows宿主、本地管理员、WSL root及EDR仍可识别进程与网络活动，不能承诺“本地完全看不见”。
- **R12 文档不部署**：本报告不构成修改许可，不启动Stopped发行版、不SSH、不写核心API、不改网络。
- **R13 路由与地区一致性**：必须证明实际目标所用的VPS出站及地区，不用中立探针或其他域名的DE结果替代目标路由。

本方案的**无旁路安全不变量**是：所有受控公网TCP/UDP只能由同一核心经VPS承载，不支持时明确拒绝；不存在未经授权的公网直连。这不是“全流量完整功能通过”的替代定义：**R02最终必须证明透明TCP和UDP实际成功。全部阻断UDP只是临时安全降级，功能验收仍未通过；只有用户明确修改需求范围，才能降低最终承载目标。** 若要求“任意IP协议全部可用，含真正ICMP转发、广播、组播和任意raw socket”，普通SOCKS/HTTP代理架构不能默认满足，必须调整承载协议与权限边界。不能把ICMP被本地合成响应当作到VPS的真实ping。

WSLg显示、回环IPC、容器内部通信等不是公网出口，但必须列明本地允许范围，不能用“允许所有回环/私网”制造另一代理出口。对可自行改防火墙、路由、netns或调用宿主Windows exe的特权主体，不存在仅靠发行版iptables就能建立的强宿主安全边界。

## 3. 当前状态：不把历史设计当成已生效

主调查会话提供的现场摘要如下，不是本文再次启动应用取得：

- 10:28：WSL版本3.0.3.0，用户发行版处于Stopped。本文没有唤醒它们，因此没有当场证明其网络模式、iptables、systemd启动顺序或浏览器环境。
- 10:29：认证只读核心查询报告 v1.19.32、rule；TUN开启，`auto-route`、`strict-route`、IPv6为true；普通17890有TCP/UDP监听，9090有TCP监听；18001、1053、17892均无监听。
- 同轮磁盘两个nameserver都有 `#COR-Claude-*` 固定保护组后缀。`respect-rules=false` 不代表这些请求直连；显式DNS代理后缀要单独解释。
- 10:41：只读psutil确认核心进程属于 `D:\Clash of Rust\resources\mihomo.exe`，父进程是正式应用，`-d/-f` 对应当前data/runtime；源码checkout为v0.5.9 `f8a1379`。
- 实时 `tun.stack` 值为 `Mips`，磁盘为 `mips`。保留本机真实值，不能擅自替换为常见system/gvisor/mixed；它与公开源码/依赖的具体枚举语义、构建来源仍需匹配核验。

因此，旧WSL链路依赖的18001和1053当前缺失，是具体兼容断点；但“补两个端口”不等于完成透明转发、失败关闭和地理验收。17890有UDP socket也不自动证明WSL到它的SOCKS UDP关联、返回地址及整个VPS链路都能工作。

旧安装脚本、服务及浏览器适配器的现状需以后在授权后读取，不能由文件名推断服务活跃。旧资料的边界已在 [WSL全流量说明](../../XUAN_VPS/docs/WSL-Claude-DE-全流量.md) 明示：它主要是显式代理加TCP/UDP直连拒绝，未完成透明TCP、ICMP、其他回环代理与Docker daemon全覆盖。

## 4. 官方0.5.9原生能力与硬限制

### 4.1 自定义入口会被清理

本地源码依据：

- [Settings](../src/config.rs#L41)只有一个 `mixed_port`，没有专用WSL listener对象；不能凭空给settings增加字段并声称应用会持久化。
- [runtime_config_with_rules](../src/config.rs#L339)从profile生成运行时。第351行的注释说明应用拥有所有入口；第361行删除 `listeners`，第362行删除 `authentication`。
- [固定普通入口](../src/config.rs#L366)把HTTP/SOCKS/redir/tproxy独立端口置0，只用 `settings.mixed_port`，并强制 `allow-lan=false`、bind到 `127.0.0.1`。
- [回归测试](../src/config.rs#L911)注入不可信listener；第920行断言生成结果不存在listeners。这是有意安全设计，不是新版“也许已修复”的未知项。

所以将18001写入订阅、运行时YAML或调试API后暂时出现，不等于原生支持。把普通mixed_port改成18001会迁移整个普通入口，并影响现有Chrome17890，不能当作添加WSL专用入口。面向NAT直接把bind改为0.0.0.0也会扩大暴露、破坏应用入口安全语义，不能作为快捷办法。

### 4.2 Claude保护是特定目标固定节点，不是WSL全目标策略

[保护应用逻辑](../src/claude_check/protection.rs#L162)创建一个隐藏 `COR-Claude-*` 单节点Selector；provider模式使用精确名称过滤和 `empty-fallback=REJECT`。第205行起仅对预定义域、关联域、关键词、诊断域和官方入站IP加优先规则。第220行起保留其余原规则，第239行强制rule模式。因此WSL访问其他目标仍可能按原规则直连或使用其他组。

[DNS与TUN覆盖](../src/claude_check/protection.rs#L253)强制公网DoH经保护组、启用fake-IP；第290行保留private名称system解析；第295行起启用strict-route/TCP与UDP DNS接管并移除原TUN排除项。[BOOTSTRAP](../src/claude_check/protection.rs#L55)仍是直连阿里DoH，仅为节点引导解析。节点地址是IP literal时不应据此宣称引导请求一定发生，但也不能把存在此配置说成“所有DNS天然经VPS”。

[配置事务](../src/engine.rs#L1199)保存保护、恢复记录与runtime；第1219行起目标运行状态为rule/TUN；[启动恢复](../src/engine.rs#L1614)会重新启用保护。保存的普通偏好和实时rule/TUN不同，可能是设计中的临时覆盖，不能擅改磁盘来“统一”。[设置限制](../src/engine.rs#L688)与[订阅锁定](../src/engine.rs#L988)要求先关闭保护再改部分设置/订阅；本轮没有授权执行该开关。

[后台Guard](../src/claude_check/guard.rs#L41)观测并关闭已识别异常连接，不等于在发行版启动前封堵所有数据包，也不保证核心外旁路。官方 [检测说明](claude-region-detection.md) 同样限定了覆盖范围、私有DNS例外和独立浏览器/指纹验证。

## 5. 当前Mihomo是否能独立热插listener

### 5.1 API结论

已只读检查官方公开 **v1.19.32 tag**，不是用开发分支替代安装版本：

- [hub/route/server.go，第128–142行](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/hub/route/server.go#L128)注册configs/proxies/groups/rules/connections/providers等路由，未见独立 `/listeners` CRUD 路由。
- [hub/route/configs.go，第25–60行](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/hub/route/configs.go#L25)提供GET/PUT/PATCH configs；PATCH schema没有named `listeners` 字段。不能猜测向 `/listeners` PUT即可热插，也不能把未知字段HTTP成功当作生效。
- 同文件 [第448行](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/hub/route/configs.go#L448)完整PUT调用 `executor.ApplyConfig(cfg, force)`。

公开常规代码的结论是：**没有查到受支持的独立named listener CRUD；候选机制仍是完整配置提交。** 安装核心的扩展/构建来源与上游版本标签未逐字核实，不能进一步断言它绝无任何私有API；也不能因这个可能性对生产发写请求探测。

### 5.2 `force=false` 与“严格相同TUN”候选

[executor.ApplyConfig，第84–123行](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/hub/executor/executor.go#L84)会全局 `OnSuspend`，更新proxies/rules/sniffer/hosts/general/DNS/NTP，再更新listeners、TUN，最后 `OnRunning` 和重置resolver连接。不是只增一端口的事务。

[updateListeners，第186行](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/hub/executor/executor.go#L186)先 `PatchInboundListeners(..., true)`，再按force决定是否重建普通端口；因此 `force=false` 仍可更新named listeners。[updateTun，第210行](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/hub/executor/executor.go#L210)没有force豁免，仍调用 `ReCreateTun`。

存在一个**未来受审实现候选**：[listener.ReCreateTun，第498–535行](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/listener/listener.go#L498)先Sort，若 `tunConf.Equal(LastTunConf)`，只调用当前TUN的 `OnReload` 并返回；不等则关闭旧TUN后重建。[Tun.Equal，第99行](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/listener/config/tun.go#L99)比较enable/device/stack、DNS hijack、路由、MTU等大量字段，不是只比较enable与stack。named listener自身的 [更新逻辑，第627行](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/listener/listener.go#L627)也会按配置相等跳过、变化时关闭重开，并删除提交中遗漏的旧listener。

这支持研究“同一审计控制器完整保留所有配置和TUN语义，只合并一个named listener”的可能性，**但不证明生产无损或可立即实施**：

1. 当前GET /configs未必暴露完整、可逆的生成输入，重用磁盘配置也可能漏掉原生保护内存覆盖或归一化默认值。
2. 即使TUN结构Equal，`OnReload`、DNS/provider/规则和全局suspend仍有副作用，不能等同无网络变化。
3. 本机stack为Mips，版本标签不证明与公开二进制完全相同；须对实际安装核心的隔离副本验证，而非把生产核心当试验台。
4. Clash应用重生配置会再次删除额外listeners，仍需解决单一写入所有权、竞态、重试隔离和失败关闭持久化。
5. 旧维护器在live TUN时拒绝重载的安全条件保持不动。只有新方案独立审查、隔离通过、关键网址持续通路成立且得到明确授权后，才可讨论另一个受控实现；不能借本文静态分析放宽旧guard。

较理想的长期能力是上游原生提供受校验的WSL专用listener对象：应用生成与重启都保留、只允许固定非DIRECT目标、UDP能力可声明、禁止不必要公网暴露，并有与原生保护协同的事务。**这是未来产品支持建议，0.5.9当前没有。** 本轮不修改或编译上游源码。

## 6. 推荐主方案A：WSL透明适配 + 同一核心固定入口

### 6.1 应用数据与DNS是并行业务链，不是串行“DNS下一跳”

应用数据链：WSL应用产生目标TCP/UDP，进入发行版专用TUN/透明适配层，经SOCKS5/兼容的UDP relay交给Windows同一核心固定VPS入口，由核心建立VLESS/Hysteria等既有隧道，再由VPS连接目标网站。

普通DNS链：WSL libc/system resolver先查询发行版本地受控stub；stub把DNS封装为DoH/DoT等可承载请求，经同一固定入口和VPS到指定递归解析器，返回记录给应用。**解析完成后应用的数据独立走应用链，不是所有网页数据经过DNS服务器。**

浏览器/应用内置DoH、DoQ、硬编码IP和DNS缓存绕过的是libc解析链，但其实际网络请求仍必须进入透明适配与固定入口。需要检查其resolver目的地与传输；“允许应用DoH”不会自动违反出口约束，也不代表其DNS政策符合预期。

两种DNS实现候选择一作为发行版普通解析的权威来源：

- **WSL内stub经固定入口发DoH**：不依赖当前缺失的Windows1053，易保持解析与普通应用相同出口。仅stub代理进程拥有到固定入口的例外；不得意外把它的DoH再指回自己。固定DoH端点证书/SNI仍验证，不使用跳过TLS证书验证。
- **Windows专用受控DNS入口**：WSL stub转发到同一核心的DNS listener，上游必须显式绑定固定VPS组。必须先解决listener存在、归属、WSL可达性和共享DNS的影响范围，不能仅因1053曾使用便恢复整个旧栈。

两条是可替代的普通解析实现，不应同时互相转发形成循环。Windows宿主日常DNS、NRPT、Dnscache完全不作为WSL失败关闭的锁定对象（R04/R09）。

### 6.2 tun2socks选择与协议能力

这里“tun2socks”指Linux用户态IP到代理适配器，不是某个产品名称的功能保证。候选包括xjasonlyu/tun2socks与hev-socks5-tunnel等项目；必须先审查其确定版本的TCP、SOCKS5 UDP ASSOCIATE、IPv6目标/relay、超时、MTU、fragment、DNS和capability行为，并用该安装核心隔离验证。本文不下载、不安装、不把README支持宣称为本机测试结果。

- TCP：透明接管需要默认路由/策略路由、原目标保留、专用服务账户及反回环规则；应用不读HTTP_PROXY也应受控。
- UDP：必须是适配器到固定SOCKS5 relay再到支持UDP的VPS节点的完整链。HTTP CONNECT入口单独不足以承载任意UDP；UDP-over-TCP也需两端明确支持，不能擅加协议字段。
- IPv6：TUN内可接管IPv6目标，同时根据地区政策决定由VPS真实IPv6发出或明确拒绝。IPv6隧道承载可保留，不等于允许目标IPv6出口。仅关闭浏览器IPv6或删除AAAA不是包级防旁路。
- ICMP：一般SOCKS不承载任意ICMP；应明确拒绝公网ICMP或确认适配器行为。必需的本地IPv6邻居发现/PMTU相关控制消息不能粗暴全阻后宣称网络正常，需按作用域及实现验证。
- 其他协议、raw socket、multicast/ROS2：默认不承载；受控边界应拒绝公网旁路。业务例外须单独授权并列入不经VPS清单，不能默默开放。

### 6.3 失败关闭与控制面

Linux防火墙/路由应有明确启动顺序：先安装受控出口策略，再启动stub和适配器，最后允许普通应用；服务异常时不能由ExecStop清除所有保护。允许适配器自身到Windows固定入口的引导路径，避免默认TUN捕获自己的代理连接形成递归。不得为方便直接放行所有回环、私网和宿主端口；控制API9090不属于普通WSL应用所需网络出口。

明确拒绝其他已知本地代理通路只能解决一部分问题，最终允许策略应按受审socket目的地、服务身份及所需IPC建立。WSL root可改规则属于信任边界，不承诺抵抗宿主管理员。R08的容器forward链必须另管，不能假设OUTPUT规则覆盖转发流量。

固定入口设计应直接绑定固定节点或仅含合格VPS节点的组，无DIRECT/PASS、无其他地区节点、无通配provider自动纳入。若组选择会变化，需锁定与审计；节点缺失或UDP不支持时拒绝，不能继续匹配原规则。18001可作为旧适配兼容端口候选，**尚未分配/创建**；任何新增/移动端口前须更新 [端口单一事实来源](../../XUAN_VPS/docs/10-端口使用清单.md) 并检查占用。不能复用未验收17892却称独立WSL入口。

### 6.4 受管workload network namespace：部分减少本地设备信息可见性

如果需求包含“普通Linux CLI运行 `ip addr` 不应直接列出mirrored宿主全局IPv6”，仅改变默认路由不够。可研究将**受管CLI/浏览器工作负载**置于单独Linux network namespace，而非把整个用户发行版的共享默认命名空间当隐私边界。此方案尚未创建或实测，不能假定历史工作负载会自动进入。全WSL普通原生公网流量仍是最终目标，namespace/launcher只是分阶段实施边界，不是缩小目标的授权。普通交互shell、systemd系统与用户服务、子进程继承、定时任务及后台进程均须纳管或在验收表明确标为未覆盖；只证明一个受管launcher成功，不能宣称整个WSL已完成。必须在授权后建立完整进程与启动入口清单，再确定迁移顺序。

候选拓扑分为权限内外两侧：

- **工作负载侧**只有自己的lo、私有地址veth与专用TUN；真实mirrored/NAT接口不移入，宿主全局IPv6不赋给这些接口。默认IPv4/IPv6公网路径只能进入TUN；veth是到专用relay的控制/代理传输链，不提供普通WAN转发。普通 `ip addr` 会诚实显示此namespace设备，而不是伪造命令结果；它不会显示VPS公网IP“属于本机接口”。
- **边界/relay侧**保留在外部namespace，只准连接已核验Windows固定proxy地址/端口。优先使用独立relay身份、不可被普通工作负载修改的cgroup/UID与专用链；禁止IP forwarding把工作负载包直接转发到外部真实WAN。外部侧不开放shell通用转发、任意SOCKS上游或9090控制API。
- **TUN适配器**可以在受管namespace内以专用非特权身份运行，初始化时由受信管理者创建TUN/路由，再移交所需fd/设备权限；普通CLI不能继承CAP_NET_ADMIN、CAP_NET_RAW或可进入外部namespace的fd。若实现要求适配器常驻高权限，应作为新的风险审查，不给整个namespace中的应用附加这些capability。
- **TCP与UDP relay**需分别实现并验证。SOCKS5 UDP ASSOCIATE返回的relay地址必须是工作负载可达且受限的私有边界地址，不能把Windows/公网relay地址原样返回后迫使工作负载开真实WAN路由；控制连接、UDP关联生命周期、来源认证、目标编码及返回端口映射都要隔离验证。仅做TCP端口转发不算UDP支持。
- **DNS stub**置于工作负载namespace的loopback，普通解析只访问它；stub的DoH经同一个私有relay再进入固定VPS入口。外部边界不把普通53/任意宿主resolver开放给工作负载。若使用Unix域socket而非veth传送代理控制数据，仍须明确UDP数据传送实现，不能假设普通tun2socks原生支持Unix socket。

失败关闭由边界策略与namespace的无真实WAN路径共同约束，而不是依赖普通CLI自觉保留环境变量。cgroup/UID只是授权标识，不能抵抗WSL root、宿主管理员或可任意创建特权容器的主体；禁止普通工作负载获得setns/unshare相关越界权限，具体用户namespace、setuid工具、继承fd和容器能力仍需逐项审查。

本地例外精确列出：namespace内loopback服务、必要私有relay socket、WSLg所需Unix域显示/音频连接及应用实际需要的IPC。WSLg通常不要求把宿主所有TCP回环端口都开放；应按实际AF_UNIX/共享目录权限验证，不能放行整个127/8或私网段作为捷径。Docker socket、宿主 `/proc`/namespace句柄、`/mnt/c`敏感路径及Windows interop会扩大边界；受管workload的launcher需按用户同意限制或移除这些暴露，不修改整个发行版互操作来误伤既有开发环境。

Linux网络namespace只隔离网络设备与路由视图，不隔离所有机器身份。若普通CLI还能调用Windows exe、读宿主挂载/proc或访问Docker API，仍可发现Windows/WSL痕迹。更强的本地可见性需求还需要mount/PID权限和受控launcher，不得把network namespace描述为完整沙箱。远端浏览器指纹与地区资格依然另验（R07/R11/R13）。

实施时先在隔离工作负载中验证 `ip addr`、路由、UDP/DNS与绕过负例，再决定是否纳管Claude；本轮R10禁止启动目标。该边界可以部分满足R11，但不能修复第5节尚未通过的同核心固定入口持久化闸门；即使namespace可建，也不能将普通17890当作固定VPS替身。
## 7. 其他候选与取舍

### 方案B：复用当前17890 + 原生保护 + 代理变量

优点是无需新增listener；显式HTTP/SOCKS应用可较快兼容，原生保护已能固定其覆盖目标。缺点是普通规则仍决定其他目标，程序可忽略变量，透明UDP和IPv6旁路、失败关闭都没有因此解决。若增加WSL透明适配而仍接普通17890，也只是把更多流量交给普通分流，不等于固定VPS。

结论：可作为另行授权后的有限功能验证，不满足R01/R02/R05的最终保证；不能作为主方案的同义实现。

### 方案C：NAT WSL源子网 + Windows现有TUN源地址规则

候选是利用已经存在的TUN，在普通规则之前对真正可区分的WSL源地址/入站条件固定到VPS，避免新增listener。它仍是WSL经Windows同一核心到VPS，符合路径目标，值得作为A被入口闸门阻断时的研究备选。

但需同时证明以下条件，否则不能部署或声称原生已支持：

1. 宿主接收到WSL流量、经过Hyper-V/NAT/TUN后的核心metadata仍保留原WSL源，而非已SNAT为Windows地址或回环地址。规则名 `SRC-IP-CIDR` 存在不等于现场一定能识别。
2. 匹配范围不混入Docker Desktop、其他发行版或Windows程序；同一WSL VM内多发行版可能共享网络边界，不能仅以一个子网声称逐发行版隔离。
3. NAT地址重建/重启后变化有受支持的更新与失败关闭机制；WSL直连流量是否必经现有TUN也需覆盖TCP/UDP/IPv6证明。
4. 原生Claude保护会在普通规则之前注入自己的规则（见第4.2节），并锁定部分规则编辑操作。如果源地址规则落在它之后，已被Claude规则匹配的流量不会再用新规则；固定组必须与现保护节点一致或有明确协调方案。不能猜测“加第一条”就能跨过应用overlay顺序。
5. DNS可能由宿主代发而丢失WSL源，不能用数据流SRC规则推导DNS也正确。失败时宿主TUN失效不能让WSL回退物理网卡。
6. mirrored不保证具有稳定独占的WSL NAT源子网；该方案不能在镜像模式凭空套用。

本轮没有启动Stopped发行版，也没有生成用于证明的中立流量/包捕获，因此这些均是未验证闸门。不能现在为迁就它切换网络模式、修改现有TUN或全局规则（R09/R12）。

### 方案D：Linux自己连接VPS、SSH隧道或VPN直达VPS

可能简化Linux透明转发，但把节点、凭据、隧道生命周期移到WSL，绕过Windows官方Clash同一核心。即使出口是同一个VPS，也违反R06和用户指定路径。只能在用户明确更改目标后单独立项，不能作为当前“更简单的修复”偷偷采用。

### 方案E：官方未来原生WSL专用listener

长期维护最清晰，与A的Linux侧兼容；应用原生持久生成入口并与保护事务协作，可消除外部overlay竞态。但0.5.9没有该能力，本轮既不改源码也不编译替换。应将其列为上游支持路径，不把等待未来功能写成当前已完成。

## 8. NAT、mirrored及“隐藏Windows”能做到什么

Microsoft [WSL网络说明](https://learn.microsoft.com/windows/wsl/networking)区分默认NAT与mirrored；[高级配置](https://learn.microsoft.com/windows/wsl/wsl-config)说明networkingMode、dnsTunneling、autoProxy等设置。本文引用为后续核验入口，不把Windows与WSL版本号直接映射成某个活动模式。

- NAT：Linux访问Windows通常使用宿主在WSL虚拟网络的地址，宿主只绑定127.0.0.1的listener不能假定可达。需要受控bridge/relay或经证明的host-loopback机制；桥接的TCP/UDP地址、认证、Hyper-V防火墙、来源限制、端口占用均是新设计对象。不能把listener扩大到所有网卡来规避问题。
- mirrored：Microsoft支持Linux访问Windows IPv4 localhost，但具体双向端口冲突、IPv6 localhost差异、UDP ASSOCIATE返回地址、Windows TUN和防火墙仍需实测。不能简单将 `127.0.0.1` 换 `::1`；非本轮授权不启动WSL验证。
- dnsTunneling/autoProxy是WSL集成能力，不是“固定VPS与失败关闭”的证明。旧 `/etc/resolv.conf` 人工固定和自动生成开关可能覆盖集成行为，需只读对照后设计迁移。

远端网站能看到的是它收到连接的VPS公网地址、协议和应用提供的指纹。Linux浏览器/CLI可呈现Linux环境，但HTTP User-Agent、Client Hints、字体、WebGL、时区、语言、WebRTC候选、地理位置权限、代理头、DNS和TLS实现仍可揭示差异；“Windows作为转发宿主”不自动出现在每个HTTP请求中，也无法承诺不可推断。

对本地宿主，Windows仍可看到WSL VM/进程、Windows代理核心及到VPS的连接；本地CLI、系统审计、管理员与EDR权限不会因经VPS消失。若“隐藏Windows”指从本地CLI/宿主彻底消除这些事实，这是不可达承诺（R11）。本方案不规避EDR、不伪造安全日志、不保证网站无法识别自动化或账号风险。

## 9. VPS出口、IPv6和地区：不能混淆三层地址

需要独立识别：Linux应用目标地址族、Windows到VPS的隧道端点地址族、VPS到目标网站的出站地址族。客户端以IPv6连接VPS，网站仍可看到VPS IPv4；客户端改用IPv4节点也不自动阻止VPS向目标发出IPv6。

[OpenAI变更](vps-ai-ipv4-change-2026-10-15.md)与[Claude变更](vps-claude-ipv4-change-2026-10-15.md)记录：现有服务端只对列明匹配器做严格IPv4解析/IPv6拒绝，保留其他原规则；后续合计31个明确匹配器。这不是WSL任意目标全域IPv4保证。共享遥测、存储、外部provider/MCP/工作区工具、未知IP字面量和无法识别的ECH/QUIC可能不在分类范围。

历史现场还存在VPS IPv6在地区库标CN与标DE冲突，不能因它不是本机地址就宣布安全。目标真实出口若仍有地区冲突，按R13停止对应在线验证；本轮R10更严格，无论中立结果如何都不启动Claude。

若用户希望所有WSL目标都呈现一致德国IPv4，需另行授权服务器侧按可区分的WSL身份/入站/专用认证通道做严格IPv4-only策略，明确AAAA-only拒绝；不能把整个共享入站用户都改掉而误伤Windows或其他客户端。若同一节点与凭据使服务端无法区分WSL，不存在凭空增加“仅WSL”服务端政策的办法，必须承认需要新的身份设计或更广影响授权。双栈全可用与所有网站仅看到IPv4也不能同时作为未经定义的承诺。

不在本报告新增公网入站端口。已有SSH22、订阅443、Reality10443、HY2 444保持原分工；任何服务端变更先备份、校验与定向回滚，必须重新明确授权，不能由本文触发SSH。

## 10. 指纹、浏览器及Claude兼容边界

原有Europe/Berlin、en_US/en-US、地理位置、浏览器profile、Camoufox/Firefox适配和Claude user service环境应保留并逐项只读比较。系统语言是偏好，不是德国地理证明；en-US与德国出口不天然矛盾，也不能擅自全改为de-DE。时区应关注Europe/Berlin季节性夏令时，不能固定UTC+1冒充全年一致。

Linux桌面应用可从systemd user environment继承旧HTTP_PROXY/ALL_PROXY；旧127.0.0.1:12345/18001适配器可能仍指向缺失Windows入口。恢复网络时先确认每层角色，不能删掉本地认证兼容层或保留硬编码旧端口后宣称已迁移。浏览器单独代理、SOCKS remote DNS、WebRTC/QUIC及DoH也需明确策略。

这里只列后续检查点，不启动CLI的help/version、Desktop、浏览器或登录。静态端点审计见 [本轮离线报告](claude-app-static-network-audit-2026-10-15.md)，它不等于运行时完整连接清单，也不证明账号、风控或地理资格。CC Switch数据目录、备份及外部helper完全不在迁移修改范围。

## 11. 实施阶段、授权与定向回退

### 阶段0：本轮文档完成，不部署

本文只创建本报告，读取源码和公开文档。没有启动WSL、SSH或核心写API，没有访问Claude，没有修改Windows DNS/NRPT/代理/TUN/防火墙、服务或启动任务。因此没有网络回退操作；文档撤回仅涉及本文件，不能借此执行网络恢复脚本。

### 阶段1：另行授权后的只读基线与隔离设计

先与另一活动Codex会话约定单一写入者。验证两关键网址的实际日常DNS/TLS/HTTP并记录时间与通路，不跳证书、不临时绕日常代理制造通过。只读盘点当前settings/运行配置/保护选择/安装二进制、WSL模式与发行版服务；Stopped发行版的启动本身须明确授权，不能冒充被动检查。所有敏感数据仅在本地白名单字段比较，不转储secret、真实端点或完整profile。

确定实际二进制构建与Mips语义，隔离复现same-TUN更新、named listener保持、UDP relay及失败关闭；隔离环境使用独立资源且不影响生产TUN。若无法构造满足R09的隔离/独立通路，停止入口实验，而不是放宽旧维护器条件。

### 阶段2：先过同核心固定入口与持久化闸门

实施前准备紧邻变更快照、哈希、事务所有权、仅本轮对象的回退清单。未来控制器必须合并完整named listeners并保留原生保护、当前Mips TUN、选择器、DNS及其他内存配置；检测到源/进程/选择变化时停止，不能抢写用户新配置。先证明入口正常且固定，无DIRECT回退，再迁移WSL应用。

**没有受支持且隔离验证通过的入口机制，不执行这一阶段。** 不能先把所有WSL指向不存在端口；不能先关当前保护/TUN；不能用共享核心重启做故障测试。每个改变状态的步骤后复验两个关键网址；异常立即停止并只撤回本轮确认导致异常的对象。

### 阶段3：单发行版试点，不先覆盖所有发行版

备份并记录已有iptables/nftables后端、专用链、policy routing、resolv.conf文件/符号链接状态、wsl.conf合并内容、systemd unit与环境、浏览器适配、Docker用户/daemon设置。保留原有时区/语言；敏感代理URL不写日志。

先构建仅本轮命名的规则/服务及失败关闭，再启用解析和透明适配；测试通过后才切普通流量。处理多发行版共享网络命名空间及端口冲突。若需重启WSL应用或整台VM，必须另行协调，不能用 `wsl --shutdown` 顺便中断所有发行版。

回退只删除/恢复本轮拥有的规则、路由、服务与精确配置字段；不要flush整个表，不恢复远早于本轮的全量文件，不运行旧恢复脚本覆盖后来用户改动。恢复原先受保护但不通的状态与放开公网直连是不同动作；若回退会取消失败关闭并可能泄漏，先保持WSL应用停用/受控，向用户说明，不能自动放行。

### 阶段4：容器、interop与应用兼容

Linux原生Docker需检查FORWARD/DOCKER-USER与容器DNS；Docker Desktop daemon在发行版外，需宿主设置/网络边界独立证明。镜像pull不是Docker客户端HTTP_PROXY自动覆盖的行为。host-network、特权容器、独立netns及Windows exe互操作分别列为不受控或建立经授权的限制；禁止以一条OUTPUT规则覆盖所有这些路径的说法。

Claude保持离线，不登录、不启动。其他获准中立程序先验证；后续若用户重新授权Claude运行，还必须重新完成当时目标路由与德国出口门槛，不能继承今日历史样本。

### 阶段5：验收与保留未覆盖项

正例：显式代理与清空代理环境的TCP、DNS UDP/TCP/应用DoH、UDP relay、IPv4/IPv6目标和返回路径；核对核心实际入站/链路与VPS出站。负例：其他未授权本地代理、未经批准的公共DNS解析器或DNS直出、未授权备用IPv6及未知协议应有明确拒绝证据，不以任意超时当通过。

失败测试只在隔离应用路径/隔离VM或具备经验证独立关键通路时进行；不得停止用户共享核心、切DNS、禁网卡、重启Wi-Fi。不能安全验证的核心退出/休眠/换网窗口保留为未验收。最终逐项标R01–R13通过、部分、未验证或不满足，不能只写“网络已正常”。

## 12. 总体风险与下一步决策

最小正确下一步不是运行旧WSL配置脚本，而是审核 **同核心固定入口的受支持持久化机制** 与 **当前Stopped发行版的实际网络/身份状态**。两者都未证明时，只能给出主方案和可行性闸门，不能宣称完成迁移。

优先研究A的入口事务；若0.5.9外部overlay无法在隔离中证明安全，研究C的源身份路径与规则优先级；若二者都不成立，等待官方原生支持或向用户报告约束冲突。D不作为暗中降级选项。对任一方案，VPS地区/出站、Linux失败关闭、DNS两链、容器边界和指纹保留都仍需独立验收。

本报告没有授权执行命令的快捷清单，也没有可直接加载的私密配置。公开源码结论是设计依据，现场时间点是样本，不是“任何时候、任何网络绝不泄漏”的保证。