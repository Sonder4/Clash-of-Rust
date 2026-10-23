# Ubuntu-22.04 空间清理方案（2026-10-23）

> 本文件记录 Ubuntu-22.04 磁盘占用调查结果与清理方案。调查为只读；2026-10-24
> 执行了 §8 所列步骤，原始方案保留用于追溯。

## 1. 背景与顺序约束

用户目标：先把 WSL Secure Egress 的 manager 从 Ubuntu-22.04 迁移到
Ubuntu-26.04，然后清理 Ubuntu-22.04（占用过大）。

**顺序约束**：Ubuntu-22.04 当前仍是运行中的 manager（持有 `wg0`、nft guard、
`wireguard.key`、`/etc/cor-egress/profile.json`）。在 26.04 接管之前清理 22.04
会影响隧道，因此清理必须排在迁移完成之后。

## 2. 实测占用（只读）

| 发行版 | 总占用 |
| --- | --- |
| Ubuntu-22.04 | **约 30 GB** |
| Ubuntu-26.04 | 约 5.6 GB |

Ubuntu-22.04 顶层分布（MB）：

| 路径 | 大小 | 说明 |
| --- | --- | --- |
| `/root/quarantine-root-repo-copy-20261018` | **17500** | 仓库旧副本，占全盘 58% |
| 其中 `target/` | **17318** | Rust 构建产物 |
| `/home/xuan/.cache` | 2667 | 其中 camoufox 浏览器缓存 2545 |
| `/usr` | 4969 | 含 claude-desktop 579、llvm-14 434 |
| `/var` | 2063 | 其中 journal 809、apt cache 677 |

## 3. 关键发现：quarantine 不能直接删除

`/root/quarantine-root-repo-copy-20261018` 是仓库的一份旧副本
（HEAD `d1ea0a7`，2026-10-18，分支 `feat/wsl-secure-egress`，remote
`Sonder4/Clash-of-Rust`）。该提交已是真实仓库 `E:\...\Clash-of-Rust`
的历史祖先，`target/` 最新产物时间为 2026-10-17 20:50，无任何进程占用。

**但它含有 18 个真实仓库中不存在的未跟踪文件**（已用 PowerShell 从 Windows 侧
逐一确认 `Test-Path` 为 `ABSENT`）。其中数份是 `AGENTS.md` 明确要求每个会话
必读的文档：

- `docs/local-network-handoff-2026-10-15.md` —— 交接文档
- `docs/xuan-vps-reference.md` —— VPS 资料检索指南
- `docs/next-session-prompt.md` —— 后续会话提示词模板
- `config/ai-domain-inventory.json` —— 域名管理台账
- `docs/claude-app-static-network-audit-2026-10-15.md`
- `docs/ai-domain-inventory-2026-10-15.md`
- `docs/local-update-2026-10-15.md`
- `docs/vps-ai-ipv4-change-2026-10-15.md`
- `docs/vps-claude-ipv4-change-2026-10-15.md`
- `docs/wsl-3-network-updates-and-implementation-plan-2026-10-15.md`
- `docs/wsl-vps-design-overview-2026-10-15.html`
- `docs/wsl-vps-followup-assessment-2026-10-15.md`
- `docs/wsl-vps-github-project-survey-2026-10-15.md`
- `docs/wsl-vps-identity-threat-model-2026-10-15.md`
- `docs/wsl-vps-network-architecture-2026-10-15.md`
- `docs/wsl-vps-requirements-and-plan-2026-10-15.md`
- `docs/wsl-vps-validation-and-review-2026-10-15.md`
- `config/claude-app-endpoints-2026-10-15.json`

直接 `rm -rf` 会永久丢失这些资料。

## 4. 已完成的安全备份（只读，未删任何东西）

18 个文件已复制到：

```
C:\Users\xuan\AppData\Local\Temp\wsl-egress-migration-20261023T\quarantine-unique-files\
```

共 18 个文件、452 KB。**已用 sha256 逐一比对，18/18 完全一致，0 失败。**

## 5. 可安全回收空间（约 22.8 GB）

| 项目 | 大小 | 性质 | 风险 |
| --- | --- | --- | --- |
| `quarantine/target/` | **17.3 GB** | Rust 构建产物，6 天前，无进程占用 | 无（独有文件已备份） |
| camoufox 浏览器缓存 | 2.5 GB | 可重新下载 | 低 |
| rustup stable toolchain | 1.7 GB | 全盘无其他 cargo 项目 | 低 |
| systemd journal | 809 MB | 日志，可 `vacuum` | 无 |
| apt cache archives | 677 MB | 已下载 deb，纯缓存 | 无 |

合计约 22.8 GB，占当前 30 GB 的 76%。

**绝对不动**：`/var/lib/cor-egress`、`/etc/cor-egress`、
`/usr/local/lib/cor-egress`（合计 212 KB，隧道与 guard 依赖）。

## 6. 待确认事项

1. 那 18 个独有文件是否提交进仓库 Git？考虑到 `AGENTS.md` 引用其中多份，
   提交进 Git 比留在 WSL 临时目录更持久。
2. `camoufox`（2.5 GB）、`claude-desktop`（579 MB）、`firefox`（320 MB）、
   `llvm-14-dev`（434 MB）是否仍在用？这些是用户自装工具，需用户确认。
3. 清理排在 Ubuntu-26.04 迁移完成之后。

## 7. 未完成项（NOT_RUN）

- 清理本身未执行。
- Ubuntu-26.04 迁移未执行（需管理员提权 + 停掉所有 WSL 发行版）。
- fail-closed 验收、冷启动、主机重启、切换网络、Docker 受保护出口均未验证。
- 未宣称任何端到端出口结论。

## 8. 2026-10-24 执行记录

前提确认：

- Ubuntu-26.04 已接管 manager；Ubuntu-22.04 为普通发行版，保持运行。
- 18 个 quarantine 独有文件已在提交 `5078347` 恢复到仓库；临时备份
  `%TEMP%\wsl-egress-migration-20261023T\quarantine-unique-files\` 仍在（18/18）。
- 未触碰 `/var/lib/cor-egress`、`/etc/cor-egress`、`/usr/local/lib/cor-egress`。

| 项目 | 操作 | 回收 |
| --- | --- | --- |
| `/root/quarantine-root-repo-copy-20261018/target` | `rm -rf` | 约 17 GB |
| systemd journal | `journalctl --vacuum-size=100M` | 696 MB |
| apt cache archives | `apt-get clean` | 677 MB |
| pip / fontconfig cache | 删除 `~/.cache/pip`、`~/.cache/fontconfig` | 约 123 MB |
| camoufox 缓存 | 删除 `~/.cache/camoufox` | 2.5 GB |
| rustup 工具链与 cargo | 删除 `~/.rustup`、`~/.cargo` | 1.7 GB + 21 MB |
| llvm-14-dev | `apt-get purge -y llvm-14-dev` | 277 MB |

保留：

- `claude-desktop`（579 MB）：用户选择保留。
- `llvm-14` / `clang-14`：`llvm-14-dev` 删除后仍安装；`/usr/lib/llvm-14` 剩余约 190 MB。
- `quarantine` 仓库副本其余部分（约 47 MB）。
- `/var/lib/cor-egress`、`/etc/cor-egress`、`/usr/local/lib/cor-egress`。

结果：`/` 已用从 30 GB 降至约 6.6 GB，回收约 23.4 GB。

清理后的联通性：

- Windows 关键地址：`ipgw.neu.edu.cn` 302、`api.okinto.com` 200。
- WSL 隧道当时为 `phase=blocked`、端点规则 `Enabled=False`，WireGuard 最后握手约
  1 小时 13 分钟前。这是清理前已存在的 fail-closed 状态，删除项不涉及 cor-egress。
  用户选择暂不恢复，保持关闭。
- 因此本轮没有 WSL 出网验收；恢复需运行登录任务或产品 `Start`。

未执行：`apt-get autoremove`（会移除其他自动安装依赖，未授权）、删除
`claude-desktop`、恢复 WSL 隧道，以及既有的主机重启/网卡切换等未测项。
