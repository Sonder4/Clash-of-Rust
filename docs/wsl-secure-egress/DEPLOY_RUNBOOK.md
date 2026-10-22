# WSL Secure Egress 部署手册（实机执行）

本文件记录在实机上把已安装但 fail-closed 的 WSL Secure Egress 打开为
“全部 WSL 出口经德国 VPS”所需的完整步骤、阻塞点与验证标准。以下状态是
2026-10-22 的只读快照；历史成功记录不能替代本轮实测。

## 1. 当前实机状态（已确认，只读检查）

| 项目 | 实际值 |
| --- | --- |
| Windows 账户 | `XUAN\xuan`；需要单独发起并确认 UAC |
| WSL 发行版 | Ubuntu-22.04（Running）、Ubuntu-26.04（Stopped）、docker-desktop（Stopped） |
| `.wslconfig` | `networkingMode=nat`、`localhostForwarding=false`、`dnsTunneling=false`、`firewall=true` |
| Ubuntu-22.04 网卡 | `eth0 172.19.104.128/20`，默认路由 `172.19.96.1` |
| Ubuntu DNS | 当前只读解析检查失败；具体 resolver 状态以最新状态检查为准 |
| Ubuntu nft | 当前隧道未开启；不得用历史 guard 结果代替本轮检查 |
| Windows 状态 | profile 缺失、`endpoint_enabled: false`、`phase: failed_closed_requested` |
| Hyper-V 持久策略 | 入站 Block、出站 Block |
| Hyper-V 端点规则 | `ClashOfRust-WslEgress-Endpoint`，存在但 `Enabled=False` |
| Windows profile | `MISSING`；Linux root-only 副本待经管理员事务恢复 |
| Guardian 服务 | Running / Automatic；仅证明监控进程在运行 |
| 实机出口 | `curl -4 https://ifconfig.co/ip` 返回 6（DNS 解析失败），无出口 |

结论：系统已安装但保持 fail-closed。这与设计一致——隧道未启动时不允许任何回退出口。

## 2. 打开隧道的唯一条件：管理员提权

所有写入（包安装、broker 启动、端点放行）都需要 **High integrity + Administrator**
令牌。本机当前进程是 Medium integrity，因此必须先通过 UAC。

最近一次管理员作业没有得到 `WORKER-READY.txt`、`DONE.txt` 或管理员报告。
因此当前不能宣称 UAC 成功，也不能把“管理员终端标题”或 `sudo.exe` 返回当作
提权证据。每次发起 UAC 前，操作者必须说明原因并取得用户明确确认。

## 3. 部署前必须满足的前置条件

### 3.1 只运行当前仓库中的脚本

旧目录副本不是权威版本；不得运行其中过期或损坏的脚本。只使用当前审查
工作树的：

```text
scripts/wsl-secure-egress/COR-Full-AdminJob.ps1
scripts/wsl-secure-egress/Restore-WslEgressProfile.ps1
scripts/wsl-secure-egress/Prepare-PackageStage.ps1
```

运行前先执行 PowerShell parser、离线测试和 staging preview。只有新 head 的
GitHub CI 通过后才能把它当作可审查候选。

### 3.2 包 staging 必须可验证

先运行 `Prepare-PackageStage.ps1` 的 preview，确认 `outcome=not_run` 且不写盘。
真实 staging 只允许白名单包文件，receipt 必须位于 stage 外部并使用原子写入。
强制重置 ACL 只可用于已验证的专用工作目录；不得递归修改仓库、用户目录或
CC Switch 数据目录。

## 4. 部署步骤（需要一次 UAC）

权威管理员作业：`scripts/wsl-secure-egress/COR-Full-AdminJob.ps1`。
它必须先恢复受保护 profile、修复受控 ACL、执行 package upgrade 并启动隧道。

```powershell
# 先显示命令并说明原因；取得用户明确确认后再执行
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\wsl-secure-egress\COR-Full-AdminJob.ps1
```

脚本顺序（全部 fail-closed，任一子步骤非零即停止）：

1. 校验 High integrity + Administrator 令牌；只通过原生参数向量调用
   Windows sudo，取消或失败即停。
2. 从 profile 所选管理发行版中的 root-only
   `/etc/cor-egress/profile.json` 恢复 Windows profile，校验 SHA256、
   schema、私钥结构和受保护 ACL。示例中的 `Ubuntu-22.04` 只是当前主机选择，
   不是强制发行版名称。
3. 只接受已通过 manifest、架构、资源、PE 版本和 dependency snapshot 校验
   的 Windows x64 Release artifact。禁止从 `target\debug` 或未经校验的
   `target\release` 目录部署。
4. 从已验证 artifact 的 `payload` 复制 `clash-of-rust.exe`、
   `clash-tun-launcher.exe`、`clash-wsl-guardian.exe`、`LICENSE`、
   `resources\mihomo.exe` 及完整 `resources\wsl-secure-egress` 资源。
5. 逐个校验必需文件存在且可 OpenRead，并记录 artifact commit、版本和
   manifest SHA256。
6. 生成受保护 staging manifest，执行 `Upgrade-Package.ps1` 的 Apply/Commit。
7. 启动 broker 和 WireGuard，通过严格启动器确认近期 handshake、VPS 出口、
   DNS、IPv6 和 interop 负向检查。

## 5. 验收标准（脚本必须实际执行通过，不得标为未测通过）

| 检查 | 期望值 |
| --- | --- |
| 严格启动器中 `curl -4 https://ifconfig.co/ip` | 受保护 profile 中记录的 VPS IPv4 |
| 严格启动器中 `getent hosts api.openai.com` | 成功 |
| 严格启动器中 `curl -6 https://ifconfig.co/ip` | 失败（IPv6 必须阻断） |
| 严格启动器中 `command -v ipconfig.exe` | 未找到 |
| 严格启动器中 `ip -brief addr` | 只出现 `lo`、`wg0`、`cor-bg0` |
| 严格启动器中 `ls /mnt/c` | 宿主挂载不可见 |
| `nft list tables` | 含 `cor_egress_guard` |
| Windows profile | 存在、ACL 受保护、哈希和 schema 已验证 |
| 作业标记 | 当前受保护作业报告明确写出 `DONE.txt` 或等价成功状态 |

本手册不记录 VPS 地址；该值来自当前私密 profile，只用于本机验收。配置只存在
于受保护的本地 profile，不应写入仓库。任何未重新执行的检查保持
`NOT_RUN`，失败保持 `FAIL` 或 `BLOCKED`。

只有当前作业生成的最新成功证据才能视为打开成功。旧 `DONE.txt`、历史日志、
UAC 弹窗出现或 sudo 返回 0 都不能单独证明成功。

## 6. 打开后的模型厂商出口验证

```bash
# 在严格隔离启动器中执行
curl -4 -fsS https://ifconfig.co/ip            # 必须等于受保护 profile 中的 VPS IPv4
curl -4 -fsS https://ifconfig.co/country       # 必须 Germany
curl -4 -sS -o /dev/null -w '%{http_code}\n' https://api.openai.com/v1/models
curl -4 -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/v1/models
curl -4 -sS -o /dev/null -w '%{http_code}\n' https://api.deepseek.com/v1/models
```

未认证时 401/403 是正常的；关键是出口 IP 必须是 VPS IP，而不是 Windows 的本地公网 IP。

## 7. 当前未完成实机验收

- Chrome、Codex CLI、Claude Code CLI、Claude Desktop 尚未在当前 Ubuntu 26.04
  上完成安装和验证。工具安装器必须在严格启动器中先证明出口 IP，当前结果为
  `NOT_RUN`。
- docker-desktop 被策略阻断，不作为管理器发行版。
- WSL 中的 IPv6 被彻底阻断，这是按验收要求的设计行为。
- 当前普通 shell 仍可见 `/mnt/*`；严格启动器的 mount namespace 隐藏宿主挂载。
- VPN 断开、WSL 冷启动、Windows 重启、网络切换、恢复、卸载和重装均为
  `NOT_RUN`，必须在管理员事务后进行独立测试。
