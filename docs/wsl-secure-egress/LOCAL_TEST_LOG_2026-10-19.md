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
