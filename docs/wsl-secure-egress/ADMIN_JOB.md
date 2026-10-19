# COR-Full-AdminJob 管理员作业

`scripts/wsl-secure-egress/COR-Full-AdminJob.ps1` 是 WSL Secure Egress 的一次性主机部署作业。它只负责管理员阶段的主机 ACL、受保护包升级、broker 启动和实机验收；WSL Linux 组件仍由 `WslSecureEgress.psm1` 与 `linux/manager.py` 管理。

运行方式：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\wsl-secure-egress\COR-Full-AdminJob.ps1
```

脚本先检查当前令牌是否同时满足管理员角色和 High integrity。中完整性令牌会通过 `Start-Process -Verb RunAs` 请求一次 UAC；取消或无法提权时只写 `FAILED.txt`，不会继续改动主机网络。也可以用 `-NoSelfElevation` 做只读前置验证，确认当前终端不具备管理员令牌时立即失败。

阶段顺序固定为：

1. 修复工作树、管理员工作目录和包 staging 的 ACL，并读取 `.git\HEAD` 作为回读证据。
2. 生成受保护 manifest，执行 `Upgrade-Package.ps1` 的 `Apply` 和 `Commit`，每个子进程非零立即停止。
3. 使用固定 WireGuard profile 启动已安装 broker。
4. 在 `Ubuntu-26.04` 中断言德国 VPS IPv4 `62.84.164.122`、DNS 可解析、IPv6 阻断、`ipconfig.exe` 不可用以及 `cor_egress_guard` 存在。

只有所有阶段和断言都通过才会写入 `DONE.txt`。失败会写入 `FAILED.txt` 和 `REPORT.txt`，保留 fail-closed 状态；旧的 `DONE.txt` 会在每次运行开始时删除，避免把历史结果误当成当前成功。

## 2026-10-19 实机记录

手动执行旧版作业时，终端标题虽然显示“管理员”，令牌实际为：

```text
Mandatory Label: Medium Mandatory Level
Administrators: Group used for deny only
```

因此旧作业的 ACL 修复为 `0/1`，manifest 创建失败，broker 返回 `blocked`，Ubuntu 继续保持 `nameserver 10.77.0.1` 和 nftables 默认拒绝。该结果是 fail-closed，不能当作网络验收通过。

新作业已在普通令牌下用 `-NoSelfElevation` 做语法和失败门控验证，结果为退出码 `1` 并写入 `FAILED.txt`；尚未把管理员 UAC 授权视为成功，也未把未执行的出口 IP 测试标记为通过。
