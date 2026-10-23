# Clash of Rust 本机配置交接与后续任务

记录日期：2026-10-15，时区 Asia/Taipei（UTC+08:00）。
新工作目录：`E:\Desktop\workspace\Project\Clash-of-Rust`。
旧资料目录：`E:\Desktop\workspace\Project\XUAN_VPS`。

## 0. 后续更新核查（优先于下文历史路径）

2026-10-15 用户随后授权更新应用并要求新会话提示词。本轮确认：官方最新稳定版为 v0.5.9，实际运行的应用已是 `D:\Clash of Rust\clash-of-rust.exe` 0.5.9，核心为同目录 `resources\mihomo.exe`，注册表唯一安装条目也指向该处；因此没有再次安装、停止或重启应用。

克隆已从 `dab7714` 快进同步到官方 tag v0.5.9 的 `f8a1379`，保留全部本地交接文件。下文 0.5.7 克隆/0.5.8 安装路径描述属于此前历史，不能再当作当前定位。`D:\Clash` 的旧 0.5.8 文件仍在，但未运行；本轮未卸载或清理。

**仓库后续状态（2026-10-17）：** GitHub fork 与本地 `main` 已继续快进同步至上游 tag `v0.5.11`、提交 `78d5f548389fe80056027c03416210f16106917e`。这是源码仓库更新，不代表已安装应用升级；同步细节见第 22 节。

当前读取到：核心实时 rule/TUN开启，保存偏好仍 tun/global/dns_override=true，且新版 `claude_protection` 非空。新版保护可能有临时覆盖与恢复记录，先依 0.5.9 源码和实际 UI 核对语义，不将保存偏好与运行模式不同直接定性为故障，也不宣称保护已完成验收。维护任务核查为 Ready/Limited，17892 未监听。两个关键网址正常，见 [本轮更新记录](local-update-2026-10-15.md)。

旧维护器默认 app 路径、旧安装器的核心归属检查仍指向 `D:\Clash`，与当前安装不符。不能直接运行，也不能为了通过检查移除所有权校验。修复执行继续暂停；用户可使用 [新会话提示词](next-session-prompt.md) 在新目录明确开始后续工作。
## 1. 文档迁移时的交付与完成状态（历史）

用户要求暂停操作、先评估，再在 Clash of Rust 克隆目录开启新会话。本次只新增文档：

- 根目录 `AGENTS.md`：新会话必须继承的约束与阅读顺序。
- 本文：此前改动、证据边界、未解决问题和执行顺序。
- [XUAN VPS 资料检索指南](xuan-vps-reference.md)：查找 SSH、服务、订阅、端口、原脚本的方法。

本轮没有修改上游源码、应用配置、Windows 策略、DNS、规则或任务；没有启动/停止应用、访问测试网站、SSH 登录、安装、提交或归档。旧项目和原脚本保留原处，没有迁移执行路径。

**Chrome 专用代理与断连保护未完成验收，不能声称修复完成。**
暂停前已停止维护任务 `ClashOfRust-Chrome-Listener`，当时任务状态为 Ready；任务定义和登录触发器仍启用，因此“已停止”不等于禁用或删除。Clash of Rust 与 Mihomo 未因暂停而停止。暂停后未再验证网络，本次文档整理也没有重新检测；下文状态均须在恢复修复时重新核查。

## 2. 用户目标与不可破坏的能力

目标：官方 EXE 安装的 Clash of Rust 管理德国 VPS；Chrome 所有网站流量经 VPS，相关 DNS 通过外部解析；代理不可用时 Chrome 不回退直连。旧 XUAN VPS 客户端栈应不再接管本机网络，但旧项目仍是服务器资料来源。

校园认证 <https://ipgw.neu.edu.cn/>、API <https://api.okinto.com/> 必须持续可用。暂停前最后一次正常证书校验下的响应分别为 302、200；这只是历史基线，不能替代当前测试。

不访问 Claude/Anthropic 及相关测试页；不继续使用 `ip.net.coffee/claude/` 或 `site.html` 检测；不运行会顺带访问这些站点的全量检测。保留 CC Switch 数据和外部 `com.vortex.helper`。不修改上游应用源码，不重复安装客户端。

先读 [AGENTS.md](../AGENTS.md)、[故障记录 12](../../XUAN_VPS/docs/12-Windows-Clash-DNS-incident-2026-10-15.md) 和 [DNS 定向修复脚本](../../XUAN_VPS/scripts/repair-clash-system-dns.ps1)。不要把阅读要求理解为运行修复脚本的要求。

## 3. 安装位置与历史观察

以下是暂停前最后观察，不是本轮重新核实的当前状态：

- 应用：`D:\Clash\clash-of-rust.exe`，报告版本 0.5.8。
- 核心：`D:\Clash\resources\mihomo.exe`，报告版本 v1.19.32。
- 数据：`C:\Users\xuan\AppData\Local\clash-of-rust\ClashOfRust\data`。
- 当时活动 profile：`profiles\d9230dba-1320-42ee-91bc-6ef5fbb96919.yaml`。配置中含私密连接资料，不全文输出。
- 控制器：`127.0.0.1:9090`；普通代理：`127.0.0.1:17890`；专用代理 17892 当时未监听。
- Chrome 固定代理策略仍指向 17890，正式 Chrome 专用 WFP 保护尚未成功部署。
- 旧三条 `ClashOfRust-Strict-Chrome-*` 规则当时仍启用；四条 `ClashOfRust-Strict-DNS-*` 事故规则当时禁用。
- 维护任务为当前用户 Limited 权限，暂停前启动曾成功；不应因 WMI 读不到路径便断言必须提权。
- UI/实时核心观察到 rule，但磁盘设置仍曾显示 `proxy_mode=tun`、`run_mode=global`。磁盘、应用内存、核心实时状态未统一，原因未确定。

本轮只读查看的克隆基线提交为 `dab7714`；本地 README/Cargo.toml 为 0.5.7，与历史安装报告的 0.5.8 不同。只读源码结论必须注明版本差异，不能直接保证适用于安装版本；不要为消除这个差异自动更新或重装。

## 4. 之前修改的文件及影响

以下修改均留在旧目录 `E:\Desktop\workspace\Project\XUAN_VPS`。本次只读查看时这些变更尚未提交。

### 4.1 已修改的旧项目文件

- `AGENTS.md`：加入两个关键地址的保护、变更前后验证、定向回滚、禁止全局 DNS 锁定和共享网络故障注入等要求。影响后续代理的执行约束，不直接改变运行网络。
- `docs/10-端口使用清单.md`：登记本地 Chrome 专用 17892 设计。它是规划记录，不证明端口已经可用。

### 4.2 本轮修复历史中新建的脚本与文档

- `scripts/maintain-chrome-clash.py`：通过认证后的本地核心 API，给应用管理的同一个 Mihomo 补充专用 listener；不另启核心。间接影响该核心的配置重载，当前实时 TUN 开启时拒绝重载。
- `scripts/ChromeProxyWfp.cs`：独立 provider/sublayer 的 Windows WFP 管理代码，设计为按 Chrome 可执行路径限制出站。正式安装未完成。
- `scripts/test-chrome-proxy-wfp.ps1`：WFP 数据结构和条件等离线验证。历史 615 项通过，不等于 Windows 真实过滤效果通过。
- `scripts/ChromeGuardProbe.cs`：隔离 TCP/UDP 探针。UDP 使用独立接收线程、随机 nonce 和测试前后对照，避免将 Send 成功或单纯超时误当成逃逸/拦截证据。
- `scripts/install-chrome-clash-guard.ps1`：原计划编译和校验探针、安装正式 WFP、调整 Chrome 策略并退下旧三条 Chrome 规则。存在未修复问题，当前不可直接使用 `-Execute`。
- `docs/13-Chrome-Clash-dedicated-proxy.md`：旧方案说明；其中部分安装说明与实际代码冲突，不能将其命令当作已审定操作。
- Python 编译检查可能产生 `scripts/__pycache__`；这是运行产物，不应提交。

### 4.3 用户原有恢复资料（本轮没有修改）

- `docs/12-Windows-Clash-DNS-incident-2026-10-15.md`。
- `scripts/repair-clash-system-dns.ps1`。
- `scripts/repair-clash-system-dns.Tests.ps1`。

只读检查时这三份文件也是 untracked，但由用户此前手动恢复工作带入；不能因为未跟踪就当作本轮可删除的临时文件。

### 4.4 旧仓库外的历史修改

- 活动 profile 增加 `CHROME-VPS` fallback 组，纳入四个现有 VLESS/Hysteria2 IPv4/IPv6 节点；DNS 配置使用经该组转发的 `https://1.1.1.1/dns-query#CHROME-VPS`、`https://1.0.0.1/dns-query#CHROME-VPS`，以及 `respect-rules=true`。节点服务器使用 IP 字面量。这里不记录真实服务器地址、认证资料。
- 应用设置曾改为 off/rule/dns_override=false，但之后观察存在 TUN/global 与实时 rule 不一致，不能把早期目标值写成最终落地状态。
- `%LOCALAPPDATA%\ClashOfRust-chrome\` 下放置维护器副本，以及 `runtime\overlay.yaml`、`before-overlay.yaml`、`state.json`、`maintainer.log`、`maintainer.lock` 和探针/状态文件。这些配置可能含私密信息，不复制进 Git。
- 创建维护任务 `ClashOfRust-Chrome-Listener`。原 Limited 任务已证明能启动；最后因用户要求暂停而停止。登录触发仍在。
- 失败的早期测试遗留四条只针对 `%LOCALAPPDATA%\ClashOfRust-chrome\ChromeGuardProbe.exe` 的持久 WFP 规则；没有确认清理成功。不能将其说成 Chrome 正式保护。

备份目录：`C:\Users\xuan\AppData\Local\ClashOfRust-network-backups\chrome-20261015-040446`。
备份指针：`$env:TEMP\clash-chrome-current-backup.txt`。
其中含配置、策略、防火墙状态、任务 XML 和测试结果；它们是私密恢复材料，不全文读取到上下文、不提交。备份早于后来用户修改，不能作为覆盖现状的通用恢复源。

## 5. 采用过的方案及已确认的技术事实

原设计连接链：Chrome 固定代理 → `127.0.0.1:17892` → 应用自己的 Mihomo → `CHROME-VPS` → 德国 VPS。专用 listener 为 mixed、`udp:false`、绑定 loopback，并指定代理组。WFP 设计仅允许标准 Chrome 路径以 IPv4 TCP 访问该入口，阻断其其他 IPv4 目的地址/端口、非 TCP 与 IPv6。

该方案增加了一个维护辅助进程。原因是此前观察到 Clash of Rust 0.5.8 重新生成配置时会丢弃 profile 自定义 `listeners`；仅修改 YAML 无法保证 17892 持续存在。维护器向认证后的 `PUT /configs?force=false` 提交补充配置，并检查核心路径、父进程、命令行和端口归属；保留模式/选择器，拒绝在实时 TUN 开启时重载。后续应先评估是否存在更简单、符合用户目标的受支持配置方式，再决定是否保留辅助进程，不必强行延续此方案。

已修复过 WFP 原生 ABI：`FWPM_FILTER0` 应为 200 字节，context union 为 16 字节；回读 flags 允许 `PERSISTENT` 或 `PERSISTENT|INDEXED`（0x1/0x41）。这些静态修复尚未由最新完整安装与真实流量测试证明有效。

普通用户通过 psutil 曾能读取提升权限的应用/核心路径、命令行、创建时间与父进程。WMI 返回空路径不等于 Limited 维护任务无法工作。此前一次提升任务为 Highest 的命令被自动审批以 `blocked by policy` 拒绝，没有证据证明执行成功；后来直接启动原 Limited 任务成功。不要把提权当成默认解决方式，也不要规避该拒绝。

## 6. 恢复前必须修正或查明的问题

本次只读核查安装器确认：

1. `install-chrome-clash-guard.ps1` 仍在 `-RepairListenerTask` 分支创建 Highest Principal（约第 121 行），并在约第 135、141 行要求 Highest。旧 doc13 却说保留原权限级别，二者冲突。此前发给已完成代理的跟进消息没有落实，不能当成修复证据。
2. 约第 101 行从旧备份读取 `chrome-policy.json` 用作回退来源，可能覆盖此后用户更改。应在每次运行紧邻修改前保存相关值、值类型和是否存在，并只回退本次拥有且实际更改的值；不能恢复整个旧策略键。
3. 参数列表没有 `-RemoveProbeOnly`；该清理模式并未实现，不能按想象调用。探针规则需要校验 provider、AppId、条件和归属后定向清理。
4. 磁盘设置、UI 内存、核心实时 mode/TUN 未一致。直接 PATCH 核心 API 不会自动更新应用内存设置；只读源码检查未发现能证明 `elevation.json` 定期恢复模式的依据。不要猜测删除它，也不要将原因归咎于用户。
5. 最新真实 TCP/UDP 探针、WFP 部署、Chrome 17892 策略、有效策略页面与 DNS 证据都未完成。

旧 doc13 的“继续安装”命令在这些问题处理并审查前不得执行。本交接只记录阻断项，没有修改安装器或旧文档。

## 7. 新会话获得继续修复指令后的任务顺序

1. **只读核对现状。** 先检查两个关键地址的正常通路与 TLS/HTTP 基线，再确认实际安装版本、核心归属、应用设置/实时 mode/TUN、监听端口、任务、NRPT/防火墙/WFP、Chrome 有效策略。最小范围定位旧 XUAN VPS 残留，确认是否仍有接管；不启动旧栈。
2. **评估与收敛方案。** 优先保证开关入口正常、恢复路径明确，不维持磁盘和应用内存冲突。通过受支持的应用行为统一配置，避免周期性强制覆盖用户模式。若保留 17892，明确维护器是辅助该应用同一核心，不是第二套代理。
3. **修正安装器与文档。** 消除不必要的 Highest 要求；实现本轮即时快照和定向回滚；实现或采用经审查的探针清理方式；同步旧 doc13。重要代码和安全规则修改需要独立审查，之后仅运行与变更有关的测试。
4. **清理已确认属于本方案的残留。** 仅处理探针四条持久 WFP 和本次文件；不全局清空规则，不删除用户恢复脚本，不触碰 CC Switch 或外部 helper。
5. **单独验证专用入口。** 在经过许可、TUN 状态明确且不影响共享联网的前提下，核验同一核心的 17892 loopback 入口、组选择、外部 DoH、维护任务权限与稳定性。入口不存在时不能先把 Chrome 指向它。
6. **真实隔离探针验收。** 验证 TCP 允许/拒绝目标、IPv4/IPv6、UDP 前后对照与 nonce 接收数；回读规则条件并完整清理。未通过不部署正式 Chrome 规则。
7. **实施 Chrome 配置。** 用本轮备份、定向回滚与逐步关键 URL 复验，将有效策略迁至已确认的入口并安装正式 WFP；确认后才退下旧三条 Chrome 规则。不要恢复四条系统 DNS 事故规则。
8. **实际浏览器与 DNS 证据。** 检查 `chrome://policy` 的生效值和错误；核对固定代理、无 DIRECT 回退、bypass、DoH、QUIC、WebRTC、预取等真实效果。用获准的普通页面及最小流量证明 VPS 出口、核心连接链和 DNS 去向，不访问禁止站点，不反复触发 Google 验证。
9. **隔离断连测试。** 检验 Chrome 在代理入口消失、应用正常开关、重启/休眠/换 Wi-Fi 时不会直连。不得对用户共享网络停核心、切 DNS 或禁网卡做故障注入；没有隔离或独立通路时将该项保留为未验收。
10. **交付与归档。** 更新实际改动、前后状态、证据、回滚和限制；核对旧 XUAN VPS 不再接管。用户此前提出过保存 Git/归档，但尚未完成；实施前先厘清两个仓库的提交范围，保留用户未提交文件，检查秘密与运行产物。不要在仅文档迁移时顺带提交、推送或归档。

每个网络变更步骤必须遵守根 AGENTS 的备份、回退与两个关键地址复验约束；任一异常停止扩大变更。

## 8. 验收口径与现有浏览器证据

此前独立 Chrome 曾正常打开 Google 首页，IP 查询显示与德国 VPS 相同的出口；用户遇到的 Google 异常流量提示也显示该 VPS 地址。这支持那次请求使用 VPS 出口，不能证明所有浏览器流量、DNS、断连窗口均受保护。数据中心 IP 的信誉和请求行为可以触发 Google 人机验证，该提示本身不能证明本地 IP 泄漏。

`chrome://policy` 的实际有效策略校验未完成。Chrome WFP 按 AppId 限制连接，但 Windows Dnscache 通过 IPC 代发的 DNS 不直接归属 Chrome；必须另外取得实际 DNS 通路证据，不能通过阻断全系统 DNS 补齐。

最终至少应分别报告：关键网址持续正常、应用开关与核心归属正常、Chrome 有效策略、VPS 出口、DNS 去向、IPv4/IPv6 与 WebRTC/QUIC 行为、代理不可用时拒绝直连、隔离故障测试、旧栈残留、回滚验证。未覆盖的场景列明，不承诺任何时候和任何 Wi-Fi 下绝对零泄漏。

## 9. 新会话可直接使用的指令

> 工作目录为 E:\Desktop\workspace\Project\Clash-of-Rust。先阅读 AGENTS.md、docs/local-network-handoff-2026-10-15.md、docs/xuan-vps-reference.md，以及它们引用的故障记录12。先汇报当前只读核查结果与最小实施方案；仅在我明确要求继续修复后进行状态变更。不得访问 Claude，必须持续保证 ipgw.neu.edu.cn 与 api.okinto.com 正常连接，不修改上游源码，不重装第二份客户端。SSH 和 VPS 资料按检索指南定位，不读取禁止的密钥文档，不输出凭据。

## 10. 08:09–08:11 本机浏览器入口只读排查

用户询问应用跳转到 `127.0.0.1:59791` 的页面无法打开。本轮只读结果：

- 59791 仍在 loopback 监听，归属 `clash-of-rust` PID 33888；17890、9090 归属 `mihomo` PID 19312。此为检查时状态，不保证临时入口之后仍存在。
- `D:\Clash\clash-of-rust.exe` 的文件与产品版本均为 0.5.8；本仓库 0.5.7 源码仅用于机制参考。
- 当前用户 Chrome 策略存储中的 `ProxySettings` 为固定 `http://127.0.0.1:17890`，`ProxyBypassList` 为 `<-loopback>`，即取消 Chrome 默认的 loopback 代理绕过。尚未通过 `chrome://policy` 确认浏览器实际生效状态。
- ActiveStore 中旧三条 `ClashOfRust-Strict-Chrome-*` 规则仍启用；其中 LoopbackTCP 的阻断范围为 `127.0.0.1` 的 `1-17889,17891-65535`，包含 59791。这套配置与浏览器访问随机本机端口存在冲突；规则存在不等于已证明实际 loopback 拦截效果。
- URL 形态匹配 `src/claude_check/browser.rs` 的临时地区检测入口：随机端口及路径，20 分钟到期；关闭入口、切页或隐藏窗口也可能关闭服务。未在浏览器加载该页面，未请求其 HTTP 正文，未触发检测或访问外站。缺少 Chrome 错误码及实际请求通路证据，暂不将具体失败层定为已证实。

本轮仅追加此 Markdown 记录，未修改应用源码、代理策略、防火墙、DNS、任务或应用运行状态，未执行旧脚本。没有网络状态变更，因此未为文档验证访问两个关键网址，也不声称它们已重新通过连通性验收。无需网络回滚；文档回退仅移除本节。不应为此直接关闭全部 Chrome 保护、重装应用或改动全系统 DNS；若后续获准修复，应对必要的本机入口做最小范围设计，保留外部流量不回退直连的目标，并遵守基线、即时备份及定向回滚约束。

## 11. 本次会话后续授权、出口预检与 08:33 旧版清理

用户随后允许针对性修复 Chrome 本机入口及运行内置相关检测，附加访问 Claude 前必须检查德国出口的条件。执行采用更保守门槛：只在同一实际目标通路确认德国时继续；中国大陆、其他地区、未知或路由变化均停止。用户要求使用其现有 Chrome，不另开窗口。

只读预检已确认活动程序和核心分别来自 `D:\Clash of Rust\clash-of-rust.exe`、同目录 `resources\mihomo.exe`，版本 0.5.9。先前第 10 节读取旧目录版本，不能代表活动版本。实时 rule/TUN、原生保护固定单节点 Selector 到 Hysteria2；中立 IPv4/IPv6 IPify 出口经 IP.SB 查询均为 DE，Cloudflare trace 同样为 DE。对应中立域名与自动检测的四个 Claude/Anthropic 目标域名的实时域名规则均指向该固定保护组。未请求 Claude/Anthropic，也未启动全量检测；后续执行前仍须重新核对时效和浏览器实际通路，不能将此次预检当作永久保证。

应用截图明确显示 0.5.9 和“回传入口已到期”；59791 后续不再监听。Chrome 窗口核查仍为最小化，GUI 点击被驱动以 `window_minimized` 拒绝，没有重放点击或更改其配置。完整本机入口兼容修复、Chrome 实际策略/出口及全量功能验收尚未完成。未修改代理、DNS、TUN、防火墙或任务。

用户随后明确要求卸载旧版，完成如下处理：

- 旧目录：`D:\Clash`，文件版本 0.5.8，19 个文件，共 131638116 字节；核查整树无 reparse point，活动进程均不来自该目录。
- 系统唯一卸载项属于 0.5.9，指向 `D:\Clash of Rust`。未运行任何卸载器：旧版安装器源码使用共享卸载注册键、快捷方式与应用数据路径，运行旧卸载器可能误伤新版。
- 紧邻删除前备份到 `C:\Users\xuan\AppData\Local\ClashOfRust-install-backups\legacy-0.5.8-20261015-083310-847961c6.zip`，相邻 `.manifest.clixml` 保存文件校验清单。备份目的路径及祖先无 reparse point，位于旧目录外；逐个核对 ZIP 中 19 个文件的长度与 SHA256，随后再次核对源文件和进程归属才删除精确的 `D:\Clash`。
- 08:33:48 复核旧目录不存在；新版 GUI PID 33888、核心 PID 19312 继续运行，未重启。新版 EXE 和共享 `settings.json` 前后 SHA256 不变；0.5.9 卸载项保留，17890/9090 仍归属当前核心。未改订阅、共享应用数据、快捷方式、任务、任何网络配置或 CC Switch。
- 08:29:44 清理前、08:33:48 清理后，正常系统通路均为校园认证 DNS 正常、HTTP 302、TLS 校验 0；API DNS 正常、HTTP 200、TLS 校验 0，curl 退出均为 0。没有跳过证书或临时切换通路。

回退：仅在确有需要且 `D:\Clash` 仍不存在时，核验此 ZIP/清单后将内容解压回该目录；不得覆盖新版安装或共享应用数据，也不要执行备份中的旧卸载器。备份不纳入 Git。旧维护器仍引用已移除的旧路径，本轮没有启动或修订它；其路径/权限及旧安全方案问题继续保留，不能直接恢复运行。此次旧版清理不等于 Chrome 完整功能或断连保护验收完成。

## 12. 08:36–08:49 Chrome 本机页面 HTTP 502 定向修复

用户明确要求立刻修复 502，随后确认管理员授权并要求继续，同时反馈 Edge 也打不开。实际只修改一个 Chrome 策略值，没有修改上游源码或运行全量检测。

### 复现与原因

- 现有 Chrome PID 20236、窗口 199360 正在访问当前会话的 `127.0.0.1:60826`；该端口由 Clash of Rust PID 33888 监听。
- 对同一精确本机 URL，用不执行 JavaScript 的客户端比较：直接访问 HTTP 200，经 `127.0.0.1:17890` HTTP 代理访问 HTTP 502。由此证实本轮 502 来自错误的本机代理通路，不是页面服务没有启动。
- Chrome 原策略 `ProxyBypassList=<-loopback>` 取消其默认本机绕过。旧 LoopbackTCP 防火墙规则仍启用，但不凭规则文本断定其实际拦截：修复后无需修改该规则，浏览器已成功直达页面。
- Edge 只读窗口检查仍显示旧端口 59791 的入口，该会话已过期、端口已停止监听。它与 Chrome 当前 60826 的代理 502 是不同问题，不能通过反复刷新旧地址解决。本轮未修改 Edge 设置、未恢复其最小化窗口，也未宣称完成 Edge 新入口实测。

### 精确改动与备份

- 注册表位置：`HKCU\Software\Policies\Google\Chrome`，仅现有 REG_SZ 值 `ProxySettings`。
- 只把该 JSON 的 `ProxyBypassList` 从 `<-loopback>` 改为 `<-loopback>;127.0.0.1`；保留 `ProxyMode=fixed_servers`、`ProxyServer=http://127.0.0.1:17890` 及其他字段。顺序有意义：显式本机例外位于减去隐式绕过的 token 后面。
- 例外仅为精确的 IPv4 loopback 字面量 `127.0.0.1`，允许其随机端口以兼容临时检测入口；不是外部域名、局域网网段、其他 127/8 地址、localhost 或 IPv6 的绕过。它允许访问同一地址上的其他本机服务，不能据此声称绝对零泄漏。
- 普通权限写入因 Windows 注册表 ACL 拒绝，未发生修改。管理员助手首次账户核验未通过也安全退出、未改策略；只读核实真实用户及 ProfileList 对应关系后，使用同一账户 UAC 确认执行。没有更改注册表 ACL 或绕过拒绝。
- 紧邻成功变更前的快照及回退位于 `C:\Users\xuan\AppData\Local\ClashOfRust-network-backups\local-page-admin-20261015-084234`：`before.clixml`、`after.clixml`、`baseline.clixml`、`rollback.ps1`。这些本机快照不纳入 Git。

### 实际验证及边界

- 08:42:33 变更前、08:42:34 变更后和 08:49:09 最终复验，正常系统通路均为校园认证 DNS 正常、HTTP 302、TLS 校验 0；API DNS 正常、HTTP 200、TLS 校验 0，curl 退出 0。未临时切通路或忽略证书。
- 使用用户已打开的 Chrome，在同一原有标签页进入 `chrome://policy` 点击 Reload policies；策略刷新及页面加载有异步延迟，未仅凭注册表成功宣告完成。
- 返回并刷新原入口后，约 08:47 真实浏览器显示“Clash of Rust · 浏览器地区检测”和“检测报告已回传到 Clash of Rust。你可以关闭此页面。”；本机接收服务仍返回 HTTP 200。这是页面加载及回传的实际证据，不只是端口存活。
- 本机页面自动进行了中立浏览器采样，读取到的 Cloudflare trace 地区为 DE。没有点击应用的重新检测、原生保护开关或执行 Claude/Anthropic 请求；完整检测仍须按第 11 节重新执行同通路德国门槛核验。浏览器全部协议、DNS 与隔离断连保护不因页面成功自动验收通过。
- 旧三条 Chrome 防火墙规则均仍启用；核心保持 rule、TUN 开启和 mixed-port 17890。未改 DNS、NRPT、路由、网卡、系统代理、任务、订阅或 CC Switch，未重启核心/应用/浏览器。
- 最终浏览器核查时活动标签已变为 New Tab，未再切换用户标签；成功结果以此前实际页面及回传检查点为准。不要误把后续新标签的空匹配解释为此前页面仍失败。

回退：以同一用户的管理员 PowerShell 执行上述备份目录中的 `rollback.ps1`，仅当当前 `ProxySettings` 仍精确等于本次写入值时恢复本轮紧邻快照，避免覆盖后来修改；随后在 Chrome 刷新策略，并重新验证两个关键网址。此回退会重新引入本机入口经代理的已知兼容问题，不应例行执行。临时 UAC 助手已从工作区移除，保留备份目录中的定向回退文件。

## 13. 08:54 起 GPT 检测的中国 IPv6 与地区库冲突

用户报告 `https://ip.net.coffee/gpt/` 的“ChatGPT 出口 IP”显示中国浙江宁波 IPv6。本轮仅只读诊断，没有执行该网页脚本、重新请求 ChatGPT、访问 Claude/Anthropic 或改动网络配置。实际地址不转录到交接或 Git。

- 静态读取准确的 `/gpt/` HTML 和其引用的 `gpt-page.js`，确认 ChatGPT 卡片 IP 由浏览器请求 `chatgpt.com/cdn-cgi/trace` 得到，不是 ChatGPT 服务器目的地址或 DNS AAAA；失败不回退用其他卡片的 IP。卡片的国家/地区/城市主要来自网站自己的 `/api/geoip/<IP>` 查询，缺失时才回退 trace 的 loc。因此显示 CN 不等于已经读取并证实目标 trace 的 loc=CN。
- 用当前代理查询用户报告的同一精确 IPv6，Net.Coffee 自身归属接口复现 China/Zhejiang/Ningbo (Yinzhou Qu)；APNIC RDAP 登记 country=CN。IP.SB 返回 DE，ipapi.is 返回 Germany，ipwho.is 返回 DE，且三者响应中的查询地址均与目标相符。登记国家和地理库标签不直接证明服务器物理位置或服务商自己的地区判定。
- 当前运行配置中，IPv6 VLESS 和 IPv6 Hysteria2 节点的服务器地址均与用户报告的 IPv6 完全相同；本机网卡地址中没有该 IPv6。当前 API6 IPify 探针也观察到相同 IPv6。这支持该值来自 VPS IPv6 出口及其地区标签冲突，不支持直接把它断言为本机校园网 IPv6 泄漏；没有据此保证全部流量无泄漏。
- 实时核心仍为 rule、TUN 开启、IPv6 开启，保存偏好仍为 global。原生 Claude 保护固定节点并覆盖其诊断域名，但未覆盖 ChatGPT/OpenAI 域名。当前规则没有专门 ChatGPT 域名规则，最终 Match 经 URLTest；读取到的四条已有 `ab.chatgpt.com` 连接均走 Hysteria2/URLTest，其中不同连接使用了 IPv4/IPv6 两个节点。已有连接不是重放该次 chatgpt.com trace 的精确链路证据。
- 本机页面修复仅对 `127.0.0.1` 添加绕过，不会让 `chatgpt.com` 获得外网 DIRECT 例外；不能将新的地理标签问题简单归因于第 12 节的 502 修复。

安全决策：出现 CN 与德国冲突，维持停止 Claude/Anthropic 请求，不将早先中立服务的 DE 结果等同于所有目标认可德国。若用户要求修复，应优先研究 ChatGPT/相关目标实际使用经核验的 IPv4 出口，保留校园认证与 API 通路；仅选择名称含 IPv4 的节点不能保证服务器连接目标时不会再使用 IPv6。不得在未验证前全局禁用系统 IPv6、改 DNS 或切断当前网络。下一轮任何网络状态变更仍须新的关键通路基线、紧邻快照和定向回退。本轮无需网络回退，未将只读诊断冒充出口风险修复或完整功能验收。

## 14. 用户授权 SSH 后的 OpenAI IPv4-only 配置与域名管理

用户后续明确授权 SSH 和服务端配置，并允许静态读取 GPT/Claude 两篇 `site.html` 建立域名清单。本轮仅修改 VPS `/etc/sing-box/conf/03_route.json`，对列明 OpenAI 专属域名强制 IPv4 解析并拒绝分类到的 IPv6 字面量，保留其他原规则。已在隔离实例验证无 A/IPv6 字面量失败，再应用生产；现有 Chrome 实际 ChatGPT trace 为 IPv4、`loc=DE`，Net.Coffee 同地址也为德国。09:26 最终校园认证 302、API 200、DNS/TLS 正常。

完整变更、影响、备份、回退及限制见 [VPS 变更记录](vps-ai-ipv4-change-2026-10-15.md)。两篇页面清单见 [域名管理](ai-domain-inventory-2026-10-15.md) 和 [JSON](../config/ai-domain-inventory.json)。Claude 本轮只登记清单，不新增其路由或访问测试；其原 IPv6 地区冲突仍不得用 OpenAI 的验证结果替代。并未宣布全功能/任意网络零泄漏验收通过。

清单最终共 102 条管理记录：OpenAI 60、Claude 32、非目标引用 10，包含域名、匹配方式、共享服务、关键词和 IP/ASN 建议，并非 102 个独立网站。新增部署为 20 个匹配器（10 后缀、9 精确主机、1 正则），其余明确区分只登记、共享未新增和宽泛不采用。已核验 JSON 字段/枚举、唯一性、Markdown 全部条目、相对链接，以及新增匹配器与实施清单精确一致；台账不会自动部署。

## 15. 09:35–09:41 Claude 同样通过 VPS IPv4 出站

用户随后明确要求 Claude 也优先使用 VPS IPv4，同时保留本机通过 IPv6 连接 VPS。已在同一远端路由文件追加 7 后缀、4 精确主机的严格 IPv4 分类策略；原 OpenAI/私网防护等 19 条规则内容及相对顺序完全保留。客户端固定 HY2 IPv6 节点未改。

生产配置生效后，重新核验同组中立 IPv4 探针、Net.Coffee/ipwho.is 德国归属及 Claude A 记录的 VPS 源路由一致，才发起实际 Claude trace 请求；返回 HTTP 200、IPv4、DE，与预检出口一致。OpenAI 回归亦正常。09:41:25 两关键地址为 DNS 正常、TLS 校验 0、校园认证 302/API 200。已解除自动回退，服务 active。

最新范围、隔离/生产证据及即时备份回退见 [Claude 变更记录](vps-claude-ipv4-change-2026-10-15.md)。清单总计仍为 102 条，当前明确应用匹配器升为 31（OpenAI 20、Claude 11）。第 14 节“Claude 仅登记”和 20 条部署数是本次追加前的历史状态；今后以本节及最新台账为准。未触及共享服务整域、legacy gateway、客户端系统设置或 CC Switch；不宣称全功能/零泄漏已验收。

## 16. CLI / Desktop 仅离线解析，不登录或模型调用

用户收紧要求：不得使用 Claude 或登录账号，只解析本机 CLI 与 Desktop 会连接的 URL。取消此前准备的受限 CLI 模型请求及 Desktop 启动观察；该测试从未执行。收紧后不再启动 CLI（包括 help）或 Desktop、不访问 Claude/检测页面、不 SSH、不更改任何网络配置。

已对 CLI 2.1.299 原生 EXE 内嵌代码与 Desktop 2.19675.1 app.asar 做离线检查，并核对 9 份允许配置的网络字段白名单。输出[静态网络报告](claude-app-static-network-audit-2026-10-15.md)及[84 条分类 JSON 台账](../config/claude-app-endpoints-2026-10-15.json)。该台账不替换此前 102 条页面清单，不自动加载或部署；包含条件模板和示例，不是 84 个真实活跃连接。未发现白名单显式覆盖不能排除受保护存储、运行时注入或远端配置。

10:11 本地只读观察为 rule/TUN 开启/process 查找 off，官方域名规则指向原生保护 Selector/HY2 IPv6；此前 VPS 严格 IPv4 后缀已涵盖新发现官方子域。无需重复添加这些子域或重装客户端。共享遥测、存储、外部 provider/MCP/工作区工具不全在 VPS 严格 IPv4 范围内；客户端保护不等于服务端强制 IPv4，未据此宣布 CLI/Desktop 全部流量已受控或零泄漏。

REA 语义覆盖 partial，6 个 unpacked 原生文件与 ASAR 声明哈希不一致；仅记录观察，未确认原因或官方真实性。没有修改安装文件。大体积原始证据和离线工具仅在忽略目录 `.local-tools/`；本轮只有文档/台账变化，无网络回退需求。后续保持用户不登录、不运行目标的最新边界，不自动恢复已取消的联网测试。

## 17. WSL 德国出口与设备环境：专家分析入口

用户另行要求详细分析 WSL → Windows Clash of Rust → VPS 的完整流量接管、境外 DNS、公网 CLI 出口及德国地区环境，并要求专家子代理评估。本轮仅做只读状态核查和文档设计，不启动 WSL、不 SSH、不运行 Claude、不改变网络状态。

入口为 [需求原文、证据与方案总纲](wsl-vps-requirements-and-plan-2026-10-15.md)，关联 [网络架构](wsl-vps-network-architecture-2026-10-15.md)、[身份与威胁模型](wsl-vps-identity-threat-model-2026-10-15.md)、[独立验收与评审](wsl-vps-validation-and-review-2026-10-15.md) 和 [离线图解](wsl-vps-design-overview-2026-10-15.html)。R01–R13 为需求，VR-01–VR-17 为未来验收项目，不代表运行验收通过。

10:28–10:29 只读观察：Ubuntu/Docker WSL均停止；正式核心 v1.19.32 为 rule/TUN 开启，17890 TCP/UDP 与9090 TCP监听，旧18001/1053及规划17892未监听。主机两个关键网址 DNS/TLS正常、最终HTTP200。10:41 psutil重新核实核心来自 `D:\Clash of Rust\resources\mihomo.exe`，父进程为正式应用，runtime参数匹配。本轮没有核验Linux实际配置或远端现状。

关键可行性闸门仍是0.5.9自定义listener持久化；普通17890/环境变量不等于透明接管，原生Claude域名保护不等于全部WSL目标固定VPS。公网查询应显示VPS，与本地接口命令如实显示虚拟/私网地址须分开。完整硬件/内核复刻及平台永久认定德国不可由代理保证。后续实施须由唯一网络管理会话协调，遵守原有关键网址、备份回退及禁用生产故障注入要求；不因此自动恢复任何旧脚本或维护任务。

## 18. GitHub 候选项目调查：研究结论，不是部署

用户继续询问 GitHub 是否有可帮助实现上述需求的项目。已进行实际仓库搜索，并由三个专家分别核查透明数据面、隔离/L3、DNS/Clash 控制面；详细证据、固定 tag 链接、许可证及限制见 [GitHub 项目调查与选型](wsl-vps-github-project-survey-2026-10-15.md)。

建议优先在隔离环境研究 tun2proxy 的 namespace 集成，hev-socks5-tunnel / xjasonlyu/tun2socks 作标准 SOCKS UDP 数据面对照，nsjail / bubblewrap 作受管工作负载隔离骨架；dnscrypt-proxy 仅作封闭 bootstrap/系统回退/H3 之后的 TCP/DoH 条件候选。wsl-vpnkit 是连通性参考，不能当固定 VPS 方案；uppet/wsl-tun2socks 只核查 README、license API 为空，不直接运行或复用代码。Tailscale / WireGuard 是需另行确认的三层架构选项，不自动满足同核心 R06。

本轮 GitHub API 返回 Clash v0.5.10，但 HTTP Date 与本机时间约差 8 小时，不据此断言当前发布时序或应立即升级；所读 tag 仍清除自定义 listeners/authentication，未发现足以解除同核心固定入口持久化闸门的官方功能。不能以新装透明层、普通 17890 或全 Windows 改全局模式替代该闸门。

本轮只有调查文档、需求入口及本交接追加；没有安装/编译/执行候选、启动 WSL/Claude、SSH、写核心 API 或改变网络，未触碰 CC Switch。不为 Markdown 验证另做网络测试，不声称关键地址有新实时验收结果。R02 仍要求 TCP/UDP 都功能成功，阻断只是安全降级；只包装 shell 不算全 WSL。后续由唯一网络管理会话按 G0–G5/P1–P5 协调，保持原有关键通路、即时备份、定向回滚与生产故障注入禁令。文档撤回仅处理本轮追加内容，先检查后续修改，不恢复整份旧交接或执行网络回滚。

## 19. 新增 WSL 要求的接续复核：只分析，不部署

用户要求阅读并分析项目新增 WSL 网络要求。已阅读需求、架构、身份、验收、GitHub 选型及图解，由两位只读子代理分别复核架构/源码和身份/验收，并整合为[接续分析与实施前缺口](wsl-vps-followup-assessment-2026-10-15.md)。本次只新增报告和本段，不改写原设计、源码或活动配置；没有启动 WSL/Claude、登录、SSH、外站访问、核心查询或网络变更。

确认同核心固定策略持久化仍是首要闸门，不能用普通17890/代理变量或现有Claude保护替代全部WSL固定出口。新增发现：现有system DNS例外涵盖整个IPv4/IPv6反向查询区，包含公网PTR；遥测隐私保证应限定应用权限和已测字段；WSL校园服务范围须与强制Windows保障分开；DNS矩阵须绑定境外resolver证据；VR-12须补普通模式/节点/profile切换负例。它们是设计/验收缺口，不是已观测的生产泄漏。原验收报告“无剩余实质矛盾”为此前审查记录，不能替代本次结论。

原报告中的端口、WSL状态、版本、出口及关键网址响应仍是历史快照，本次未更新实时状态。后续应先明确范围与唯一实施者，再经授权进行现场盘点和隔离固定策略原型；不自动运行旧脚本、迁移业务、扩大VPS规则或取消Claude离线边界。本次仅核验文档，无网络回退需求。

## 20. WSL 范围确认与 fork 功能 Issue

用户明确 WSL 不需要访问校园服务，并要求 fork 上游、仅在 fork 中提交 WSL 功能 Issue。此决定解决第 19 节的校园范围待定项：Windows 原有校园认证、API 与正常系统联网仍须保留；WSL 不增加校园可达性要求或校园/LAN/宿主 DNS 直连例外。已同步需求 R09、身份模型关键网络段及验收 VR-01；此前报告中范围待定的文字属于历史记录。

- 已创建公开 fork：[Sonder4/Clash-of-Rust](https://github.com/Sonder4/Clash-of-Rust)，来源为 Fu021/Clash-of-Rust；只在该 fork 启用 Issues。
- 已发布并远端核验 OPEN：[Issue #1：功能请求：原生 WSL2 同核心透明接管、固定 VPS 出口与失败关闭](https://github.com/Sonder4/Clash-of-Rust/issues/1)。没有向上游提交 Issue。
- 公开正文留档：[已审查的 WSL 功能请求](issues/wsl-managed-network-feature-request.md)。内容涵盖同核心持久入口、固定 VPS、透明 TCP/UDP、双栈、受控 DNS、失败关闭、隔离边界、状态 UI 与分项验收；明确 WSL 无校园需求和 Windows 原通路保护。
- 正文已脱敏，不公开真实 VPS 地址、用户路径、凭据、控制器 secret、完整订阅或私密配置；只发布该 Issue 正文，没有上传本地配置、推送代码或提交本地 Git 变更，现有 origin 保持指向上游。
- 本轮未启动 WSL/Claude、登录、SSH、修改源码或活动网络配置，未触碰 CC Switch。GitHub 发布不代表功能已实现或网络已验收；仅核验文档与发布结果，不为 Markdown 改动测试外站连通性。

回退范围：如需撤回公开需求，可关闭 fork 的 Issue #1；本地文档仅定向撤销本轮范围说明与追加段，不恢复整份历史文档，不执行任何网络回滚。功能实施仍须另行授权、现场盘点、隔离验证和紧邻备份。

## 21. WSL 3.0 网络更新核查与实施路线

用户询问 WSL 3.0 的网络更新及本目标如何修改。已新增 [WSL 3.0 网络更新与实施方案](wsl-3-network-updates-and-implementation-plan-2026-10-15.md)，由版本研究、架构分析与独立复核三个只读工作流整合，并直接对照 Microsoft 官方发布 API、Learn 与固定 3.0.3 源码。

本轮官方 latest 返回稳定版 3.0.3（2026-10-09 发布）；这是软件包版本，不是新的 WSL 3 运行架构。3.0.1 主打 WSLc GA，3.0.2 预发布修复双栈监听/Consommé 网络兼容问题，3.0.3 主要是内核、生命周期和测试修复。mirrored、dnsTunneling、autoProxy 和 firewall 不是 3.0 首创，也不构成全流量代理。3.0.0 有 Git tag，但 Release API 404，不能编造其发布说明。

落实顺序仍是：同核心固定 VPS 入口持久化 → Linux TUN/标准 SOCKS5 TCP+UDP → 独立 DNS → netns/权限与失败关闭 → shell/systemd/容器/interop 全范围验收。不要因隐藏接口直接切 NAT；先核实有效模式，若已 mirrored 可保留作原型候选。独立 netns 才是减少工作负载接口视图的关键，且它自己的 loopback 不能自动当 Windows loopback 使用。

版本核查补充：正式 network 键归 `[wsl2]`，hostAddressLoopback 等仍在 `[experimental]`；3.0.3 保留旧节兼容，故历史文件不能仅凭节名判定已生效或无效。mirrored 强制 Hyper-V firewall；hostAddressLoopback=false 不取消基本 127.0.0.1 互通；DNS tunneling 使用虚拟化通路，不能以 Linux 未见 UDP/53 证明境外解析。关闭 autoProxy/dnsTunneling、纠正节名和重启都只是未来受控迁移步骤，未在本轮执行。

本轮仅新增报告和本交接段，未改源码或活动配置，没有启动 WSL/Claude、SSH、安装组件、写核心 API 或修改网络；未触碰 CC Switch。WSL/核心/端口及关键网址状态仍引用先前带时间快照，没有刷新运行验收。Windows 校园认证/API 必须保持；WSL 无校园服务要求，不增直连例外。只有文档变更，不为此执行网络回滚；如撤回，仅处理本轮报告与本段，保留后续用户修改，不提交或推送。

## 22. 2026-10-17 同步 fork 与本地仓库

用户要求将 GitHub fork 更新到上游后再拉取到本地。操作前确认本地 `main`、fork `origin/main` 均为 `a1d1140`（v0.5.10），且该提交是上游 `main` 的祖先；上游目标为 `78d5f548389fe80056027c03416210f16106917e`，对应 tag `v0.5.11`。检查上游变更路径与本地未跟踪文件没有路径冲突。

先执行 `git push origin upstream/main:main`，GitHub fork 的 `main` 快进至 `78d5f54`；随后执行 `git pull --ff-only origin main`，本地 `main`、`origin/main`、`upstream/main` 均核实为同一提交。此次快进包含 198 个上游文件路径变更（15,555 行新增、22,569 行删除）。

本轮只更新 GitHub fork 分支与本地源码仓库；没有安装/启动应用、编译、运行测试、改上游源码或更改活动网络配置。已存在的本地交接文档和配置仍保留；没有提交这些本地文件。仓库同步不代表已安装程序升级到 0.5.11。

同步前的 fork 提交 `a1d1140` 仍可用于只读回看，例如在独立 worktree 检查；本轮未重写 fork 历史或执行回退。后续若需把 fork 分支恢复到旧提交，应先核对远端新状态并单独处理。

## 23. Ubuntu-26.04 接管 WSL 出口（2026-10-23 晚）

用户要求完成 Ubuntu-26.04 在 WSL 中的对外访问、确认不暴露本机 IP，并授权修改 Clash 配置。本轮已完成迁移并验证，详细记录见 [Ubuntu-26.04 迁移、根因与验证](wsl-secure-egress/UBUNTU26-MIGRATION-2026-10-23.md)。

结果概要：Ubuntu-26.04 已成为 manager，WireGuard 握手正常，WSL 出口实测为 VPS `62.84.164.122`；Hyper-V 对 WSL 默认拒绝，唯一放行 `UDP 51820 → 62.84.164.122`；Clash `run_mode` 持久化为 `rule`（备份在 `%TEMP%\wsl-egress-migration-20261023T\clash-settings.before.json`）；新增登录计划任务 `ClashOfRust-WslEgress-Autostart`，在登录后 30 秒自动恢复隧道，已用两次 `wsl --shutdown` 实测。

重要边界：产品本身不自动建立隧道（boot hook 只恢复默认拒绝）；`wsl --shutdown` 无登录事件，需手动运行该任务或执行产品 Start；Ubuntu-22.04 必须保持运行，否则刷新任务会在 60 秒内关闭端点；主机冷启动尚未实测。两个发行版的旧 payload 与 journal 备份在各自 `/root/cor-egress-stale/`。未执行 fail-closed 隔离断连测试、逐跳定位、主机重启、网卡切换、Docker 受管出口与浏览器验收。

本轮只新增文档，未改仓库源码；未记录凭据、私钥、控制器 secret 或完整订阅。
