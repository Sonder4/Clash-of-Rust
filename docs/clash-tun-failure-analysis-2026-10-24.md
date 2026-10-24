# Clash of Rust TUN 无法使用与 9090 端口错误分析

- 日期：2026-10-24
- 诊断时间：02:05–02:16（+08:00）；后续复现 02:24–02:29（§11）；根因分析定稿 02:40–02:55（§12，整合用户独立完成的五组对照实验）
- 状态：现行（只读诊断记录；诊断期间未修改任何系统设置、服务或网络；本文件为事后新增文档）
- 应用：Clash of Rust 0.6.1，`D:\Clash\Clash of Rust\clash-of-rust.exe`
- 内核：mihomo v1.19.33，`D:\Clash\Clash of Rust Network\mihomo.exe`
- Windows 网络助手：`ClashOfRust.Network` 服务，`D:\Clash\Clash of Rust Network\clash-tun-launcher.exe --windows-service`
- 结论强度标记：**CONFIRMED**（有直接证据）、**LIKELY**（证据一致但缺少最后一步）、**NOT_PROVEN**（未能验证）、**REJECTED**（证据排除）

## 1. 摘要

这次实际出现了两个层次不同、但互相放大问题：

1. **直接可见的错误是 9090 端口绑定失败（`os error 10048`）**。应用在 02:10:53 以新进程重启，新内核的端口预检无法绑定控制器端口 9090。02:16 检查时旧内核/旧服务已退出，9090 没有任何监听或 `TIME_WAIT`，也不在 Windows 排除端口段内；最一致的解释是旧内核尚未完全释放 9090 时新内核抢先绑定，而 Windows 启动路径只绑定一次、没有等待重试。该错误目前是**瞬时的重启时序问题**，不是 9090 被永久占用。
2. **更早的 TUN 失败不是“TUN 没开”**。在 02:05–02:10 的失败会话里，`Meta` 适配器为 `Up`，默认路由指向 `198.18.0.2`，控制器 live 配置为 `tun.enable=true`；但直连和 `17890` 代理两条路径都出现 TLS 握手失败，`Meta` 适配器持续收发包。也就是说，流量进入了 TUN，却没有正常从代理出口返回。
3. 最可能的机制是：**TUN 默认路由把内核自身的出站流量也抓回了 TUN，形成回环**。项目文档记录过 `strict-route: true` 会导致“内核自身出站被 WFP 拦截、全部流量超时”；00:44 的备份配置确实同时有 `tun.enable=true` 和 `strict-route=true`。但故障内核已经退出，无法再读取它当时的 live `strict-route`，因此这条只能标为 **LIKELY / NOT_PROVEN**，不能写成唯一已证实根因。
4. 应用的状态也出现了不同步：`settings.json` 写 `proxy_mode=system`，UI 在 02:07 显示“TUN 模式已连接”，运行时基础配置写 `tun.enable=false`，而 live 内核为 `tun.enable=true`。这说明 TUN 切换/回滚没有收敛到同一个状态，随后应用重启。**CONFIRMED**。
5. `mips` 协议栈不是原因：源码 [crates/client-core/src/config/mod.rs:428](../crates/client-core/src/config/mod.rs:428) 明确写入 `mips`，0.5.5 发布说明也写明使用 mips 协议栈。网络助手哈希与应用侧一致，UAC/助手缺失也不是原因。现有证据不支持 WSL 是这次 TUN 转发失败的直接原因。

## 2. 当前状态（02:16:40 快照）

| 项目 | 当前值 |
| --- | --- |
| Clash 应用 | 运行中，PID 43028，启动于 02:10:53 |
| 内核 | 未运行；无 `mihomo` 进程 |
| `ClashOfRust.Network` 服务 | `Stopped`（Manual） |
| 9090 控制器端口 | 无监听、无 `TIME_WAIT` |
| 17890 混合代理端口 | 无监听 |
| `Meta` 适配器 | 不存在 |
| 默认路由 | 仅 WLAN `0.0.0.0/0 via 172.22.255.254` |
| 设置文件 `proxy_mode` | `system` |
| UI | “内核尚未运行”，代理模式“关闭” |
| `https://ipgw.neu.edu.cn/` | 直连 302；17890 代理连接失败（内核未运行） |
| `https://api.okinto.com/` | 直连 200；17890 代理连接失败（内核未运行） |
| WSL 出口状态 | `phase=restored`，`endpoint_enabled=false` |

因此当前“TUN 无法使用”的直接状态是：**内核没有启动，TUN 没有开启**；而此前 TUN 开启时的问题是**转发失败/回环**，不是开关没有生效。

## 3. 时间线

| 时间（+08:00） | 事件 | 证据 |
| --- | --- | --- |
| 01:41:30 | `clash-tun-launcher.exe`、`clash-wsl-guardian.exe` 时间戳 | 文件属性 |
| 01:41:56 | `clash-of-rust.exe` 0.6.1 时间戳 | 文件属性 |
| 01:46:56 | `mihomo.exe` v1.19.33 时间戳 | 文件属性、`core.json` |
| 01:59:53 | `clash-wsl-guardian.exe` 启动 | `Win32_Process.CreationDate` |
| 02:00:34 | `clash-tun-launcher.exe`（服务侧）启动，PID 47452 | 进程创建时间 |
| 02:05:26 | 应用 `clash-of-rust.exe` 启动，PID 2348 | 进程创建时间 |
| 02:05:34 | `runtime/config.yaml` 与 `candidate.yaml` 写入；应用侧 bridge PID 53628 启动 | 文件时间、进程树 |
| 02:05:35 | `mihomo.exe` 启动，PID 50060，父进程为服务侧 launcher | 进程树 |
| 02:05:56 | `settings.json` 写入，`proxy_mode=system` | 文件时间、字段 |
| ~02:07 | UI 显示“TUN 模式已连接”；live `tun.enable=true`、`stack=Mips`；`Meta` Up；直连和 17890 均 TLS 失败 | UI 截图、控制器 GET、`curl` |
| 02:10:53 | 应用以新 PID 43028 启动；旧窗口消失；出现“无法绑定端口 9090 ... os error 10048” | 进程时间、用户截图 |
| 02:11:03 | 无 `mihomo`；9090 无监听；仅 17890 有 `TIME_WAIT`；直连恢复 302/200；17890 失败 | `Get-NetTCPConnection`、`netstat`、`curl` |
| 02:16:40 | 内核仍未运行；服务 `Stopped`；无 Meta；默认仅 WLAN；直连 302/200、代理失败 | 最终快照 |

说明：应用在 02:10:53 的新进程未检索到对应的 Application Error 事件；仅凭现有证据无法区分“用户手动重启”和“应用自身重启”。旧进程的内存日志已随进程退出丢失，也没有找到持久化日志文件。

## 4. 证据

### 4.1 9090 端口：错误是重启时序，不是永久占用

用户截图中的错误原文：

> 无法绑定端口 9090，请检查占用或系统端口限制: 通常每个套接字地址(协议/网络地址/端口)只允许使用一次。(os error 10048)

02:11 与 02:16 的只读检查：

- `Get-NetTCPConnection -LocalPort 9090`：没有任何条目。
- `netstat -ano | grep 9090`：没有 9090 监听或 `TIME_WAIT`。
- `netsh interface ipv4 show excludedportrange protocol=tcp`：排除段包括 `8032`、`9032`、`50000–50059` 等，**没有 9090**。
- `ClashOfRust.Network` 服务：02:16 为 `Stopped`；没有 `mihomo` 子进程。

应用启动内核前的端口检查位于 [apps/desktop/src/engine/mod.rs:400](../apps/desktop/src/engine/mod.rs:400)：

```rust
#[cfg(not(target_os = "macos"))]
let _listener = std::net::TcpListener::bind(("127.0.0.1", port))
    .with_context(|| format!("无法绑定端口 {port}，请检查占用或系统端口限制"))?;
```

Windows 路径只绑定一次；macOS 路径有 `wait_for_mac_port` 的 60 秒宽限（[engine/mod.rs:46](../apps/desktop/src/engine/mod.rs:46) 注释：“A prior TUN core can leave root-owned TIME_WAIT sockets after it exits”）。因此旧内核/旧桥接尚未完全释放 9090 时，新内核会立刻得到 `EADDRINUSE`，而不是等待后重试。

**判定：CONFIRMED（错误发生在重启时序；当前 9090 已空闲）**。无法在错误发生的那一秒保留监听快照，因此“当时占用者一定是旧 mihomo”属于 **LIKELY**，不是直接抓到的证据；但进程时序、旧核心在 02:07 仍监听 9090、02:11 已无监听，三者一致。

### 4.2 TUN 确实开启并接管了流量

失败会话（约 02:07）的 live 控制器配置：

| 字段 | 值 |
| --- | --- |
| `mode` | `rule` |
| `mixed-port` | `17890` |
| `tun.enable` | `true` |
| `tun.device` | `Meta` |
| `tun.stack` | `Mips` |
| `tun.auto-route` | `true` |
| `tun.auto-detect-interface` | `true` |
| `tun.dns-hijack` | `any:53`、`tcp://any:53` |
| `tun.inet4-address` | `198.18.0.1/30` |

系统侧同时满足：

- `Meta` 适配器 `Status=Up`，`InterfaceDescription=Meta Tunnel`，`ifIndex=64`。
- `Meta` 地址 `198.18.0.1/30`；默认路由 `0.0.0.0/0 via 198.18.0.2`，路由 metric 0。
- WLAN 默认路由同样 metric 0；接口 metric：`Meta=9000`，`WLAN=45`。
- `Find-NetRoute` 对 `1.1.1.1`、校园域名解析地址、`api.okinto.com` 的解析地址都选择了 `Meta`/`198.18.0.2`。

**判定：CONFIRMED**。这不是“TUN 开关没生效”，而是 TUN 已创建并成为系统默认路径。

### 4.3 TUN 数据面失败

失败会话中，直连和 17890 代理两条路径全部失败：

| 测试 | 结果 |
| --- | --- |
| `curl https://ipgw.neu.edu.cn/`（直连） | `000`，`schannel: failed to receive handshake, SSL/TLS connection failed` |
| `curl https://www.baidu.com/`（直连） | `000`，同样的 TLS 握手失败 |
| `curl https://api.okinto.com/`（直连） | `000`，同样的 TLS 握手失败 |
| `curl https://www.cloudflare.com/`（直连） | `000`，同样的 TLS 握手失败 |
| 上述地址经 `-x http://127.0.0.1:17890` | 同样 `000`，TLS 握手失败 |

`17890` 当时确实在监听，owner 为 `mihomo.exe` PID 50060；`9090` 也在同一进程。因此不是代理端口没有启动，而是**内核出站或 TUN 转发链路没有把响应带回来**。

`Meta` 适配器统计在一次请求前后增加：

- 请求前：`ReceivedBytes=1205685`、`SentBytes=1611658`
- 请求后：`ReceivedBytes=1265517`、`SentBytes=1673895`

计数增加说明数据进入了 TUN，但 TLS 没有完成，不能据此认定出口可用。

### 4.4 配置与应用状态不同步

失败会话同时存在四套状态：

| 状态载体 | TUN/代理状态 |
| --- | --- |
| `settings.json`（02:05:56） | `proxy_mode=system` |
| UI（~02:07 截图） | “TUN 模式已连接”，TUN 按钮高亮 |
| `runtime/config.yaml` / `candidate.yaml` | `tun.enable: false`，`stack: mips`，`strict-route: false` |
| live 控制器 `/configs` | `tun.enable: true`，`stack: Mips` |

这说明应用在切换 TUN 时的“设置持久化、UI 展示、基础配置、运行内核”不是同一个原子状态。应用在 02:10:53 重启后，UI 变为“内核尚未运行”、代理模式“关闭”，但 `settings.json` 仍保留 `proxy_mode=system`，进一步说明状态没有收敛。

可能的过程是：用户/应用尝试从系统代理切到 TUN，`prepare_windows_tun` 停止旧内核并通过服务重启；TUN 在 live 内核中已打开，但出站失败；回滚/事务没有把四套状态重新对齐，随后应用重启并撞上 9090 端口释放时序。

**判定：CONFIRMED（状态不一致）；具体写入顺序无法仅从文件时间还原，属于 LIKELY 的过程解释。**

### 4.5 配置、版本与助手

| 项目 | 值 | 结论 |
| --- | --- | --- |
| 应用版本 | 0.6.1 | 与安装文件一致 |
| 内核 | mihomo v1.19.33 | `core.json` 记录 |
| 应用侧助手 | `D:\Clash\Clash of Rust\clash-tun-launcher.exe`，915456 字节，SHA256 `BA1EB91665BBFDFE7359BDF27A0EB089B98070F1E8BD2F72FC7F8F2C81D63AC7` | 与网络助手侧完全一致 |
| 网络助手 | `D:\Clash\Clash of Rust Network\clash-tun-launcher.exe`，同尺寸、同哈希 | 不存在版本/哈希不匹配 |
| 服务 | `ClashOfRust.Network`，Demand Start，LocalSystem；当前 `Stopped` | 不是“服务不存在” |

配置文件对比：

| 文件 | `tun.enable` | `tun.stack` | `strict-route` |
| --- | --- | --- | --- |
| `runtime/config.yaml`（当前） | `false` | `mips` | `false` |
| `runtime/candidate.yaml` | `false` | `mips` | `false` |
| 当前活动 profile | `false` | `mixed` | `false` |
| `config.yaml.bak-sr-20261024-004412` | `true` | `mips` | `true` |
| `config.yaml.bak-20261024-002039` | `false` | `mips` | `true` |

`mips` 是应用生成器主动写入的值（[config/mod.rs:428](../crates/client-core/src/config/mod.rs:428)），不是非法值；profile 写 `mixed`、生成配置写 `mips` 是应用的映射行为。0.5.5 发布说明也写明“TUN 使用 mips 协议栈”。

### 4.6 WSL 与其他系统状态

- WSL 出口 `state.json`：`phase=restored`，`endpoint_enabled=false`。
- `ClashOfRust.WslEgress` 服务仍在运行；`WslService`、`vmcompute`、`HvHost` 也在运行。
- Windows TCP 排除端口段没有 9090；WSL/Hyper-V 没有占用该端口。
- 未观察到 WSL 功能在本轮写入主机路由、DNS、系统代理或 TUN 设置。

**判定：现有证据不支持“Clash of WSL 修改主机网络导致本次 TUN 失败”**。这不等同于证明 WSL 在所有情况下都不可能影响网络；只是本次失败的直接证据指向主机 TUN/内核出站状态，而不是 WSL 端点或 DNS 配置。WSL 出口当前本身是 `restored`，没有开启的端点。

## 5. 根因判断

### 5.1 已确认

1. **02:10:53 的 9090 错误是端口释放时序导致的启动失败**。旧内核/旧桥接在应用重启时尚未完全释放 9090；Windows 端口预检只绑定一次，没有等待/重试。现在端口已空闲、服务已停止。
2. **失败会话中 TUN 确实开启并接管了默认路由**。`Meta` Up、`tun.enable=true`、`Find-NetRoute` 选择 Meta，都是直接证据。
3. **TUN 数据面失败**。直连和 17890 代理都 TLS 握手失败；`Meta` 计数增加但无成功响应。
4. **应用状态不同步**。settings、UI、基础配置、live 内核四套状态不一致；应用重启后 UI 与 settings 仍不一致。
5. **`mips` 不是原因**。源码和发布说明均支持 `mips`；**助手/哈希/UAC 不是原因**；**9090 不在 WSL 排除端口段**。

### 5.2 最可能但未完全证实

1. **TUN 默认路由回环**：`Meta` 默认路由 metric 0，`Find-NetRoute` 对所有目标都选 Meta。内核自己连接代理节点的出站流量如果也走这条默认路由，就会重新进入 TUN，形成“应用 → TUN → 内核 → TUN”的循环。`auto-detect-interface=true` 本应让内核绑定物理网卡，但当前证据无法证明它实际排除了 Meta。
2. **旧配置中的 `strict-route: true`**：项目文档明确记录 `strict-route: true` 会让内核自身出站被 WFP 拦截、全部流量超时。`config.yaml.bak-sr-20261024-004412` 同时有 `tun.enable=true` 和 `strict-route=true`。如果 02:05:35 启动的内核读取到的是这份旧状态（而不是 02:05:34 写入的 `strict-route: false`），就能解释“TUN 计数器在动、所有 TLS 都失败”。但内核已退出，live `/configs` 不返回 `strict-route`，因此这条只能是 **LIKELY / NOT_PROVEN**。
3. **应用 TUN 切换事务不原子**：停止旧内核、写配置、启动新内核、打开 TUN、写 settings 之间没有形成一个可回滚的整体；任一阶段失败会留下“UI 已 TUN、settings 仍 system、live 内核 TUN 已开”的混合状态。这是从代码路径和时间线推断的 **LIKELY**，不是运行时逐帧证明。

### 5.3 已排除或证据不支持

| 假设 | 判定 | 依据 |
| --- | --- | --- |
| `mips` 是非法协议栈 | REJECTED | 源码主动写入；0.5.5 发布说明；内核对 live `stack=Mips` 已接受并创建适配器 |
| 助手缺失/版本不匹配/UAC 未授权 | REJECTED | 应用侧与 Network 侧助手 SHA256 完全一致；服务已安装 |
| 9090 被永久占用或 WSL 排除 | REJECTED | 当前无 9090 socket；排除段无 9090 |
| WSL 改动直接导致本次 TUN 失败 | 证据不支持 | WSL 出口 `restored`、endpoint 关闭；无主机路由/DNS 改动证据 |
| TUN 没开启 | REJECTED | live `tun.enable=true`、Meta Up、默认路由指向 Meta |
| 应用崩溃是唯一原因 | NOT_PROVEN | 未检索到 Application Error 事件；无法区分用户重启与应用自身重启 |

## 6. 影响

- 当前内核未运行：TUN、系统代理、规则分流都不可用；`17890` 没有监听。
- 直连网络仍正常：`ipgw.neu.edu.cn` 302、`api.okinto.com` 200。
- 任何仍把系统代理设为 `127.0.0.1:17890` 的浏览器或程序，在当前状态下会连接失败，直到内核重新启动。
- 之前的 TUN 失败会让所有被 TUN 接管的直连和代理流量同时超时，表现为“整机断网/HTTPS 全部失败”，容易被误判为 DNS 或 WSL 故障。
- WSL 出口当前已 `restored`，不是本次 TUN 失败的直接来源；但 `ClashOfRust.WslEgress` 服务仍在运行，后续若要彻底停用 WSL 功能，需要单独处理该服务/自启项。

## 7. 未执行与限制

- 未点击“重启内核”、未点击“日志”、未启动/停止内核、未修改 settings、未改端口、未改 DNS/防火墙/系统代理/TUN/路由。
- 未对 9090 做端口占用实验；因此没有“当前占用者”的精确时刻快照，只有错误前后进程时序。
- 故障内核已退出，无法读取它当时的完整 live 配置；`/configs` 不暴露 `strict-route`。
- 应用日志在内存中，进程重启后丢失；没有找到持久化日志文件。
- 没有运行会改变网络状态的 TUN 复现实验；TUN 数据面的“回环”判断基于路由、适配器计数和 TLS 失败，属于强证据但非抓包级证明。
- 本文不记录控制器 secret、订阅 URL、VPS 地址、节点名或任何私密配置；读取控制器时只在进程内使用 settings 中的 secret，未打印、未写入文档。

## 8. 建议的下一步（均需另行授权）

### 8.1 恢复当前可用性

1. 先确认旧服务和旧内核已完全停止：当前 `ClashOfRust.Network` 已是 `Stopped`，9090/17890 无监听。
2. 若允许操作，点击“重启内核”或在系统代理模式下启动内核；先验证：
   - `17890` 监听；
   - `https://ipgw.neu.edu.cn/` 与 `https://api.okinto.com/` 直连/代理均正常；
   - 没有再出现 9090 `10048`。
3. 确认系统代理路径正常后，再单独测试 TUN；不要在一次操作里同时切换运行模式和代理模式。

### 8.2 TUN 复现时的最小证据集

在开启 TUN 后 5 秒内、30 秒、90 秒分别记录：

- 控制器 `GET /configs`：`mode`、`tun.enable`、`tun.stack`、`tun.auto-route`、`tun.auto-detect-interface`；
- `Get-NetIPInterface`：Meta/WLAN 的接口 metric；
- `Get-NetRoute`：Meta/WLAN 默认路由；
- `Find-NetRoute` 对 `1.1.1.1`、校园域名、`api.okinto.com` 的选择；
- `Get-NetAdapterStatistics Meta` 前后计数；
- 应用日志页的内核 stderr；
- `curl` 直连与 `-x 127.0.0.1:17890` 两条路径。

验收标准：TUN 开启后，直连与代理两条路径都能完成 TLS 并返回 302/200；`Meta` 计数有来有回；90 秒后仍稳定；没有 9090 `10048`。

### 8.3 产品侧修复建议

1. **Windows 端口预检增加等待/重试**：对齐 macOS 的 `wait_for_mac_port`，在旧内核/旧桥接释放 9090/17890 前做有界等待；或在启动前明确停止旧服务实例，避免把正常的重启时序暴露成 `10048`。
2. **TUN 切换事务原子化**：停止旧内核 → 等端口释放 → 写配置 → 启动新内核 → 打开 TUN → 写 settings/UI，任一步失败都要把四套状态恢复一致；不要在回滚后留下 live TUN 已开、settings 仍 system 的混合状态。
3. **明确内核出站绕开 TUN**：为内核到代理节点的出站使用接口绑定/fwmark/路由排除，或在启用 TUN 时校验 `Find-NetRoute` 不会把内核自身出站选到 Meta；至少在日志中记录 auto-detect-interface 的选择结果。
4. **把 `strict-route` 纳入 live 可见状态**：当前 `/configs` 不返回 `strict-route`，故障后无法判断运行内核是否仍是 `true`；建议在 UI/日志/控制器状态中显式展示，并在 TUN 开启前强制校验为 `false`（除非用户明确选择严格路由）。
5. **持久化应用日志**：当前内核 stderr 只进入内存日志，应用重启即丢失；建议写入有界滚动日志，便于定位 TUN 回环和 9090 冲突。

## 9. 只读核查命令

以下命令均不修改状态；控制器 secret 不打印。

```powershell
# 端口与占用
Get-NetTCPConnection -LocalPort 9090 -ErrorAction SilentlyContinue |
  Select-Object LocalAddress,LocalPort,State,OwningProcess
netstat -ano | Select-String ':9090|:17890'
netsh interface ipv4 show excludedportrange protocol=tcp

# 进程与服务
Get-CimInstance Win32_Process |
  Where-Object { $_.Name -match 'clash|mihomo' } |
  Select-Object ProcessId,ParentProcessId,Name,CreationDate,ExecutablePath
Get-Service ClashOfRust.Network,ClashOfRust.WslEgress |
  Select-Object Name,Status,StartType

# TUN 适配器、接口 metric、路由选择
Get-NetAdapter -Name Meta -ErrorAction SilentlyContinue
Get-NetIPInterface -AddressFamily IPv4 |
  Where-Object { $_.InterfaceAlias -in @('Meta','WLAN') } |
  Select-Object InterfaceAlias,InterfaceMetric,NlMtu,ConnectionState
Get-NetRoute -DestinationPrefix '0.0.0.0/0'
Find-NetRoute -RemoteIPAddress 1.1.1.1

# 配置字段（不打印 secret）
$s = Get-Content "$env:LOCALAPPDATA\clash-of-rust\ClashOfRust\data\settings.json" -Raw | ConvertFrom-Json
$s | Select-Object proxy_mode,run_mode,dns_override,ipv6,udp
Select-String -Path "$env:LOCALAPPDATA\clash-of-rust\ClashOfRust\data\runtime\config.yaml" `
  -Pattern '^tun:|^  (enable|stack|auto-route|strict-route|auto-detect-interface|dns-hijack):'
```

控制器查询（如控制器需要认证，从 settings 读取认证信息到变量后仅在进程内使用；不要输出 secret）：

```powershell
$s = Get-Content "$env:LOCALAPPDATA\clash-of-rust\ClashOfRust\data\settings.json" -Raw | ConvertFrom-Json
# 按当前控制器认证方式构造 $h；不要把 secret 打印或写入文档
Invoke-RestMethod -Uri 'http://127.0.0.1:9090/configs' -Headers $h |
  Select-Object mode,@{n='tun';e={$_.tun.enable}},@{n='stack';e={$_.tun.stack}}
```

## 10. 相关文件与参考

- [本机网络与软件清单（2026-10-24）](local-network-inventory-2026-10-24.md)
- [网络操作审计（2026-10-24）](network-operations-audit-2026-10-24.md)
- [本机配置交接（2026-10-15）](local-network-handoff-2026-10-15.md)
- [应用端口预检与启动路径](../apps/desktop/src/engine/mod.rs:400)
- [macOS 端口等待逻辑](../apps/desktop/src/engine/mod.rs:46)
- [TUN `mips` 生成逻辑](../crates/client-core/src/config/mod.rs:428)
- [0.5.5 发布说明（mips 协议栈）](releases/0.5.5.md)
- [TUN 行为与 strict-route 记录](local-network-inventory-2026-10-24.md)
- [WSL 出口当前状态](wsl-secure-egress/UBUNTU26-MIGRATION-2026-10-23.md)

## 11. 后续复现（2026-10-24 02:24–02:27）

- 02:24:20 TUN 再次开启，`ClashOfRust.Network` 服务成功启动；live `tun.enable=true`、`ProxyEnable=0`，`Meta` Up，IPv4/IPv6 默认路由均指向 Meta。
- 02:26 关键地址直连与 17890 代理再次全部 TLS 失败；`Find-NetRoute` 对 API 的 IPv4/IPv6 均选择 Meta。
- 02:27 连接采样显示内核有 8 条 IPv6 `SynSent`，其中 7 条远端端口为 **10443**（VLESS Reality），另有 2 条 IPv4 `SynSent`；连接在快速重试，IPv6 10443 的 SYN 没有得到响应。
- 9090 `10048` 没有再次出现，说明它是上一次重启的独立端口释放竞态；当前 TUN 失败是运行期的 IPv6 出站路由/回环问题。
- 详细的主机网络、防火墙、Tailscale、WSL 与依赖快照见 [系统网络配置审计](system-network-audit-2026-10-24.md) §6。
- 这次复现把“内核自身出站被 TUN 默认路由捕获”的证据从路由选择扩展到了“IPv6 10443 SYN 卡在 SynSent”，但仍未抓包，维持 **LIKELY / 强证据**，不写成抓包级已证实。
- 02:29 复核：应用已切回系统代理，TUN 关闭，Meta 适配器/路由消失；`ipgw` 与 `api` 直连/17890 代理均恢复 302/200。说明故障仅在 TUN 开启时出现，主机 DNS/WLAN 基础连通性正常。

---

## 12. 根因分析定稿：为什么 TUN 开启后”只有上行、没有下行”（02:40–02:55）

本节整合两部分证据：本文 §3–§5、§11 的现场观测，以及用户在 02:30–02:55 独立完成的五组对照实验。实验由用户全程自行操作；主代理本轮仅做只读复核与文档整理，未修改任何代码、未编写脚本、未改动系统配置。

### 12.1 五组对照实验结果（用户执行）

| 对照 | 操作 | 结果 | 排除/确认 |
| --- | --- | --- | --- |
| 现象 | TUN 开启后 135 秒采样 | 全程 `000`；`Meta` 在 t+60s 前后消失；内核日志出现 51 条 loopback 拒绝 | 现象稳定复现 |
| 节点 | 依次切换 VLESS-IPv6 / VLESS-IPv4 / HY2-IPv4 | 三个节点全部 `000` | 不是单个节点故障 |
| 网卡 | 禁用”以太网 2”（手机 USB 网卡，跃点 35） | 仍然全部 `000` | 不是多网卡路由干扰 |
| 运行方式 | 停掉应用与提权服务，裸跑 `mihomo.exe` 加载同一份配置 | 仍然全部 `000` | 不是应用、提权服务或启动器的锅 |
| 系统侧 | WFP 全量导出仅 `Chrome to Clash of Rust proxy guard` 与 `Clash of Rust WSL Docker guard` 两个无害 provider；NRPT 为空；TUN 关闭时默认路由仅 WLAN | 无第三方拦截 | 不是 Windows/旧脚本残留 |
| 规则 | 控制器 `delay` 探测（不经过任何规则与分组） | DIRECT 与 VLESS 都 FAIL | 不是订阅规则/分组问题 |

### 12.2 直接证据：内核日志承认回环

用户提供的内核日志（已按本仓库约定遮蔽 VPS 地址与本机内网地址）：

> `[UDP] dial DIRECT (match IPCIDR/62.84.x.x/32) 172.22.x.x:xxxxx --> 62.84.x.x:444 error: reject loopback`

- 目的地 `62.84.x.x:444` 是 VPS 的 Hysteria2 UDP 端口，规则将其判为 DIRECT。
- 但这条 **DIRECT 出站同样被 TUN 默认路由抓回**：内核发包 → `0.0.0.0/0` 与 `::/0` 均指向 `Meta` → 包重新进入自己的 TUN 栈 → 内核识别出回环并拒绝（`reject loopback connection`）。
- 与 TUN 下路由表实测（两条默认路由全指 Meta、**没有任何为代理服务器地址建立的排除路由**）以及 02:26 的 SynSent 分布（IPv6 10443 ×7 卡死）相互印证。
- **判定：根因从 §5.2/§11 的 LIKELY 升级为 CONFIRMED——TUN 开启后，内核自身到代理节点（含 DIRECT 判定目标）的出站被 TUN 默认路由捕获，形成回环/自拒，代理上游全部不可达。**

### 12.3 为什么表现为”只有上行、没有下行”

1. **上行有**：客户端 → TUN/17890 → 内核。TUN 栈（mips）在本地完成与客户端的握手并 ACK，客户端认为连接正常、持续发送（TLS ClientHello、HTTP 请求、QUIC Initial、重试），这些字节全部计入 upload。
2. **下行无**：内核 → 节点的真实出站全部死在回环/自拒上，没有任何真实响应可返回，download ≈ 0。
3. `Meta` 适配器 Sent/Received 同时增长（§4.3：1205685→1265517 等）是环内自发自收与重试的痕迹，不是出口流量。
4. 即 UI 曲线”上行持续、下行归零”的本质是：**入口活着，出口死了**。

### 12.4 为什么 auto-detect-interface 与 strict-route 都没有救回来

- **无排除路由**：TUN 下路由表没有为节点地址建立 /32、/128 排除路由（用户实测）；runtime 与全部 profile/备份的 tun 块也没有 `interface-name`、`route-exclude-address` 字段（02:39 rg 全目录无匹配）。内核出站隔离完全依赖 `auto-detect-interface` 的运行时绑定。
- **绑定不稳定**：`auto-detect-interface: true` 依赖默认接口检测；TUN 建立后 Meta 拥有 metric 0 的 IPv4/IPv6 默认路由（IPv6 `::/0` metric 0 完胜 WLAN 256），检测存在时序竞争。实测部分 TCP 偶尔绑定 WLAN 成功（02:26 有 11 条 IPv4 Established；02:39 关 TUN 后同一节点 14 条 Established:10443），多数到节点的连接卡在 SynSent——这就是”时好时坏”的来源。
- **strict-route 反而更糟**：订阅原始 profile（d9230dba）与 00:44 备份带 `strict-route: true`，本应通过 WFP 为内核进程豁免回环，但本机实测它会把包括内核在内的所有流量一起拦死（用户实验），等效豁免失败。当前生成配置 `strict-route: false`，因此本轮故障不是 strict-route 拦截，而是”无排除 + 绑定不稳定”。
- 两道防线在本机均不可用 → 回环必然发生，与节点、订阅规则、应用/服务层均无关（与 12.1 五组对照一致）。

### 12.5 02:39–02:47 只读复核（关 TUN 后的对照面）

| 项目 | 值 |
| --- | --- |
| 内核 | 应用直接子进程（非服务 launcher），监听 9090/17890；核心 TCP：Established 10443 ×14、Established 443 ×12、无 SynSent——同一节点通路健康 |
| 基线 | `ipgw` 直连/17890 均 302；`okinto` 直连/17890 均 200 |
| 路由 | Meta 适配器/路由不存在；默认路由仅 WLAN（IPv4 metric 0/45、IPv6 `::/0` metric 256/45）；02:23 的 IPv6 残留已清理 |
| 版本实测 | 两个真实内核路径 `mihomo.exe -v` 均为 **v1.19.33**（用户实验记录为 v1.19.32，以实测为准；差异原因未查） |
| 最终状态 | 用户恢复系统代理模式：`ProxyEnable=1`、`127.0.0.1:17890`，settings `proxy_mode=system`、`run_mode=rule`；TUN 关闭 |

疑点（记录，不下结论）：

- 02:39 控制器 live `/configs` 仍返回 `tun.enable=true`（含 inet4/inet6-address、auto-route），但系统层无 Meta、无路由——内核配置内存态与实际 TUN 设备脱节，与用户观测”Meta 在 t+60s 消失”吻合：**TUN 设备建立后被移除，而内核配置态未回写**。与 §4.4 的”四套状态不同步”同型。移除 Meta 的触发者（内核接口监控、应用 watchdog、驱动错误）未定位。

### 12.6 后续方向（均需另行授权；本轮未修改代码、未编写脚本）

1. **最小 TUN 配置对照**（用户建议，认可）：`MATCH,DIRECT` + 单条直连规则 + 无 DNS 劫持 + 无 fake-ip，验证回环是否仍复现；若复现，则是内核 v1.19.33 在本机的 TUN 行为问题，适合给上游提 issue（附 `reject loopback` 日志与路由表，遮蔽私密地址）。
2. **核心版本 A/B**：仅替换内核二进制对比行为，确认是否版本相关。
3. **本机可用 TUN 的前提**：内核出站与 TUN 强制隔离——显式 `interface-name` 或为节点地址建立排除路由；涉及修改配置或应用生成器行为，需单独授权、先备份、可回退。
4. **现阶段**：维持系统代理模式（功能完整、稳定，两关键地址 302/200）；该问题解决前不启用 TUN。

### 12.7 修复方案（2026-10-24 02:55 定稿；均需另行授权，本轮未执行）

根因是"内核自身出站被 TUN 默认路由捕获"，因此修复目标只有一个：**让内核到节点的出站绕开 TUN**。基于对生成器源码的只读核查（不改代码的前提下），落点与约束如下。

**为什么只能改 profile**：

- `runtime/config.yaml` 每次启动由生成器重建，直接编辑无效。
- `Settings` 结构（[config/mod.rs:65](../crates/client-core/src/config/mod.rs:65)）没有任何接口绑定/路由排除字段，UI 无开关。
- 生成器只覆写 tun 块的 `enable/stack/auto-route/auto-detect-interface/dns-hijack`（[config/mod.rs:427-432](../crates/client-core/src/config/mod.rs:427)），**根级 `interface-name` 与 tun 块其他键（含 `route-exclude-address`）原样透传**。
- 活动 profile `28b1ea79`（"XUAN VPS 2026-10-21"）来自本地文件导入，不会被远程订阅刷新覆盖；但重新导入源 YAML 会覆盖手工修改。

**方案 A（首选）：profile 根级 `interface-name: WLAN`**

- 机制：内核所有出站拨号绑定物理网卡，不查路由表，从源头避免回环；对域名节点、节点换 IP 均有效。
- 代价：网卡别名变化（如改用有线）时内核出站会断，表现为 fail-closed；别名必须与实际接口名 `WLAN` 一致。
- 注意：profiles 目录存在 `bak-iface-20261024-011739`、`bak-iface-20261024-020516` 两份备份，说明当天已有人尝试过 interface-name 方案并回退，当前文件无该键；**当时试的具体写法与结果未知**，执行前应先向用户确认，若根级写法已试过仍失败则直接进入方案 C。

**方案 B（兜底，可与 A 叠加）：tun 块 `route-exclude-address`**

- 机制：auto-route 为节点地址建立 /32、/128 排除路由，OS 路由层绕开 Meta。
- 代价：只覆盖枚举到的 IP，节点换地址即失效；需要列出全部节点 IP（VLESS-IPv6、VLESS-IPv4、HY2-IPv4）。真实地址只写入本地私有配置文件，不入库、不入文档。
- **硬约束**：`claude_protection` 开启时生成器会强制 `strict-route: true` 并删除全部 `route-exclude-*`/`include-interface`/`exclude-interface` 键（[protection/mod.rs:586-608](../crates/client-core/src/protection/mod.rs:586)）；本机 `strict-route: true` 又会拦死所有流量。因此**本机上 TUN 与 claude_protection 不得同时开启**，直到回环问题解决。

**验证序列（每个改变网络状态的步骤后复验两个关键地址）**：

1. 基线：系统代理模式下 `ipgw`/`okinto` 直连+17890 均 302/200；备份 profile。
2. 写入 A（必要时叠加 B）→ 应用内切 TUN → 按 §8.2 采集证据集。
3. 通过判据：`Find-NetRoute` 对节点地址选择 WLAN 而非 Meta；delay 探测 DIRECT/VLESS 均通；curl 两条路径 302/200；90 秒稳定；内核连接不再出现 IPv6-10443 SynSent 重试。
4. 回退：恢复 profile 备份，切回系统代理，复验 302/200。

**方案 C（A/B 均无效时）**：确认为 mihomo v1.19.33 在本机的 TUN 行为问题。用官方 release 做核心版本 A/B（仓库约定不得替换核心，除非用户明确授权），并用遮蔽后的 `reject loopback` 日志、路由表、SynSent 分布向上游提 issue。可并入用户提出的最小 TUN 配置对照（`MATCH,DIRECT`、无 DNS 劫持）。

**对用户两项既有需求的影响（2026-10-24 03:10 补充）**：

- 需求 1（Chrome 全走 VPS、Edge 正常）：A/B 只改变 mihomo 自身连 VPS 的出口网卡，不改变 Chrome 的路径（系统代理 17890 + 4 条防火墙禁直连规则均不受影响），fail-closed 属性保留；Edge 行为不变。系统代理模式下 Chrome 的"全走 VPS"今天已满足，TUN 只是额外加固。
- 需求 2（WSL 与 VPS 的 WireGuard 局域网、不暴露本机真实 IP）：WSL 出口当前 `restored`、发行版停止，暂无交互。将来重新启用后：仅方案 A 时 WSL 经 NAT 出去的 WireGuard 握手会被 TUN 抓进 mihomo（VPS IP 命中 DIRECT 规则），WG 被塞进 mihomo 的 UDP 转发，脆弱；叠加方案 B 后 WSL→VPS 的 WireGuard 在 OS 层直走 WLAN，与现状一致。暴露面：mihomo 今天本来就从 WLAN 直连 VPS，VPS 看到校园网出口 IP 是连接的对端事实，A/B 均不改变；第三方服务看到的仍是 VPS 出口，无新增暴露。若在未修复的 TUN 下启用 WSL 出口，WSL→VPS 的 WG 会落入同一回环黑洞。


**配置层无法修复的部分**（需产品代码/上游解决，预期保留）：live `tun.enable=true` 与实际设备脱节、Meta 适配器 t+60s 被移除的触发者、9090 重启端口竞态、四套状态不同步。

### 12.8 修复执行结果与最终结论（2026-10-24 03:00–03:40，经用户授权执行）

本节记录 §12.7 修复方案的实际执行、两次真实 TUN 验证、新证据与回退。**结论：配置层无法修复，根因升级——mihomo v1.19.33 在本机不生效"内核自身出站绑定物理网卡"机制，TUN 在更换核心版本前不可用。当前已稳定回退到系统代理模式并通过两轮重启验证。**

**执行内容**（备份 `bak-fix-20261024-030336`，含 profile 与 settings.json）：

1. profile 写入方案 A（根级 `interface-name: WLAN`）+ 方案 B（`tun.route-exclude-address` 覆盖 2 个唯一节点地址：1×IPv4/32、1×IPv6/128；4 个节点共用，无域名服务器）。生成器透传验证：runtime `config.yaml` 第 30 行 `interface-name: WLAN`、第 141 行 `route-exclude-address` 均存在。claude_protection 全程为 null。
2. 第一次 TUN 启用（03:06）：应用正常走 `prepare_windows_tun` 全流程；核心到节点连接健康（31 Established、0 SynSent——原回环问题对节点已消除）；但 Meta 默认路由在 t+20s 内消失、系统代理已被关闭，Chrome 被禁直连规则阻断，用户侧断网。人工回滚系统代理。
3. 第二次 TUN 启用（03:13，经 UI 之外的 restore 路径触发）：失败后应用**自动回滚**系统代理（03:15 settings 写回 `system`），Meta 消失。通过应用日志页"导出"获得 `data/logs-export.txt`（499 条，覆盖故障窗口），**关键新证据（03:14:49–52，TUN 捕获期）**：
   - 内核自身 DoH 拨号全部超时：`dial DIRECT mihomo --> 223.5.5.5:443 / 223.6.6.6:443 / 1.12.12.12:443 / 120.53.53.53:443 error: i/o timeout`（阿里/腾讯公共 DoH，runtime 配置中 `interface-name: WLAN` 生效中的同一时刻）；
   - 所有域名解析失败：`dns resolve failed: couldn't find ip`。
4. **判定（由 §5.2/§12.4 的 LIKELY 升级为 CONFIRMED）**：`interface-name` 显式绑定在本机对该内核的自身拨号路径不生效——被 TUN 捕获后，除 `route-exclude-address` 枚举的节点地址外，内核其余出站（DoH、以及为被捕获流量做的 DIRECT 直连）仍然回环超时。逐项追加排除地址（DoH 四个 IP 等）无法收敛：任何走 DIRECT 规则的国内目的地都会重新回环。**这是核心在本机的行为缺陷，与用户此前裸跑 mihomo 复现的结论一致。**
5. 回退与稳定性：settings 回 `system`；**两轮完整重启验证（03:26、03:38）均自动恢复**——app/mihomo 正常、`ProxyEnable=1`、`proxy_mode=system`、无 Meta、`ipgw` 302/302、`okinto` 200/200、cloudflare 经 17890 200。profile 中的 A+B 字段在每次重新生成后持续存在（保留：系统代理模式下无害；未来核心修复后 TUN 可直接受益）。重启电脑机制：应用无自启项，开机后手动打开即按 settings 恢复系统代理；本轮未实际重启电脑（会中断会话），机制验证以两轮进程重启代替。
6. 限制：两次尝试中"路由/适配器为何被移除"的精确触发者仍未定位（第二次为应用回滚所致，第一次疑似 sing-tun 内部 teardown，无日志）；应用导出的日志无 `[客户端]` 行，自动回滚的具体错误消息未能捕获。临时采集脚本（因 ExecutionPolicy 未能启动）与截图已清理。

**下一步（均需用户另行明确授权）**：

- 用官方 release 的其他 mihomo 版本做核心 A/B（仓库约定默认不得替换核心，须逐字确认授权与回退方案）。
- 以遮蔽后的证据包（DoH i/o timeout + interface-name 生效中、`reject loopback`、SynSent 分布、路由消失时序）向 mihomo 上游提 issue。
- 在核心问题解决前，**继续使用系统代理模式，勿开启 TUN**；Chrome 全走 VPS 的需求在系统代理模式下已满足并验证。

### 12.10 上游核对与内核 A/B（2026-10-24 03:42–03:55，经用户授权执行）

用户提出"上游项目应该没问题，问题出现在修改过程之后"，本节为核对结果。

**核对结论（CONFIRMED 部分）**：

1. **已安装的 0.6.1 是本地构建，不是官方安装包**：克隆工作树 `target/release/clash-of-rust.exe`（48,798,208 字节，2026-10-24 01:41 构建）与 `D:\Clash\Clash of Rust\clash-of-rust.exe`（同大小、01:41:56）完全对应；launcher（915,456 字节）同样吻合。克隆基线为 `v0.6.0-122-gf7edf3c` + 工作区未提交改动，Cargo.toml 版本号 0.6.1。
2. **部署过程静默把内核从 v1.19.32 升到了 v1.19.33**：交接文档记录 10-15 官方 0.5.9 时代内核为 v1.19.32（TUN 开启且两关键地址 HTTP 200）；`core.json` 记录 01:41 部署时从 GitHub 拉取了 v1.19.33（2026-10-21 发布）。用户实验笔记中的"当前 v1.19.32"沿用了旧文档记录，实际已是 .33。
3. **工作区本地源码改动对 TUN 无害**：`security.rs` 仅新增安装目录重定位解析（`D:\Clash` 布局），`runner.rs`/脚本为 WSL 与构建代理支持；v0.6.0→HEAD 的引擎/配置改动均为 Claude 保护与 WSL 功能，不触及 TUN 主流程。`platform/windows/service/*` 自 v0.6.0 起未变。

**内核 A/B 实验（经用户授权，含一次 UAC 提权）**：备份两处 `mihomo.exe`/`core.json`（`.v1.19.33.bak`，共 4 文件）后，将两处内核替换为官方 v1.19.32（compatible 变体，含 zip/exe SHA256 并同步更新 core.json，通过服务端 `verify_core` 校验）。TUN 启用实测（03:49:37）：**仍然失败，现象与 v1.19.33 完全一致**——Meta 适配器创建但无 IP/无路由，DNS 解析失败（导出日志 03:50–03:51：`[UDP] dial XUAN-VPS … www.google.com:443 error: can't resolve ip`）。用户随后手动切回系统代理。

**A/B 推论**：

- **内核版本（.32 vs .33）不是根本原因**，"换回旧内核"不解决 TUN。
- 但 TUN 故障的时间线被前移澄清：00:44 的备份已带 `strict-route: true`、01:17 已有 `bak-iface` 备份，说明 **TUN 故障在 01:41 本地重建之前就已存在**（0.5.9 + v1.19.32 时代已坏）。01:41 的本地构建与内核升级更可能是**为修 TUN 而做的尝试**，而非起因。10-15 正常 → 10-24 00:44 之间生效的某个变化才是真正的诱因，现有证据仍指向"内核自身出站在 TUN 下无法绕开"这一机器级/环境级问题（与 §12.8 的 CONFIRMED 判断一致）。
- 上游应用源码经核对未见导致 TUN 失败的改动；用户的本地改动亦为良性。**"上游没问题"与"修改过程引入问题"均不完全成立：故障跨越了 0.5.9 与本地 0.6.1、跨越了 .32 与 .33 两个内核版本。**

**当前状态（03:55）**：系统代理模式（用户手动恢复），`ipgw` 302/302、`okinto` 200/200；内核现为 v1.19.32（行为与 .33 无差异），`.v1.19.33.bak` 备份完整保留，可一次 UAC 提权恢复。

**遗留可选实验（需用户明确授权，未执行）**：应用生成器强制 `tun.stack: mips`（[config/mod.rs:428](../crates/client-core/src/config/mod.rs:428)）。可通过控制器热切换测试 `stack: mixed`/`system`（`PATCH /configs`，无需改代码、可即时回退）——若 mips 栈是本机问题的一环，这将直接显形；若仍失败，则可确认问题在更底层的 wintun/绑定环境，届时建议以完整证据包向 mihomo 上游提 issue。



### 12.12 30 秒自动回滚测试管线与机制定案（2026-10-24 04:00–04:30，经用户授权）

应用户要求建立"TUN 开启 30s 后自动返回系统代理"的测试管线（`scripts/tun-test/orchestrator.ps1`，含路由采样、控制器状态采样、URL 验收、curl 重连式内核 debug 日志捕获、finally 强制回滚），并完成以下对照实验（每轮窗口约 50s，回滚全部成功，Chrome 断网窗口受限）：

| 实验 | 结果 |
| --- | --- |
| 基线（mips，.32，排除=节点+DoH 前后对照） | 适配器 Up、IP 已配、TUN 自认 `auto route: true`，但 DNS 全灭、URL ERR |
| 排除路由加入 DoH 4 IP（223.5.5.5/223.6.6.6/1.12.12.12/120.53.53.53） | **内核 DoH 拨号恢复可达**（`mihomo --> 223.6.6.6:443 DIRECT`），证明按 IP 排除是唯一生效的豁免机制 |
| `stack: mixed`（控制器热切换，日志确认生效） | 失败依旧 |
| `strict-route: true` + mixed | 失败依旧 |
| `route-exclude-address-set: [geoip-cn]` | 被静默忽略，无效 |
| 校园 DNS 排除（202.118.1.29/53） | 消除对应自劫持（日志原证：`[DNS] hijack udp:202.118.1.29:53 from 172.22.94.221`） |

**机制定案（CONFIRMED，内核 debug 日志直接证据）**：

1. TUN 设备、适配器、IP 配置、流量捕获全部正常工作（`[TUN] Tun adapter listening at: Meta(...), auto route: true`；大量客户端流量被捕获进入内核）。采样中"默认路由表无 Meta 条目"属新版 sing-tun Windows 捕获方式的正常表现（分裂路由/WFP 重定向），不是故障。
2. **唯一故障：内核自身出站没有任何进程级豁免**——除 `route-exclude-address` 枚举的 IP 外，内核自己的所有拨号（DNS 引导 `udp://223.5.5.5:53`、校园 DNS、以及为被捕获流量执行 DIRECT 规则的全部直连）都被自己的 TUN 捕回。最直接的证据是内核日志自述：`[DNS] resolve doh.pub A from udp://223.5.5.5:53` 紧接 `[DNS] hijack udp:223.5.5.5:53 from 172.22.94.221`——内核吃掉了自己的 DNS 引导查询，形成无限循环。
3. 该豁免缺失与内核版本（.32/.33）、栈（mips/mixed）、strict-route（开/关）无关，均实测排除；上游 0.6.3 的 DNS 模块重写（`config/dns.rs`）不触及引导自劫持，重建上游最新版也无法修复。
4. 由于 DIRECT 拨号目的地集合（GeoSite/CN、GeoIP/cn、校园、okinto 等）无界，按 IP 枚举排除不可行。**结论：在本机环境 + 当前 mihomo Windows 实现下，TUN 无法通过任何配置组合修复；这属于内核级缺陷，应向上游（Fu021/Clash-of-Rust 的 Windows TUN 配方或 mihomo）反馈。**

**当前最终状态（04:30）**：系统代理模式（`proxy_mode=system`、`ProxyEnable=1`），`ipgw` 302/302、`okinto` 200/200；内核 v1.19.32（core.json 哈希一致，`.v1.19.33.bak` 备份保留可回退）；profile 保留 `interface-name: WLAN` 与 8 条排除路由（节点 ×2、公共 DoH ×4、校园 DNS ×2）——系统代理模式下全部无害，内核修复后即为现成的 TUN 前置条件。测试管线存于 `scripts/tun-test/orchestrator.ps1`；含节点名/secret 的临时日志与 curl 配置已删除。



### 12.13 重装官方 0.6.2 与最终定论（2026-10-24 04:35–05:15，经用户授权）

**执行**：卸载本地构建 0.6.1（删除 `ClashOfRust.Network`/`ClashOfRust.WslEgress` 服务、禁用 3 个计划任务、旧目录移入 `D:\Clash\_old-20261024-0435\`、清除 0.6.1 注册表卸载项）→ 下载官方 **v0.6.2** x64 安装包（SHA256 校验通过）→ 安装回 `D:\Clash\Clash of Rust`（安装器沿用原位置并重建 Network 服务）→ 数据目录（settings/profiles）自动继承。

**官方 0.6.2 + 原始订阅 profile + TUN 实测（30/75 秒自动回滚管线）**：默认路由首次真正装上（v4/v6 全程在表），内核逐目的地 `Auto detect interface --> WLAN` 自绑定可见，但结果仍失败——故障收敛为两条结构性缺陷：

1. **DNS 引导死锁**：`dns_override=true` 时 DNS 服务器为 doh.pub/dns.alidns.com（域名），需先经 `udp://1.0.0.1:53`/`223.5.5.5:53` 引导解析；TUN 下引导查询被自身 `dns-hijack: any:53` 劫持回环，全部域名 `couldn't find ip`。`dns_override=false` 时订阅 DNS 含 `dns.google`（校园网解析被污染），其解析死锁会把内核 DNS 模块整体拖死——**TUN 与系统代理模式一起失效**（05:03–05:07 两轮实测复现，恢复 dns_override=true 后系统模式立即恢复）。
2. **DNS 模块拨号器不走自绑定**：`dial DIRECT mihomo --> VPS-DoH:443 i/o timeout`——内核为代理节点拨号时会按 auto-detect 绑定物理网卡（节点连接正常），但 DNS 模块的出站拨号不经过该绑定，被 TUN 默认路由捕获回环。

**chnroute 全表方案评估**（10,861 条排除路由，含 APNIC CN v4 8,797 + v6 2,046 + RFC1918）：单条排除机制有效（此前已证明），但全表会使内核启动/拨号器失效（04:49–04:52 实测：核心监听端口但 68 条 SynSent、DNS 500、代理握手全挂，恢复原始 profile 后立即恢复），且维护成本不可接受（用户已否决）。**放弃。**

**最终状态（05:15）**：官方 0.6.2、原始订阅 profile、`dns_override=true`、系统代理模式，`ipgw` 302/302、`okinto` 200/200、百度 200，全部低延迟。比当晚任何中间状态都干净（无本地构建、无手工内核、无 profile 附加字段；应用内自带的 mihomo v1.19.33 与 core.json 哈希一致）。残留：一个 04:42 由安装器提权启动的无响应应用实例（不占端口，重启电脑后消失）；`data.bak-reinstall-20261024-043529` 数据备份；6 个 profile 备份含 `.bak-chnroute-20261024`。

**结论**：TUN 在本机 + 本应用上的失败是**结构性**的（应用的域名式 DoH + `dns-hijack any:53` 设计，与内核 DNS 模块拨号器/自身豁免行为在本机的组合），12+ 轮受控实验穷尽了配置空间（内核 .32/.33、栈 mips/mixed、strict 开/关、interface-name、按 IP 排除、排除全表、DNS 覆盖开/关、原始/官方配置）均无法达到"国外+国内同时可用"。修复需上游变更（建议方向：DNS 服务器支持 IP 字面量优先/引导豁免自身劫持；或 DNS 模块拨号器沿用出站绑定）。日常使用继续系统代理模式，两个关键地址与 Chrome 防泄漏需求已满足并验证。



### 12.15 追加终验：VPS-DoH-only 与用户实验日志互证（2026-10-24 11:20–11:30）

用户上午在规则+TUN 下再次断网后复测。新证据与终验：

1. **`D:\Clash\logs\` 保存了用户本人 01:52–02:39 的实验日志**（`core-isolation.log`、`loop-sample.log`、`ipv4-vs-ipv6.log`、`tun-ab-eth2.log` 等）。`core-isolation.log` 证明**隔离裸跑内核**（独立端口 17891/9191、无应用、无服务、无脚本）TUN 依然全部失败——排除"先前脚本/指令残留导致"；`loop-sample.log` 显示当时连节点拨号（`[VPS-v6]:10443 i/o timeout`）也在超时。
2. **终验组合**：profile DNS 仅保留 VPS DoH（IP 字面量，移除 dns.google）+ `dns_override=false`。TUN 窗口内默认路由稳定、适配器正常，但内核日志反复出现 `re-creating the http client due to requesting https://VPS:443/dns-query: context deadline exceeded`——**DNS 模块的 HTTP 客户端拨纯 IP DoH 也超时**，DIRECT 拨号继续回环。
3. **最终定论（配置空间已穷尽）**：本机 TUN 下仅代理节点拨号经 auto-detect 绑定豁免；**DNS 模块全部出站与所有 DIRECT 拨号均被内核自身 TUN 捕获回环**。三种 DNS 配置（域名 DoH、混合、纯 IP DoH）全部失败。修复只能来自上游代码变更。已恢复原状（profile 原始、`dns_override=true`），系统代理模式复验 302/200/200。
4. **用户历史记录互证（[需求汇编](user-requirements-compilation-2026-10-24.md)）**：PC 端 TUN 故障最早记录于 2026-10-24 00:06（"之前可以正常使用"）与 00:29（"只能上传"），**早于当晚全部修复操作**（D:\Clash 迁移与本地重编译是 01:25 用户指示下的修复尝试）；10-21/10-23 存在手机端 TUN 同类故障记录；10-14 至 10-23 期间没有任何"PC 端 TUN 验证可用"的记录（10-15 交接明确"TUN 开启但未通过实际流量验证"，日常验证通过的一直是系统代理模式）。"先前脚本搞坏网络"的假设由此被当事人时间线、隔离裸跑复现（`core-isolation.log`）与配置穷举三方共同排除。


### 12.17 0.6.3 部署后的 TUN 实测与事故记录（2026-10-24 11:56–12:20）

部署合并构建（含 §12.16 两项修复）到 `D:\Clash\Clash of Rust`（旧件 `.bak-062-*`）。过程与结论：

1. **GUI 空白窗口**：0.6.3 宿主+渲染进程架构启动后内核未拉起、窗口空白。根因之一已定位：数据目录残留旧协议 `control.json`（protocol=1）导致新版握手失败；清除后 `cor start` 正常拉起内核。GUI 完整修复待后续专项（日常入口用 `cor` CLI：`cor start/stop/restart/status/proxy`）。
2. **TUN 实测（`cor proxy tun`，含两项修复的生成配置）**：窗口内 `open.bigmodel.cn` 200、`platform.deepseek.com` 429、`ipgw` 302（校园排除生效）、`cloudflare` 200（经节点，代理路径正常）——**IP 式 DoH 与自动排除两项修复在 TUN 下确实生效**；但 `api.deepseek.com` 000（部分 IP 未覆盖/DIRECT 回环）且 `zcode.z.ai` 等 GeoSite/CN 域名在 TUN 下全部回环（GLM 5.3 API 因此不可达）。
3. **事故（本代理失误）**：TUN 验收命令结束后未执行回滚，TUN 留在开启状态，导致用户整机断网（含 zcode/GLM），用户手动结束 Clash 进程恢复直连。处置：settings 强制 `proxy_mode=system`、清除陈旧 `control.json`、`cor start` 恢复，复验 `ipgw` 302 / `okinto` 200 / `bigmodel` 200 / `api.deepseek` 401 / `zcode.z.ai` 307 全绿；补充 `DOMAIN-SUFFIX,z.ai,DIRECT` 规则。
4. **当前决定**：TUN 保持关闭。新构建下 TUN 为"部分可用"（国外经节点 ✓、排除清单内直连 ✓、未排除国内 ✗——内核缺陷边界未变），且故障成本过高；日常使用系统代理模式（CLI/托盘入口）。



### 12.18 TUN 下 AI 端点全通：nameserver-policy 方案定稿（2026-10-24 12:35–12:50）

用户指示继续 TUN 测试（30 秒回滚纪律，`cor proxy tun` + try/finally 单命令窗口）。三轮迭代后全部通过：

| 轮次 | 变化 | 结果 |
| --- | --- | --- |
| 1 | zcode IP 排除补齐 | bigmodel/platform/ipgw/cloudflare 200；api.deepseek、zcode 仍 ERR（两轮一致，排除瞬时故障） |
| 2 | 规则改 XUAN-VPS 经节点 | 同样失败——发现应用将 `GEOSITE,CN,DIRECT` 内置规则**前置**，profile 后缀规则永在其后不生效 |
| 3 | **`dns.nameserver-policy`**：`+.deepseek.com`、`+.z.ai` → 校园 DNS 202.118.1.29 | **六端点两轮全绿**：bigmodel 200 / platform 200 / api.deepseek 401 / zcode.z.ai 200 / ipgw 200 / cloudflare 200 |

**机制**：api.deepseek/zcode 失败的根因是 CDN 解析漂移——内核 DoH（doh.pub）把 api.deepseek 解析到腾讯 EdgeOne IP（14.116.x），与校园解析的移动 IP（36.131.x/221.180.x）完全不同，按 IP 枚举排除永远追不上。`nameserver-policy` 让这两个域用校园 DNS 解析：返回的移动 IP 已在排除表、校园 DNS 服务器本身也在排除表（TUN 下内核的该查询经物理网卡直达），不依赖规则顺序，零 IP 追逐维护。回滚后系统模式复验 302/200/200/401/307 全绿。

**TUN 最终能力矩阵（0.6.3 合并构建 + 本配置）**：国外（经节点）✅；排除清单/策略内国内目标（校园、bigmodel、deepseek、z.ai）✅；未列入排除的普通国内站点 ❌（内核 DIRECT 拨号自捕获缺陷，待上游，见 §12.15）。启用 `cor proxy tun`，回滚 `cor proxy system`；日常建议系统代理模式。

### 12.19 终局：根因是本机网络环境（用户假设证实），上游 DNS 无罪（2026-10-24 13:10–13:40）

用户坚持两点：上游域名式 DoH 设计有其原因（非 bug）、本机其他网络环境有问题。实验完全证实：

1. **按用户要求恢复上游原版 DNS**（doh.pub/dns.alidns.com，代码已回退并重建部署；注意 cor.exe 内嵌同一生成器，部署时必须同步替换，否则出现新旧混跑）。
2. **环境隔离实验**：提权禁用 VirtNet（呈现名"以太网 2"，Up 且 metric 35 优于 WLAN 45，仅链路本地地址）与 TAP-Windows 两个历史遗留适配器（本地的 Wi-Fi Direct/ICS 192.168.137.1 适配器同期亦消失）。环境仅剩 WLAN + WSL + 系统 WAN Miniport。
3. **决定性结果**：纯净环境 + 上游原版 DNS + TUN：**全部目标两轮全绿，包括未做任何排除的 baidu/qq（国内直连金丝雀）**——内核自豁免完全恢复。此前的"内核 DIRECT 拨号自捕获缺陷"结论（§12.15）**被推翻并修正**：真正机制是 VirtNet/TAP 一类多余虚拟适配器干扰 mihomo 的接口检测/自身出站豁免；在受干扰环境下仅"到节点的拨号"仍走绑定豁免，DNS 引导与 DIRECT 拨号全部回环。
4. 元凶精确归属：VirtNet 与 TAP 启用后均无法经 Enable-NetAdapter/netsh 恢复（设备级禁用），无法单项 A/B；但两者皆为无使用者、无路由的历史遗留（审计确认），**保持禁用即最终修复**（需要时可在设备管理器手动重新启用——届时 TUN 会再次失效，可作反向验证）。
5. **最终验证（上游 DNS + 禁用两适配器）**：TUN 下 baidu/qq/cloudflare/ipgw/bigmodel/platform.deepseek/api.deepseek(401)/zcode.z.ai 全通；回滚后系统代理 302/200/307；重启稳定。此前我方加入的 IP 式 DoH（已按用户要求回退）、nameserver-policy 与 AI IP 排除在自豁免恢复后不再是必要条件（保留无害，可按需清理）。
6. 手机端数据点按用户说明作废（当时为订阅配置错误所致）。

**最终结论**：TUN 问题的完整根因链 = 多余虚拟适配器（VirtNet metric 35 / TAP）→ mihomo 自身出站豁免失效 → DNS 引导自劫持 + DIRECT 拨号回环。上游 DNS 设计、订阅规则、应用代码均无过错。修复 = 禁用两个遗留适配器。感谢用户的方向坚持。

### 12.20 结论修正：真凶是 Windows 移动热点/ICS，VirtNet 与 TAP 无罪（2026-10-24 14:10–14:40，A/B/C 三面实证）

按用户规程（备份→关闭程序→A/B 确认→确认后才卸载）执行，结果推翻 §12.19 的适配器归因：

1. **备份**：还原点已建；驱动文件备份于 `D:\Clashackups\driver-orphan-20261024`（9 文件）。
2. **A 面（适配器启用）**：PnP 层重新启用 VirtNet（Up）与 TAP（Disconnected）后，TUN 金丝雀 **baidu/cloudflare 双双 200**——适配器在场不破坏 TUN，**VirtNet/TAP 无罪，不予卸载**。
3. **真凶锁定**：回溯全部记录，`本地连接* 3`（Microsoft Wi-Fi Direct Virtual Adapter，**192.168.137.1 = Windows 移动热点/ICS 会话**）在**所有失败测试中 Up**、在**所有成功测试中缺席**。程序化开启热点复现故障条件后：
   - **B 面（热点 ON）**：baidu **ERR**、cloudflare 200——与原始"国外通、国内死"症状完全一致；
   - **C 面（热点 OFF）**：baidu/cloudflare/api.deepseek/zcode 全通。
4. **机制**：ICS（SharedAccess）启用的 Windows NAT/转发层吞掉内核**未绑定的 DIRECT 出站**（节点拨号走 auto-detect 绑定不受影响）——完整解释了全程所有症状，包括最早的"只有上行没有下行"。
5. **最终修复指引**：**使用 TUN 时不要开移动热点/网络共享**；如需两者同时使用，属 Windows ICS 与 mihomo TUN 的真实冲突，值得连同本轮 A/B/C 证据提给 mihomo 上游。VirtNet/TAP/驱动均未卸载（还原点与备份保留作保险）。


**补记（2026-10-24 14:50–15:10）**：联网查证两驱动均为第三方非 Windows 自带（VirtNet=ntkernel.com 虚拟网卡工具；TAP=OpenVPN 系客户端组件），经用户授权已用 `pnputil /delete-driver oem23.inf` 与 `oem0.inf` 彻底卸载并验证 CLEAN（"以太网 2"随之消失；备份与还原点保留）。**热点×TUN 共存实验**：先开 TUN 后开热点——热点激活瞬间 DIRECT 拨卡即死（baidu ERR、经节点仍 200），顺序无关，属 Windows ICS NAT 与内核未绑定 DIRECT 出站的硬冲突，配置层无解。替代方案：需要共享网络时用手机自身热点（不经电脑 ICS）或手机 USB 共享给电脑（RNDIS，不涉及 SharedAccess NAT）；二者与 TUN 无冲突。彻底共存需 mihomo 上游处理 ICS 兼容。

### 12.21 规则+TUN+热点三开深度体检（2026-10-24 15:20–16:10，两窗口对照实测）

用户要求对"规则+TUN+移动热点"三开状态做 DNS/流量/国内外站点/VPS 上下行的广泛详细记录。以"热点关+TUN"为基线窗口做同套对照。均为 finally 强制恢复窗口，恢复后全部复验 302/200。

**A. DNS 分层（热点 ON）**：系统侧（经 TUN 劫持的解析）正常应答——baidu 490ms（真实 IP）、google/deepseek/zcode 1ms（缓存/fake-ip）；内核 `/dns/query` REST API 在两种状态下均 ~2s 报错（与热点无关，API 层问题，NOT_RUN 深查）。

**B. 20 站矩阵（状态码@耗时，ERR=5s 超时除非注明）**：

| 站点 | 热点 ON | 热点 OFF（基线） |
| --- | --- | --- |
| baidu/qq/taobao/bilibili/zhihu/weibo/jd/163（8 个国内站） | **全部 ERR** | **全部 200**（173–538ms） |
| ipgw.neu.edu.cn（校园，已排除） | 200 @52ms | 200 @53ms |
| open.bigmodel.cn（已排除 IP） | **ERR**（CDN 解析漂移） | 200 @113ms |
| platform.deepseek.com | 200 @216ms | 200 @223ms |
| api.deepseek.com | ERR @104ms（快速重置） | **ERR @92ms（与热点无关的独立问题：移动 CDN 对 TUN 路径快速重置，系统代理模式稳定 401）** |
| zcode.z.ai | 200 @793ms | 200 @974ms |
| google/youtube/cloudflare/wikipedia | **ERR** | 200（471–4714ms） |
| openai.com | ERR | **ERR @598ms（独立问题：openai 对 VPS 出口拒绝，与热点无关）** |
| github.com / x.com | 200（953–1885ms） | 200 |

**C. VPS 上下行吞吐（speed.cloudflare.com 经 XUAN-VPS 节点）**：

| 项目 | 热点 ON | 基线 | 退化 |
| --- | --- | --- | --- |
| 下载 25MB（经 17890） | 3.15 MB/s | 7.50 MB/s | **-58%** |
| 下载 25MB（经 TUN 路径） | 3.09 MB/s | — | 与显式代理一致 |
| 上传 5MB（经 17890） | 0.76 MB/s | 2.90 MB/s | **-74%** |

**D. 连接与流量追踪**：热点 ON 时内核进程 58 条 `SynSent`（443×58/80×4，DIRECT 拨号坟场）+ Bound 77/Established 24；基线 **SynSent=0**、Established 64。Meta 适配器计数窗口内收 26.7MB（25MB 测试下载经 TUN 转发确认）。路由表：热点 ON 时 `本地连接* 3` 出现 ICS 三条路由（/24+/32×2），TUN 侧无路由表变化（sing-tun Windows 模式）。

**E. 结论**：① 热点 ON 的破坏面比"国内直连"更广——国外站也大面积 ERR（仅 github/x.com 存活，节点连接池被 58 条死拨号拖累后新流不稳），且 **VPS 吞吐下降 58%–74%**；② bigmodel 在热点 ON 下因 CDN 解析漂移再次失败（复现 §12.18 机制）；③ api.deepseek 的 TUN 快速重置与 openai 的出口拒绝是两个与热点无关的独立小问题；④ debug 日志流（/logs）在 CLI 后台所有者的内核上不可用（两种窗口均 0 行），日志级取证 NOT_RUN，不影响上述行为层结论。

**实用指引**：需要热点时用手机热点或 USB 共享（§12.20）；若必须电脑热点+TUN 同时，预期国内全断、国外不稳、VPS 吞吐减半。

### 12.22 限制

- `Meta` 在 t+60s 消失的触发者未定位（内核 stderr 无持久化日志）。
- 未抓包；回环结论由内核 `reject loopback` 日志（内核自身承认）、路由表实测、SynSent/Established 分布三方支撑，为当前可达的最强证据等级。
- 10-15（正常）与 10-24 00:44（故障）之间的具体环境变化未能从现有备份还原；v1.19.32 A/B 仅覆盖内核版本这一个变量。
- §12.8/§12.10 的执行轮经用户授权修改了本机 Clash 配置、更换过官方内核二进制并启停应用；未修改任何代码、未编写持久脚本（临时采集命令文件已删除）；未提交 Git。

---

**文档状态**（更新）：本文件记录 2026-10-24 02:05–03:40 的现场、对照实验、修复执行与回退；根因与"配置层不可修复"均已升级为 CONFIRMED。后续如果更换核心版本或恢复 TUN，应在本文末尾追加"后续验证"节，并把新的结果标记为 PASS / FAIL / NOT_RUN。
