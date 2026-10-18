# 本机 WSL 模型厂商连接与应用可用性实测

记录日期：2026-10-18。下文时间统一为 Asia/Taipei（UTC+08:00）；JSON 保留各记录的显式时区。测试窗口为 09:42–09:53。结论只覆盖这些实际执行的请求，不将历史结果或未执行场景列为通过。

**最新 PR 修复阶段状态：已安装 Clash of Rust 0.6.0 仍在运行，新源码尚未替换安装；生产 WSL 为 `installed_closed`，endpoint 已禁用。当前不能把 09:42–09:53 的历史 VPS 连接结果当作实时连通状态。Claude Desktop/CLI 与完整冷启动安全验收仍未完成。**

本次新增的是 PR 修复与离线/隔离环境验证。Windows unit 实际通过 125
项断言（包括真实临时目录 archive/readback/hash 与篡改拒绝），workflow
96、elevation 21、package-upgrade 38 项断言此前已通过。最新 Linux
static 52 项测试与 fresh Linux-native source copy 的 full isolated
integration 89 个案例已通过；后者只使用临时命名空间和 fixture receiver，
不代表真实 VPS 或生产重启测试。Rust release WSL core 与 desktop WSL
测试各 27 项通过，release build 与 workspace all-targets Clippy 通过。
新提交对应 GitHub CI 尚待运行。详细命令和失败记录见
[TEST_STATUS.md](TEST_STATUS.md#2026-10-18-pr-repair-verification)。

以下第 1–5 节保留原 09:42–09:53 测试记录，不将当时 Running 状态、已安装
payload 哈希或短时采样结果改写为当前源码已经部署/当前实时联网的证明。

**该历史窗口结论：普通 WSL 的已测公网连接经德国 VPS 成功；现有 Claude Desktop 仍不可用，严格隔离启动器被审计证明过期阻止，完整安全验收未完成。**

## 1. 范围与安装状态

- 已安装 Clash of Rust 0.6.0；安装位置为 `%ProgramFiles%\Clash of Rust`。先前安装被 UAC 阻塞的记录已由用户之后成功完成的安装取代，不能再当作当前安装状态。
- `ClashOfRust.Network` 为 Running / Manual；`ClashOfRust.WslEgress` 为 Running / Automatic。
- 已安装 Linux `manager.py` 与本仓库相应文件 SHA-256 相同。
- 目标发行版为 Ubuntu-22.04，系统为 Ubuntu 22.04.5 LTS，glibc 2.35。
- 当前后端为 **WireGuard**；本轮没有部署或验证 Tailscale。不得把本轮结果写成 Tailscale Exit Node 已验收。
- Windows `.wslconfig` 审计：NAT、`localhostForwarding=false`、`dnsTunneling=false`、`autoProxy=false`、`firewall=true`，与已记录配置哈希一致。
- Linux `status` 返回 Running / Unverified；Windows 保存状态为 connected_unverified。

本轮没有修改产品源码、Windows/WSL 网络配置、应用持久设置、路由、DNS、防火墙或 VPS 服务，没有登录模型厂商账号、发送 API 凭据或进行认证推理。新增的是本机测试脚本、证据与文档。临时 AF_PACKET 观察进程只统计匹配报文包头/随机标记，不保存其他用户流量载荷；远端观察已正常退出。

测试目录位于项目内被 Git 忽略的 `ClashOfRust-network-backups/usability-20261018-094234/`。不上传其原始运行资料。公网源地址在探针内与本机配置比较，只保留匹配结论和本机证据中的摘要；本文不公开真实 VPS 地址、密钥、认证信息或私密配置。

## 2. 实际执行结果

### T01 — Windows 必保通路：PASS

09:42 基线与 09:52 最终复验均使用正常 Windows 通路，未增加代理绕过、路由覆盖或关闭证书校验。

- 校园认证：DNS 成功，HTTP 302，TLS 校验结果 0，curl 退出 0。
- 必保 API：DNS 成功，HTTP 200，TLS 校验结果 0，curl 退出 0。
- 最终 DNS 探针第一次使用了错误的 PowerShell 过滤语法，记录为 `dns_records=-1`。随后修正探针重测，两个域名各得到 1 条有效地址记录；该探针错误没有覆盖或删除。

WSL 不增加校园站点分流或特殊规则。这里的校园检查仅保护 Windows 原有联网。

证据：`01-windows-baseline.json`、`13-windows-final-baseline.json`、`14-final-host-status.json`、`15-windows-dns-recheck.json`。

### T02 — Hyper-V / 全发行版有效审计：PARTIAL / BLOCKED

已安装 broker 的只读 `Get-WslEgressGuardAudit` 返回 `valid=true`、无 issues；NAT 配置审计也通过。这支持其检查的有效 Hyper-V 规则与已保存策略一致。

完整范围证明未通过：当前 PowerShell 不是 Windows 管理员令牌，Docker WFP `Verify` 返回 `0x00000005`（Access denied），因此得到 `docker_desktop_blocked=false`、`effective_audit_passed=false`。这是审计能力不足，不能据此断言 Docker 防护规则实际失效。

已尝试通过 UAC 启动只读管理员审计；`Start-Process -Verb RunAs` 最终返回“操作已被用户取消”。管理员脚本未完成，没有 `04-admin-audit.json` 成功结果。未放宽规则，也未伪造审计字段。

证据：`02-host-audit.json`、`03-audit-permissions.json`、`12-crosschecks-and-blockers.json`；可供后续执行的本机脚本为 `ReadOnly-AdminAudit.ps1`。

### T03 — 当前严格隔离启动器：BLOCKED

实际执行当前 generation 的：

```text
secure-egress --generation <当前 generation> run -- /usr/bin/true
```

退出码为 2，返回 `Windows attestation missing or older than five minutes.`，保护状态为 Blocked。旧证明已超过五分钟；新证明依赖 T02 的有效管理员审计，因此本轮没有新的 isolated-launcher 实测结果。

这是实际的可用性阻塞：**隧道显示 Running 不代表用户现在能直接启动受保护应用。** 没有绕过证明门槛、延长 TTL、直接进入命名空间冒充正式启动器成功，或使用先前隔离测试替代本轮结果。

证据：`05-current-usability.json`、`06-current-usability-isolated-python.json` 的 `existing_attestation_launcher` 与 `isolated-launcher` 项。

### T04 — 普通 WSL 的中立 IPv4 出口：PASS

使用 UID 1000、清空代理变量和 shell 启动环境的进程，先执行三个中立请求：

- `https://api.ipify.org`：HTTP 200，源地址与配置的 VPS IPv4 一致。
- `https://ipinfo.io/json`：HTTP 200，同一源地址，DE / Frankfurt am Main / Hesse。
- `https://www.cloudflare.com/cdn-cgi/trace`：HTTP 200，同一源地址，`loc=DE`、`colo=FRA`。

全部启用 TLS 证书校验且结果为 0。通过这个门槛后才执行厂商请求；各目标 `route get` 记录的业务接口为 `cor-eb0`。

证据：`06-current-usability-isolated-python.json` 的 ordinary-wsl 结果。

### T05 — OpenAI / Claude 网页域名实际回显出口：PASS

09:46 的下列请求均 HTTP 200、TLS 校验结果 0，返回源地址与配置的 VPS IPv4 相同，均为 DE / FRA：

- `chatgpt.com/cdn-cgi/trace`
- `auth.openai.com/cdn-cgi/trace`
- `claude.ai/cdn-cgi/trace`
- `console.anthropic.com/cdn-cgi/trace`

这是这些域名本次 trace 请求观察到 VPS 源地址的直接证据。它不代表账号登录、模型推理成功或服务商其他风控信号的判定。

证据：`06-current-usability-isolated-python.json` 的 `vendor_probes`。

### T06 — OpenAI / Anthropic / DeepSeek API 的网络与源地址：PASS（未认证）

09:51 重新核验中立出口匹配 VPS 且两份地域结果均 DE 后，执行：

- `GET https://api.openai.com/v1/models`：HTTP 401。
- 无认证的 `POST https://api.anthropic.com/v1/messages`：HTTP 401。
- `GET https://api.deepseek.com/models`：HTTP 401。

三者均 curl 退出 0、TLS 校验 0。**401 只证明未认证 HTTPS 服务可达，不表示认证推理成功。**

为单独确认 API 源 IP，在现有 VPS 上启动只读包头观察器，并为三个客户端请求分别指定不同的本地端口。对每个请求都实际观察到：

1. VPS 的 WireGuard 接口收到对应 SYN：1 个。
2. VPS 公网接口发出对应 SYN：1 个，源地址匹配 VPS。
3. 公网接口收到对应 SYN-ACK：1 个。
4. VPS 出站包的目标地址摘要与 curl 的实际 `remote_ip` 摘要相同。
5. SSH 所连接 VPS 的公网路由源地址摘要与 WSL 配置预期的 VPS IPv4 摘要相同。

这些证据把三次 API 连接与真实 VPS 出站报文关联起来，补足 API 的 401 响应本身不回显源 IP 的缺口。结论限于本轮三条 TCP/TLS 连接。

SSH 保留 `BatchMode=yes`、`StrictHostKeyChecking=yes`、`IdentitiesOnly=yes`，未读取私钥正文、接受新主机密钥或修改远端配置。

证据：`10-documented-ssh.json`、`11-vendor-vps-packets.json`、`12-crosschecks-and-blockers.json`。

### T07 — DNS 隧道采样：PASS（单次查询）

09:49 从普通 WSL 的非 root 进程向配置 resolver 发送带随机 nonce 的 UDP DNS 查询，收到事务匹配且包含 nonce 的有效响应。

- 网关命名空间 `wg0`：观察到 2 个 nonce 报文，其中 1 个出站。
- 普通 WSL `eth0`：观察到 0 个对应明文 nonce 报文。
- 两个观察进程均正常退出。

本次查询在 WireGuard 内可见，在所测 NAT 上联接口未发现对应明文查询。观察窗口约五秒；不把它扩大为全部应用、全部接口、DoH/DoT、未来网络故障或永久 DNS 无泄漏保证。

证据：`07-dns-electron-interop.json`。

### T08 — IPv6 及 Windows EXE 互操作：PASS（本次负向采样）

- 强制 IPv6 访问 `api6.ipify.org`：curl 退出 7，未能建立连接。这证明该次连接失败，不代替完整 IPv6 故障矩阵。
- UID 1000 通过绝对路径尝试执行 Windows `ipconfig.exe /?` 与 `cmd.exe /?`：均 `errno=8`（Exec format error），没有执行成功。
- `/proc/sys/fs/binfmt_misc/WSLInterop` 第一行为 `disabled`。

普通 WSL 中 `/mnt/c`、`/init`、WSLg、用户 home、机器标识和部分系统信息仍可见。禁止 Windows EXE 常规执行与隐藏 Windows 文件是不同边界，不能相互替代。

证据：`06-current-usability-isolated-python.json`、`07-dns-electron-interop.json`。

### T09 — 已安装 Claude Desktop：FAIL / 尚不可用

当前主进程与默认 WSL 位于相同 network namespace，并非本轮成功启动的严格隔离应用。

实际进程和现有用户 service 都仍带有：

```text
--proxy-server=http://127.0.0.1:12345
--proxy-bypass-list=<-loopback>
```

service 同时保存六个大小写代理环境变量，全部指向该旧端口。当前进程的代理问题以实际命令行参数为准；本次读取到的进程环境没有这些代理变量，不能把 service 的保存值当作进程已继承的证明。

所在命名空间 12345 无监听。显式经该代理访问中立 HTTPS 的现场复现立即返回 Connection refused。应用 `main.log` 多次记录 `ERR_PROXY_CONNECTION_FAILED`、`Failed to load URL: https://claude.ai/` 和 bootstrap 失败。因此可以确定当前启动方式无法正常通过这个代理联网。

日志另有独立原生模块兼容错误：

```text
GLIBC_2.39 not found
@ant/claude-native/claude-native-binding.node
```

系统实际为 glibc 2.35；对已安装 binding 的只读检查也发现 `GLIBC_2.39` 需求。该问题特指当前安装包的原生模块，不能推断所有 Claude Desktop 版本或所有 Ubuntu 22.04 安装都不兼容。

原始应用日志使用 Europe/Berlin 时间；09:xx 本机测试对应其 03:xx 日志。旧错误不会因为文件 mtime 更新就变成新请求证据。当前代理参数、无监听端口与现场复现单独支持故障结论。

还尝试用现有 Electron 可执行文件的 `ELECTRON_RUN_AS_NODE=1` 模式进行无账号运行时探测。该实例在初始化图形平台时退出 -5，报告 Missing X server / DISPLAY，未执行其 HTTPS 探针。**该诊断记为 ERROR/BLOCKED，不能作为 Desktop 网络通过或网络损坏的依据。** 它没有完成用户 Desktop 的 UI、bootstrap 或原生功能验收。

证据：`06-current-usability-isolated-python.json` 的 `desktop`、`07-dns-electron-interop.json` 的 `electron_runtime`。

### T10 — Claude Code CLI 与真实位置隐私：NOT_RUN / 未满足完整要求

在检查的常见系统/用户 CLI 路径中没有找到独立 `claude`，也未在已检查的 Desktop unpacked 目录中发现独立 CLI 入口；这不是全磁盘不存在 CLI 的证明。Desktop 日志的集成 Code 版本不等于终端 CLI 已安装或可运行。

本轮没有运行真实 Claude Code CLI 会话、账号登录、认证模型请求或 Desktop 内的 Code 会话。当前 Desktop 仍能看到 Windows 挂载及部分宿主相关元数据，严格隔离启动器又被 T03 阻塞，所以不能宣称现有 Desktop / 任意 CLI 已满足“无法获取 Windows 信息”的要求。

可以确认的范围是：本轮已测厂商网络连接使用 VPS 公网源地址。无法由这个事实推出应用永远无法读取本机配置中的真实地址、账号资料、主机标识、时区、用户文件或其他位置线索，也不能保证厂商最终如何判断物理位置。

### T11 — DeepSeek 子代理：ERROR（已尝试）

确实调用了子代理工具，请求模型 `deepseek/deepseek-flash`，任务仅为判断旧代理错误与 glibc 错误的区别，不给代理文件或网络修改权限。

服务端返回 `invalid_request_error`，说明当前 Codex multi-agent V2 的 sealed task 无法由该跨模型后端读取，代理任务未执行。没有伪装成模型成功回答，也没有修改 Codex 配置、另找凭据或替换成其他模型后声称 DeepSeek 成功。

DeepSeek API 401 的联网结果与 DeepSeek 子代理调用失败分别记录。另一个正常运行的只读审查代理已独立复核本轮测试证据及结论边界。

证据：`12-crosschecks-and-blockers.json` 与本会话子代理工具返回。

### T12 — 故障与生命周期验收：NOT_RUN

本轮未执行：生产 VPN 中断、Windows 物理网络切换、休眠恢复、冷重启、长时间失联、账号认证推理，以及新的严格隔离 GUI/CLI 会话。本轮没有为补测试而停止共享 Windows 核心、断开网卡或改防火墙。

现有 `Unverified` / `connected_unverified` 状态保留，不能写成完整 PASS。

## 3. 未解决问题与后续最小工作

1. 完成只读管理员 WFP / 全发行版审计；UAC 没有成功执行前，保留有效审计 BLOCKED，不能把 Access denied 当作规则失效或放宽过滤器。
2. 恢复受信任的当前 scope attestation，并复测正式 `secure-egress run`。五分钟后启动器如何按产品流程取得新证明，也是实际易用性问题；不能靠延长 TTL 或手工把布尔字段写成 true 解决。
3. 对 Claude Desktop 保存的 service 和实际启动方式做紧邻备份后，移除过时代理参数/环境变量，验证新的 UI 页面、bootstrap 与实际请求；本轮没有做这个配置修改。
4. 核实并修复当前 Desktop 包的 native binding ABI。优先使用与现有发行版兼容的受信任包；不要直接替换系统 glibc。是否升级发行版须单独评估，不把整个发行版迁移作为默认修复。
5. 选择真实需要的 CLI 或 Desktop Code 入口后验证。正式隔离器隐藏用户 home、`/usr/local`、WSLg 和会话 socket；不能假设用户目录安装的 CLI、项目目录、账号存储或 GUI 会话天然可用。图形与文件集成必须维持受控边界，不能为了显示 Desktop 全量暴露 Windows 挂载或任意宿主 socket。
6. 在不破坏 Windows 必保通路的受控条件下，补故障、重启和网络切换验收，再决定是否能升级整体验收状态。

## 4. 测试工具自身失败与证据保留

- `05-current-usability.json`：首次 ordinary 探针对 root 私有路径做 `exists()` 时遇到 PermissionError，在执行网络请求前退出。记为探针 ERROR；未算网络测试通过。
- `06-current-usability-isolated-python.json`：修正权限处理、进程参数解析，使用 `python3 -I -S` 减少启动定制影响后的重新执行结果。保留 05，不覆盖失败历史。
- `07-dns-electron-interop.json`：DNS/EXE 子项成功；Electron 子项失败。顶层命令退出 0 不意味着所有子项通过。
- `08-vps-route.json`、`09-ssh-failure.json`：旧 `use-xuan-pc-key.ps1` 文档默认身份连接被拒绝。没有改 SSH 或私钥。
- `10-documented-ssh.json`：改用另一份文档 `verify-vps.ps1` 已记录的别名/身份文件后，只读标记成功。没有执行旧部署脚本。
- `13/14` 的最终 DNS 计数探针语法错误由 `15-windows-dns-recheck.json` 补正；HTTP/TLS 记录保持原结果。

本轮只有记录和测试产物，无需网络回滚。后续若撤销报告，只处理本轮新增文档、测试目录及对应追加段，不恢复历史全量网络备份、不覆盖用户其他修改。原始日志保留于项目忽略目录，不提交或推送。

## 5. 官方资料与解释边界

- [Microsoft WSL networking](https://learn.microsoft.com/windows/wsl/networking)：NAT、mirrored、DNS tunneling 和 Hyper-V Firewall 属不同功能边界；NAT 本身不提供应用文件系统隔离。
- [Claude Desktop 安装与系统要求](https://support.claude.com/en/articles/10065433-install-claude-desktop)：当前官方列有 Linux 支持，包括 Ubuntu 22.04 LTS+。因此本文只判定本机已安装 native binding 的 ABI 需求不匹配，不笼统宣称 Ubuntu 22.04 不受支持。
- [Claude Code setup](https://code.claude.com/docs/en/setup)：CLI 可在 WSL 中单独安装与验证；Desktop 集成入口不等于独立 CLI 已就绪。

上述资料用于解释兼容性与功能范围；通过/失败状态全部来自本轮记录的实际命令与报文观察。
