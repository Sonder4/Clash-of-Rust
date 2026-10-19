# WSL Secure Egress 部署手册（实机执行）

本文件记录在实机上把已安装但 fail-closed 的 WSL Secure Egress 打开为
"全部 WSL 出口经德国 VPS" 所需的完整步骤、阻塞点与验证标准。

## 1. 当前实机状态（已确认，只读检查）

| 项目 | 实际值 |
| --- | --- |
| Windows 账户 | XUAN\xuan（普通令牌，属于 Administrators 组但 Medium integrity） |
| WSL 发行版 | Ubuntu-22.04（Running）、Ubuntu-26.04（Stopped）、docker-desktop（Stopped） |
| `.wslconfig` | `networkingMode=nat`、`localhostForwarding=false`、`dnsTunneling=false`、`firewall=true` |
| Ubuntu-22.04 网卡 | `eth0 172.19.104.128/20`，默认路由 `172.19.96.1` |
| Ubuntu-22.04 DNS | `nameserver 10.77.0.1`（解析失败） |
| Ubuntu-22.04 nft | `table inet cor_egress_guard` 存在（fail-closed guard 生效） |
| Windows 状态 | `installation_complete: true`、`endpoint_enabled: false`、`phase: failed_closed_requested` |
| Hyper-V 持久策略 | `{40E0AC32-...}` Enabled=True、DefaultInboundAction=Block、DefaultOutboundAction=Block |
| Hyper-V 端点规则 | `ClashOfRust-WslEgress-Endpoint` Outbound/Allow/UDP |
| Profile | WireGuard，manager_distro=Ubuntu-22.04，endpoint=62.84.164.122:51820 |
| 实机出口 | `curl -4 https://ifconfig.co/ip` 返回 6（DNS 解析失败），无出口 |

结论：系统已安装但保持 fail-closed。这与设计一致——隧道未启动时不允许任何回退出口。

## 2. 打开隧道的唯一条件：管理员提权

所有写入（包安装、broker 启动、端点放行）都需要 **High integrity + Administrator**
令牌。本机当前进程是 Medium integrity，因此必须先通过 UAC。

实机记录：多次 UAC 请求均被取消或超时，因此没有执行任何主机写入。
失败证据保存在 F:\Codex\admin-job\DEPLOY-LOG.txt。

## 3. 部署前必须修复的两个问题

### 3.1 admin-job 目录中的 COR-Full-AdminJob.ps1 已损坏

F:\Codex\admin-job\COR-Full-AdminJob.ps1 在早期编辑中损坏：

- `Start-SelfElevated` 缺少右花括号
- `function Invoke-Native` 的函数头丢失，因此 `Invoke-Native` 根本不是函数

后果：直接运行该副本会在调用 `Invoke-Native` 时报"不是此作用域中的命令"。

处理：不要使用该副本。仓库中的 `scripts/wsl-secure-egress/COR-Full-AdminJob.ps1`
结构正确（PowerShell AST 解析通过），部署脚本调用的是仓库副本。

### 3.2 cor-package-stage 为空且 ACL 拒绝写入

F:\Codex\cor-package-stage 与 F:\Codex\cor-upload-manifest 均为空，
且目录 ACL 拒绝当前用户写入。这正是上次 stage 2 CreateManifest 失败的原因：

```text
CreateManifest failed ... OpenRead ... F:\Codex\cor-package-stage\clash-wsl-guardian.exe ... 拒绝访问
```

处理：新部署脚本先用 icacls reset 并显式授予 SYSTEM/Administrators/当前用户，
再写入文件。

## 4. 部署步骤（需要一次 UAC）

部署脚本：F:\Codex\admin-job\Deploy-SecureEgress.ps1

```powershell
# 方式 A：直接运行（会自动请求一次 UAC）
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File F:\Codex\admin-job\Deploy-SecureEgress.ps1

# 方式 B：在普通终端里请求提权子进程
Start-Process powershell.exe -Verb RunAs -ArgumentList @(
  '-NoProfile','-ExecutionPolicy','Bypass',
  '-File','F:\Codex\admin-job\Deploy-SecureEgress.ps1','-SkipElevation')
```

脚本顺序（全部 fail-closed，任一子步骤非零即停止）：

1. 校验 High integrity + Administrator 令牌，否则请求 UAC；取消即退出。
2. icacls reset 并显式授予 staging/manifest 目录 ACL。
3. 从 `target\debug` 与 Clash of Rust 安装根复制 `clash-of-rust.exe`、
   `clash-tun-launcher.exe`、`clash-wsl-guardian.exe`、`LICENSE`、
   `uninstall.exe`、`resources\mihomo.exe`。
4. 从仓库 `scripts\wsl-secure-egress` 复制 `resources\wsl-secure-egress` 下的全部脚本
   以及 `linux\` 与 `server\` 子目录。
5. 逐个校验必需文件存在且可 OpenRead。
6. 调用仓库中的 `COR-Full-AdminJob.ps1`，由其完成 ACL 修复、manifest 生成、
   Upgrade-Package Apply/Commit、broker 启动与实机验收。

## 5. 验收标准（脚本必须实际执行通过，不得标为未测通过）

| 检查 | 期望值 |
| --- | --- |
| Ubuntu-22.04 `curl -4 https://ifconfig.co/ip` | `62.84.164.122` |
| Ubuntu-22.04 `getent hosts api.openai.com` | 成功 |
| Ubuntu-22.04 `curl -6 https://ifconfig.co/ip` | 失败（IPv6 必须阻断） |
| Ubuntu-22.04 `command -v ipconfig.exe` | 未找到（interop 必须阻断） |
| Ubuntu-22.04 `nft list tables` | 含 `cor_egress_guard` |
| 作业标记 | F:\Codex\admin-job\DONE.txt 生成 |

只有 DONE.txt 生成才能视为打开成功。FAILED.txt 或没有 DONE.txt 都表示
fail-closed，不能当作网络可用。

## 6. 打开后的模型厂商出口验证

```bash
# 在 Ubuntu-22.04 中执行
curl -4 -fsS https://ifconfig.co/ip            # 必须 62.84.164.122
curl -4 -fsS https://ifconfig.co/country       # 必须 Germany
curl -4 -sS -o /dev/null -w '%{http_code}\n' https://api.openai.com/v1/models
curl -4 -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/v1/models
curl -4 -sS -o /dev/null -w '%{http_code}\n' https://api.deepseek.com/v1/models
```

未认证时 401/403 是正常的；关键是出口 IP 必须是 VPS IP，而不是 Windows 的本地公网 IP。

## 7. 已知限制

- Ubuntu-26.04 未安装 Claude Code / Codex CLI，打开隧道后才能安装。
- docker-desktop 被策略阻断，不作为管理器发行版。
- WSL 中的 IPv6 被彻底阻断，这是按验收要求的设计行为。
