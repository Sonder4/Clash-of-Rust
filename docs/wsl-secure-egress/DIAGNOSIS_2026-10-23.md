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
