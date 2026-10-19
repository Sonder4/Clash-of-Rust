# 本地测试记录（2026-10-19）

## 已执行的离线测试（全部 PASS）

| 套件 | 命令 | 结果 |
| --- | --- | --- |
| Linux 静态 | `py -B scripts/wsl-secure-egress/tests/linux_static_test.py` | Ran 87 tests, OK (skipped=2) |
| VPS 供应 | `py -B scripts/wsl-secure-egress/tests/provision_unit.py` | Ran 26 tests, OK |
| Windows 单元 | `pwsh tests/windows-unit.ps1` | PASS, 165 assertions |
| Windows 工作流 | `pwsh tests/windows-workflow.ps1` | PASS, 244 assertions |
| 包升级 | `pwsh tests/package-upgrade-unit.ps1` | PASS, 53 assertions |
| 提权 | `pwsh tests/elevation-unit.ps1` | PASS, 21 assertions |
| Rust WSL | `cargo test -p clash-client-core wsl` | 27 passed |
| Rust 全量 | `cargo test --workspace` | clash-of-rust: 41 passed / 1 skipped |

## 唯一非通过项（环境性，与本次改动无关）

`platform::application_guard_tests::ordinary_user_can_initialize_desktop_control`
在 `apps\desktop\src\platform\mod.rs:159` 失败，报 `test desktop must not have an existing GUI`。

原因：本机 Clash of Rust 桌面客户端（PID 53184）正在运行并持有 single-instance mutex，
该测试要求测试时桌面端未运行。属于环境冲突，不是代码缺陷。复测命令：

```
cargo test -p clash-of-rust --lib -- --skip ordinary_user_can_initialize_desktop_control
```

跳过后 41 passed / 0 failed。

## 尚未执行（需要管理员权限 + 实机 WSL）

- `Start -Execute` 与出口 IP 验收
- 断隧道 / 冷启动 / 物理网络切换 fail-closed 验收
- Windows WSL NAT 切换与 Hyper-V Firewall 实际写入

## 2026-10-19 08:54-09:00 追加实机记录

手动运行 `F:\Codex\admin-job\COR-Full-AdminJob.ps1`。作业进入 UAC
请求，但系统返回：

```text
elevation cancelled: This command cannot be run due to the error: The operation was canceled by the user.
```

因此没有执行管理员阶段，也没有生成 `DONE.txt`。只读检查结果如下：

| 检查 | 实际结果 |
| --- | --- |
| Ubuntu-22.04/26.04 地址 | `eth0` 为 `172.19.104.128/20` |
| 默认路由 | `172.19.96.1` |
| DNS | `10.77.0.1`，解析失败 |
| `curl -4/-6 ifconfig.co` | 均因 DNS 失败退出 |
| `getent hosts api.openai.com` | 失败 |
| `nft list tables` | 非 root 只读检查返回权限错误；未宣称 guard 通过 |
| Hyper-V managed endpoint | 保持禁用 |

这组结果说明当前 WSL 处于受保护但未连接状态；在 UAC 成功前不能测试
德国 VPS 出口，也不能启动 Claude Code、Codex CLI 或 Claude Desktop 的联网验收。

## 2026-10-19 09:00 热重启与工具盘点

执行 `wsl.exe --shutdown` 返回 `0`，随后启动 `Ubuntu-26.04`。重启后仍为
NAT 地址 `172.19.104.128/20`、默认路由 `172.19.96.1` 和
`nameserver 10.77.0.1`；`getent hosts api.openai.com` 返回码 `2`，
`curl -4/-6 https://ifconfig.co/ip` 均返回码 `6`（DNS 解析失败）。
热重启没有恢复出口，仍保持 fail-closed。

重启后工具盘点：

| 发行版 | Claude Code | Codex CLI | Chrome/Chromium |
| --- | --- | --- | --- |
| Ubuntu-22.04 | `/usr/bin/claude`, `2.1.302` | 未安装 | 未发现 |
| Ubuntu-26.04 | 未安装 | 未安装 | 未发现 |

因此 `Ubuntu-26.04` 尚未达到工具安装验收条件；安装包下载和 Claude/OpenAI
真实 VPS 出口测试必须等待管理员隧道启动成功。
