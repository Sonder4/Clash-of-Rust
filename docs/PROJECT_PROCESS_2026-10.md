# Clash of WSL / WSL Secure Egress 完整过程文档（2026-10）

日期：2026-10-23。时区：Asia/Taipei（UTC+08:00）。

性质：**过程与决策记录，不是部署验收报告**。文中"已验"只对应记录时的实际测量；
未执行的检查保留 `NOT_RUN` / `BLOCKED`。运行状态会变化，交付前必须重新核验。

## 1. 文档目的与来源

本文把分散在 Codex、Claude 会话、仓库文档和 Git 历史中的设计需求、计划、实施与验证，
整理成一条可追溯的过程线。详细技术证据仍以各专项文档为准。

来源与提取方式：

| 来源 | 范围 | 用法 |
| --- | --- | --- |
| Codex 会话 | `~/.codex/sessions` 与 `~/.codex/archived_sessions` 中 `cwd` 为本项目的 161 个会话 | 提取用户原始消息，按语义去重 |
| Codex 主计划 | `~/.codex/plans/01a146ed-05f1-7c83-aac7-67b01a8df56e/01a146f6-199e-7743-bd03-2c62813b5907/PLAN.md` | 已批准的架构、阶段与验收计划 |
| Claude 会话 | `7e2f16e3-c6ca-4404-90ae-af366760a02a`（10-22）、`99cd322d-8711-4943-b02e-c160ba2c62fe`（10-23） | 后续恢复、迁移与整理需求 |
| 仓库文档 | `docs/wsl-vps-*`、`docs/wsl-secure-egress/*`、`docs/local-network-handoff-2026-10-15.md` | 设计、记录、证据 |
| Git 历史 | 本 fork 的提交与合并 | 时间线与产物 |

提取规则：只取用户原始消息和已批准计划；不复制工具输出、私钥、口令、令牌、控制器
secret 或完整订阅；重复提示合并。本文不复述真实端点地址和主机地址。

## 2. 项目定位

在 Clash of Rust 的 fork 中增加原生 **WSL Secure Egress** 页面，并把 WSL 侧做成独立组件
**Clash of WSL**。目标路径：

```text
WSL 工作负载 → Windows 侧隐藏/防护 → 德国 VPS → 指定 DNS → 目标服务
```

- Windows 保留原 IPv4、IPv6、日常代理和普通联网。
- WSL 受管业务仅使用 IPv4；WSL IPv6 出站拒绝。
- 隧道或 guard 不正常时 WSL 失败关闭，不回退本地出口。
- Clash of Rust 只负责 UI 控制与用户操作；WSL 网络由独立后端和系统组件管理。

## 3. 设计需求

### 3.1 最初需求（2026-10-15、10-17）

用户在 Codex 主会话中的原始要求，按语义整理：

1. Windows 保持原来的 IPv4、IPv6 网络，不需要全局 VPN/Exit Node。
2. 通过专用命令或页面启动的 WSL 隔离应用只使用虚拟网络；`ip addr`、`ip route`
   只能看到隔离命名空间中的虚拟网卡和地址，不能直接枚举 Windows 物理网卡。
3. 所有互联网流量经德国 VPS 出口；DNS 和 IPv6 不能绕过隧道。
4. VPN 断线、系统重启、网络切换时必须 fail-closed，不能回退 Windows 本地出口。
5. 优先使用 Tailscale Exit Node；无法满足严格隔离时，分析原因并采用固定 Endpoint
   WireGuard 备选。
6. Windows 层评估并使用 WSL NAT、Hyper-V Firewall 等官方支持机制。
7. 项目必须提供安装、状态检查、测试、卸载和完整回滚脚本。
8. 先只读检查与官方文档研究，明确批准后才修改防火墙、WSL 网络、VPS SSH、路由或 DNS。
9. 每个阶段运行验证测试并记录实际结果；不得把未执行的测试标记为通过。
10. 最终交付 README、PowerShell 脚本、Linux Shell 脚本、测试脚本和安全模型文档。

### 3.2 形式化需求

2026-10-15 的需求总纲把目标转化为 R01–R13，详见
[WSL 德国出口与设备环境：需求、证据及方案总纲](wsl-vps-requirements-and-plan-2026-10-15.md)。

| 编号 | 要求 | 验收要点 |
| --- | --- | --- |
| R01 | 公网出口 | WSL 查询来源地址应由 VPS 出口发出，不出现宿主校园/家庭公网地址；覆盖清空代理变量、不同客户端 |
| R02 | 透明接管 | 普通原生进程 TCP/UDP 不依赖应用代理变量；阻断 UDP 属安全降级，不算完整通过 |
| R03 | IPv6 | 处理字面量、AAAA-only、双栈竞速；不满足条件时 WSL 内失败关闭，不关闭 Windows IPv6 |
| R04 | DNS | 受管解析经 VPS 路径；不回退校园/宿主解析；记录 DoH/DoT 与应用内解析边界 |
| R05 | 失败关闭 | 核心未就绪、节点失败、转发器退出、配置重生时不回退本地出口；不影响 Windows 普通联网 |
| R06 | 同核心与持久化 | 使用正式 Clash of Rust 管理的同一核心；WSL 路径固定到已核实 VPS |
| R07 | 设备环境一致性 | 保留浏览器/Claude 身份资料；时区、语言、定位与出口一致；不承诺"平台认定德国" |
| R08 | 容器与跨系统边界 | Docker、interop、WSLg、子进程分别纳入范围或明确不支持 |
| R09 | 不可破坏的 Windows 网络 | `ipgw.neu.edu.cn` 与 `api.okinto.com` 保持正常 DNS/TLS/HTTP；禁全局 NRPT 与 Dnscache 封锁 |
| R10 | 无目标业务在线测试 | 不用真实业务账号检测代替验收；Claude/Anthropic 默认不访问 |
| R11 | 本地 CLI 可见性 | 公网来源查询看到 VPS 出口；本地网卡枚举反映真实虚拟接口；不伪造命令输出 |
| R12 | 记录与实施边界 | 原始要求、证据、方案、风险、阶段、回退和验收写入文档；文档完成不等于目标完成 |
| R13 | 德国地区与实际路由 | 端点位于德国、客户端到 VPS 的链路、目标实际出口是三件事，必须分别核验 |

### 3.3 产品形态与交付要求（2026-10-18）

- Clash of Rust 只承担 UI 控制和用户操作；**最小化修改**，不嵌入 WSL 网络逻辑。
- WSL 侧做成完整工具/系统组件，可安装、部署、常驻后台，并能与 Windows 侧通信和展示状态。
- 文档拆分为 WSL 部分、Windows 部分、Clash of Rust 部分，并与上游主线对比。
- 修改与测试完成后提交 PR 到自己的 fork，不直接提交上游。
- 支持自动申请提权（UAC）、错误处理和反馈机制；用户可手动确认 UAC。
- 在 `F:\WSL` 安装 Ubuntu 26.04，并在其中安装配置 Chrome、Codex CLI、Claude Code CLI、
  Claude Code Desktop，用 Clash of WSL 完成安装测试。
- 在 WSL 内测试 OpenAI、Claude、DeepSeek 等模型厂商连接，确认展示的出口 IP 为 VPS IP；
  确保 Claude Code CLI/Desktop 等工具不能获得 Windows 真实 IP 与物理位置。

### 3.4 后续收敛要求（2026-10-22 至 10-23）

- 恢复 WSL 网络，代理配置为默认；不得影响 Windows。
- WSL 不使用 Windows 的 IPv6 或 VPS 的 IPv6 出口，固定使用 VPS IPv4；SSH 管理走 IPv4。
- WSL 不需要访问 `ipgw.neu.edu.cn`，也不要求校园网/国内站点分流；该访问不作为 WSL 验收项。
- 实际只会使用一个 WSL 发行版：Ubuntu 26.04。
- 确认 WSL 内任何指令都无法直接获得 Windows 的校园网 IP 地址。
- 隧道或 guard 不正常时，WSL 无法访问外网（失败关闭）。
- 持久化 Clash 模式为 `rule`；为 WSL 保留一条只与目标 VPS 通信的路径/端口。
- WSL 重启后自动恢复隧道；用户选择"登录时自动恢复"。
- 整理文档、脚本、测试文件和分支；把最新版本合并到 `main`；删除已合并的远端分支。
- 从 Codex、Claude 会话提取设计需求与计划，形成完整过程文档（本文）。

### 3.5 明确边界

- 不启用 Windows 全局 VPN/Exit Node，不接管普通 Windows 应用。
- 不做全局 NRPT `Namespace='.'` 绑定、不阻断整个 `Dnscache`、不清空防火墙、不重置网络。
- 不删除 WSL 发行版、Docker 数据、用户文件或 CC Switch 数据。
- 不宣称"任何时候、任何网络零泄漏"；未执行的测试保持 `NOT_RUN` / `BLOCKED`。
- Claude/Anthropic 默认不访问；唯一例外是静态读取指定页面，且访问前必须确认同一实际
  通路出口为德国。中国大陆禁止访问。

## 4. 方案与架构

### 4.1 分层

```text
┌─────────────────────────────────────────────────────────────┐
│ Clash of Rust (Slint UI)                                    │
│   WSL 安全网络页面：安装 / 连接 / 状态 / 日志 / 测试 / 回退   │
└───────────────────────────┬─────────────────────────────────┘
                            │ 固定操作协议（SID、操作 ID、代次）
┌───────────────────────────▼─────────────────────────────────┐
│ Windows                                                     │
│   用户级 broker（管理本用户 WSL）                            │
│   SYSTEM guard（持久策略、Hyper-V VM firewall、恢复）        │
│   Hyper-V 默认拒绝 + 唯一出站放行：UDP → VPS 端点            │
└───────────────────────────┬─────────────────────────────────┘
                            │ WSL NAT
┌───────────────────────────▼─────────────────────────────────┐
│ WSL（共享 netns）                                            │
│   manager 发行版（Ubuntu-26.04）                             │
│   nft guard（默认 drop，boot hook 恢复）                     │
│   transport netns ── veth ── gateway netns                   │
│   WireGuard wg0（在 gateway；UDP socket 留在 transport）     │
│   路由表 10077 + 规则 10070–10074                            │
└───────────────────────────┬─────────────────────────────────┘
                            │ WireGuard UDP
┌───────────────────────────▼─────────────────────────────────┐
│ 德国 VPS                                                    │
│   固定 IPv4 出口、WireGuard peer、Tunnel DNS resolver        │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 关键决策

| 决策 | 结论 | 依据 |
| --- | --- | --- |
| 后端选择 | Tailscale 严格模式标记 `BLOCKED`，采用固定 Endpoint WireGuard | Tailscale 控制面/DERP 使用动态地址，无法在 Windows 防火墙只放行固定 VPS 的同时证明严格冷启动闭锁 |
| manager 发行版 | 原计划专用 `COR-Egress`；2026-10-23 起改为现有 Ubuntu-26.04 | 产品 profile 允许现有发行版；避免额外维护专用发行版；同一 WSL VM 只有一个 manager |
| 隧道 IP | 一个 peer 对应一个 tunnel IP；26.04 接管时复用 22.04 的密钥与同一 tunnel 地址 | VPS 侧原本只登记一个 peer；复用后无需改 VPS |
| WSL IPv6 | 过滤层拒绝，VPS WSL 出口仅 IPv4 | 避免 IPv6 绕过和地区归属冲突 |
| Windows 防线 | Hyper-V VM firewall 默认拒绝 + 精确放行 UDP 51820 → VPS | 独立第二层；即使 WSL 内 nft 被清空，仍无外网 |
| Linux 防线 | nft `policy drop`，仅放行隧道必要流量；`/etc/wsl.conf` boot hook 恢复 | 冷启动窗口 fail-closed |
| WireGuard 位置 | 在 transport netns 创建，移入 gateway netns，UDP socket 留在 transport | 官方 birthplace 模式，避免外层封装包绕回隧道 |
| DNS | 经隧道到 VPS resolver；无宿主/校园备用 | 防止解析泄漏 |
| Clash 模式 | `run_mode=rule`，profile 顶部 `IP-CIDR,<VPS>/32,DIRECT` | `global` 模式绕过所有规则，WireGuard 外层包会被投进代理节点 |
| 自动恢复 | 产品 boot hook 只恢复 guard；登录计划任务调用产品 `Start` | 产品本身不自动建立隧道 |

### 4.3 生命周期与状态

产品生命周期：`install → configure → guard → start → stop → rollback`。

Windows journal 的主要 phase：

```text
restored → preparing → prepared_for_reinstall → installed_closed
        → connected_unverified → verified
        ↘ blocked / closure_unverified / failed_closed_requested
```

关键语义：

- `Guarded` 是 WSL 每次启动后的常态；`Running` 需要 Windows 侧 `Start` 重新建立。
- `Start` 打开 Hyper-V 端点规则前会重新审计整个范围；任一必需条件不满足则保持关闭。
- 刷新任务要求所有受管发行版都在运行；任一停止会关闭端点并置 `blocked`，不会自行重试。
- 普通发行版在隧道表打开时启动，可能因无法识别共享表而安装 `cor_egress_boot_emergency`；
  因此 `Start` 前应确保普通发行版已运行。

## 5. 计划阶段与执行结果

Codex 已批准计划的阶段与最终状态：

| 阶段 | 计划内容 | 最终状态 |
| --- | --- | --- |
| 0 规格冻结与基线 | 对照附件、刷新版本/模式/规则、记录回滚 | 完成；需求与基线文档在 `docs/wsl-vps-*` |
| 1 原生 UI 与离线骨架 | 侧栏、状态模型、日志、模拟后端 | 完成；PR #2 合并（`50390d3`，2026-10-18） |
| 2 Linux 隔离原型 | 应用 netns、网关、nft、TCP/UDP/DNS/权限 | 完成；隔离数据面测试通过 |
| 3 Windows 持久防线 | broker、SYSTEM guard、Hyper-V、崩溃恢复 | 完成；默认拒绝 + 单端点放行，结构审计通过 |
| 4 VPS 与隧道后端 | Tailscale 闸门 → WireGuard、VPS 出口与 DNS | Tailscale `BLOCKED`；WireGuard 完成并实测出口 |
| 5 全部 WSL 迁移 | NAT、Hyper-V、guard、迁移发行版 | 完成；Ubuntu-26.04 于 2026-10-23 成为 manager |
| 6 故障/重启/回滚验收 | 断线、重启、网络切换、回滚矩阵 | **部分完成**；失败关闭已实测，主机冷启动/网卡切换未测 |
| 7 构建与安装包交付 | CI、fork 测试包、生产替换 | 完成 CI 与测试包；生产替换未执行 |

计划原文见 [WSL Secure Egress implementation plan](wsl-secure-egress-plan.md) 与 Codex
已批准计划（路径见 §1）。

## 6. 实施时间线

### 6.1 2026-10-15：只读调研与需求冻结

- 产出需求、架构、身份威胁模型、GitHub 项目调查、独立验收评审和可视化总览：
  `wsl-vps-requirements-and-plan`、`wsl-vps-network-architecture`、
  `wsl-vps-identity-threat-model`、`wsl-vps-github-project-survey`、
  `wsl-vps-validation-and-review`、`wsl-vps-design-overview.html`。
- 确认现状为 WSL 3.0.3、`mirrored` 文件配置、旧 `XUAN_VPS` 仅作资料来源。
- 本轮未改网络、未登录 VPS、未访问 Claude。

### 6.2 2026-10-16 至 10-17：实现与 PR #2

- 主 Codex 会话批准计划；实现 Rust/Slint 页面、client-core 状态机、Windows broker、
  Linux manager、nft guard、测试和文档。
- 发现并纠正 `mirrored` → NAT 的配置差异；确认 Hyper-V Firewall 路径。
- 同步上游 `v0.5.11`/`v0.6.0`，在 fork 创建 PR #2。
- Tailscale 严格模式闸门未通过，按计划转为固定 Endpoint WireGuard。

### 6.3 2026-10-18：PR #2 合并与审查修复

- PR #2 合并：`50390d3`。
- 处理 PR 审查意见：profile 必填、无 Linux helper 时回滚、`restored` 后重新安装、
  所有受管发行版的 boot guard、VPS unit 首次启动等。
- 启动 Ubuntu 26.04 与 Chrome、Codex CLI、Claude Code CLI/Desktop 工具链的安装；
  工具安装器与基线记录在 10-19 完成。
- 在 WSL 中测试模型厂商连接；确认出口为 VPS IPv4；记录 Claude Code 重启与联网问题。
- 引入管理员作业（UAC）与持久管理员终端；部分 UAC 尝试被取消或超时，保留 `NOT_RUN`。

### 6.4 2026-10-19：实机验证与 Clash of WSL 组件

- 新增独立 `clash-of-wsl` 系统组件、egress-gated 工作区工具安装器、管理员作业。
- 实机验证 NAT 热重启、Ubuntu 26.04 基线、失败关闭 guard、工具链版本。
- 提交系列包括 `75d9517`、`9fb2d48`、`df4fce6`、`717d830`、`917008b`、`1a6c705` 等。
- 管理员作业多次因 UAC 取消、路径不匹配或 DNS 失败而阻塞，均如实记录。

### 6.5 2026-10-20 至 10-21：阻塞与上游 0.6.1

- 端点规则禁用、journal `blocked`，WSL 无出口；记录诊断与阻塞点。
- 合并上游 0.6.1（`2615ebc`），保持 fork 与主线同步。

### 6.6 2026-10-22：PR #3 与审查加固

- PR #3 合并：`1a3920a`。
- 审查加固：移除特权 worker 与硬编码部署数据、恢复 Docker WFP guard、
  规范 SID ACL、验证 release 构建、压缩 UI、隔离 profile fixture。
- Claude 会话开始接手运行态诊断：确认 `blocked`、端点关闭、WSL 无出网。
- 产出 `CODE_REVIEW_2026-10-22`、`DIAGNOSIS_2026-10-23`、`ubuntu22-cleanup-plan`。

### 6.7 2026-10-23：根因修复、26.04 接管与整理

1. **定位 Clash 全局模式**：`settings.json` 的 `run_mode=global` 绕过 profile 顶部的
   `IP-CIDR,...,DIRECT`，WireGuard 外层包被投进代理节点；切换为 `rule` 并持久化。
2. **26.04 manager 迁移**：处理旧 payload、旧 journal、无续跑命令、boot emergency、
   刷新任务失败锁等六个独立阻塞点；journal 从 `restored` 推进到 `installed_closed`
   再到 `connected_unverified`。
3. **验证**：WSL 出口为 VPS IPv4；DNS 正常；IPv6 拒绝；Hyper-V 结构审计通过；
   WSL 重启后 boot hook 只恢复 guard，隧道需重新 `Start`。
4. **失败关闭**：关闭 guard、删除 guard 表、删除 guard 但启用端点、WSL 重启未 Start，
   均无外网出口；端点规则即使启用也只允许 UDP 到 VPS。
5. **主机地址暴露面**：迁移文档 §8.1 所列途径检查，网络/系统命令面无法获得 Windows 校园网地址；
   残余理论面为 `/mnt/c` 全盘可读。
6. **登录自动恢复**：新增 `ClashOfRust-WslEgress-Autostart` 计划任务，按 journal、
   有效端点规则、Linux manager 三事实判断，两次 `wsl --shutdown` 实测恢复。
7. **文档与脚本整理**：`scripts/wsl-secure-egress/local-ops/` 与索引；
   文档入口与运行记录清单。
8. **分支整理**：本地分支合并进 `main`（`ba00c29`），清理行尾问题（`f1fa1a0`），
   删除已合并的本地与远端分支；本地仅保留 `main`。

## 7. 验证与证据

### 7.1 关键验证

| 项目 | 结果 | 证据/边界 |
| --- | --- | --- |
| WSL 出口 IP | PASS（记录时为 VPS 德国 IPv4） | `api.ipify.org`、`ifconfig.co` 一致；`api.myip.com` 曾返回空 |
| WSL DNS | PASS（记录时） | `dns.google` 返回 `Status:0` 与 A 记录 |
| WSL IPv6 出站 | 拒绝 | curl -6 失败；nft 过滤层拒绝 |
| Hyper-V 结构 | PASS | 默认入站/出站 Block，唯一出站允许 UDP → VPS 端点 |
| 失败关闭（共享 netns） | PASS | 关闭 guard、删除 guard、启用端点、重启未 Start 均无出口 |
| WSL 重启 | PASS（fail-closed） | boot hook 恢复 `Guarded`；不自动建隧道 |
| 登录自动恢复 | PASS | 两次 `wsl --shutdown` 后由计划任务恢复握手与出口 |
| 主机地址暴露面 | 结构上无直接途径 | 迁移文档 §8.1 所列途径；`/mnt/c` 仍为理论残余面 |
| Clash 模式 | PASS | `settings.json` `run_mode=rule`；profile 直连规则在 `MATCH` 之前 |
| Windows 关键地址 | PASS | `ipgw` 302、`api.okinto.com` 200（多次复验） |
| 产品测试 | PASS | Python 7 套件、Windows 8 套件、ClashOfWsl 34 断言、Rust 28 |
| 隔离数据面 | PASS | `linux_integration.py --execute-isolated` 86 例 |
| 主机冷启动 | `NOT_RUN` | 未真实重启主机 |
| 网卡切换/休眠恢复 | `NOT_RUN` | 需隔离环境 |
| Docker 受管出口 | `NOT_SUPPORTED` | 独立适配器未实现 |
| WFP 隔离探测 | `NOT_RUN` | 会改变 WFP 状态 |
| live acceptance / fail-closed acceptance | `NOT_RUN` / `BLOCKED` | 需运行态与独立授权 |

### 7.2 测试命令

```bash
python3 -m compileall -q scripts/wsl-secure-egress
python3 -B scripts/wsl-secure-egress/tests/linux_static_test.py
python3 -B scripts/wsl-secure-egress/tests/acceptance_harness_unit.py
python3 scripts/wsl-secure-egress/tests/server_unit.py
sudo python3 -I -B scripts/wsl-secure-egress/tests/payload_unit.py
python3 scripts/wsl-secure-egress/tests/provision_unit.py
```

Windows 离线套件：`windows-unit.ps1`、`elevation-unit.ps1`、`windows-workflow.ps1`、
`windows-automation.ps1`、`package-upgrade-unit.ps1`、`restore-profile-unit.ps1`、
`prepare-package-stage-unit.ps1`、`admin-job-acl.ps1`。

```powershell
cargo fmt --all -- --check
cargo test -p clash-client-core wsl::tests --locked --offline
```

## 8. 当前状态（2026-10-23 晚）

运行态（迁移记录为 2026-10-23 实测；2026-10-24 清理时复核见末条）：

- Ubuntu-26.04 为 manager，`phase=connected_unverified`，端点规则启用。
- WireGuard 握手正常；WSL 出口为 VPS 德国 IPv4；DNS 正常。
- Ubuntu-22.04 作为普通发行版保持运行（刷新任务要求）。
- 登录计划任务 `ClashOfRust-WslEgress-Autostart` 已安装。
- Clash `run_mode=rule` 已持久化；应用中内存模式可能仍需人工确认。
- 失败关闭的 guard 语义保持；无 emergency 表。
- **2026-10-24 清理时复核**：journal `phase=blocked`、`endpoint_enabled=false`，端点规则
  `Enabled=False`，WireGuard 最后握手约 1 小时 13 分钟前；用户选择暂不恢复，保持
  fail-closed。该状态在清理前已存在，删除项不涉及 cor-egress。

仓库状态：

- `main` 在本文提交前位于 `f1fa1a0`；本地仅保留 `main`，最终以 `git log -1` 为准。
- 已合并的远端分支 `feat/wsl-secure-egress`、`fix/wsl-recovery-review-20261018`、
  `codex/fix-claude-protection-recovery` 已删除。
- `main` 领先 `origin/main`（未推送）；领先数随本文提交变化。
- 工作树干净；`cor-upgrade-package/` 为既有权限拒绝目录，未跟踪。
- 文档入口：[docs/README.md](README.md)；本机脚本索引：
  [local-ops](../scripts/wsl-secure-egress/local-ops/README.md)。

## 9. 未完成与风险

1. **主机冷启动未实测**：登录任务为 `AtLogOn`，本轮用 `Start-ScheduledTask` 模拟。
2. **`wsl --shutdown` 不触发登录事件**：需手动运行任务或产品 `Start`。
3. **Ubuntu-22.04 必须保持运行**：刷新任务要求所有受管发行版在运行；停止后约 60 秒
   关闭端点并置 `blocked`，不会自行重试。
4. **Clash 应用内存模式回写风险**：`settings.json` 已改为 `rule`，但运行中的应用可能
   在退出或设置变更时回写；应在 UI 确认模式显示为"规则"。
5. **自动恢复脚本依赖产品私有函数**：产品升级改变模块内部结构时脚本会失效，升级后需复验。
6. **`/mnt/c` 暴露面**：WSL 内以 9p 全盘可读；若其他可读文件含校园网地址，仍可被提取。
   完全消除需关闭 automount，代价是失去 Windows 文件访问。
7. **Docker 受管出口未实现**：Docker Desktop 数据保留，但外部网络未适配、未验收。
8. **Ubuntu-22.04 空间清理已完成（2026-10-24）**：`/` 已用从 30 GB 降至约 6.6 GB，
   回收约 23.4 GB；保留 `claude-desktop`；详见
   [清理方案](wsl-secure-egress/ubuntu22-cleanup-plan-2026-10-23.md) §8。
9. **历史文档含真实地址**：若需脱敏，应单独处理并注意 Git 历史仍保留旧值。
10. **未执行项**：主机重启、网卡切换、休眠恢复、WFP 隔离探测、live acceptance、
    fail-closed acceptance、浏览器/Claude Desktop 完整验收。

## 10. 运维与回退入口

- [本机运维脚本索引](../scripts/wsl-secure-egress/local-ops/README.md)
- [本机配置交接](local-network-handoff-2026-10-15.md)
- [Ubuntu-26.04 迁移、根因与验证](wsl-secure-egress/UBUNTU26-MIGRATION-2026-10-23.md)
- [运行态诊断](wsl-secure-egress/DIAGNOSIS_2026-10-23.md)
- [测试状态](wsl-secure-egress/TEST_STATUS.md)
- [操作指南](wsl-secure-egress/OPERATIONS.md)
- [安全模型](wsl-secure-egress/SECURITY_MODEL.md)

常用恢复路径：

```powershell
Start-ScheduledTask -TaskName 'ClashOfRust-WslEgress-Autostart'
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\wsl-secure-egress\local-ops\Invoke-ProductAction.ps1 -Action Start -Execute
```

回退顺序：产品 `Rollback -RestoreOriginalNetwork` → 恢复发行版旧 payload/journal →
恢复 journal 修复前快照。不要反向覆盖。详见迁移文档 §7。

## 11. 来源与引用

### 11.1 会话

- Codex 主实施会话：`01a146ed-05f1-7c83-aac7-67b01a8df56e`（2026-10-16/17）。
- Codex 设计调研：`01a13cda-d2a8-7183-9ed2-773ac4d4f7ed` 等 2026-10-15 会话。
- Codex 审查与实机：2026-10-18 至 10-19 的会话组。
- Claude：`7e2f16e3-c6ca-4404-90ae-af366760a02a`、`99cd322d-8711-4943-b02e-c160ba2c62fe`。
- 已批准计划：`~/.codex/plans/01a146ed-05f1-7c83-aac7-67b01a8df56e/01a146f6-199e-7743-bd03-2c62813b5907/PLAN.md`。

### 11.2 关键提交与合并

| 日期 | 提交 | 说明 |
| --- | --- | --- |
| 2026-10-18 | `50390d3` | PR #2 合并 |
| 2026-10-22 | `1a3920a` | PR #3 合并 |
| 2026-10-23 | `9477679` | 修正 WSL 出网结论 |
| 2026-10-23 | `bd0f3c2` | 26.04 迁移与验证 |
| 2026-10-23 | `3c8e308` | 本机工作最后提交 |
| 2026-10-23 | `ba00c29` | 合并到 main |
| 2026-10-23 | `f1fa1a0` | 行尾规范化 |

本文档自身的提交未列入上表；最终状态以 `git log -1` 为准。

### 11.3 详细文档

- 需求与调研：`docs/wsl-vps-requirements-and-plan-2026-10-15.md`、
  `docs/wsl-vps-network-architecture-2026-10-15.md`、
  `docs/wsl-vps-identity-threat-model-2026-10-15.md`、
  `docs/wsl-vps-github-project-survey-2026-10-15.md`、
  `docs/wsl-vps-validation-and-review-2026-10-15.md`、
  `docs/wsl-vps-followup-assessment-2026-10-15.md`。
- 产品文档：`docs/wsl-secure-egress/README.md`、`SECURITY_MODEL.md`、
  `OPERATIONS.md`、`COMPATIBILITY.md`、`WSL_CHANGES.md`、`WINDOWS_CHANGES.md`、
  `CLASH_UI_CHANGES.md`、`UPSTREAM_COMPARISON.md`。
- 运行记录：`docs/wsl-secure-egress/TEST_STATUS.md`、`LOCAL_TEST_2026-10-18.md`、
  `LOCAL_TEST_LOG_2026-10-19.md`、`LIVE_VALIDATION_2026-10-19.md`、
  `DIAGNOSIS_2026-10-23.md`、`UBUNTU26-MIGRATION-2026-10-23.md`。
- 本机网络：`docs/local-network-handoff-2026-10-15.md`、
  `docs/ai-domain-inventory-2026-10-15.md`、`docs/vps-ai-ipv4-change-2026-10-15.md`、
  `docs/vps-claude-ipv4-change-2026-10-15.md`。
