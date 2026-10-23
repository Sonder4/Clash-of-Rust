# WSL Secure Egress 代码审查（2026-10-22）

## 结论

当前实现已经形成一条较完整的保护链：Windows Hyper-V WSL 防火墙边界、WSL 共享根网络命名空间的 nftables 默认拒绝、独立 WireGuard transport/gateway 命名空间、固定 IPv4 DNS、IPv6 拒绝和严格 launcher。代码也明确把 `PASS`、`NOT_RUN`、`BLOCKED` 和生产验收分开。

本轮不能确认 Ubuntu 26 的真实通信已经完成。仓库现有现场记录覆盖 Ubuntu-22.04，且当前只读调用 `wsl.exe --status` / `wsl.exe --list --verbose` 返回了 WSL 服务 `E_ACCESSDENIED`，没有取得当前发行版、内核、接口、路由或 DNS 的有效回读。因此当前状态应继续视为“静态代码审查完成，Ubuntu 26 运行验收未完成”。

本轮只读检查未启动 WSL、未修改 `.wslconfig`、防火墙、路由、DNS、WireGuard 或服务器；工作区原有以下未提交修改保留不动：

- `scripts/wsl-secure-egress/linux/manager.py`
- `scripts/wsl-secure-egress/tests/linux_static_test.py`
- `scripts/wsl-secure-egress/tests/windows-workflow.ps1`

## 审查范围

- Windows 编排和 WSL 生命周期：`scripts/wsl-secure-egress/WslSecureEgress.psm1`
- Linux manager、共享根 guard、WireGuard namespace、DNS 和 sandbox：`scripts/wsl-secure-egress/linux/manager.py`
- VPS WireGuard/DNS/nftables 服务：`scripts/wsl-secure-egress/server/manage.py`
- Rust 请求、状态和报告契约：`crates/client-core/src/wsl/request.rs`、`state.rs`、`report.rs`
- 现有测试和限制：`scripts/wsl-secure-egress/tests/`、`docs/wsl-secure-egress/TEST_STATUS.md`

## 网络通信链路判断

设计路径为：

```text
WSL 应用/容器
  -> WSL 共享根命名空间的 default-deny nftables guard
  -> cor-eb0 / cor-bg0
  -> cor-egress-gw 的 wg0
  -> cor-egress-transport
  -> WSL eth0/NAT
  -> 固定 IPv4 WireGuard VPS endpoint
  -> VPS 专用 resolver 和 IPv4 Internet egress
```

普通 WSL 和隔离 launcher 的路径不同：普通 WSL 依赖共享根 guard 和策略路由；隔离 launcher 还要求进入 gateway namespace，并通过 bubblewrap、UID/GID 降权、清空环境、隐藏 Windows 挂载和 seccomp 限制应用边界。Windows 侧的 Hyper-V 默认拒绝是外层保护，不能由 Linux manager 单独替代。

## 发现与修改意见

### P0：Ubuntu 26 的真实通信仍没有验收证据

**证据**

- [COMPATIBILITY.md](COMPATIBILITY.md) 的支持基线只描述 WSL 2.x/3.x 和“现有普通发行版”，现场记录实际执行的是 Ubuntu-22.04。
- [TEST_STATUS.md](TEST_STATUS.md) 的历史 PASS 明确来自 Ubuntu-22.04；真实 Windows/WSL 冷启动、网络切换和当前生产状态仍有 `NOT_RUN` 或历史状态限制。
- 本轮 `wsl.exe --status` / `--list --verbose` 只读调用返回 WSL 服务 `E_ACCESSDENIED`，未形成 Ubuntu 26 的有效运行快照。

**影响**

不能确认 Ubuntu 26 是否使用预期 NAT、是否真的关闭 DNS tunneling/autoProxy、`eth0` 是否是允许的物理上联、内核是否支持 WireGuard/namespace，以及 `/etc/resolv.conf`、IPv6 默认路由和 WSLInterop 是否符合代码假设。静态测试通过也不能替代这些证据。

**建议**

1. 在不改网络的前提下先修复 WSL 服务只读访问问题，取得 `wsl --list --verbose`、`wsl --status` 和 Ubuntu 26 内部快照。
2. 将 Ubuntu 26 加入兼容性矩阵，记录发行版版本、WSL 内核、`iproute2`、`nftables`、`wireguard-tools`、`bubblewrap`、`util-linux` 和 `setpriv` 版本。
3. 只有完成“关闭状态、启动后隧道、DNS、IPv6 拒绝、断开后默认拒绝、恢复后 Windows 必保通路”六组证据，才能把状态从 `NOT_RUN` 提升为 PASS。

### P1：Linux 依赖检查不足以证明 Ubuntu 26 能运行隔离链路

**证据**：`scripts/wsl-secure-egress/linux/manager.py:285-292` 只检查命令是否存在，以及 bubblewrap 是否包含少数帮助选项；没有检查实际 WSL 内核的 WireGuard、user/PID/net/mount namespace、nftables hook/conntrack 能力，也没有检查命令版本和关键行为。

**影响**：Ubuntu 26 可能通过 Doctor，但在 `wg setconf`、`ip netns`、nftables 规则加载或 launcher 阶段才失败。失败通常会保持关闭，这是安全的，但用户会得到“依赖满足、启动失败”的迟发错误，难以判断是发行版、内核还是 WSL 配置问题。

**建议**：增加只读 capability probe，并把结果纳入结构化报告：

- `wg help`/`wg show` 的实际可用性；
- `ip netns`, `ip -4/-6 rule`, `ip -4/-6 route`, nftables JSON 查询；
- 临时 disposable namespace 中的 `unshare`/`setns`/`mount`/`bwrap --seccomp` 行为；
- WSL 内核版本和 `uname -r` 的受支持范围。

探针必须只读或只在显式隔离测试命名空间执行，不能为了探针修改生产路由或防火墙。

### P1：共享根 guard 的兄弟发行版验证仍是“根路径证明”，不是完整 transport 健康证明

**证据**：`manager.py:771-810` 的 `shared_root_runtime_matches` 只核对上联接口、根命名空间 veth、策略表中的业务默认路由、unreachable 默认路由和一条 policy rule。它不读取兄弟发行版私有 `/run/netns` 中的 transport/gateway namespace；代码注释说明这是 WSL 各发行版私有挂载造成的限制。`shared_manager_table_matches` 在 `manager.py:814-885` 依赖这些根路径结果。

**影响**：某些 transport/gateway 内部状态损坏时，兄弟发行版 boot guard 仍可能认为共享 guard 足够健康；随后实际业务流量才暴露 WireGuard handshake、DNS 或 MTU 问题。该设计适合“启动时保持关闭”，不足以单独作为“通信已恢复”的证据。

**建议**：

- 将 `shared_root_runtime_matches` 的结果命名为 `shared_guard_present`，不要在报告层映射成 tunnel healthy；
- 由 manager distro 在 Windows scope audit 后返回私有 namespace 的完整健康证明，包含 `wg show`, endpoint route, gateway default route, IPv6 unreachable 和 resolver listener；
- 兄弟 distro 只接受“根 guard 存在且 endpoint 仍关闭/或已有 manager 证明”的状态，避免把共享根检查误当成全链路健康。

### P1：VPS 侧专用 nft 表不是全局默认拒绝，安全性依赖外层主机防火墙

**证据**：`scripts/wsl-secure-egress/server/manage.py:241-261` 为专用 WireGuard 接口创建 `input`/`forward`/`nat_out` 表，但 `input` 和 `forward` 的 chain policy 是 `accept`。代码注释也承认“pre-existing host firewall may still reject the flow”。

**影响**：这段代码只约束从专用接口进入的特定流量，不能单独证明 VPS 主机的其它转发、现有接口或管理面被隔离。若部署环境的既有防火墙发生漂移，WSL 端的“固定 VPS path”不等于 VPS 端的最小暴露面。

**建议**：保留“只管理专用接口”的非破坏边界，但在部署前增加只读主机策略审计：检查既有 nftables/UFW 的有效 policy、专用 endpoint、DNS listener、转发 sysctl 和监听地址。报告中把“专用表健康”和“主机全局策略已审计”拆成两个检查，后者未通过不得报告 Verified。

### P1：DNS 通过固定 resolver 的代码路径清晰，但当前测试不能证明 Ubuntu 26 全部应用都遵循它

**证据**

- `manager.py:1342-1349` 写入固定 resolver、关闭 generated resolver/hosts，并记录 `/etc/hosts` 快照。
- `manager.py:2013-2018` 为隔离 launcher 创建最小 resolver/hosts。
- `WslSecureEgress.psm1:478-523` 的 mandatory baseline 检查的是 Windows 默认代理通路，不是 Ubuntu 26 内部的 DNS 数据包路径。
- `TEST_STATUS.md` 的 DNS nonce 证据属于 Ubuntu-22.04 历史现场，不能自动迁移给 Ubuntu 26。

**影响**：普通应用可能使用 DoH/DoT、自己绑定 resolver、缓存旧 `/etc/resolv.conf`，或者通过宿主 API 绕开传统 DNS。固定 `/etc/resolv.conf` 只证明默认 libc DNS 配置，不证明所有应用的 DNS 选择。

**建议**：Ubuntu 26 现场验收至少加入：固定 resolver 的 UDP/TCP 53 nonce、错误 resolver 被拒绝、DoH/DoT 明文/目标路径分类、普通 WSL 和 isolated launcher 分别采样；结果写入报告而不是只写“DNS PASS”。

### P2：WSLInterop 防护边界实现谨慎，但文档和报告需要明确它不是 Windows 信息隔离

**证据**：`manager.py:1351-1388` 只识别并禁用精确的 `/init` PE binfmt handler；`SECURITY_MODEL.md` 同时承认 Windows 挂载、WSLg、机器标识等仍可能存在于普通 WSL，隔离 launcher 才额外隐藏这些资源。

**影响**：用户可能把 `interop.enabled=false` 理解成“应用无法获取 Windows 信息”。它只限制一条 Windows EXE 执行路径，不能替代挂载、环境、socket、metadata 和文件权限隔离。

**建议**：UI 和审查文档继续拆分 `interop_guarded`、`host_mount_hidden`、`proxy_environment_clear`，禁止用单一 interop PASS 代表完整主机隔离。

## Ubuntu 26 必须完成的最小验收矩阵

以下是建议的只读/受控验证顺序。不要在当前用户正在使用的共享网络上直接做断网、停核心或切换网卡实验。

1. **环境快照**：发行版名称/状态、`uname -a`、WSL 内核、`.wslconfig` 有效值、`ip -br link`、`ip -4/-6 route`、`/etc/resolv.conf`、`/etc/wsl.conf`、WSLInterop 状态。
2. **关闭态**：确认没有 `cor-eb0`、`cor-bg0`、`wg0`、named namespace 和 endpoint permit；普通 WSL 访问外部地址应保持关闭或按产品定义明确失败。
3. **启动态**：通过产品 broker 取得新 scope attestation；确认 transport/gateway namespace、WireGuard handshake、策略路由、IPv6 unreachable 和 resolver listener。
4. **普通 WSL 通信**：DNS nonce 经 tunnel resolver，HTTPS 通过固定 IPv4 出口，目的地源地址与受控 VPS receiver 一致。
5. **隔离 launcher**：确认接口只有预期集合、UID/GID 降权、能力为空、`NoNewPrivs=1`、Windows 挂载和 EXE interop 不可用、无代理环境变量。
6. **故障关闭**：只在隔离/可恢复环境撤回 endpoint 或模拟 transport loss；确认 Windows endpoint permit、Linux route/namespace 和 DNS 访问都关闭，并保留恢复证据。
7. **恢复与回归**：恢复后再次核对 `ipgw.neu.edu.cn` 与 `api.okinto.com` 的 DNS、TLS 证书和 HTTP 语义；这两个 Windows 必保通路不能只做端口探测。

## 建议的实施顺序

1. 先解决 WSL 服务 `E_ACCESSDENIED`，取得 Ubuntu 26 的只读快照。
2. 补 Ubuntu 26 兼容性/能力探针和结构化报告字段，先不改网络策略。
3. 补 shared-root guard 与 manager-private runtime 的分层状态语义。
4. 补 DNS/IPv6/endpoint closure 的真实 Ubuntu 26 验收和受控故障测试。
5. 最后再评估是否需要修改代码；在这些证据出现前，不建议放宽任何默认拒绝、DNS 或 IPv6 规则。

## 本轮验证限制

- 代码与文档为只读审查；没有执行网络变更。
- Windows 上的 Python launcher 不可用，因此本轮没有在当前主机运行 Python 测试套件。
- WSL 服务拒绝只读枚举，因此没有取得 Ubuntu 26 的真实接口、路由、DNS、WireGuard 或 nftables 状态。
- 未访问 Claude/Anthropic、未运行模型供应商全量检测、未 SSH 到 VPS。

## 追加分析：22:54 续期失败与 WireGuard 反复加载

### 诊断结论

这段日志链能证明“Start 失败后 endpoint 已经关闭”，不能证明“续期函数先关闭了 endpoint”。`Invoke-WslEgressScopeRenewal` 在 `WslSecureEgress.psm1:1351` 看到 `endpoint_enabled=false` 或 phase 不属于 `connected_unverified/verified` 时直接 `return`。`finally` 仍会把初始记录写入 `scope-renewal.json`，所以看到 `stage=state, outcome=not_run` 只能说明续期没有执行，原因很可能发生在更早的 Start 失败中。

真正的因果顺序更接近：

```text
Start
  -> Start-WslEgressLifetime
  -> Get-WslEgressScopeAttestation
  -> Invoke-WslEgressLinux start
  -> linux_start 失败
  -> 外层 catch 仅关闭 Windows endpoint
  -> 后续重试再次进入 Linux start，可能重复创建/加载 wg0
```

### P0：Start 失败没有回收 Linux lifetime 和部分 Linux runtime

**证据**

- `WslSecureEgress.psm1:1974-1977` 在 scope audit 前先启动长期 `wsl.exe ... sleep infinity` lifetime。
- `WslSecureEgress.psm1:1989-1991` 调用 Linux `start`。
- `WslSecureEgress.psm1:2156-2166` 的 Start 失败路径只调用 `Set-WslEgressEndpoint $state $false`，没有调用 Linux `stop`，也没有终止 `Start-WslEgressLifetime` 创建的进程。
- `manager.py:1733-1793` 的 Linux start 会逐步创建 transport/gateway namespace、veth、`wg0` 和策略规则；失败可能发生在这些资源已经部分创建之后。

**影响**

一次 `linux_start` 失败可能留下：

- Windows endpoint 已关闭；
- WSL lifetime 进程仍在；
- Linux journal 处于 `Starting` 或部分资源状态；
- transport/gateway namespace、WireGuard link 或策略路由未被 Stop 事务清理。

下一次 Start 可能再次触发 WireGuard link/module 初始化，日志中就会表现为每次唤醒重新加载 WireGuard。若旧 lifetime 进程仍存在，新的 Start 还可能与旧的 WSL 实例竞争，使故障表现为间歇性超时或对象名冲突。

**建议**

为 Start 建立明确的补偿阶段：

1. 在 `linux_start` 已 dispatch 后，任何失败都先调用带 generation/owner 校验的 Linux `stop`；
2. Stop 失败时保留 default-deny，并把状态标记为 `cleanup_required`，禁止自动重复 Start；
3. 结束或确认 lifetime 进程已失效，并把其 PID、启动时间和 generation 从 state 中清除；
4. 只有确认 namespace、`wg0`、policy rules 和 endpoint permit 都关闭后，才允许下一次 Start。

这里不能简单用 `wsl --terminate` 代替 Linux Stop，因为它会影响同一发行版中的用户工作负载，也无法提供按 owner 精确回收的证据。

### P1：续期脚本把“未执行”报告成成功退出

**证据**：`Renew-ScopeAttestation.ps1:7-9` 只有在返回对象且 `outcome -eq 'failed'` 时才退出 1。`Invoke-WslEgressScopeRenewal` 在 mutex 忙、endpoint 已关闭或 phase 不活动时可以直接返回 `$null` 或 `not_run` 记录。

**影响**：Task Scheduler 可能把一次没有续期的任务记为成功；人工看到 `not_run` 才能发现问题，但自动监控无法区分“成功续期”“安全跳过”和“异常提前退出”。这会掩盖 Start 失败后的恢复链问题。

**建议**：

- 所有路径都返回结构化记录，至少包含 `outcome`, `stage`, `reason`, `previous_phase`, `endpoint_before`；
- `mutex_busy` 和 `endpoint_closed` 使用明确的 `skipped`，并由脚本返回可区分的退出码；
- `not_run` 不应默认为 exit 0，除非任务明确只是在等待下一次调度；
- 手动诊断命令应直接输出记录，而不是只依赖退出码。

### P1：`linux_start` 阶段名不能区分 attestation 失败和真正的 WireGuard/路由失败

`manager.py:1713` 首先验证五分钟 Windows attestation；之后从 `manager.py:1733` 开始才创建 namespace、WireGuard 和路由。两类失败都会从 PowerShell 看成 `linux_start`。因此“manager start 需要 attestation”是事实，但不能仅凭 `failure_stage=linux_start` 断定根因是 attestation 超时。

需要同时检查：

- manager 的结构化 response 中的 phase/checks；
- manager 私有 journal 是否进入 `Starting`、是否已有 `namespaces`/`routing`；
- `scope-attestation.json` 的 `issued_at_unix`、generation 和五分钟窗口；
- `scope-renewal.json` 的 `stage` 与 Start operation 的同一 `operation_id`；
- WSL 进程退出码和安全摘要。

当前 PowerShell 在 `Invoke-WslEgressProcess` 中读取 stderr 后直接丢弃（`WslSecureEgress.psm1:450-451`），`Invoke-WslEgressLinux` 对无效 JSON 也只生成通用的 `Linux helper failed without a valid structured response`（`1025-1049`）。这使真正的 manager 错误只能通过手工进入提权上下文复现，诊断能力不足。

**建议**：保留经过白名单映射的错误类别，例如 `attestation_stale`、`audit_timeout`、`wg_link_create_failed`、`route_install_failed`、`cleanup_required`；不要把原始 stderr 或 endpoint/key 内容直接写入 UI。

### P1：attestation 生成是串行长链，容易把 WSL 调用超时放大为 Start 失败

**证据**：`WslSecureEgress.psm1:1119-1160` 依次枚举发行版、对 manager 和每个 configured distro 调用 `audit-config`，再执行 Hyper-V、`.wslconfig` 和 Docker 审计；每次 Linux 调用由 `Invoke-WslEgressLinux` 使用 60 秒超时（`1025-1034`）。Start 随后在 `1989-1991` 再调用 Linux `start`。

**影响**：发行版数量增加、Ubuntu 26 首次唤醒较慢、WSL 服务响应迟滞或提权上下文访问受限时，Start 会在真正建立 WireGuard 之前失败。若失败后的 runtime 没有清理，就会形成“失败—残留—再次 Start—再次加载模块”的循环。

**建议**：把 scope audit 拆成有独立超时和阶段记录的步骤；每个发行版记录开始/结束时间、exit code、response phase；在 Start 前验证 attestation freshness，Start 后不要重复做同一类 audit；对 audit timeout 直接进入 `cleanup_required`，禁止自动重试。

### 推荐的确认顺序

不要先把“反复加载模块”归因于 Ubuntu 26 的内核问题。先按同一 generation 对齐以下记录：

1. Start operation result 的 `failure_stage`、`exception_class` 和 operation id；
2. `state.json` 的 phase、lifetime、namespaces、routing 和 endpoint_enabled；
3. manager 的 Linux response/journal；
4. `scope-renewal.json` 的 `stage/outcome`；
5. WireGuard 模块加载日志时间线。

如果 `state.json` 在 `linux_start` 失败后仍有 lifetime 或 namespaces，而 endpoint 已是 false，就可以确认这是 Start 失败补偿不完整；此时应先实现精确 Stop/cleanup，再继续做 Ubuntu 26 的网络兼容性判断。
