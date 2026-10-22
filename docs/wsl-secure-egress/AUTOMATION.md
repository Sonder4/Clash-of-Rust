# WSL Secure Egress 自动化入口

本目录记录两个可重复执行的入口，把 2026-10-23 恢复 WSL 出网时手工做过的步骤固化为脚本。
两者都遵循本仓库的既有约定：**默认只读**，`-Execute` 才写入；单次变更前立即快照；
不停共享核心、不关 WSL、不重启 WSL VM、不改 VPS、不编译或替换上游应用。

## 1. `Set-WslEgressClashDirectRule.ps1` — 自定义配置

用途：保证 Clash of Rust 当前活动订阅的规则顶部存在一条到 WireGuard 端点的直连规则。

为什么需要它：WSL Secure Egress 的隧道自带 WireGuard 端点。当 `Meta` TUN 适配器持有
默认路由时，该端点被 TUN 捕获，节点自身的 bypass 逻辑把它丢弃，隧道因此永不握手。
2026-10-23 的实测证实了这一点：WSL 侧 `tcpdump` 显示封装包已正常离开 WSL
（`eth0` 上 `172.19.104.128.51821 > 62.84.164.122.51820`，SNAT 已应用），VPS 侧
`cor-wsl0` RX 不增长、`latest-handshakes` 冻结。加上直连规则后握手立即恢复。

为什么改订阅而不是 `runtime/config.yaml`：`apps/desktop/src/engine/mod.rs` 的
`start_core()` 每次启动都用 `atomic_write` 从**活动订阅**重新生成
`runtime/config.yaml`。手改 `config.yaml` 会在下次重启时被覆盖，必须改订阅本身。
`candidate.yaml` 只是 `validate_in()` 跑 `mihomo -t` 的临时文件，不会被复制回
`config.yaml`。

用法：

```powershell
# 只读检查；规则已存在时报 succeeded/changed=false，缺失时报 not_run
./scripts/wsl-secure-egress/Set-WslEgressClashDirectRule.ps1 -EndpointIPv4 <VPS IPv4> -EndpointPort 51820

# 写入；写入前先把当前订阅快照到 %TEMP%\clash-of-rust-rule-backups\
./scripts/wsl-secure-egress/Set-WslEgressClashDirectRule.ps1 -EndpointIPv4 <VPS IPv4> -EndpointPort 51820 -Execute
```

脚本输出单行 schema 化 JSON，包含 `profile`、`backup`、`changed`、`outcome`。
退出码：0 成功，1 失败（异常不外泄内容）。

**它不重启核心。** 规则写入后需要在 Clash of Rust 界面里重启一次，让应用从订阅重新生成
`config.yaml`。这是应用自己的重启路径，脚本不代做。

回退：用输出里的 `backup` 路径覆盖订阅文件，再在界面重启核心。

## 2. `Test-WslEgressDistroConfiguration.ps1` — 初始化配置核查

用途：核对每个受管发行版是否具备其角色应有的产物，并指出缺什么。

WSL Secure Egress 的部署有两类发行版，这是设计分工，不是故障状态：

| 角色 | 持有物 | 是否建隧道 |
| --- | --- | --- |
| manager（`manager_distro`） | `/etc/cor-egress/profile.json`、`/var/lib/cor-egress/wireguard.key`、`/var/lib/cor-egress/scope-attestation.json` | 是，唯一一条 |
| ordinary | 仅 `/usr/local/lib/cor-egress/manager.py` 与 `/etc/wsl.conf`（DNS、interop、boot） | 否 |

manager 只配置 ordinary 发行版的文件半边（见 `WslSecureEgress.psm1` 的
`Invoke-WslEgressDistroConfiguration`）。ordinary 发行版不建第二条隧道：端点只有一个 peer、
一个隧道地址，第二个运行时必然冲突。

用法：

```powershell
./scripts/wsl-secure-egress/Test-WslEgressDistroConfiguration.ps1
./scripts/wsl-secure-egress/Test-WslEgressDistroConfiguration.ps1 -Execute
```

`docker-desktop` 与 `docker-desktop-data` 按模块自身的
`Get-WslEgressOrdinaryDistributions` 规则排除，不算缺失。

如果 manager 产物缺失，脚本报 `blocked` 并拒绝"修复"：那属于完整安装，需要运营者
自己的 profile 与 attestation，不是本脚本能补的。

## 3. 测试

`tests/windows-automation.ps1` 对上述两个脚本做离线静态检查（文件系统、WSL、网络全部
mock），并断言两者都不会停核心、不会 `wsl.exe --shutdown`、不会调 `ssh`。
已接入 `.github/workflows/wsl-egress.yml` 的 `Offline host policy tests` 步骤。

## 4. 本机 2026-10-23 实测记录

| 命令 | 结果 |
| --- | --- |
| `Set-WslEgressClashDirectRule.ps1 -EndpointIPv4 62.84.164.122` | `succeeded`，`changed=false`（规则已在位） |
| 同上换一个未配置地址（dry run） | `not_run`，`changed=false` |
| `Test-WslEgressDistroConfiguration.ps1` | `succeeded`：22.04 为 manager，四项产物齐全；26.04 为 ordinary，两项产物齐全 |
| `tests/windows-automation.ps1` | `PASS: 28 assertions.` |
| `tests/windows-workflow.ps1`（回归） | `PASS`，248 assertions |
| `tests/windows-unit.ps1`（回归） | `PASS`，165 assertions |

## 5. 尚未自动化的部分

以下步骤有意留在脚本之外，因为它们改变运行态或需要人工判断：

- **重启 Clash of Rust 核心**以应用订阅规则。脚本只改订阅文件。
- **完整安装**（manager 产物的生成、VPS 侧 peer、attestation）。需要运营者提供 profile。
- **fail-closed 验收**。会关闭 endpoint，属独立授权项。
- **冷启动、主机重启、睡眠恢复、切换网络、Docker 受保护出口**。需隔离环境或独立授权。
