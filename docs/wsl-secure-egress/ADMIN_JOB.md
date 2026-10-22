# COR-Full-AdminJob 管理员作业

`scripts/wsl-secure-egress/COR-Full-AdminJob.ps1` 是 WSL Secure Egress 的一次性主机部署作业。它只负责管理员阶段的主机 ACL、受保护包升级、broker 启动和实机验收；WSL Linux 组件仍由 `WslSecureEgress.psm1` 与 `linux/manager.py` 管理。

运行方式：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File F:\Codex\Clash-of-Rust-work\scripts\wsl-secure-egress\COR-Full-AdminJob.ps1
```

必须直接运行当前评审工作树中的这个文件。不要把脚本复制到其他目录后运行：
复制件不会随 Git 更新，旧副本可能继续使用已经修复的 ACL、staging 或恢复
逻辑。作业日志中的诊断输出和作者修改时间不能替代工作树哈希检查。每次
管理员执行前先确认正在提交的 head 和脚本哈希：

```powershell
git status --short --branch
Get-FileHash scripts\wsl-secure-egress\COR-Full-AdminJob.ps1 -Algorithm SHA256
```

脚本先检查当前令牌是否同时满足管理员角色和 High integrity。中完整性令牌
必须通过 Windows `sudo.exe --new-window` 请求 UAC；脚本直接传递原生参数
数组，不把含空格路径重新拼接成未引用的命令行。取消或无法提权时只写失败
证据，不会继续改动主机网络。`-NoSelfElevation` 只用于证明非管理员令牌会
立即失败，不得当作提权成功。

阶段顺序固定为：

1. 恢复受保护 WireGuard profile，验证 SHA256、schema、密钥格式及 ACL。
2. 修复工作树、管理员工作目录和包 staging 的受控 ACL，并读取
   `.git\HEAD` 作为回读证据。
3. 生成受保护 manifest，执行 `Upgrade-Package.ps1` 的 `Apply` 和
   `Commit`，每个子进程非零立即停止。
4. 使用恢复后的固定 profile 启动已安装 broker。
5. 在严格启动器中断言德国 VPS IPv4、DNS、IPv6、`wg0` 默认路由、
   namespace 可见性、Windows interop 和宿主挂载边界，并验证 OpenAI、
   Anthropic、DeepSeek 的 TLS 主页面可达。

只有所有阶段和断言都通过才会写入当前作业的成功状态。失败会保留
fail-closed 状态并写出失败报告；历史 `DONE.txt`、UAC 弹窗出现或
`sudo.exe` 返回 0 都不能单独证明成功。

当前只读状态仍是 profile 缺失、endpoint 禁用、broker
`failed_closed_requested`。最近没有管理员成功证据；实机事务和所有出口测试
保持 `NOT_RUN`。

## 2026-10-22 管理员令牌与旧副本诊断

最近一次作业实际获得了 High integrity 管理员令牌，但在 Stage 1 ACL
修复处失败。只读比较发现，`F:\Codex\admin-job\COR-Full-AdminJob.ps1`
与当前仓库文件 SHA256 不同，前者是旧的工作副本。该工作副本仍会使用
不能解析当前用户 SID 的参数形式。

当前仓库所用的 canonical SID 参数已在临时目录进行真实 `icacls` 验证，
进程返回码为 `0`，最终 ACL 包含 SYSTEM、Administrators 和当前用户。该
验证没有修改项目目录。管理员作业尚未用最新仓库文件重新执行，因此 profile
恢复、staging、Endpoint 和隧道仍然 `NOT_RUN`，本机继续 fail-closed。

## 2026-10-19 实机记录

手动执行旧版作业时，终端标题虽然显示“管理员”，令牌实际为：

```text
Mandatory Label: Medium Mandatory Level
Administrators: Group used for deny only
```

因此旧作业的 ACL 修复为 `0/1`，manifest 创建失败，broker 返回 `blocked`，Ubuntu 继续保持 `nameserver 10.77.0.1` 和 nftables 默认拒绝。该结果是 fail-closed，不能当作网络验收通过。

新作业已在普通令牌下用 `-NoSelfElevation` 做语法和失败门控验证，结果为退出码 `1` 并写入 `FAILED.txt`；尚未把管理员 UAC 授权视为成功，也未把未执行的出口 IP 测试标记为通过。

随后从可见的管理员标题终端手动运行了新作业。该终端的实际令牌仍为
`Medium Mandatory Level`，子进程返回码为 `1`，作业写入：

```text
identity user=XUAN\xuan high=False administrator=False
elevation child exited with code 1
```

这次运行没有生成 manifest、没有写入 Hyper-V 端点放行，也没有启动出口；Ubuntu-22.04 和 Ubuntu-26.04 已停止，当前系统仍保持默认拒绝。

## 2026-10-19 08:54 实机复跑

再次从普通完整性 PowerShell 手动运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File F:\Codex\admin-job\COR-Full-AdminJob.ps1
```

脚本确实进入了 `Start-Process -Verb RunAs`，系统创建了 `consent.exe`，但 UAC 最终返回取消。作业证据为：

```text
F:\Codex\admin-job\FAILED.txt
elevation cancelled: This command cannot be run due to the error: The operation was canceled by the user.
```

`DONE.txt` 不存在，`PROGRESS.txt` 只包含普通令牌身份，未进入 ACL、包升级、broker 启动或出口验收阶段。

随后进行只读 WSL 检查。Ubuntu-22.04 和 Ubuntu-26.04 均显示 NAT 网卡
`172.19.104.128/20`，默认路由为 `172.19.96.1`，`/etc/resolv.conf` 的唯一
解析器为 `10.77.0.1`。`curl -4/-6 https://ifconfig.co/ip` 和
`getent hosts api.openai.com` 均因 DNS 解析失败，不能证明任何出口 IP；
该结果符合隧道未启动时的 fail-closed 行为。当前不能把 Claude、OpenAI、
Anthropic 或其它模型厂商的连通性标记为通过。
