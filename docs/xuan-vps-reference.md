# XUAN VPS 资料检索指南

记录日期：2026-10-15。供 `E:\Desktop\workspace\Project\Clash-of-Rust` 下的新会话使用。

旧项目位置：`E:\Desktop\workspace\Project\XUAN_VPS`，简称“旧资料目录”。本指南说明如何定位资料，不包含 SSH 凭据、真实服务器地址、私钥或完整订阅。旧项目中的“已部署”“已通过”属于对应日期的历史描述，不代表本轮实时状态。

先阅读 [本机工作约定](../AGENTS.md) 与 [完整交接](local-network-handoff-2026-10-15.md)。当前只允许文档整理；后续明确获得继续修复指令后，才可开展网络/SSH 操作。

## 1. 如何查找 SSH 连接方式

优先定位以下文件；行号是 2026-10-15 只读检查时的导航，文件变动后需重新搜索。

- [scripts/use-xuan-pc-key.ps1](../../XUAN_VPS/scripts/use-xuan-pc-key.ps1)：约第 2 行起定义 `HostName`、`User`、`Port`；第 8 行使用 `%USERPROFILE%\.ssh\xuan-pc`；第 15 行调用系统 OpenSSH，指定 IPv4、身份文件及 `IdentitiesOnly=yes`。不要把当前默认目标和账户复制进本仓库。
- [scripts/verify-vps.ps1](../../XUAN_VPS/scripts/verify-vps.ps1)：约第 14 行起定义 `SshAlias`、`IdentityFile`、`AddressFamily`，身份文件默认 `%USERPROFILE%\.ssh\id_ed25519`；约第 29 行带有 `BatchMode=yes`、`StrictHostKeyChecking=yes`、超时和地址族选项。这与上一脚本的身份文件不同，不能未经确认任取其一。
- [docs/09-配置与秘密管理.md](../../XUAN_VPS/docs/09-配置与秘密管理.md)：约第 13、14、41 行说明私钥、known_hosts 与系统 OpenSSH 的使用边界。
- [docs/连接与流量转接教程.md](../../XUAN_VPS/docs/连接与流量转接教程.md)：约第 32 行提及旧 SSH 别名。旧教程、README 与当前部署脚本存在参数差异，应以本机已有且核实过的连接方式为准。

查找顺序：先只定位脚本中的参数名和本机身份文件路径，再由用户已有的 SSH 配置或安全凭据来源核实目标与账户。若确有必要读取 `%USERPROFILE%\.ssh\config`，仅限已确定的相关 Host 条目，并在本地使用；不要整份转储或复制到对话/文档。

只检查身份文件是否存在、权限是否合适，不读取私钥正文。检查已有 known_hosts，不删除整个文件、不忽略主机密钥变化、不使用 `StrictHostKeyChecking=no`。出现未知或变更的主机指纹时，应通过可信渠道核验，不能为了连通而自动接受。

获得连接授权并核实本机参数后，可按下列结构使用系统 OpenSSH。它是参数模板，不能原样执行：

```text
ssh.exe -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -i <已核实身份文件> -p <已核实SSH端口> <已核实账户>@<已核实VPS地址>
```

若选择现有 SSH 别名，先核实该别名的 HostName、User、Port、IdentityFile 以及 ProxyJump/ProxyCommand。不要打印 `ssh -G` 的整份输出；只在本地确认需要的字段。资料不足时向用户索取连接方式，不能转而读取下面的禁止文件。

**禁止读取、检索正文或复制：**
`E:\Desktop\workspace\Project\XUAN_VPS\docs\ssh密钥(你不得将该文件内任何内容添加到上下文).txt`。
此限制也适用于递归全文搜索：不要对整个 `docs/` 或项目根目录运行可能命中该文件的内容搜索。

## 2. VPS 提供哪些内容，去哪里找

### 主要代理与订阅

权威端口索引是 [docs/10-端口使用清单.md](../../XUAN_VPS/docs/10-端口使用清单.md)，约第 9–18 行：

- SSH 管理：`22/tcp`。
- HTTPS 订阅：`443/tcp`，文档记录服务为 `xuan-peer-subscription.service`，后续方案包含 Cloudflare 域名入口。
- VLESS Reality：`10443/tcp`，由服务端 sing-box 提供。
- Hysteria2：`444/udp`，由服务端 sing-box 提供。

这些是现有资料中的职责分配，不是本轮探测所得。443 不得复用为代理入站；不要为了客户端配置修改服务端端口。

[docs/08-网络设计.md](../../XUAN_VPS/docs/08-网络设计.md) 约第 22、59 行说明 Windows/Mihomo → VPS/sing-box → 目标网站的链路，以及服务端认证、出站重建、日志和生命周期职责。该文还包含旧 XUAN 栈的 IPv6-only、TUN 和全机 kill-switch 方案，不能直接套用到当前 Chrome 保护。

订阅相关资料与实现入口：

- [docs/11-订阅修复记录-2026-10-07.md](../../XUAN_VPS/docs/11-订阅修复记录-2026-10-07.md)：2026-10-07 的修复范围、服务与监听证据，以及尚需单独确认的 DNS/Cloudflare 条件。
- [server/peer_subscription.py](../../XUAN_VPS/server/peer_subscription.py)、[server/xuan-peer-subscription.service](../../XUAN_VPS/server/xuan-peer-subscription.service)：订阅服务实现与服务单元，定位资料不等于运行或重部署。
- [scripts/manage-peer-01.ps1](../../XUAN_VPS/scripts/manage-peer-01.ps1)、[scripts/generate-peer-01.mjs](../../XUAN_VPS/scripts/generate-peer-01.mjs)：管理/生成入口；其中的 URL、token 和认证参数不得转录到交接文档。

如需核实服务是否仍在运行，应在另行授权后使用最小只读远端检查。不能凭文件存在宣称当前运行正常，也不能因状态未知自动部署。

### 其他已有功能与历史入口

端口清单还记录 HTTP 入站 `8443/tcp`、Docker Registry pull-through proxy `5000/tcp` 和旧 gateway 回环入口；它们不是本次 Chrome 专用代理的必要组成，文档存在不代表现在运行。Docker 功能对应 [docs/docker-registry-加速.md](../../XUAN_VPS/docs/docker-registry-加速.md) 与 [server/docker-registry-proxy.sh](../../XUAN_VPS/server/docker-registry-proxy.sh)。不要为盘点服务访问 Claude 或启动旧 gateway。

`80/tcp` 是有条件的 ACME 预留；`9443/tcp` 是旧订阅端口，后续文档要求迁移后不再监听。旧资料中的本机 `17892` 只是 Chrome 入口规划，不证明当前存在。

## 3. 部署、检查、回滚资料在哪里

- [server/README.md](../../XUAN_VPS/server/README.md)：约第 8、16、21–29 行介绍 overlay、rollback、固定上游、受管 UFW 标记和配置检查。
- [server/xuan-vps-overlay.sh](../../XUAN_VPS/server/xuan-vps-overlay.sh)、[server/xuan-vps-rollback.sh](../../XUAN_VPS/server/xuan-vps-rollback.sh)：服务端部署和回滚实现。不要为确认内容运行脚本。
- [scripts/deploy-vps.ps1](../../XUAN_VPS/scripts/deploy-vps.ps1)：省略 `-Execute` 是部署预检，**仍会通过 SSH 执行远端命令，不是离线只读文件检查**。约第 59、64 行已有远程调用，约第 68 行才是预检退出边界，暂停期间不可运行。
- [scripts/verify-vps.ps1](../../XUAN_VPS/scripts/verify-vps.ps1)：约第 59 行开始真实 SSH，随后查询 sing-box active/enabled/config 和监听，并写入本地 `runtime/checks/`。它是运行检查，不是纯文档读取。
- [docs/05-验收与回滚.md](../../XUAN_VPS/docs/05-验收与回滚.md)：旧验收设计和回退原则，不能替代当前网络保护约束。
- [scripts/validate-profile.ps1](../../XUAN_VPS/scripts/validate-profile.ps1)：非秘密 profile 的校验入口；先阅读脚本及旧项目 AGENTS，只有修改对应 profile 后才按需验证，不为文档整理顺带执行。

远端状态检查也属于联网行为。若后续获得授权，优先只读确认服务状态、预期监听与 UFW，输出脱敏摘要；先识别实际配置来源，再决定是否有变更必要。部署、重启、UFW 和端口变更需要单独纳入方案与回滚，不能混入“查询”。

## 4. 安全的离线检索命令

以下命令只读本地文件，不执行项目脚本、不建立 SSH。先在 Clash of Rust 目录设置旧资料路径：

```powershell
$vpsReferenceRoot = 'E:\Desktop\workspace\Project\XUAN_VPS'
```

仅列文档和脚本文件名，排除秘密目录及用户禁止的密钥文档：

```powershell
rg --files --glob '*.md' --glob '*.ps1' --glob '*.service' `
  --glob '!secrets/**' --glob '!generated/**' --glob '!runtime/**' `
  --glob '!**/*密钥*' --glob '!**/*.key' --glob '!**/*.pem' `
  --glob '!**/node_modules/**' --glob '!**/.git/**' $vpsReferenceRoot
```

只输出已知脚本的参数名与行号，不输出值：

```powershell
rg -n --only-matching `
  'SshAlias|IdentityFile|AddressFamily|HostName|IdentitiesOnly|StrictHostKeyChecking' `
  "$vpsReferenceRoot\scripts\use-xuan-pc-key.ps1" `
  "$vpsReferenceRoot\scripts\verify-vps.ps1" `
  "$vpsReferenceRoot\scripts\deploy-vps.ps1"
```

只在明确白名单中返回相关文件名，再按问题定位需要的章节：

```powershell
rg -l 'VLESS|Hysteria2|xuan-peer-subscription|xuan-vps-managed|回滚|备份' `
  "$vpsReferenceRoot\README.md" `
  "$vpsReferenceRoot\server\README.md" `
  "$vpsReferenceRoot\docs\08-网络设计.md" `
  "$vpsReferenceRoot\docs\09-配置与秘密管理.md" `
  "$vpsReferenceRoot\docs\10-端口使用清单.md" `
  "$vpsReferenceRoot\docs\11-订阅修复记录-2026-10-07.md"
```

不要把 `rg -l` 改成对全目录输出匹配行的搜索；不要递归打印全部 YAML/JSON、日志、`.ssh` 或秘密目录。若需要查看安全规则实现，按已知源文件显式指定路径；配置值须脱敏，不能把秘密打印后再补做清理。

## 5. 已知资料冲突，避免误用

- 早期 server/README 与秘密管理文档写“订阅仅 localhost”，后来端口清单和文档 11 记录认证 HTTPS 订阅。以后者定位最新设计，再单独核实实时状态。
- 旧连接教程包含过时端口检查；以端口清单为检索起点，不能直接运行旧命令。
- deploy-vps 的 `StartPort`、`StartPort+1` 计算不能证明当前协议使用相邻端口；现有清单的 Hysteria2 是 `444/udp`。
- README 的 operational、TUN 自启、kill-switch 和旧脚本结论属于旧 XUAN 栈，不能证明 Clash of Rust、Chrome 断连保护已经完成。
- 本机维护器、WFP 和新 Chrome 策略的阻断项见 [交接文档第 6 节](local-network-handoff-2026-10-15.md#6-恢复前必须修正或查明的问题)，不要直接执行旧 doc13 的安装命令。

## 6. 秘密和项目边界

`secrets/runtime.json`、`generated/`、`runtime/` 以及本机 `.ssh` 中的内容都是“按需要安全定位”的来源，不是待迁移进新仓库的文件。新目录只保存资料索引、脱敏变更和验收结果。

服务器功能资料继续从旧项目读取；本机代理管理从 Clash of Rust 的实际安装与配置核实。保留旧项目不等于继续运行旧客户端栈，停止旧栈也不等于应卸载 VPS 的 sing-box 或订阅服务。不要把旧客户端清理扩大为服务端删除。
