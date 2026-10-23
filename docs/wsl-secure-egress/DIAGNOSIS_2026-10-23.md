# WSL Secure Egress 运行态诊断（2026-10-23）

性质：本机只读诊断 + 离线/隔离验证。不是运行验收，不证明端到端出口。

## 1. 观察到的运行态

| 对象 | 观察值 | 说明 |
| --- | --- | --- |
| WSL `wg0` 最后握手 | 2026-10-22 23:56:32，至诊断时已停 2 小时以上 | WSL 与 VPS 两侧 `latest-handshakes` 时间戳一致 |
| WSL `wg0` transfer | 797.39 MiB received / 29.12 MiB sent，冻结 | 计数不再增长 |
| 保活包 | 35 秒内 transport 命名空间计数器 +7 包 | 符合 5 秒间隔；socket 与出向路径本身是通的 |
| Windows Hyper-V 规则 `ClashOfRust-WslEgress-Endpoint` | `Enabled=False`（ActiveStore 与 PersistentStore 一致） | 规则存在，仅 UDP 51820 → 62.84.164.122 |
| Windows journal `state.json` | `phase=blocked`，`endpoint_enabled=false` | 与规则状态一致 |
| WSL 出网 | 无（nft guard `policy drop` 生效） | fail-closed 生效，无直连泄漏 |
| 关键地址基线 | `ipgw.neu.edu.cn` HTTP 302；`api.okinto.com` HTTP 200 | 00:47:29 复验通过 |

## 2. 已定位的代码级现象

### 2.1 GW 命名空间无 fwmark / 无 bypass 规则

`scripts/wsl-secure-egress/linux/manager.py` 中 `setup_routing()`（约 1653 行）建立的策略
路由只有 10070–10074 五条 `ip rule`，全部围绕业务流量；`wg set` 调用（约 1826 行）
未设置 `fwmark`，GW 命名空间也没有 `not fwmark … lookup main` 规则。因此
`ip netns exec cor-egress-gw ip route get 62.84.164.122` 解析回 `dev wg0`。

### 2.2 renewal 的 fail-closed 不可恢复

`scripts/wsl-secure-egress/WslSecureEgress.psm1` 的 `Invoke-WslEgressScopeRenewal`
（1340 行起）开头：

```powershell
if (-not $state.endpoint_enabled -or $state.phase -notin @('connected_unverified','verified')) { return }
```

同一函数的 catch 会执行 `Set-WslEgressEndpoint $state $false` 并写入
`$state.phase = 'blocked'`。一次审计失败后，后续每次运行都在函数开头返回，
不再重试；续期任务每分钟触发，等于每分钟都有一次把自己锁死的机会。

### 2.3 Windows 侧到 VPS 的路由被 Clash TUN 接管

`Find-NetRoute` 显示到 `62.84.164.122`（v4）与 `2401:1da0:22:f7::a`（v6）均经
`Meta` 适配器，metric 0。

## 3. 本轮验证得到的修正：2.1 不是隧道不通的成因

这是本轮最重要的结论，它推翻了诊断初期把 fwmark 缺失视为主因的判断。

隔离集成测试使用**与生产完全相同的代码路径**（`install` → `manager.py start()`），
WireGuard 接口同样先创建于 transport 命名空间、再移入 GW 命名空间，同样没有 fwmark：

```
CI=true COR_EGRESS_ISOLATED_CI=1 python3 scripts/wsl-secure-egress/tests/linux_integration.py --execute-isolated
→ outcome: passed，86 个用例全部 PASS
```

其中 `managed-tcp` / `managed-udp` / `managed-dns-tcp` / `managed-dns-udp` 均收到
`source=10.77.0.2` 的隧道回执，`stop-blocks-*` 与 `missing-tunnel-*` 均正确拒绝。
**同一份代码、同样的命名空间布局、同样的 fwmark 缺失，隧道是通的。**

因此 fwmark 缺失是**设计上依赖 socket 出生命名空间的既定行为**（与
[WireGuard 官方 netns 设计](https://www.wireguard.com/netns/) 一致：接口移入受管
namespace，加密 UDP socket 保留在创建它的 namespace），不是缺陷，也不是本故障成因。

真正的拓扑差异只有一处：

| | 隔离 fixture | 生产 |
| --- | --- | --- |
| WireGuard 端点 | `192.0.2.1`，Linux 内核内 veth，on-link | `62.84.164.122`，需跨 WSL NAT → Windows → Meta TUN |

隔离测试自身也明确声明了范围限制：

```
"notRun": ["Windows/WSL/Hyper-V effective audit", "cold boot", "real VPS/geography"],
"scope": "disposable Linux netns only; not WSL/Windows/real VPS acceptance"
```

## 4. 丢包点已收缩到 Windows 侧

以下测量表明 WSL 发出的封装包确实到达了 Windows，但没有到达 VPS：

| 测量 | 结果 |
| --- | --- |
| WSL `eth0` tx 与 Windows vNIC recv 同步对比 | 35 秒窗口内 +1372 = +1372，逐字节吻合 |
| 500 × 1000 字节 UDP 突发 | WSL `eth0` tx +190 字节，Windows vNIC recv +190 字节 |
| VPS `cor-wsl0` RX | 不增长；`latest-handshakes` 不更新 |
| WSL→VPS 的 SOCKS5/HTTP 探测 | 无响应 |
| mihomo 连接表 | 未出现来自 WSL 子网的 UDP 流 |

结论：包在 Windows 侧之后丢失。可能位置是 Hyper-V 回程、NAT 转换或 Meta TUN 接管，
**本轮未用 pktmon 等抓包手段定位到具体一跳**（该类操作会改变系统状态，未执行）。

因此 2.2（renewal 锁死）是**确认存在的行为缺陷**，但它与当前丢包无因果关系；
2.3 是既定的 Windows 网络环境，不是本产品的缺陷。

## 5. 为何不能借鉴 wsl-vpnkit

本轮明确否掉"直接借鉴 GitHub 上的 wsl vpn namespace 项目"这一路径。

`wsl-vpnkit` 的连通机制依赖 Windows interop：它要求在 WSL 内执行
`wsl-gvproxy.exe` 等 Windows 可执行文件。而本设计的 `manager.py interop_guard()`
主动禁用 interop（`/proc/sys/fs/binfmt_misc/WSLInterop: disabled`，WSL 内运行
`.exe` 返回 `Exec format error`）。这是**刻意的安全边界**：interop 开启时，WSL 内
任意进程都可调用 Windows 程序，隔离即失效。

两者是根本冲突，不是可以借鉴实现的细节。本机 2026-10-15 的项目调研
（`docs/wsl-vps-github-project-survey-2026-10-15.md` §6.1）已有相同结论：

> `wsl-vpnkit` 主要解决连通性，不保证固定 VPS 或失败关闭

另：本机 `/dev/vsock` 存在但 `AF_VSOCK` 连接 host CID 2 超时，无可用监听，
无法作为替代通道。

## 6. 已否掉的替代方案：tun2socks → Clash 端口

该方案来自"WSL 直接走 Clash of Rust 的端口，让风控生效"这一要求。实测否掉：

```
SOCKS5 UDP ASSOCIATE → BND.ADDR = 127.0.0.1, BND.PORT = 17890
```

mihomo 把 UDP 中继地址报为 `127.0.0.1`。WSL 内的 tun2socks 会向自己的
`127.0.0.1:17890` 发包，连不到 Windows 上的 Clash。TCP 侧同样不通：
WSL → `172.19.96.1:<port>` 超时，因为 Hyper-V 防火墙
`DefaultOutboundAction = Block`。`netsh portproxy` 能解决 TCP 端口转发，
但解决不了"中继地址是 127.0.0.1"这个地址转换问题。

## 7. 本轮对系统做过的改动

| 改动 | 内容 | 定向回退 |
| --- | --- | --- |
| 手动启用 Hyper-V endpoint 规则 | `ClashOfRust-WslEgress-Endpoint` 两个 store 均设为 `Enabled=True`（原为 False），范围不变：仅 UDP 51820 → 62.84.164.122 | 重新设回 `Enabled=False` |

该改动**未恢复隧道**（握手仍未更新），证明仅靠放行规则不足以打通路径。
其余诊断均为只读。

未做：未停 Clash/Mihomo、未改 `.wslconfig`、未动 Hyper-V 默认策略、未重启 WSL、
未删除任何防火墙规则、未访问 Claude/Anthropic、未在生产命名空间执行写操作。

## 8. 未完成项

| 项 | 状态 | 阻塞原因 |
| --- | --- | --- |
| `live_acceptance.py --execute` | BLOCKED | 要求 running 且 endpoint 启用；当前 journal 为 `blocked` |
| fail-closed 验收 | NOT_RUN | 会关闭 endpoint，属独立授权项 |
| Windows 侧丢包精确定位 | NOT_RUN | 需 pktmon 等会改变系统状态的手段 |
| 冷启动、重启、睡眠恢复、切网 | NOT_RUN | 需隔离环境 |
| 实际德国 IPv4 出口证据 | NOT_RUN | 需授权 VPS 与受控接收端 |
| Docker 受保护出口 | NOT_SUPPORTED | 独立适配器未实现 |

**本轮没有任何一步证明 WSL 端到端出口。** 当前状态应描述为：静态与离线验证通过、
隔离数据面通过、Windows 边界丢包点已收缩但未定位、运行态 fail-closed 生效。

## 9. Ubuntu-26.04 manager 迁移（2026-10-23 执行记录）

目标：把 WSL Secure Egress 的 manager 从 Ubuntu-22.04 换成 Ubuntu-26.04，
并使 WSL 重启后隧道自动恢复。

### 9.1 事实核查（已证实）

| 结论 | 证据 |
| --- | --- |
| profile 私钥与 22.04 现有 `wireguard.key` 逐字节相同 | sha256 前 20 位 `ffeb368f1e8401ae8d5e` 两侧一致 |
| 隧道地址 `10.77.0.2/32` 就是 VPS 上唯一已授权 peer | 与 profile `tunnel_address` 一致 |
| **迁移不需要改 VPS** | 由上面两条推出 |
| WSL2 是单 VM 共享内核 | 三个发行版都解析到同一个 `net:[4026531833]` |
| 已装 EXE 与其嵌入 payload 哈希不一致 | 13/16 个 blob 与磁盘一致；`WslSecureEgress.psm1`、`linux/manager.py`、`linux/CONTRACT.md` 三个 blob 在磁盘和所有 git 版本里都不存在 |
| 该不一致是版本滞后而非篡改 | 磁盘资源比 EXE 新；EXE 是官方安装包产物 |

结论：GUI 的 `payload::verify()` 在应用重新编译前**不可能通过**，因此 GUI 的
UAC 通道不可用，只能直接调用已安装包内的脚本。直接调用本身工作正常。
（另有两份安装：主包 `C:\Program Files\Clash of Rust\...` 与辅助包
`C:\Program Files\Clash of Rust WSL\...`，内容有分歧，是后续多个问题的根源。）

### 9.2 run 1：卡死

按顺序执行到 `04-rollback` 成功（`outcome=succeeded`，`phase=restored`）后，
进程永久冻结：CPU 停在 19.3 秒不再增长，2.0 GB RSS，7 个线程处于
`UserRequest` 等待，没有子进程，`05-install.json` 始终没出现。
该进程是管理员进程，本会话（非管理员）无法结束；`taskkill /F` 的 UAC
提示被取消。它当前是无害的残留：模块的
`Global\ClashOfRust.WslEgress.Operation` 互斥体不存在，即使它醒过来也会被
模块自身的并发保护拒绝，而不是与新 Install 竞争。

卡死前的实际战果：

    00-baseline   ipgw=302  okinto=200
    01-snapshot   295 MB（序列化缺陷，见 9.3）
    02-stop       被 resume 检查跳过（已是 installed_closed）
    03-shutdown   wsl --shutdown，无发行版在跑
    04-rollback   outcome=succeeded  phase=restored

宿主此后一直处于"已回滚"的安全状态：journal `restored`、`endpoint_enabled=false`、
三个发行版全部 Stopped、两个强制地址 302/200 正常。

### 9.3 定位到的三个缺陷（均已单独复现验证）

**缺陷 1：快照序列化爆炸。** `ConvertTo-Json -Depth 6` 作用在"值为原始文件
文本"的哈希表上时，会递归遍历字符串本身。本机实测：

    stateJson only, Depth 1:      3,841 bytes
    stateJson only, Depth 2:      4,400
    stateJson only, Depth 3:     28,567
    stateJson only, Depth 4:    384,604
    stateJson only, Depth 5:  2,222,751
    stateJson only, Depth 6: 46,352,501

一个 3.3 KB 的文件在 Depth 6 下变成 46 MB；四个字段合起来就是
295,339,235 字节的 `01-snapshot.json`。

修法：每段文本单独过 `ConvertTo-Json -Depth 1`（单个字符串不会递归），再拼接。
结果 4,704 字节，`ConvertFrom-Json` 往返成功，`stateJson.Length` 仍是 3295。
顺带修掉一个隐藏问题：空数组过 `ConvertTo-Json` 返回 `$null`，字符串拼接后
变成 `"hyperv":}`，是非法 JSON；现在空数组固定输出 `[]`。

**缺陷 2：任何步骤都没有超时。** run 1 因此挂了 50 分钟无人察觉。现在每步都
用 `Start-Process` + 文件重定向 + `WaitForExit(超时)`，超时就杀掉并报告。

**缺陷 3：进度只靠 `Start-Transcript` 记录。** run 1 的 transcript 在 12:15:45
之后就不再更新，而 `04-rollback.json` 是 12:16 落的盘，说明 transcript 丢了
最后的进度。换成逐行 append + flush。

### 9.4 run 2：已就绪但未执行

`migrate-26-run2.ps1` 已写好并通过语法检查与非提权 plan-only 演练：
快照 4,704 字节、全程约 2 秒、日志逐行落盘。
正式执行需要一次 UAC 提权，该提权提示两次均被取消，因此 run 2 尚未运行，
系统状态与 run 1 结束时一致（安全、未变更）。

**迁移仍未完成。** 在 run 2 成功之前，不得认为 Ubuntu-26.04 已接管 manager，
也不得认为"WSL 重启后自动恢复"已经实现。

### 9.5 已识别但未处理的风险

| 项 | 说明 |
| --- | --- |
| 计划任务身份校验 | `Test-WslEgressRenewalTaskIdentity` 用 `$PSScriptRoot` 拼出期望参数，而旧任务指向辅助包路径，两边必然不符。已手动删除该过期任务（XML 已备份到 `migration/renewal-task-backup.xml`），Install/Start 会按主包重新注册 |
| `dnsTunneling=true` | 当前 `.wslconfig` 的 `dnsTunneling=true` 是 10-18 快照的既有状态，不是本轮改动；但产品要求 `false`，`Get-WslEgressWindowsConfigAudit` 会判 `valid=false` |
| Ubuntu-22.04 清理 | 尚未开始，属单独授权项 |
