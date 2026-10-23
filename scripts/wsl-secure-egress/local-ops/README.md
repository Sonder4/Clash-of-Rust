# local-ops：本机 WSL Secure Egress 操作脚本

这些脚本是**本机运维工具**，用于已安装的 Clash of Rust（`C:\Program Files\Clash of Rust`）
与 Ubuntu-26.04 manager 的迁移、恢复与验证。它们不是上游产品代码，不进入安装包，不随产品
升级发布。安装包升级后应先复验（自动恢复脚本依赖产品的私有函数）。

迁移过程、根因与实测结果见
[UBUNTU26-MIGRATION-2026-10-23.md](../../../docs/wsl-secure-egress/UBUNTU26-MIGRATION-2026-10-23.md)；
本机交接见 [local-network-handoff-2026-10-15.md](../../../docs/local-network-handoff-2026-10-15.md)。

## 网络变更前的强制前提

以下适用于所有会改变 Windows/WSL 网络状态的脚本（`Invoke-ProductAction.ps1`、
`Start-WslEgressAndVerify.ps1`、`Migrate-ManagerDistro.ps1`、`Install-StartAtLogonTask.ps1`
中会触发 Start 的部分）：

1. 先取两个关键地址的基线：

   ```powershell
   curl.exe -s -o NUL -w '%{http_code}' --max-time 25 https://ipgw.neu.edu.cn/
   curl.exe -s -o NUL -w '%{http_code}' --max-time 25 https://api.okinto.com/
   ```

   期望校园网 302、API 200；任一异常即停止。
2. 确认已安装包存在：
   `C:\Program Files\Clash of Rust\resources\wsl-secure-egress\Manage-WslSecureEgress.ps1`。
3. 需要提权的 PowerShell 窗口（脚本自身不会绕过产品的审计）。
4. 记录当前 journal：`C:\ProgramData\ClashOfRust\WslEgress\state.json`。

所有脚本日志默认写入 `%TEMP%\clash-of-rust-wsl-egress\`，只写本机临时区。
脚本中不保存私钥、口令、控制器 secret 或端点地址；端点由参数或产品的 root-private
`/etc/cor-egress/profile.json` 提供。

## Windows 侧脚本

| 文件 | 作用 | 是否改网络 |
| --- | --- | --- |
| `Start-AtLogon.ps1` | 登录后恢复隧道（由计划任务调用） | 仅在隧道未开时调用产品 `Start` |
| `Install-StartAtLogonTask.ps1` | 安装上述脚本与计划任务 | 否（只注册任务） |
| `Start-WslEgressAndVerify.ps1` | 调用产品 `Start`，随后 Doctor + 结构审计 + 基线复验 | 是 |
| `Invoke-ProductAction.ps1` | 执行任意产品 Action 并保存 JSON 响应 | 取决于 Action |
| `Migrate-ManagerDistro.ps1` | 重新执行 22.04 → 26.04 manager 迁移 | 是（破坏性，非常规） |

### `Start-AtLogon.ps1`

产品的 boot hook 会在 WSL 启动时恢复**失败关闭**的 guard，但产品从不自行建立隧道。
`Start` 是 Windows 侧提权动作，所以主机重启/登录后隧道一直是关闭的，直到有人手动运行。

本脚本在每次登录后：

1. 产品包或 journal 缺失时直接退出；
2. 用三条实时事实判断隧道是否真的开着，不信任 journal 单一声明：
   journal `phase ∈ {connected_unverified, verified}` 且 `endpoint_enabled=true`、
   ActiveStore 中 `ClashOfRust-WslEgress-Endpoint` 实际启用、Linux manager `status` 返回
   `phase=Running`；
3. 未开时先启动所有受管普通发行版（刷新任务要求它们都在运行），再调用产品 `Start`；
4. 记录响应到 `C:\ProgramData\ClashOfRust\WslEgress-Autostart\autostart.log`。

它不编辑 guard、profile 或 Hyper-V 策略。`wsl --shutdown` 不会触发登录事件，需要手动：

```powershell
Start-ScheduledTask -TaskName 'ClashOfRust-WslEgress-Autostart'
```

### `Install-StartAtLogonTask.ps1`

以管理员身份运行，把 `Start-AtLogon.ps1` 复制到
`C:\ProgramData\ClashOfRust\WslEgress-Autostart\`，并注册计划任务
`ClashOfRust-WslEgress-Autostart`（AtLogOn、当前用户、最高权限、30 s 延迟）。
幂等，可重复执行。卸载：

```powershell
Unregister-ScheduledTask -TaskName 'ClashOfRust-WslEgress-Autostart' -Confirm:$false
Remove-Item 'C:\ProgramData\ClashOfRust\WslEgress-Autostart' -Recurse
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-StartAtLogonTask.ps1
```

### `Start-WslEgressAndVerify.ps1`

默认只预览；加 `-Execute` 才调用产品 `Start`。顺序：读取 journal → `Start` →
`Doctor` → 结构审计（Hyper-V 默认拒绝、唯一出站放行规则是 VPS 端点）→ 关键地址基线复验。
任一环节失败即写 `FAILED.txt` 并退出非零。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-WslEgressAndVerify.ps1 -Execute
```

### `Invoke-ProductAction.ps1`

包装产品的 `Manage-WslSecureEgress.ps1`，便于在提权会话里执行单个 Action 并拿到 JSON。
产品 Action 集合：`Doctor`、`Status`、`Install`、`Start`、`Stop`、`Test`、`Rollback`、
`Uninstall`。默认是预览；加 `-Execute` 才真正执行。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-ProductAction.ps1 -Action Status
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-ProductAction.ps1 -Action Start -Execute
```

注意：在 `restored` 阶段执行 `Stop` 必然失败（产品守卫审计会把 Microsoft 自带的三条
`MPSSVC_DEFAULT_RULE_OUTBOUND_*` 判为 `foreign_outbound_allow`），并把 journal 写成
`closure_unverified`。`Stop` 只应在产品自己的 `connected_unverified`/`verified` 状态使用。

### `Migrate-ManagerDistro.ps1`

这是 2026-10-23 迁移所用的第 4 版脚本（`migrate-26-run4.ps1` 的整理副本），用于在
**两个发行版都停止**的前提下重新执行 22.04 → 26.04 的 manager 迁移：基线 → 快照 →
canary → 停发行版 → 安装 manager → 配置普通发行版 → `Start` → Doctor → 结构审计 → 基线。

只在需要重做迁移时使用；日常启停请用 `Invoke-ProductAction.ps1` 或产品界面。运行前先读
迁移文档 §3 的六个已知阻塞点，并确认两个发行版中 `/root/cor-egress-stale/` 的备份仍在。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Migrate-ManagerDistro.ps1 -Execute
```

## WSL 内诊断脚本（`diagnostics/`）

在 WSL 内运行，多数需要 root（nft/wg 部分）。默认只读，唯一的例外是 `failclosed-test.sh`。

| 文件 | 作用 | 是否改状态 |
| --- | --- | --- |
| `wsl-diag.sh` | 发行版、地址、路由、DNS、nft 表、guard 概览 | 只读 |
| `verify-egress.sh` | netns、wg 状态（从 `cor-egress-gw` 读）、DNS、出网 IP、IPv6 拒绝、端点路由 | 只读 |
| `post-restart-check.sh` | 重启后 boot guard 自己恢复到了什么状态 | 只读 |
| `payload-diag.sh` | `/usr/local/lib/cor-egress` 与 payload receipt 检查 | 只读 |
| `hostip-discovery-check.sh [前缀...]` | WSL 内各种命令能否直接获得主机校园网地址 | 只读 |
| `mnt-c-leak-check.sh [前缀...]` | `/mnt/c` 是否可读出主机地址 | 只读 |
| `exposure-check.sh [前缀...]` | 主机地址暴露面 + 出网/IPv6 拒绝汇总 | 只读 |
| `failclosed-test.sh` | 模拟 guard 失效：**删除** `inet cor_egress_guard` 后测出网 | **是（破坏性）** |

`verify-egress.sh` 的端点由参数给出，缺省时从 root-private 的
`/etc/cor-egress/profile.json` 读取，不在脚本里保存。

```bash
wsl.exe -d Ubuntu-26.04 -u root -- bash verify-egress.sh
```

`failclosed-test.sh` 会删除 WSL 内的 guard 表。测试前确认可以恢复（boot hook
`/usr/local/lib/cor-egress/manager guard` 或产品 `Start`），测试后立即复验两个关键地址。
它只应在已确认 Hyper-V 端点规则状态、且不处于他人使用中的窗口内运行。

## 不应做的事

- 不要把这些脚本复制进安装包目录，也不要改上游 `resources/` 内容来"修好"它们。
- 不要在 `restored` journal 上执行产品 `Stop`（见上）。
- 不要在普通发行版停止时依赖产品 `Start` 成功：刷新任务会关闭端点并把 `phase` 置为
  `blocked`，不会自行重试。
- 不要在 `global` 模式下运行：Clash 全局模式绕过 `IP-CIDR,...,DIRECT`，WireGuard 外层包
  会被投进代理节点，隧道与 SSH 都无法建立。
- 不要在未取基线的状态下运行任何改网络的脚本。
