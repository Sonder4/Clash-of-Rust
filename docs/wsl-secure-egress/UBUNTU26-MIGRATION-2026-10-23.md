# Ubuntu-26.04 接管 WSL 出口：迁移、根因与验证（2026-10-23）

本轮把 WSL Secure Egress 的 manager 从 Ubuntu-22.04 迁移到 Ubuntu-26.04，打通隧道并验证
登录自动恢复。所有变更都记录在案，回退点见文末。

## 1. 结果

| 目标 | 状态 | 证据 |
| --- | --- | --- |
| Ubuntu-26.04 成为 manager | 完成 | Linux journal `role` 为空（manager）、`phase=Running`；`/etc/wsl.conf` 含 boot hook |
| WSL 出网经 VPS | 完成 | WSL 内 `api.ipify.org`/`ifconfig.co` 均返回 `62.84.164.122` |
| 不暴露本机 IP | 结构成立 | Hyper-V 对 WSL 默认拒绝，唯一放行 `UDP 51820 → 62.84.164.122` |
| 重启 WSL 后自动恢复 | **部分完成** | 登录计划任务可自动恢复；纯 `wsl --shutdown` 后需手动运行该任务 |

## 2. 变更清单

### 2.1 Windows 侧

| 对象 | 变更 | 回退 |
| --- | --- | --- |
| `C:\ProgramData\ClashOfRust\WslEgress\state.json` | `phase` 由 `closure_unverified` 改为 `restored`（仅在实测有效策略与 journal 记录的 `before_effective_settings` 完全一致、端点规则已禁用、所有发行版已停止时执行） | 恢复 `run3/02-journal-before-repair.json` |
| Hyper-V 端点规则 `ClashOfRust-WslEgress-Endpoint` | 由产品 `Start` 打开；现为 `Enabled=True` | 产品 `Stop` 或 `Rollback` |
| `%LOCALAPPDATA%\clash-of-rust\ClashOfRust\data\settings.json` | `run_mode`：`global` → `rule` | `%TEMP%\wsl-egress-migration-20261023T\clash-settings.before.json` |
| 计划任务 `ClashOfRust-WslEgress-Autostart` | 新增：用户登录后 30 秒运行一次恢复脚本 | `Unregister-ScheduledTask -TaskName 'ClashOfRust-WslEgress-Autostart'` |
| `C:\ProgramData\ClashOfRust\WslEgress-Autostart\Start-AtLogon.ps1` | 新增：自动恢复脚本，日志同目录 `autostart.log` | 删除该目录 |
| 产品刷新任务 `ClashOfRust-WslEgress-Renew` | 由 `Start` 重新创建（此前已过期删除） | 由产品 `Stop`/`Rollback` 移除 |
| 两份 `cor_egress_boot_emergency` nft 表 | 核对为产品自有精确定义后删除（详见 §3.4） | 由 boot guard 在异常时重建 |

### 2.2 Ubuntu-26.04

| 对象 | 变更 | 回退 |
| --- | --- | --- |
| `/usr/local/lib/cor-egress` | 旧 payload（`manager.py` 117403 B）移走，由安装包 payload（112922 B）全新安装 | 备份在 `/root/cor-egress-stale/payload-` |
| `/var/lib/cor-egress/state.json` | 旧 `distro-config`/`DistroRestored` journal 移走 | 备份在 `/root/cor-egress-stale/state-.json` |
| `/etc/wsl.conf` 与 `/etc/cor-egress/profile.json` | 由产品 manager 安装写入（含 boot hook） | 产品 `Rollback` |

### 2.3 Ubuntu-22.04

| 对象 | 变更 | 回退 |
| --- | --- | --- |
| `/usr/local/lib/cor-egress` | 旧 payload（117403 B）移走，重新安装 | 备份在 `/root/cor-egress-stale/payload-2204` |
| `/var/lib/cor-egress/state.json` | 旧 `RolledBack` manager journal（40416 B）移走 | 备份在 `/root/cor-egress-stale/state-2204.json` |
| 普通发行版配置 | 产品无续跑命令，调用其自身 `Invoke-WslEgressDistroConfiguration` 完成，并补写 `linux_manager_installed`/`installation_complete`/`phase=installed_closed` | 产品 `Rollback` |

## 3. 根因

按发现顺序，六个独立问题叠加，任意一个都会让迁移失败：

1. **在 `restored` 上执行 `Stop` 必然失败**。`Set-WslEgressEndpoint` 的守卫审计要求主机已处于
   安装后的默认拒绝姿态；`restored` 下审计把 Microsoft 自带的三条
   `MPSSVC_DEFAULT_RULE_OUTBOUND_*` 判为 `foreign_outbound_allow`，于是抛错并把 journal 写成
   `closure_unverified`。`Stop` 在 `restored` 上是无意义的操作，应跳过。
2. **两个发行版都有旧 payload 与不兼容 journal**。`install-payload.py` 在已有不同 payload 且无
   `--reviewed-upgrade` 时拒绝；`manager.py install()` 只接受无 journal 或 `phase=RolledBack`。
3. **产品没有"续跑配置"的命令**。`linux_manager_install_started=true` 后 `Install` 走
   `Test-WslEgressCompleteInstallation`，在普通发行版未配置时必然失败。
4. **Clash 处于 `global` 模式**。全局模式绕过所有规则，包括产品写入的
   `IP-CIDR,62.84.164.122/32,DIRECT`；WSL 的 WireGuard 封装包被投进 `XUAN-HY2-IPV6`，
   VPS 永远收不到握手。同一原因也让当时的 SSH 在 kex 阶段被关闭。
5. **普通发行版启动时的 boot guard 缺陷**。隧道处于打开（opened）表时，普通发行版的
   `ensure_static_boot_guard()` 无法识别该表，判为 `unknown` 并安装
   `cor_egress_boot_emergency`（output/forward 全 drop），把共享 netns 全部打死。
6. **刷新任务的失败锁**。刷新任务要求所有受管发行版都在运行；任一不在运行即抛错，随即关闭
   端点并把 `phase` 置为 `blocked`，且不会自行重试。

## 4. 验证

### 4.1 迁移后（20:36–20:38）

- 客户端 wg0：握手正常，收发持续增长；VPS `cor-wsl0` 同步显示最新握手。
- WSL 内 `api.ipify.org`、`ifconfig.co` 均返回 `62.84.164.122`；DNS 与 `example.com` 200 正常。
- 结构审计：`Enabled=True`、`DefaultInboundAction=Block`、`DefaultOutboundAction=Block`、
  `AllowHostPolicyMerge=False`、`LoopbackEnabled=False`；唯一启用的出站放行规则为
  `ClashOfRust-WslEgress-Endpoint → 62.84.164.122:51820 UDP`。
- `api.myip.com` 返回空，未确认原因；另外两个独立服务一致。

### 4.2 WSL 重启（20:44–20:47）

`wsl --shutdown` 后只启动 Ubuntu-26.04：

- boot hook 生效：`phase=Guarded`、`namespaces={}`、只有关闭表、无 emergency 表、WSL 完全无出口。
- Windows journal 仍是 `connected_unverified/enabled`（陈旧）；刷新任务随后关闭端点并置
  `blocked`。**结论：产品本身不会自动建立隧道。**
- 手动恢复路径（启动 22.04 → `Start`）成功，握手与出口恢复。

### 4.3 登录自动恢复（20:51–20:55）

新增计划任务后重新 `wsl --shutdown`，仅运行该任务：

```
journal phase=connected_unverified endpoint_enabled=True effective_rule_enabled=True
manager status outcome=succeeded phase=Guarded        ← 识别出 journal 陈旧
starting ordinary distribution: Ubuntu-22.04
start outcome=succeeded phase=connected_unverified
check PASS all_wsl_coverage / host_policy / dns_tunneling_disabled / interop_guarded / docker_desktop_isolated
endpoint rule enabled after start = True
```

90 秒后复核：刷新任务 `outcome=succeeded`，端点保持开启，握手 10 秒前，收发 8.32/8.18 KiB，
WSL 出口 `62.84.164.122`，DNS 正常，两个发行版均在运行，无 emergency 表。

任务在隧道已开时幂等跳过（日志 `tunnel verified open ...; skipping`）。

## 5. 自动恢复脚本的判定逻辑

`Start-AtLogon.ps1` 不信任 journal 单一声明——WSL 重启后 journal 仍写着"已连接"。只有以下三条
同时成立才跳过：

1. journal `phase ∈ {connected_unverified, verified}` 且 `endpoint_enabled=true`；
2. ActiveStore 中端点规则实际 `Enabled=True`；
3. Linux manager 的 `status` 返回 `phase=Running`。

否则：先启动所有普通发行版（刷新任务要求它们在运行），再调用产品自身 `Start`。脚本不编辑
guard、profile 或 Hyper-V 策略，也不绕过 `Start` 的内部审计。

## 6. 未完成与风险

1. **主机冷启动未实测**。任务为 `AtLogOn` 触发器，本轮用 `Start-ScheduledTask` 模拟，未真正重启主机。
2. **`wsl --shutdown` 后不会自动触发**。该动作没有登录事件；需要手动运行
   `Start-ScheduledTask -TaskName 'ClashOfRust-WslEgress-Autostart'`，或打开应用执行 Start。
3. **Ubuntu-22.04 必须保持运行**。刷新任务每约 60 秒检查一次，任一受管发行版停止即关闭端点并
   `blocked`。自启任务会在登录时启动它，但用户手动停止后不会自动拉起。
4. **Clash 模式回写风险**。已把 `settings.json` 的 `run_mode` 改为 `rule`，但运行中的应用内存
   仍是 `global`；若应用在退出或设置变更时回写，可能退回。建议在应用界面确认模式显示为"规则"。
5. **自动恢复脚本依赖产品私有函数**（`Read-WslEgressState`、`Invoke-WslEgressLinux`、
   `Get-WslEgressDistributions`）。产品升级改变模块内部结构时脚本会失效，升级后需复验。
6. **本轮未做的验收**：fail-closed 隔离断连测试、逐跳丢包定位、主机重启、网卡切换、Docker 受管
   出口、`/mnt/c` 隐藏、Chrome/Claude Desktop 启动与登录。

## 7. 回退

按影响从小到大：

1. **关闭自动恢复**：`Unregister-ScheduledTask -TaskName 'ClashOfRust-WslEgress-Autostart' -Confirm:$false`
2. **恢复 Clash 模式**：控制器 `PATCH /configs {"mode":"global"}`，并用
   `clash-settings.before.json` 覆盖 `settings.json`。
3. **关闭隧道并恢复原始网络**：产品 `Rollback -RestoreOriginalNetwork`（需所有发行版停止）。
4. **恢复发行版旧状态**：从两个发行版的 `/root/cor-egress-stale/` 移回 payload 与 journal。
5. **恢复 journal 修复前状态**：`run3/02-journal-before-repair.json`。

回退顺序应为 3 → 4（先让产品自己收尾，再恢复被移走的旧代文件），不要反向覆盖。
