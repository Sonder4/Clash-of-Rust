# WSL 经 Clash of Rust 到德国 VPS：GitHub 项目调查与选型

日期：2026-10-15。性质：公开资料搜索、固定版本源码抽查和专家评估；不是部署、安全审计或运行验收。

## 1. 对本次问题的直接回答

**有可以帮助的 GitHub 项目，但本轮没有找到能直接满足全部要求的一键成品。** 最有价值的是透明转发、进程隔离和受控 DNS 三类组件，而不是再装一份 Linux Mihomo 或仅设置 `HTTP_PROXY`。

本次延续的原始要求为：WSL 普通原生 TCP/UDP 请求透明经过 Windows 正式 Clash of Rust 的同一个核心，固定送到指定德国 VPS；公共解析经受控境外 DNS；公网查询不出现 Windows 实际公网地址；尽量减少本地接口和宿主信息暴露，保持时区、语言、浏览器及 CLI 环境一致。详细定义见 [R01–R13 需求总纲](wsl-vps-requirements-and-plan-2026-10-15.md)。

先给出选型结论：

- **透明转发原型优先研究 `tun2proxy/tun2proxy`**，因其内置 namespace 相关接口最接近既定方案；其默认 DNS 和跨 namespace socket 权限不能直接作为安全边界。
- **`heiher/hev-socks5-tunnel` 和 `xjasonlyu/tun2socks` 是数据面备选**，都值得验证标准 SOCKS5 UDP；选择其中一个，不同时部署三套转发器。
- **`google/nsjail` 或 `containers/bubblewrap` 可作隔离骨架**，用于真实减少接口、主机名及挂载视图，而不是修改 `ip addr` 输出。
- **`DNSCrypt/dnscrypt-proxy` 仅是有条件的 DNS 候选**；其 bootstrap、系统解析回退及 HTTP/3 路径必须另外封闭。若已有核心 DNS 能满足并证明要求，不必为了使用开源项目再叠一层解析器。
- **`wsl-vpnkit` 主要解决连通性，不保证固定 VPS 或失败关闭**；Tailscale/WireGuard 则主要对应另一种三层隧道架构。
- **最先解决的仍是 Clash of Rust 同核心固定入口及其持久化**。上述项目没有解决官方应用配置生成器清除自定义 listener 的问题。

这些是适配性建议，不是性能、安全性或维护质量排名。

## 2. 搜索方法、证据与限制

### 2.1 实际搜索范围

本轮主代理通过 GitHub 搜索 API 使用以下宽泛关键词，随后阅读命中候选的 README：

- [`WSL tun socks5 proxy`](https://api.github.com/search/repositories?q=WSL+tun+socks5+proxy&per_page=6)：返回 1 个命中，`uppet/wsl-tun2socks`。
- [`WSL vpnkit`](https://api.github.com/search/repositories?q=WSL+vpnkit&per_page=6)：返回 11 个命中，进一步查看 `sakai135/wsl-vpnkit`。
- [`WSL proxy windows network`](https://api.github.com/search/repositories?q=WSL+proxy+windows+network&per_page=6)：返回 14 个命中，包含环境配置和连接辅助工具。

三个专家子代理分别调查透明数据面、namespace/三层隧道、DNS/Clash 控制面；对指定项目进行精确仓库搜索，再读取仓库元数据、release/tag、README 和相关源码。检查功能是否实际实现，而非仅凭项目名称或宣传判定。部分隔离项目仅核查官方说明与手册，未做逐行源码审计。

搜索不是穷尽所有 GitHub 项目。关键词命中数、issue 搜索无结果、仓库未归档、stars 数及最近推送日期，都不能独立证明功能、安全性或长期维护承诺。

### 2.2 证据时效与时间源异常

本机记录约为 `2026-10-15 11:28–11:34 +08:00`，对应约 `03:28–03:34Z`；GitHub 响应的 HTTP Date 却约为 `11:28–11:34 GMT`，两者相差约 8 小时。部分 API 发布字段因此晚于本机折算的 UTC。

本文将版本称为“本轮 API 返回的标签”，不据此断言“截至本机现在最新已发布”，也不依据该时间序列判断谁更活跃。没有校时或升级软件。用于数据面和 DNS 关键结论的链接尽量固定到所读 tag；tag 本身也不等于不可变供应链锁定，实施时仍须记录解析后的 commit、产物校验及来源。

以下为 E-SOURCE/E-DESIGN 证据，不是 E-LIVE 运行证据。已安装 0.5.9、核心 v1.19.32、WSL 停止等状态来自 [前轮快照](wsl-vps-requirements-and-plan-2026-10-15.md)，本轮没有重新查询运行状态或把历史快照当成当前保证。

## 3. 透明 TCP/UDP 数据面：三个值得做原型的项目

### 3.1 tun2proxy/tun2proxy：优先研究 namespace 集成

项目：<https://github.com/tun2proxy/tun2proxy>。本轮 API 返回 `v0.8.4`，MIT，未归档；Rust。

能帮助的部分：

- 将 Linux TUN 流量转换为上游代理请求，不依赖普通应用遵守代理环境变量。
- [SOCKS 实现](https://github.com/tun2proxy/tun2proxy/blob/v0.8.4/src/socks.rs#L214)实际包含 UDP ASSOCIATE，不是只有 TCP CONNECT。
- [参数](https://github.com/tun2proxy/tun2proxy/blob/v0.8.4/src/args.rs#L49)和 [feature](https://github.com/tun2proxy/tun2proxy/blob/v0.8.4/Cargo.toml#L26)提供 unshare、TUN fd、IPv6 和 DNS 模式相关能力，适合研究“受管进程只见私有 TUN”的结构。

不能忽略的限制：

- 所读版本 **DNS 默认 direct，IPv6 默认未启用**；不能把默认配置称为满足本需求。virtual DNS、DNS-over-TCP、双栈和原始 IP 字面量必须分别设计。
- [socket_transfer.rs](https://github.com/tun2proxy/tun2proxy/blob/v0.8.4/src/socket_transfer.rs#L204)会创建并转交全局 namespace 中尚未连接的 TCP/UDP socket fd，所读分支没有把目的地限制为唯一 Windows 代理。持有 fd 的适配进程仍是受信组件；仅启用 unshare 不等于严格失败关闭。
- `--setup` 会修改路由和解析挂载；不能在正在使用的发行版直接照搬。admin command 的 namespace 权限也不能授给普通工作负载。
- 不管理 Windows 核心归属、GUI 配置重生、WSLg、Docker Desktop 或 Windows 子进程。

适用结论：**最值得先做 netns 原型，但安全边界必须补足**。需要约束适配进程可获得的宿主 socket、路由及目的地，不能仅证明 namespace 内 `ip addr` 看起来干净。

### 3.2 heiher/hev-socks5-tunnel：精细 UDP relay 备选

项目：<https://github.com/heiher/hev-socks5-tunnel>。本轮 API 返回 `2.19.0`，MIT，未归档；C/lwIP。

能帮助的部分：IPv4/IPv6 TUN-to-SOCKS，TCP 与 UDP；[配置示例](https://github.com/heiher/hev-socks5-tunnel/blob/2.19.0/conf/main.yml)提供 UDP 模式、relay 地址覆盖和 socket mark 等选项，便于研究 WSL 到 Windows 的 UDP 返回地址问题。

关键限制：

- 应优先验证标准 `socks5.udp: udp`。[UDP session 源码](https://github.com/heiher/hev-socks5-tunnel/blob/2.19.0/src/hev-socks5-session-udp.c#L432)区分不同模式；其 UDP-in-TCP 为 hev 扩展，**不能假定 Windows Mihomo 兼容**。
- `mapdns` 是映射 DNS 功能，不等于加密 DNS、境外 DNS 或失败关闭。
- ICMP Echo 可由本地模拟响应，成功 ping 不足以证明流量真正从 VPS 发出。
- [Linux TUN 实现](https://github.com/heiher/hev-socks5-tunnel/blob/2.19.0/src/hev-tunnel-linux.c#L52)涉及设备与网络配置权限；[库接口](https://github.com/heiher/hev-socks5-tunnel/blob/2.19.0/include/hev-socks5-tunnel.h)可接受外部 TUN fd，但是否能在目标配置下完成初始化后降权，仍需核验。

适用结论：当标准 SOCKS UDP relay 地址、标记和回程成为主要困难时，优先作为对照原型；不是自动管理全 WSL 的产品。

### 3.3 xjasonlyu/tun2socks：Go/gVisor 数据面备选

项目：<https://github.com/xjasonlyu/tun2socks>。本轮 API 返回 `v2.7.0`，MIT，未归档；Go/gVisor。

[SOCKS5 源码](https://github.com/xjasonlyu/tun2socks/blob/v2.7.0/proxy/socks5/socks5.go#L74)实际实现 UDP ASSOCIATE 并维持 TCP 控制连接；支持双栈，适合把流量交给 Windows 同一核心，而无需在 Linux 再保存 VPS 协议凭据。

关键限制：

- 同一实现明确拒绝 **Unix-domain SOCKS 的 UDP**。不能把 Unix socket 桥接当作全 TCP/UDP 解决方案。
- [TUN fd 支持](https://github.com/xjasonlyu/tun2socks/blob/v2.7.0/engine/parse.go#L57)不是自动降权或 netns 生命周期管理。
- [进程解析器处理](https://github.com/xjasonlyu/tun2socks/blob/v2.7.0/dns/resolver.go)不等于独立受控 DoH，也不封闭系统、应用或容器 DNS 旁路。
- 上游 socket 绕行、代理循环、防火墙和启动失败行为需要外部设计；本轮未测吞吐、内存或 WSL 兼容性。

适用结论：作为结构较清晰的数据面候选和其他 WSL 工具所依赖的基础组件，值得比较，但不因使用广泛就视作满足安全要求。

### 3.4 三者共有的原型前提

SOCKS TCP 连通不能替代 UDP 成功。还必须验证 UDP ASSOCIATE 返回的 `BND.ADDR/BND.PORT` 在实际 WSL NAT/mirrored/netns 拓扑可达、来源校验和回程正确、TCP 控制连接生命周期与 MTU/分片可接受。监听了 UDP 端口也不是这些条件的证据。

新增 netns 的 `127.0.0.1` 不等于发行版外层或 Windows 的 loopback。若需要受控桥接，须同时设计 TCP 与 UDP，限定调用者和目的地，不通过开放所有 LAN 访问来省略隔离。不新增或承诺端口；此前 17892 只是未验收设计，不能假定已经存在。

最终 R02 要求 **普通 TCP 和 UDP 均功能成功且不直出**；临时拒绝 UDP/IPv6 只是安全降级，对应功能仍为未完成。ICMP、组播及其他 IP 协议另列范围，不把 TUN-to-SOCKS 称作任意协议三层 VPN。

## 4. 减少本地宿主信息暴露：隔离骨架

### 4.1 google/nsjail

项目：<https://github.com/google/nsjail>。本轮 API 返回 [3.6](https://github.com/google/nsjail/releases/tag/3.6)，Apache-2.0，未归档。

[官方说明](https://github.com/google/nsjail/blob/master/README.md)包含 NET/UTS/USER/MOUNT/PID namespace 与 seccomp，可用于建立受管 CLI 的最小可见视图。但它不是代理、VPS 管理器或自动失败关闭方案；不能照抄 privileged、MACVLAN 或 pasta 例子并称其安全。

### 4.2 containers/bubblewrap

项目：<https://github.com/containers/bubblewrap>。本轮 API 返回 [v0.13.1](https://github.com/containers/bubblewrap/releases/tag/v0.13.1)，未归档。

[手册](https://github.com/containers/bubblewrap/blob/main/bwrap.xml)提供网络/UTS 隔离、hostname、挂载和环境约束；[README](https://github.com/containers/bubblewrap/blob/main/README.md)也明确它不是完整现成安全模型。GitHub license API 为 `NOASSERTION`，但 [bubblewrap.c](https://github.com/containers/bubblewrap/blob/main/bubblewrap.c)有 `LGPL-2.0-or-later` SPDX，[COPYING](https://github.com/containers/bubblewrap/blob/main/COPYING)为 LGPL 2.1 文本；采用代码前须按实际文件确认，不能写成“未知即随意使用”。

### 4.3 可达到和不可达到的界限

netns 可以使普通工作负载真实只看到自己的回环和私有 TUN/veth，而不直接枚举外层 mirrored 接口；UTS 可以提供独立主机名。因此公网查询可显示 VPS，而 `ip addr` 如实显示私有接口，两者不矛盾，也不应伪造命令结果。

但隔离器不把 VPS 公网地址赋给 WSL，也不复制 VPS 内核或硬件。宿主 root、可进入其他 namespace 的进程、拥有高权限 helper 或 Docker socket 的程序不在普通用户边界内。Windows interop、宿主挂载、会话总线、WSLg/GPU、IDE 和 OAuth 回调都可能重新暴露信息或建立旁路，须按最小权限逐项审查。

只包装一个 shell 不等于接管整个发行版：systemd 服务、未包装终端、其他 UID、容器和 Windows `.exe` 都须盘点。若先建“受限工作区”，应明确它是阶段性范围，不能冒充用户要求的全 WSL 完成。

## 5. 境外 DNS：有条件候选和明确排除项

### 5.1 DNSCrypt/dnscrypt-proxy

项目：<https://github.com/DNSCrypt/dnscrypt-proxy>。本轮 API 返回 `2.1.18`，ISC，未归档。

[示例配置](https://github.com/DNSCrypt/dnscrypt-proxy/blob/2.1.18/dnscrypt-proxy/example-dnscrypt-proxy.toml)及 [加载实现](https://github.com/DNSCrypt/dnscrypt-proxy/blob/2.1.18/dnscrypt-proxy/config_loader.go#L99)支持 SOCKS5 TCP 和用于 DoH 的 HTTP proxy；可研究“本地 UDP/TCP DNS → 受控 TCP/DoH → Windows 固定入口 → VPS”。本地收 UDP DNS 不等于上游支持 SOCKS UDP；所读 [vendored SOCKS](https://github.com/DNSCrypt/dnscrypt-proxy/blob/2.1.18/vendor/golang.org/x/net/internal/socks/socks.go#L233)仅支持 TCP/CONNECT 等，不提供可用 UDP ASSOCIATE。

不能只填代理 URL 就上线，原因是：

- [代理 TCP 分支](https://github.com/DNSCrypt/dnscrypt-proxy/blob/2.1.18/dnscrypt-proxy/xtransport.go#L324)失败会返回错误，这个分支没有自动回退直连；**但不代表其他路径都经过它**。
- 同文件 bootstrap 使用普通 DNS client；[后续分支](https://github.com/DNSCrypt/dnscrypt-proxy/blob/2.1.18/dnscrypt-proxy/xtransport.go#L624)在 bootstrap 失败后仍可能调用系统 resolver，即使 `ignore_system_dns=true`。不能按配置名推断完全无系统解析。
- HTTP/3 分支直接创建 UDP/QUIC，不等于 SOCKS/HTTP CONNECT。对此候选须关闭 H3，并核验实际版本行为。
- 解析器列表更新、冷缓存引导、代理域名预解析及转发例外必须审查；可研究静态 stamp/缓存预置，但须保留 TLS 证书与主机名校验。

选择条件：外部 namespace/egress 边界限制它只访问精确允许的入口，入口优先避免额外域名解析；显式约束 TCP、bootstrap、更新与回退，并完成冷启动和故障测试。`force_tcp` 或 `ignore_system_dns` 不是替代操作系统边界的安全证明。

### 5.2 AdguardTeam/dnsproxy

项目：<https://github.com/AdguardTeam/dnsproxy>。本轮 API 返回 `v0.86.0`，Apache-2.0。

所读 README/CLI 未找到原生出站 SOCKS/HTTP CONNECT 选项。[DoH transport](https://github.com/AdguardTeam/dnsproxy/blob/v0.86.0/upstream/doh.go#L490)自行设定 dialer，不能假定遵守 `HTTP_PROXY`；[默认 bootstrap](https://github.com/AdguardTeam/dnsproxy/blob/v0.86.0/upstream/upstream.go#L388)使用系统解析。

因此 **不选它来补“显式通过固定 SOCKS 入口的 DNS”缺口**。它可以作为已正确透明接管环境内的 DNS 程序，但安全性全部依赖外层；支持 DoH/DoT/DoQ 本身不等于支持代理出站。相关 [#292](https://github.com/AdguardTeam/dnsproxy/issues/292)、[#86](https://github.com/AdguardTeam/dnsproxy/issues/86)、[#410](https://github.com/AdguardTeam/dnsproxy/issues/410)的本轮搜索结果仍为 open，不能拿其他 closed issue 当功能已实现的证明。

### 5.3 DNS 要求不能偷换

DNS 是解析平面，不是所有业务数据的串行下一跳。应分别证明业务和解析都经过 VPS，并核验指定 resolver；anycast 地址、加密 DNS 或公共品牌不能单独证明实际节点/上游完全在境外。

允许任意应用访问任意 HTTPS 目标时，应用还可自行执行加密解析。普通代理不能在不解密 TLS 的条件下识别所有这种行为；要满足 R04 须另外约束受管应用或目标，无法证明的路径明确列出，不采用 HTTPS 中间人或忽略证书校验。

## 6. 名字很贴近 WSL，但不能直接照搬的项目

### 6.1 sakai135/wsl-vpnkit

项目：<https://github.com/sakai135/wsl-vpnkit>。本轮 API：MIT、未归档；README 为 [main](https://github.com/sakai135/wsl-vpnkit/blob/main/README.md)。

它主要解决 Windows VPN 导致 WSL 无法联网，通过 Windows 侧 gvproxy 建立连接，需要 Windows interop；README 也提示 HTTP 代理可能需要另外配置。**让流量能借 Windows 出去，不等于锁定到 Clash 或指定 VPS**，宿主代建的 socket 仍可能使用普通 Windows 路由。

它不解决用户要求的 interop 收敛、同核固定入口、全 DNS 约束和严格失败关闭；ICMP 行为也不能当完整远端 IP 转发证明。README 涉及路由/防火墙、发行版重建和恢复操作，不照抄执行，尤其不将 unregister 当普通诊断。

结论：保留为 WSL 连通性故障参考，不选作本需求主方案。

### 6.2 uppet/wsl-tun2socks

项目：<https://github.com/uppet/wsl-tun2socks>。本轮 API：未归档，license 字段为 `null`；本轮仅阅读 [README](https://github.com/uppet/wsl-tun2socks/blob/master/README.md)，未完成脚本源码审计。

它明确面向“WSL TUN → 已有 Windows SOCKS5”，包装 `xjasonlyu/tun2socks`，因此在路由、systemd 和诊断流程方面很贴近问题，值得参考。

但 README 自己排除开箱即用的严格 DNS 防泄漏、Windows `.exe` 和未额外处理的 IPv6；IPv6 blackhole 也不是双栈功能成功。其 down 恢复直连路由、主路由修改和 WSL 重启恢复建议，不构成本需求的独立失败关闭证明。按域名 sniffer 维持普通规则也不能代替固定 VPS 入口。

结论：**可参考其问题拆分，不直接运行安装脚本或当成经验证的一键方案**。公开可读不等于已授予复制/分发许可；采用代码前先确认许可证。license API 空值也不是最终法律判断。

## 7. 真正三层局域网需求：另列架构的项目

### 7.1 tailscale/tailscale

项目：<https://github.com/tailscale/tailscale>。本轮 API 返回 `v1.104.1`，BSD-3-Clause，未归档。

[Exit node](https://tailscale.com/kb/1103/exit-nodes)可让 VPS 提供互联网出口，更接近真实三层路由，但引入 daemon、身份/控制面、节点及可能的中继路径，仍须配置 VPS 转发、DNS、IPv6 和故障策略。[Userspace 模式](https://tailscale.com/kb/1112/userspace-networking)只提供 SOCKS/HTTP 代理，不自动透明接管所有 CLI。

直接由 WSL 建 Tailscale 隧道通常是平行数据面，不自动满足 R06“Windows Clash 同核心固定链”。即使 Windows TUN 可能捕获外层，也必须验证，不能靠推测认定。

### 7.2 WireGuard/wireguard-tools

项目：<https://github.com/WireGuard/wireguard-tools>。本轮 `/releases/latest` 返回 404，tag 查询返回 `v1.0.20260223`，GPL-2.0，未归档。它是工具，不等于完整内核、服务端和运维方案。

[官方 namespace 设计](https://www.wireguard.com/netns/)非常值得借鉴：接口移入受管 namespace，而加密 UDP socket 保留在创建它的 namespace。该机制有利于真实限定普通进程只见隧道接口，但 `wg-quick` 路由不是自动 kill switch，DNS、双栈、MTU、启动窗口及 VPS 回程仍须独立处理。

直接 WSL → VPS WireGuard 同样绕开指定的 Clash listener；HTTP CONNECT 不能承载任意 UDP。若用户以后优先要“真正的虚拟子网/任意 IP 协议”而允许改架构，再单独比较这些方案；本轮不增加远端服务或将它们悄悄替换为主方案。

## 8. Clash of Rust 官方项目：缺口仍在控制面

项目：<https://github.com/Fu021/Clash-of-Rust>，GitHub API 报告 GPL-3.0。本轮 API 返回 `v0.5.10`；鉴于第 2.2 节时间异常，只作为已取得的 tag 内容核查，不宣称应立即升级。已安装程序与本地 v0.5.9 checkout 都没有改变。

[v0.5.10 发布说明](https://github.com/Fu021/Clash-of-Rust/releases/tag/v0.5.10)主要涉及 macOS DNS 与更新助手；[该 tag 的 config.rs](https://github.com/Fu021/Clash-of-Rust/blob/v0.5.10/src/config.rs#L351)仍删除自定义 `listeners`/`authentication`，相关测试仍断言 listeners 为空。README 的 WSL 内容指向 Linux 构建，不是受支持的 Windows 同核 WSL 专属入口。

使用 `repo:Fu021/Clash-of-Rust WSL` 和 `listener` 的 issue/PR 搜索本轮各得 0；这只代表这些关键词未命中，不证明官方永远没有其他设计或未来支持。**本轮未找到足以解除持久入口闸门的官方功能证据。**

因此不能：

- 将普通 mixed-port 17890 的可用性等同于全部 WSL 请求永远固定该 VPS。
- 以普通全局模式或全 Windows `MATCH` 改写来替代 WSL 独立策略，破坏其他应用或校园认证。
- 通过启动旧 XUAN Mihomo、另装客户端或两个维护器互相覆盖绕过约束。
- 把完整配置 PUT、`force=false`、相同 TUN 配置或“热重载”字样当成生产无影响的证明；本轮没有执行写 API 或重载。

下一步应先研究受支持的同核心专属入口或可靠的 WSL 独立身份规则。若确实需要上游支持、受审辅助控制器、升级或源码改动，先单独确认范围和授权，而非安装透明层后才发现流量仍随普通规则漂移。

## 9. 推荐组合与不能承诺的内容

### 9.1 保持当前主目标时

推荐按职责组合，而不是寻找一个包办所有问题的客户端：

1. Windows 正式 Clash of Rust 继续独占管理现有核心；先验证 WSL 专用固定 VPS 入口的认证、UDP、配置重生及唯一控制者。
2. WSL 内从 tun2proxy/hev/tun2socks 中选一个透明适配器；它只接 Windows 固定入口，不在 WSL 再维护 VPS 凭据或独立 Mihomo。
3. 依据实际 userns/WSL/WSLg 兼容性，从 nsjail/bubblewrap 或等效受审 namespace 管理方式中选一种，限制普通工作负载的接口、挂载、interop 和权限。
4. 优先复用已能证明安全的核心 DNS；确需独立解析层时，再选择受操作系统边界限制的 dnscrypt-proxy TCP/DoH 方案。
5. 使用单一启动/回退责任方：先建立拒绝旁路边界，再开放已验证数据面；失败后不自动恢复直连。全 WSL 的服务、容器和跨系统进程需另行纳入。

隔离组件本身不是“德国指纹工具”。维持稳定的 Europe/Berlin/DST、既有语言和合法定位权限，参见 [身份威胁模型](wsl-vps-identity-threat-model-2026-10-15.md)。不引入随机指纹、反检测浏览器或伪造硬件工具；Camoufox 等仅覆盖特定浏览器，不能替代 CLI/全机网络边界。

### 9.2 仍不可由这些项目保证

- 完整复制 VPS 的硬件、内核、TLS/HTTP2、图形、字体、账号历史及所有浏览器指纹。
- 让 `ip addr`/`hostname -I` 真实拥有 VPS 公网 IP，或阻止宿主管理员读取 WSL。
- 让任意服务永久认可德国。尤其已有 VPS IPv6 地区库冲突，不能把“同一 VPS 的 IPv6”直接当成合格德国出口；入站 VPS 的地址族与 VPS 连接目标的出站地址族不同。
- 在不约束应用的情况下，证明任意 HTTPS 内都没有自主 DNS 或主动上传本地信息。
- 不经测试就承诺所有 UDP、ICMP、Docker、Windows 子进程、休眠/切网与故障窗口均无泄漏。

## 10. 后续原型闸门与验收

本节是建议，不是执行命令或本轮授权。与 [阶段 P1–P5](wsl-vps-requirements-and-plan-2026-10-15.md)和 [VR-01–VR-17](wsl-vps-validation-and-review-2026-10-15.md)配合：

1. **G0：协调与基线。** 与当前网络管理会话确定唯一实施者；读取故障记录 12 和 DNS 修复脚本但不例行执行。网络改动前验证校园认证和 API 的正常 DNS/TLS/HTTP，保存拟改对象即时备份及定向回滚。启动已停止 WSL 也须单独安排，因为 systemd 可激活旧服务。
2. **G1：先验证同核心入口。** 在隔离环境确认专属入口的 TCP/标准 SOCKS UDP、固定组成员、无 DIRECT 回退、身份认证、普通模式切换及 GUI 配置重生后仍存在。未通过，不迁移业务或新增常驻维护循环。
3. **G2：对照数据面。** 优先 tun2proxy，对照 hev 或 tun2socks；用清空代理变量的普通程序验证 TCP、UDP、IPv4/IPv6 字面量和 AAAA-only，记录实际 VPS 出口和 relay 回程。三者不是必须全部部署。
4. **G3：证明权限与解析边界。** 检查普通进程与 helper 能取得的宿主 socket、namespace/caps、DNS 冷启动/引导/列表更新/回退、应用内 DoH 和容器解析；netns 内地址视图只是证据之一，不代替抓包和实际路径证据。
5. **G4：完整性与故障。** 盘点发行版外层进程、systemd、Docker、Windows interop 和 WSLg；在隔离环境测入口消失、透明器退出、重启及换网。不可在用户依赖的生产核心上停服务或切 DNS 注入故障。缺少隔离条件时将项目保留 NOT-RUN。
6. **G5：范围相符才验收。** 每次网络变更后及回退后复核两个关键地址；分开报告“无直出”“功能成功”“地区合格”。不得把 UDP 拒绝或仅一个受限 shell 成功当全 WSL 完成。

未来涉及二进制采用时，另核对许可证、依赖、release 产物来源/校验及最小权限；本轮抽查不能代替供应链或安全评估。不提供未经本机盘点的批量路由、iptables、NRPT 或安装脚本。

## 11. 本轮变更、专家评估与撤回

本轮只在本目录新增本调查，并给需求总纲和本机交接增加入口；公开研究笔记在旧项目已忽略的 `runtime/github-wsl-research-20261015/`，不是运行配置，也不是文档阅读依赖。

未安装/编译/执行候选组件，未启动 WSL/Claude，未 SSH，未改写应用源码、安装目录、核心 API、DNS、路由、代理、TUN、防火墙、网卡、服务或任务。未访问目标业务进行测试，也未触碰 CC Switch。仅文档变更按项目约定核验文档，不为此重复网络验收；本轮不声称关键地址有新的实时验收结果。

三个专家分别交付数据面、隔离/L3、DNS/控制面的公开证据；整合后由 DNS/控制面专家独立只读复核版本、许可证、DNS 旁路、UDP 功能、namespace 权限及同核心持久化边界，未发现阻断交付的重大事实错误或剩余实质问题。部分隔离项目来源为 main/master，已保留抽查限制与实施前锁定 commit 的要求。此评审不是安全认证，运行需求仍未完成。

文档 QA 已核验三份涉及文档的 UTF-8、相对链接、外部 Markdown URL 语法、尾随空白及基本敏感内容模式；未发现异常。对比本轮修改前副本，需求总纲仅多一个入口，交接原文作为前缀完整保留。`git diff --check` 通过；这些文件仍为 untracked，故另做内容校验，不把该命令当作新增内容的完整检查。公开来源已在研究阶段读取，QA 不重复 HTTP 检测；基本模式扫描也不能证明绝无敏感数据。校验摘要保存在上述研究目录的 `document-qa/validation.json`。

撤回只涉及本次新增文档及两个入口段落，须先确认没有后续用户编辑，不恢复历史整文件或执行网络回滚。本轮不提交、不推送、不归档旧项目。
