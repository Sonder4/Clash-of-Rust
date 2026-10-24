# Clash of Rust 优化与 Chrome / Claude Code / Clash of WSL 设计需求及方案

- 日期：2026-10-24
- 状态：设计建议（**未实施**；本文不修改代码、网络、防火墙或 WSL）
- 适用对象：Clash of Rust 0.6.1 本机安装、Chrome 受管配置、Claude Code CLI/Desktop、Clash of WSL / WSL Secure Egress
- 证据口径：`CONFIRMED` 有直接证据；`LIKELY` 证据一致但缺少最后一步；`NOT_RUN` 未执行；`BLOCKED` 受条件阻断

本文把用户需求、现有实现、2026-10-24 的只读诊断和代码审查结论合并成一份可执行的整改方案。所有“建议”都需要另行授权后才能实施；本文本身不代表任何验收通过。

---

## 0. 摘要：先做哪几件事

| 优先级 | 事项 | 为什么现在做 | 验收信号 |
| --- | --- | --- | --- |
| P0-1 | 修复 TUN 开启后的内核出站回环 | TUN 开启后直连与 17890 全部 TLS 失败；Chrome/Claude Code 都会失去可用路径 | 开启 TUN 后 90 秒内 `ipgw` 302、`okinto` 200、`Find-NetRoute` 不再把节点地址选到 `Meta` |
| P0-2 | 修复 `ClashOfRust-Strict-Core-VpsOnly` 的失效路径 | 规则指向不存在的 `D:\Clash\resources\mihomo.exe`，对当前两个内核都不生效 | 规则按文件身份而非路径匹配，两个真实内核均被覆盖 |
| P0-3 | 把 TUN 切换做成原子事务 | `settings.json`、UI、`runtime/config.yaml`、live 内核四套状态不同步 | 任一步失败后四套状态回到同一值，UI 不显示假“已连接” |
| P0-4 | Windows 端口预检增加有界等待 | 重启时 9090 的 `os error 10048` 是端口释放竞态 | 连续 10 次“关内核→开内核”不再出现 10048 |
| P0-5 | 解开 `claude_protection` 与 `strict-route` 的强制耦合 | 保护开启会强制 `strict-route: true` 并删除 `route-exclude-*`，而本机 strict-route 会拦死全部流量 | 保护开启时 TUN 仍可用，或明确拒绝在 TUN 下启用保护 |
| P0-6 | Chrome 本机页面使用固定回环端口 | 当前 `ProxyBypassList` 允许整个 `127.0.0.1`，暴露面大于所需 | 只绕过固定端口，Chrome 策略与 WFP 规则一致 |
| P0-7 | 给 Claude Code 增加出口预检包装器 | 当前没有“先确认德国出口，再启动 Claude”的强制入口 | 非德国/非 IPv4/代理不可用时，Claude 不启动，退出码非 0 |
| P0-8 | Clash of WSL 的“已迁移/已启用”状态收敛 | 迁移文档、AGENTS 交接与当前 `state.json` 说法不一致；端点当前关闭 | 受控 `Start` 一次并留下可复核证据，之后才更新状态文档 |

---

## 1. 基线与证据边界

### 1.1 本机安装基线（2026-10-24）

| 项目 | 当前值 | 来源 |
| --- | --- | --- |
| 应用 | Clash of Rust 0.6.1，`D:\Clash\Clash of Rust\clash-of-rust.exe` | [TUN 分析](clash-tun-failure-analysis-2026-10-24.md) |
| 应用侧内核 | `D:\Clash\Clash of Rust\resources\mihomo.exe`，mihomo v1.19.33 | 同上 |
| 服务侧内核 | `D:\Clash\Clash of Rust Network\mihomo.exe`，由 `ClashOfRust.Network` 服务拉起 | [本机清单](local-network-inventory-2026-10-24.md) |
| WSL 辅助包 | `D:\Clash\Clash of Rust WSL`，`ClashOfRust.WslEgress` 服务 Running | 同上 |
| Chrome 守护 | `D:\Clash\tools\ChromeGuard`，计划任务 `ClashOfRust-Chrome-Listener` | 同上 |
| 当前代理模式 | 系统代理 `127.0.0.1:17890` 可用；TUN 开启后失败 | [系统审计](system-network-audit-2026-10-24.md) |
| WSL 出口 | `state.json`：`phase=restored`、`endpoint_enabled=false` | 同上 |
| 关键地址 | 系统代理模式下 `ipgw` 302、`okinto` 200 | 同上 |

### 1.2 证据冲突

- 迁移文档 [UBUNTU26-MIGRATION-2026-10-23](wsl-secure-egress/UBUNTU26-MIGRATION-2026-10-23.md) 记载 Ubuntu-26.04 已成为 manager、隧道完成、登录自动恢复“部分完成”。
- 项目交接 `AGENTS.md` 记载 run 1 冻结、run 2 因 UAC 取消未执行。
- 2026-10-24 的 `state.json` 是 `restored`、端点关闭。

结论：**当前运行态以 `restored` 为准**；“迁移完成”只能作为历史候选结论，需一次受控 `Start` 并复核后更新文档。本文不据此宣称 Clash of WSL 已验收。

### 1.3 本文不重复的已知边界

- 不启用 Windows 全局 VPN，不接管普通 Windows 应用。
- 不做全局 NRPT `Namespace='.'`、不阻断整个 `Dnscache`、不清空防火墙、不重置网络。
- 不把未执行的测试写成通过；故障注入只在隔离环境或有独立通路时进行。
- 不记录订阅 URL、私钥、控制器 secret、VPS 真实地址。

---

## 2. 总体设计原则

1. **每类流量只有一个明确归属。** Chrome、Claude Code、WSL 受管业务分别定义“允许路径 / 拒绝路径 / 失败关闭”，不靠 DNS 或系统代理的隐式行为。
2. **失败关闭，不回退直连。** 隧道、代理、guard 任一不可用时，受管流量应明确失败，而不是悄悄走本地出口。
3. **状态可验证，而不是进程可验证。** “进程在”“端口在”“控制器返回 200”都不等于“出口正确”。状态至少分四层：进程/端口、代理可达、实际出口、目标地区。
4. **最小上游差异。** Clash of Rust 只做 UI 与控制器；WSL 数据面在独立后端；尽量用 profile/config 表达策略，少改生成器。
5. **无硬编码路径、IP、端口。** 安装根、内核路径、代理端口从配置派生；规则按文件身份或服务名匹配，不按会漂移的绝对路径。
6. **变更事务化。** 每次网络变更都有紧邻快照、单一定向回退、变更后复验两个关键地址。
7. **证据分级。** `CONFIRMED / LIKELY / NOT_RUN / BLOCKED` 必须保留，不把“结构成立”写成“端到端通过”。

---

## 3. Clash of Rust 优化与修改意见

### 3.1 问题与修改清单

| ID | 级别 | 问题 | 证据 | 建议修改 | 落点 | 验收 |
| --- | --- | --- | --- | --- | --- | --- |
| CR-01 | P0 | TUN 开启后内核到代理节点的出站被 TUN 默认路由抓回，形成 `reject loopback` | `CONFIRMED`：内核日志、路由表、IPv6 10443 SynSent、五组对照 | 为节点地址建立排除路由；TUN 开启前做运行时校验；不要把 `interface-name` 当默认修复 | `crates/client-core/src/config/mod.rs`（tun 生成）；profile | TUN 下 `Find-NetRoute` 对节点地址选物理网卡；delay 探测 DIRECT/VLESS 均通 |
| CR-02 | P0 | `strict-route: true` 在本机会拦死内核自身出站 | `CONFIRMED`（用户实验）；`protection/mod.rs` 会强制开启 | 保护开启时不要无条件强制 strict-route；在 UI/日志暴露 live 值；TUN 前校验 | `crates/client-core/src/protection/mod.rs:586` | 保护开启 + TUN 组合有明确通过与拒绝两种结果，不出现“全断但 UI 绿灯” |
| CR-03 | P0 | 9090 重启竞态导致 `10048` | `CONFIRMED`：错误发生在旧内核未释放时；Windows 只 bind 一次 | 对齐 macOS 的 `wait_for_mac_port`，对 9090/17890 做有界等待；先停旧实例再启动 | `apps/desktop/src/engine/mod.rs:372-390`、`:41` | 连续重启 10 次无 10048 |
| CR-04 | P0 | 四套状态不同步：settings / UI / runtime / live | `CONFIRMED`：02:07 的四种状态 | 引入单一 `EffectiveState` 回读；TUN 切换事务化；失败回滚四套状态 | `apps/desktop/src/engine/mod.rs`、`crates/client-core/src/config/mod.rs` | 任一步失败后四套状态一致；UI 只显示回读值 |
| CR-05 | P0 | 核心防火墙规则指向不存在的路径 | `CONFIRMED`：规则指向 `D:\Clash\resources\mihomo.exe` | 按文件身份/哈希或服务名匹配；覆盖应用内核与服务内核两条路径；启动时做漂移检测 | Chrome/WFP 维护脚本 | 两个真实内核都被规则覆盖；路径变化后自动报告 |
| CR-06 | P1 | 应用日志只在内存，重启即丢 | `CONFIRMED`：未找到持久化日志 | 有界滚动日志，包含 config hash、live tun、端口、内核 stderr；脱敏 | `apps/desktop/src/engine/mod.rs` | 重启后仍能回溯上一次 TUN 失败 |
| CR-07 | P1 | 更新通道被关闭，安装版与源码可能漂移 | `CONFIRMED`：0.6.1 已装，fork 更新通道禁用 | 提供签名的 fork 更新通道，或至少在 UI 显示版本/资源哈希漂移 | `apps/desktop/src/update/`、打包脚本 | 版本、资源哈希、服务二进制一致或明确告警 |
| CR-08 | P1 | 重新生成配置可能覆盖用户/运维加的键 | `LIKELY`：`interface-name`、`route-exclude-*` 不在 Settings 中 | 保留未知 tun 键与 profile 顶层键；订阅更新前备份并提示 | `crates/client-core/src/config/mod.rs` | 更新订阅后手工键仍在，或有明确差异报告 |
| CR-09 | P1 | 健康状态过于粗糙 | `CONFIRMED`：UI 曾显示“TUN 已连接”但数据面失败 | 状态分四层：core、proxy、egress、country；显示最后验证时间 | UI/状态模型 | UI 不再用进程存在推导“已连接” |
| CR-10 | P1 | 控制器 secret 明文保存在 settings | `LIKELY`：当前为本地文件 | 用 DPAPI/系统凭据保护；Debug/日志脱敏 | `crates/client-core/src/config/mod.rs` | 日志与导出不含 secret |
| CR-11 | P1 | 服务内核与应用内核可能并存/孤儿 | `CONFIRMED`：历史出现服务侧与应用侧两个内核 | 单实例锁；启动前枚举并处理孤儿；服务状态与 UI 同步 | `apps/desktop/src/engine/mod.rs`、`platform/windows/service` | 任意时刻只有一个受管内核 |
| CR-12 | P2 | WSL 页面缺少“隔离应用”入口 | 文档记录 UI 缺少应用分区 | 增加“启动安全终端/查看隔离会话”，不把安装配置堆在首屏 | WSL UI | 用户能从页面启动受管应用并看到状态 |
| CR-13 | P2 | 关键路径缺少集成测试 | TUN 回环、端口竞态、Chrome 规则语义都曾漏过 | 增加 TUN 回环集成测试、端口竞态测试、状态机属性测试 | `crates/client-core/src/wsl/tests.rs`、`apps/desktop` 测试 | CI 覆盖三类回归 |

### 3.2 TUN 专项方案

根因链（已确认）：`auto-route` 建立 `0.0.0.0/0` 与 `::/0` 指向 `Meta` 的默认路由；内核到节点的出站没有排除路由；`auto-detect-interface` 在 TUN 建立后可能选到 `Meta`；`strict-route` 在本机又会拦死内核自身。结果是“入口活着、出口死了”。

建议按以下顺序处理，**不要直接照搬 `interface-name: WLAN`**（本机已试过，表现更差并回退，见 [本机清单 §19](local-network-inventory-2026-10-24.md)）：

1. **先做最小对照**：`MATCH,DIRECT` + 单条直连规则 + 无 DNS 劫持 + 无 fake-ip，确认回环是否仍复现。若仍复现，倾向内核在本机的 TUN 行为问题。
2. **排除路由优先**：为所有实际节点地址生成 `route-exclude-address`（IPv4 /32、IPv6 /128），并在 TUN 开启后校验 `Find-NetRoute` 对节点地址选择物理网卡。节点地址变化时重新生成，不能写死。
3. **处理多网卡干扰**：手机 USB 共享的 `以太网 2`（VirtNet，link-local、跃点 35）是 `auto-detect-interface` 误判的强嫌疑；TUN 测试前先禁用或拔除，做一次有效 A/B。
4. **再考虑接口绑定**：只有在排除路由仍不足、且确认接口名稳定时，才使用 `interface-name`；并把“网卡变化导致 fail-closed”写进 UI 提示。
5. **strict-route 不作为默认**：在问题解决前，TUN 与 `claude_protection` 不得同时开启；保护逻辑不应删除 `route-exclude-*`。
6. **核心版本 A/B**：以上均无效时，用官方 release 做内核版本对照；不改仓库内核，除非用户明确授权。

TUN 启用门槛（建议写成代码级 preflight）：

- 代理节点地址有排除路由，或能证明 `auto-detect-interface` 选到物理网卡；
- `strict-route` 为 false，或明确选择严格模式并接受风险；
- 9090/17890 可用；
- 开启后 5s / 30s / 90s 三次采样通过；
- 失败时自动回到系统代理，并把四套状态对齐。

### 3.3 修改落点（按文件）

| 文件 | 建议改动 |
| --- | --- |
| `crates/client-core/src/config/mod.rs` | TUN 生成时保留/生成排除路由；保留未知 tun 键；暴露 strict-route 到状态 |
| `crates/client-core/src/protection/mod.rs` | 去掉“保护即强制 strict-route + 删除排除键”的硬耦合；改为显式策略 |
| `apps/desktop/src/engine/mod.rs` | Windows 端口有界等待；TUN 切换事务；孤儿内核处理；持久化日志 |
| `apps/desktop/src/application/wsl/*` | 与 TUN 状态解耦；WSL 页面只消费结构化状态 |
| Chrome/WFP 维护脚本 | 规则按文件身份/哈希；修正核心路径；增加漂移检测 |

---

## 4. Chrome 数据（流量）需求与方案

### 4.1 需求

| ID | 需求 | 验收 |
| --- | --- | --- |
| CH-01 | Chrome 的所有公网流量只经 VPS 出口 | `ip.net.coffee` / 中立探针显示 VPS IPv4、地区 DE |
| CH-02 | Chrome 不得直连物理网卡 | 关闭 17890 后 Chrome 明确失败，不出现直连成功 |
| CH-03 | Chrome 的 DNS 不得走校园/本地解析 | DNS 泄漏测试只看到 VPS/隧道解析路径；不出现校园 DNS |
| CH-04 | Chrome 不得通过 IPv6 绕过 | IPv6 泄漏测试无本机 IPv6 出口 |
| CH-05 | WebRTC 不得泄漏本地/直连地址 | WebRTC 测试只显示代理路径或失败 |
| CH-06 | QUIC 行为确定，不因 UDP 失败静默回退直连 | QUIC 关闭或经代理；无直连 UDP 成功 |
| CH-07 | 本机页面/回环服务可用，但绕过范围最小 | 只绕过固定回环端口，不绕过整个 `127.0.0.1` |
| CH-08 | 代理不可用时 fail-closed | Chrome 显示错误页，不自动直连 |
| CH-09 | 受管策略可审计、可回退 | `chrome://policy` 与注册表快照一致；有回退脚本 |
| CH-10 | 不依赖系统代理作为唯一约束 | WFP/防火墙与 Chrome 策略双重约束 |

### 4.2 现状与差距

- Chrome 策略：`fixed_servers`、`127.0.0.1:17890`、`ProxyBypassList=<-loopback>;127.0.0.1`、DoH `secure`、QUIC 禁用（[网络操作审计](network-operations-audit-2026-10-24.md)）。
- 四条 Chrome 出站规则：阻断非 loopback；只允许 loopback TCP 17890；阻断 loopback UDP；另有一条阻断物理网卡直连（[系统审计 §3.2](system-network-audit-2026-10-24.md)）。
- 核心规则 `ClashOfRust-Strict-Core-VpsOnly` 指向 `D:\Clash\resources\mihomo.exe`，该路径不存在，**对当前内核不生效**（`CONFIRMED`）。
- 规则文本声称“只允许 loopback TCP 17890”，但 2026-10-15 的本机页面（随机端口）在只改 bypass 后成功加载。二者语义存在冲突，说明**不能只凭规则文本判断实际拦截**，需要一次 WFP/抓包级验证。
- 系统代理绕过表是 `localhost;127.*;[::1];<local>`，与 Chrome 自己的 bypass 列表不是同一对象；两者需要分别审计。

### 4.3 目标路径

```text
Chrome
  │  固定 HTTP 代理 127.0.0.1:17890（企业策略）
  ▼
mihomo（系统代理模式或 TUN 模式）
  │  rule 模式，目标域名/规则 → 固定 VPS 节点
  ▼
德国 VPS（IPv4 出口，指定 DNS）
  ▼
目标站点
```

约束：

- Chrome 进程级 WFP：除 loopback TCP 17890 外，禁止所有出站（含 UDP/QUIC、DNS、IPv6）。
- 代理不可用时，Chrome 没有第二条路；这是有意 fail-closed。
- 本机页面只允许固定回环端口，不允许整个 `127.0.0.1`。

### 4.4 修改建议

1. **修正核心规则**：按文件身份（文件 ID/哈希/签名）匹配 `mihomo.exe`，或同时枚举应用内核与服务内核两条真实路径；启动/升级后做漂移检测。不要继续使用会随安装目录变化的绝对路径。
2. **收窄 loopback 例外**：
   - 把 Clash 的浏览器检测/回传页面改为**固定端口**（由产品分配一个未占用的专用端口），Chrome bypass 只写 `127.0.0.1:<该端口>`；
   - 如果必须保留随机端口，用 PAC 精确匹配该端口段，或把页面改为经 17890 代理访问；
   - 不建议长期保留 `127.0.0.1` 整段绕过。
3. **验证规则语义**：写一个自动化测试，实际发起“Chrome → 127.0.0.1:随机端口”“Chrome → 127.0.0.1:17890”“Chrome → 公网 443/53/UDP”的请求，确认 WFP 的实际结果与规则意图一致；不要只导出规则文本。
4. **Chrome 策略**：
   - `ProxySettings`：固定 `http://127.0.0.1:17890`；bypass 只保留必要项；
   - `DnsOverHttpsMode`：建议 `off`（或保留 `secure` 但必须验证其不会直连 DoH 供应商）；配合 WFP 阻断 53/853/DoH；
   - `QuicAllowed=false`：避免 QUIC 在代理路径上不确定；
   - `WebRtcIPHandlingPolicy=disable_non_proxied_udp`：即使 WFP 已阻断，也用策略给出确定行为；
   - `DnsPrefetchingEnabled=false`：减少非必要解析；
   - 可选：为受管浏览使用独立 Chrome profile，避免个人账号/扩展改变代理行为。
5. **把 ChromeGuard 纳入产品**：当前维护器在 `D:\Clash\tools\ChromeGuard`，规则由外部脚本维护。建议把它变成有版本、有测试、有回退的产品组件，至少要有：
   - 规则清单与哈希；
   - 每次启动校验规则存在且参数正确；
   - 规则缺失/路径漂移时在 UI 告警；
   - 一键回退到“未受管”状态。
6. **失败关闭的用户提示**：17890 不可用时，UI 应明确显示“Chrome 已阻断，代理不可用”，而不是让用户以为网络故障。当前 TUN 失败时正是这种放大效应。

### 4.5 验收矩阵

| 测试 | 方法 | 通过标准 |
| --- | --- | --- |
| 出口 | `ip.net.coffee` + 中立 IP 探针 | IPv4、DE、与 VPS 记录一致 |
| 直连阻断 | 停 17890，访问公网 | Chrome 失败；无直连成功 |
| DNS | DNS 泄漏测试 + `chrome://net-internals/#dns` | 无校园 DNS；解析经代理/隧道 |
| IPv6 | IPv6 测试页 | 无本机 IPv6 出口 |
| WebRTC | WebRTC 泄漏测试 | 仅代理地址或失败 |
| QUIC | `chrome://flags`/策略 + 抓包 | 无直连 UDP 443 |
| 本机页面 | 固定端口页面 | 可打开；端口外 loopback 被阻断 |
| 策略 | `chrome://policy` | 与注册表快照一致 |

### 4.6 Chrome 本地数据与指纹（可选加固）

“Chrome 数据”除了网络流量，还包括本地 profile、Cookie、缓存和浏览器可见的环境特征。建议把它们当作**独立的隐私边界**，不要把“流量走 VPS”误写成“浏览器身份完全等同于德国本机”。

- **独立 profile**：为受管浏览建立单独的 Chrome profile，避免个人账号、扩展和同步策略改变代理行为；profile 目录纳入备份/回退清单，但不提交到 Git。
- **时区/语言**：Chrome 的 `Date`、`Intl` 和部分 Client Hints 来自操作系统；仅改代理不会改变 Windows 时区/语言。若需要一致，应单独评估系统级或 profile 级方案，并明确其影响范围，不要静默修改系统设置。
- **WebRTC/QUIC/DNS**：由第 4.4 节的策略与 WFP 共同约束；不要只依赖 Chrome 设置。
- **本地数据清理**：缓存、历史、Cookie 可能包含非目标地区的内容；清理前必须备份并确认不影响用户账号，不例行执行 `Clear-Site-Data` 或删除 profile。
- **能力边界**：Canvas、字体、屏幕分辨率、硬件并发等指纹不在本方案范围内；不承诺“平台认定德国”或“不可识别”。现有 [身份与威胁模型](wsl-vps-identity-threat-model-2026-10-15.md) 的边界仍然适用。
- **备份**：Chrome 策略与 profile 的变更使用紧邻快照；现有备份位于 `ClashOfRust-network-backups`，不得提交到 Git。

---

## 5. Claude Code 流量需求与方案

### 5.1 需求

| ID | 需求 | 验收 |
| --- | --- | --- |
| CC-01 | Claude Code CLI/Desktop 的模型与账号流量只经 VPS 德国 IPv4 出口 | 实际请求的出口 IP 为 VPS IPv4、地区 DE |
| CC-02 | 访问 Claude/Anthropic 前必须先确认同一实际通路出口为德国 | 预检失败即不启动；中国大陆/无法确认时禁止 |
| CC-03 | 不得回退直连或校园 DNS | 代理/隧道失败时明确失败 |
| CC-04 | 不得通过 IPv6 绕过 | IPv6 出口被拒绝或不可用 |
| CC-05 | 共享遥测/第三方服务有明确策略 | 已知 Anthropic 自有走 VPS；未知共享默认阻断或显式放行 |
| CC-06 | 不记录 prompt、token、API key、完整请求体 | 日志仅记录决策与出口元数据 |
| CC-07 | CLI 与 Desktop 分别验证 | 两者都有独立证据，不互相替代 |
| CC-08 | 可在 WSL 内复现同样的出口约束 | WSL 内 Claude Code 出口为 VPS IPv4 |
| CC-09 | 不做无法证明所有权的宽泛域名规则 | 规则清单可追溯，共享域标注风险 |
| CC-10 | 失败关闭且可回退 | 一键回到系统代理/未受管状态 |

### 5.2 流量分类

| 类别 | 代表目标 | 归属 | 建议 |
| --- | --- | --- | --- |
| 模型/API | `api.anthropic.com`、`platform.claude.com` | Anthropic | 固定 VPS 代理组；IPv4-only |
| 账号/OAuth | `claude.ai`、`claude.com`、`console.anthropic.com` | Anthropic | 同上；不登录测试 |
| 下载/更新 | `downloads.claude.ai`、`releases.claude.com` | Anthropic | 走 VPS；或明确禁用自动更新 |
| MCP/桥接 | `mcp-proxy.anthropic.com`、`bridge.claudeusercontent.com` | Anthropic | 走 VPS；WebSocket 需单独验证 |
| 资源/预览 | `assets.claude.ai`、`*.claudeusercontent.com`、`*.claudemcpcontent.com` | Anthropic | 走 VPS |
| 第一方遥测 | `api.anthropic.com/api/event_logging/*` | Anthropic | 走 VPS 或按隐私策略关闭 |
| 共享遥测 | Datadog、Sentry、Statsig、Intercom 等 | 第三方/共享 | **不整域强制**；默认阻断或显式放行 |
| 共享存储/工具 | `storage.googleapis.com`、`github.com`、`amazonaws.com` | 共享 | 不因 Claude 而整域改路由 |

完整清单见 [AI 域名台账](ai-domain-inventory-2026-10-15.md) 与 [Claude 离线网络分析](claude-app-static-network-audit-2026-10-15.md)。台账是管理记录，不是可直接导入的规则。

### 5.3 现状与差距

- 服务端已对 11 个 Claude 匹配器（7 后缀、4 精确主机）强制 IPv4-only，并拒绝匹配流量使用 IPv6（`CONFIRMED`，见 [Claude 变更记录](vps-claude-ipv4-change-2026-10-15.md)）。
- 客户端 `claude_protection` 会固定域名并启用严格策略；但它会强制 `strict-route: true` 并删除排除键，与本机 TUN 回环冲突（`CONFIRMED` 代码行为，见 `crates/client-core/src/protection/mod.rs:586`）。
- 当前没有“启动 Claude 前先验证出口”的强制包装器；用户只能靠手工检查。
- CLI 与 Desktop 的共享遥测、第三方 provider、MCP、工作区工具并未全部落在 11 个严格匹配器内；不能宣称“全部流量已受控”。
- WSL 内的 Claude Code 走 WireGuard 固定出口；Windows 侧走 Clash 代理，两者是不同路径，需要分别验收。

### 5.4 方案

#### 5.4.1 路由层

- 在 mihomo 规则中为 Anthropic 自有域名建立**精确规则**，指向固定的 VPS 节点/代理组，不使用 URLTest/自动选择，不允许 DIRECT 回退。
- 共享第三方域不整域强制；需要时按“显式主机 + 用途 + 来源”登记，无法证明所有权的保持阻断或默认路径。
- VPS 侧保留 IPv4-only 强制与 IPv6 拒绝；客户端到 VPS 的接入仍可按用户要求使用 IPv6（这是两段不同链路）。
- 保持 `run_mode=rule`；`global` 会绕过规则，必须禁止。

#### 5.4.2 出口预检包装器（建议新增）

```text
claude-vps
  1. 检查 9090/17890 可用（或 TUN 状态为已验证）
  2. 经同一代理路径请求中立出口探针（如 ipwho.is / ip.sb）
  3. 要求：IPv4、国家 DE、地址与记录的 VPS 出口一致
  4. 任一条不满足 → 不启动 Claude，退出码非 0，写一条无敏感信息的拒绝日志
  5. 通过 → 设置 HTTPS_PROXY/HTTP_PROXY/NO_PROXY，exec 原始 claude
```

要点：

- 探针必须与 Claude 使用**同一代理/同一路径**，不能用直连探针代替。
- 不通过访问 Claude 本身来“测试”；使用中立探针，避免在未确认出口时请求目标。
- 包装器不读取/打印 API key、prompt、token；只记录时间、出口 IP、国家、代理路径、结果。
- 代理环境变量只注入被启动的 Claude 子进程，不写入系统环境或用户全局配置，避免影响其他程序。
- 对 Desktop：优先用系统代理 + WFP 约束；若 Desktop 不遵守代理，使用 TUN（在 CR-01 修复后）或进程级规则。

#### 5.4.3 遥测与隐私策略

- 明确三档：`route-via-vps`（Anthropic 自有）、`block`（未知共享）、`user-opt-in`（明确允许的共享服务）。
- 默认不把 `sentry.io`、`datadoghq.com`、`statsigapi.net` 等共享域整域强制到 VPS；这会误伤其他应用，也不能证明 Anthropic 所有权。
- 若阻断导致功能降级，在 UI/文档中说明，而不是静默放行。

#### 5.4.4 DNS 与 IPv6

- 代理模式下由代理远端解析；不要让 CLI 走本地 DNS。
- 阻断 Chrome/Claude 进程的 53/853/DoH 直连；DoH 策略要与 WFP 一致。
- IPv6 出口拒绝；如果目标只有 IPv6，明确失败，不回退本地 IPv6。

### 5.5 验收矩阵

| 测试 | 方法 | 通过标准 |
| --- | --- | --- |
| CLI 出口 | 包装器预检 + 中立探针 | IPv4、DE、与 VPS 记录一致 |
| CLI 失败关闭 | 停 17890 / 切换非 DE 节点 | Claude 不启动，退出码非 0 |
| Desktop 出口 | 实际请求的中立探针/日志 | IPv4、DE；不出现本机出口 |
| DNS | 解析日志/泄漏测试 | 无校园 DNS；无直连 DoH |
| IPv6 | 双栈目标测试 | 不出现本机 IPv6 |
| 共享遥测 | 连接日志 | 符合三档策略，无未登记整域规则 |
| WSL 内 CLI | 受管 launcher 内运行 | 出口为 VPS IPv4；看不到 Windows 真实 IP |

---

## 6. Clash of WSL 设计需求与方案

### 6.1 目标与非目标

**目标**

1. WSL 受管业务流量只经德国 VPS IPv4 出口；DNS、IPv6 不能绕过。
2. 隧道/guard/审计任一异常时 fail-closed，不回退 Windows 或 WSL 本地出口。
3. Windows 普通联网、校园认证、API 访问不受影响。
4. Clash of Rust 只做 UI 与控制器；WSL 数据面独立、可安装、可常驻、可回滚。
5. 所有变更可审计、可回滚、可验证；未执行测试保持 `NOT_RUN`。

**非目标**

- Windows 全局 VPN / 全局 DNS 接管。
- 删除 WSL 发行版、Docker 数据、用户文件、CC Switch 数据。
- 承诺“任何网络、任何时刻零泄漏”。
- 伪造本地命令输出或平台地区认定。
- 生产环境故障注入。

### 6.2 需求

| ID | 需求 | 验收 |
| --- | --- | --- |
| CW-01 | 受管 WSL 应用的公网出口为 VPS IPv4 | 出口探针显示 VPS IPv4；无宿主校园地址 |
| CW-02 | 透明接管 TCP/UDP/DNS，不依赖应用代理变量 | 清空代理变量后仍走隧道；UDP 阻断属降级不算通过 |
| CW-03 | IPv6 出站拒绝，不回退本地 IPv6 | 双栈/AAAA-only 目标失败关闭 |
| CW-04 | DNS 只经隧道 resolver | 无校园 DNS；DoH/DoT 边界记录 |
| CW-05 | 隧道/guard/审计失败时 fail-closed | 停隧道、停服务、清 nft 后均无直连 |
| CW-06 | Windows 外层默认拒绝 + 唯一端点放行 | Hyper-V 策略与端点规则可回读 |
| CW-07 | Linux 内层 nft 默认 drop + boot guard | 冷启动窗口也保持闭锁 |
| CW-08 | 安装/配置/启动/停止/测试/回滚全生命周期 | 每步有结构化结果与 journal |
| CW-09 | 控制面固定动作，不接受任意脚本/参数 | 参数 allowlist、SID 绑定、操作 ID、代次 |
| CW-10 | 私密材料只经 stdin/受保护文件 | 不出现在 argv、日志、报告 |
| CW-11 | 自动发现已安装发行版，只对 profile 指定的发行版执行 | 未指定/未知配置的发行版保持不动并报告 |
| CW-12 | 登录/重启后可恢复 guard；Start 仍显式 | 重启后 Guarded，不自动开隧道 |
| CW-13 | UI 最小化，只展示可回读状态 | `PASS/FAIL/BLOCKED/NOT_RUN` 四态 |
| CW-14 | 不影响 Windows 普通网络 | 两个关键地址始终 302/200 |
| CW-15 | Docker/interop/WSLg 边界明确 | 不声称未验证的 Docker 出口 |
| CW-16 | 安装包/资源可校验，升级不破坏保护 | 哈希/签名、原子替换、回滚保留 |

### 6.3 架构

```text
┌─────────────────────────────────────────────────────────────┐
│ Clash of Rust（Slint UI）                                    │
│   安装 / 连接 / 断开 / 状态 / 测试 / 日志 / 恢复原网络         │
└───────────────────────────┬─────────────────────────────────┘
                            │ 固定动作协议（SID、操作 ID、代次）
┌───────────────────────────▼─────────────────────────────────┐
│ Windows                                                     │
│   用户级 broker：校验请求、UAC、固定脚本 allowlist            │
│   SYSTEM guardian：持久策略、Hyper-V VM firewall、审计        │
│   Hyper-V：默认拒绝 + 唯一放行 UDP → VPS 端点                 │
└───────────────────────────┬─────────────────────────────────┘
                            │ WSL NAT
┌───────────────────────────▼─────────────────────────────────┐
│ WSL（共享 netns）                                            │
│   manager 发行版（当前计划 Ubuntu-26.04）                    │
│   nft guard：默认 drop，boot hook 恢复                        │
│   transport netns ── veth ── gateway netns                   │
│   WireGuard wg0（gateway；UDP socket 留 transport）           │
│   DNS 固定 resolver；IPv6 drop；interop 关闭                  │
└───────────────────────────┬─────────────────────────────────┘
                            │ WireGuard UDP（固定 IPv4 端点）
┌───────────────────────────▼─────────────────────────────────┐
│ 德国 VPS：固定 IPv4 出口、WireGuard peer、Tunnel DNS          │
└─────────────────────────────────────────────────────────────┘
```

### 6.4 关键设计决策

| 决策 | 结论 | 理由 |
| --- | --- | --- |
| 后端 | 固定 Endpoint WireGuard；Tailscale 严格模式 `BLOCKED` | Tailscale 控制面/DERP 动态地址，无法在“只放行固定 VPS”的外层边界下证明冷启动闭锁 |
| WSL 网络模式 | NAT，不用 mirrored | 与 Hyper-V firewall、netns、DNS 控制兼容；避免 mirrored 的隐式代理/DNS |
| 数据面隔离 | transport netns + gateway netns + 业务 veth | 防止外层封装包绕回隧道；WireGuard UDP socket 留在 transport |
| DNS | 固定隧道 resolver；`generateResolvConf=false`、`generateHosts=false` | 防止校园/宿主解析泄漏 |
| IPv6 | 受管流量拒绝 | 避免地区归属冲突和绕过 |
| Clash 模式 | `run_mode=rule`；WSL 端点 `IP-CIDR ... DIRECT` | `global` 会绕过规则，把 WireGuard 外层包投进代理节点 |
| 自动恢复 | boot hook 只恢复 guard；Start 显式 | 产品不自动开隧道；重启后默认闭锁 |
| UI | 只做控制与状态，不嵌入数据面 | 最小化上游差异，降低桌面进程权限面 |

### 6.5 控制面契约

**动作**：`Doctor`、`Status`、`Install`、`Start`、`Stop`、`Test`、`Rollback`、`Uninstall`；内部 `configure`、`guard`、`run`、`attest`、`restore-config`。

**请求**（建议字段）：

```json
{
  "action": "Start",
  "execute": true,
  "generation": 42,
  "operation_id": "<uuid>",
  "distro": "Ubuntu-26.04",
  "backend": "WireGuard",
  "profile_path": "<private path>",
  "caller_sid": "S-1-5-...",
  "endpoint_ipv4": "<from protected profile>",
  "endpoint_port": 51820
}
```

约束：

- 该 JSON 经本机命名管道或标准输入传递，不放在 UAC 命令行；命令行只允许固定脚本路径与最小参数。
- `execute=false` 只做预检，不改状态。
- 私密材料只经 stdin；argv 只放非敏感参数。
- 每个动作幂等；重复 `Start` 返回当前有效状态，不重复开端口。
- 超时/输出缺失视为“结果未知”，不自动重试、不自动回滚。
- 报告使用固定 JSON schema；UI 只消费 schema，不解析自由文本。
- 代次/操作 ID 防止旧结果覆盖新状态。

**状态机**：

```text
restored → preparing → prepared_for_reinstall → installed_closed
        → connected_unverified → verified
        ↘ blocked / closure_unverified / failed_closed_requested
```

`Guarded` 是 WSL 启动后的常态；`Running` 必须由 Windows `Start` 重新建立。任何失败都保持闭锁。

### 6.6 安装、配对与自检

1. **自检**：Windows 版本、WSL 版本、Hyper-V cmdlet、服务身份、资源哈希、端口、关键地址基线。
2. **配对**：profile 选择发行版与固定端点；私钥经 stdin 写入 root-only 文件；不把密钥写入 JSON/日志。
3. **安装**：Windows 持久边界 → Linux payload → nft guard → 配置审计；每步写 journal。
4. **发行版识别**：自动枚举已安装发行版；只对 profile 指定的发行版执行；未知或配置被改动的发行版 `BLOCKED`，不自动 adopt，也不删除。
5. **回滚**：Windows-only 与含 Linux 的恢复分开；含 Linux 时 Windows-only 恢复必须拒绝，保持闭锁。
6. **升级**：原子替换 payload；保留 generation 与 recovery；不在活动 guard 上卸载。

### 6.7 当前差距

| 差距 | 证据 | 影响 | 建议 |
| --- | --- | --- | --- |
| 迁移状态说法不一致 | 迁移文档 vs AGENTS vs `state.json` | 无法判断当前是否已接管 | 一次受控 `Start` + 证据后更新三处文档 |
| 端点当前关闭 | `phase=restored`、`endpoint_enabled=false` | WSL 当前无出口 | 先完成 P0 修复与基线，再启用 |
| 常驻提权 worker 风险（历史审查） | 10-22 PR 审查 P0 | 可能被利用执行任意脚本 | 复核当前实现；只保留固定动作、SID/操作 ID/代次绑定 |
| 脚本硬编码路径/IP | 历史审查与迁移记录（需复核当前实现） | 迁移后规则/任务可能失效 | 从配置派生；启动时漂移检测 |
| 单文件过大 | `WslSecureEgress.psm1` 约 2291 行、`manager.py` 约 2289 行 | 审查困难、回归风险高 | 按职责拆分：策略/事务/审计/报告 |
| Docker 边界 | 只做 containment | 不能声称 Docker 出口安全 | 保持 `unsupported`，单独设计 adapter |
| UI 缺少应用入口 | 文档记录 | 用户无法从页面启动隔离应用 | 增加“启动安全终端/查看隔离会话” |
| DoH/DoT 边界 | 只固定 53 端口 resolver | 应用自带 DoH 可能绕过 resolver | 在文档与测试中明确；必要时阻断 853/DoH |
| 自动恢复只部分完成 | 登录任务可用；纯 `wsl --shutdown` 需手动 | 重启后可能无网 | 明确产品语义：Guard 自动、Start 手动；或实现受控自动 Start |

### 6.8 路线图

**P0（先恢复可用与可信）**

1. TUN 回环修复（CR-01/02），否则 Chrome/Claude 都没有稳定基础。
2. 核心防火墙规则修正（CR-05）。
3. Clash of WSL 状态收敛：一次受控 `Start`，确认 `verified` 或明确 `BLOCKED`，更新迁移文档/AGENTS/`state.json` 三处。
4. 控制面复核：确认没有任意脚本 worker；固定动作、SID、操作 ID、代次。
5. 关键地址基线 + 定向回退演练。

**P1（可用性与可观测性）**

6. ChromeGuard 产品化：规则身份、漂移检测、固定回环端口、自动化语义测试。
7. Claude 出口预检包装器 + 三档遥测策略。
8. 日志持久化、状态四层模型、UI 显示最后验证时间。
9. 脚本拆分与单元测试补齐；Docker 边界文档化。

**P2（体验与长期维护）**

10. WSL 页面“应用”分区。
11. 签名 fork 更新通道/版本漂移提示。
12. Ubuntu 26 完整验收：冷启动、重启、网络切换、sleep/resume、真实 VPS 地区。
13. 上游 issue/内核 A/B（如 TUN 仍无法修复）。

### 6.9 验收矩阵（WSL）

| 测试 | 方法 | 通过标准 |
| --- | --- | --- |
| 出口 | 受管 launcher 内中立探针 | VPS IPv4、DE |
| 无直连 | 隔离环境中停隧道/停服务/清 nft | 无公网连通；不在生产网络做破坏性测试 |
| DNS | 解析测试 | 只经隧道 resolver |
| IPv6 | 双栈目标 | 失败关闭 |
| 冷启动 | 重启 Windows/WSL | 先 Guarded，不自动开隧道 |
| 网络切换 | Wi-Fi/有线切换 | 保持闭锁或安全恢复 |
| 回滚 | 产品 Rollback | 恢复原网络并复验两关键地址 |
| 升级 | 原子替换 payload | 保护不断档，恢复材料保留 |
| UI | 状态/日志/测试 | 四态准确，无假绿灯 |

---

## 7. 统一实施顺序与回退

建议顺序（每一步都先取基线、备份、准备定向回退）：

1. **只读基线**：两个关键地址、TUN 状态、Chrome 策略、WSL `state.json`、服务/进程。
2. **修 TUN**：先最小对照，再排除路由；每次只改一个变量；失败回系统代理。
3. **修核心规则**：按文件身份匹配；验证两个内核；保留旧规则备份。
4. **Chrome**：固定回环端口 → 策略 → WFP 语义测试 → 出口/DNS/IPv6/WebRTC 矩阵。
5. **Claude Code**：预检包装器 → 三档遥测 → CLI/Desktop 分别验收。
6. **Clash of WSL**：状态收敛 → 受控 Start → 冷启动/切换/回滚矩阵。

回退原则：

- 只撤回本轮紧邻变更，不用早期全量备份覆盖后来修改。
- 含 Linux 的 WSL 变更不能只用 Windows 回退；保持闭锁，按产品 journal 恢复。
- 任一关键地址异常，停止后续网络改动，先复验两个关键地址。

---

## 8. 风险与未决问题

| 问题 | 状态 | 说明 |
| --- | --- | --- |
| TUN 回环是否仅由排除路由解决 | `LIKELY` | 需要最小对照与内核 A/B；`interface-name` 已证明更差 |
| USB 共享网卡是否主因 | `LIKELY` | 需拔除/禁用后做有效 A/B |
| Chrome WFP 规则文本与实际行为不一致 | `CONFIRMED`（存在冲突） | 需 WFP/抓包级验证 |
| Claude Desktop 是否遵守代理 | `NOT_RUN` | 可能需 TUN 或进程级规则 |
| 共享遥测所有权 | 未确认 | 不做整域强制；默认阻断/显式放行 |
| Clash of WSL 迁移是否真正完成 | 冲突 | 以一次受控 `Start` 为准 |
| Docker 出口 | `unsupported` | 保持 containment，不宣称可用 |
| Ubuntu 26 的 Claude Desktop/GLIBC | `BLOCKED` | 用兼容发行版/包，不改系统 glibc |
| 登录自动恢复的语义 | 部分完成 | 明确“Guard 自动、Start 手动”或实现受控自动 Start |

---

## 9. 参考

- [用户原始需求汇编](user-requirements-compilation-2026-10-24.md)
- [TUN 失败分析](clash-tun-failure-analysis-2026-10-24.md)
- [系统网络审计](system-network-audit-2026-10-24.md)
- [本机网络与软件清单](local-network-inventory-2026-10-24.md)
- [网络操作审计](network-operations-audit-2026-10-24.md)
- [WSL Secure Egress 安全模型](wsl-secure-egress/SECURITY_MODEL.md)
- [WSL 变更](wsl-secure-egress/WSL_CHANGES.md)
- [Windows 变更](wsl-secure-egress/WINDOWS_CHANGES.md)
- [Clash of Rust UI/控制器变更](wsl-secure-egress/CLASH_UI_CHANGES.md)
- [上游对比](wsl-secure-egress/UPSTREAM_COMPARISON.md)
- [兼容性](wsl-secure-egress/COMPATIBILITY.md)
- [AI 域名台账](ai-domain-inventory-2026-10-15.md)
- [Claude CLI/Desktop 离线网络分析](claude-app-static-network-audit-2026-10-15.md)
- [本机配置交接](local-network-handoff-2026-10-15.md)
- [项目完整过程](PROJECT_PROCESS_2026-10.md)
