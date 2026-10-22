# 本轮工作总结（2026-10-19）

## 1. PR 审查意见处理

**结论**：附加到 fork PR 的 5 条审查意见，在当前 head 中已经全部实现且有测试覆盖。
本轮逐条核对源码与测试后，未发现仍需修改的产品代码，因此没有改动这 5 处。

| # | 意见 | 位置 | 实现 |
| --- | --- | --- | --- |
| 1 | Install/Start 必须要求 profile_path | `crates/client-core/src/wsl/request.rs:185-190` | `matches!(Install\|Start)` + `execute` + 空 `profile_path` 返回 `MissingProfile` |
| 2 | 未装 Linux manager 时也能回退 | `WslSecureEgress.psm1:751-754` 与 `Invoke-WslEgressOperation:1948-1962` | `linux_manager_install_started/installed` 任一为真即拒绝纯 Windows 恢复；否则直接恢复宿主对象，不调用不存在的 Linux helper |
| 3 | 恢复原始网络后应能重装 | `WslSecureEgress.psm1:1807-1808`、`Save-WslEgressRestoredGeneration` | `phase=restored` 时归档旧 journal 后开始新安装 |
| 4 | 每个受管发行版都要装 boot guard | `linux/manager.py:1933-1952` | `distro-config` 角色调用 `ensure_static_boot_guard()`；未知表时 `ensure_boot_emergency_deny()` |
| 5 | VPS 新 unit 允许 inactive | `prepare-vps.py:112` | `is-active` 用 `subprocess.run(...).returncode==0`，**不经过** `run()` 的致命分支 |

第 5 条补充：审查原文说 `run` 会因非零退出码中止，但第 112 行没有走 `run()`，
所以不会中止部署。`provision_unit.py:282-285` 已用 rc=3 固化了该行为（见 :387 的断言）。

## 2. 本轮新增

- `scripts/wsl-secure-egress/tools/install-wsl-tools.sh`
  Ubuntu-26.04 工具链：Node 22.23.3、google-chrome-stable、claude-desktop、
  Claude Code CLI 2.1.302、Codex CLI 0.163.0（均已固定版本），LF 行尾。
- `docs/wsl-secure-egress/LOCAL_TEST_LOG_2026-10-19.md`

## 3. 已执行并通过的本地测试

| 套件 | 结果 |
| --- | --- |
| `linux_static_test.py` | Ran 87, OK (skipped=2) |
| `provision_unit.py` | Ran 26, OK |
| `windows-unit.ps1` | PASS, 165 assertions |
| `windows-workflow.ps1` | PASS, 244 assertions |
| `package-upgrade-unit.ps1` | PASS, 53 assertions |
| `elevation-unit.ps1` | PASS, 21 assertions |
| `cargo test -p clash-client-core wsl` | 27 passed |
| `cargo test --workspace` | 41 passed, 1 环境性失败 |

唯一非通过项：`ordinary_user_can_initialize_desktop_control`
（`apps/desktop/src/platform/mod.rs:159`）。本机 Clash of Rust 客户端正在运行并持有
single-instance mutex，该测试要求桌面端未运行，属环境冲突。跳过该项后为 41 passed。

## 4. GitHub

- Fork：`github.com/Sonder4/Clash-of-Rust`
- 分支：`fix/wsl-recovery-review-20261018`
- 新提交：`cd372af feat(wsl): add Ubuntu-26.04 toolchain installer and local test log`
- PR #3 OPEN
- CI on `cd372af`：`WSL Secure Egress` = success，`CI` = success

## 5. 未完成（需要真实管理员令牌）

1. 恢复 `E:\Desktop\workspace\Project\Clash-of-Rust` 的 ACL。
2. 用新 `manager.py` 更新 `C:\Program Files\Clash of Rust WSL`。
3. 修 `Ubuntu-26.04` 的 `/etc/wsl.conf` 哈希漂移并 `Start -Execute`。
4. 出口验收：`curl -4 https://ifconfig.co/ip` 应等于受保护 profile 中的 VPS IPv4。
5. 断隧道 / 冷启动 / 物理网络切换 fail-closed 验收。
6. `Ubuntu-26.04` 装工具链并测 Claude Code。

### UAC 无法触发的原因

尝试过 `ShellExecuteExW`+`runas`（`SW_SHOWNORMAL` 与 `SW_HIDE`）、
`Start-Process -Verb RunAs`、注册 SYSTEM / Interactive-Highest 计划任务。
最后一次返回 Win32 1223 = `ERROR_CANCELLED`：UAC 对话框在安全桌面弹出后被自动取消，
因为发起进程所在会话没有可交互用户。这是环境限制，不是代码问题。
