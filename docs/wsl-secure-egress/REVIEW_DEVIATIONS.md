# 审查偏差说明：WSL Secure Egress 分支范围

本分支（`fix/wsl-recovery-review-20261018`）相对上游的改动量明显大于
常规缺陷修复。审查提出“130 个文件 / +26k 行超出最小改动目标”。本文件记录
为什么这些改动属于同一目标，以及哪些部分是刻意偏离上游行为的。

## 目标本身要求较大的新增面

用户目标是让 WSL 成为一个可安装的受管工具：管理员安装、常驻后端管理 WSL
网络、客户端只提供最小 UI 与状态。上游没有任何 WSL 网络策略、受保护
profile、Hyper-V 防火墙或 Linux fail-closed 组件，因此这部分只能是新增
文件，而不是对既有文件的修补。

新增面主要落在：

- `scripts/wsl-secure-egress/`：Windows broker、包升级、快照、离线测试；
- `scripts/wsl-secure-egress/linux/`：`manager.py`、nftables 守卫、启动守卫；
- `apps/desktop/src/application/wsl/`、`client-core` 的 `wsl` 模块与
  `wsl.slint`：最小 UI 与状态；
- `docs/wsl-secure-egress/`：部署、验收、测试状态。

## 刻意偏离上游的行为

1. **停用官方自动更新**（`apps/desktop/src/update/mod.rs` 的
   `SELF_UPDATE_ENABLED = false`）。

   上游 Release 安装包不含本 fork 的 WSL 策略所有者（Hyper-V 防火墙设置、
   Endpoint 规则、Linux 守卫与 broker 服务）。允许官方更新直接覆盖会静默
   移除这些组件，使 WSL 在无提示的情况下回到普通 NAT 出口。

   重新启用的前置条件是存在 fork 自有、且经审查确认保留 WSL 组件的更新
   通道与迁移逻辑。在那之前，UI 明确显示“已停用官方自动更新，请使用经
   审查的 fork 安装包”，不会静默失败。

   这不是遗漏，而是有意的安全取舍；审查项按“已记录偏差”处理。

2. **不编译、不替换上游应用源码之外的运行时**。WSL 组件只通过受保护包
   升级路径更新，不通过官方更新器。

## 已在本轮修正的偏差

- 删除项目自带的常驻 UAC worker（P0）。
- 管理员作业不再内嵌 VPS IPv4、profile 摘要或 `F:\Codex` 路径（P1）。
- 取消对工作树的整树递归 ACL 重写（P1）。
- 安装器不再默认写入 VPS 地址（P1）。
- 停止跟踪宿主机系统备份文件（P2）。

## 仍然开放的偏差

- 本仓库 Git 历史中仍保留真实 VPS IPv4 的旧提交。该 fork 为公开仓库，
  改写历史会破坏已有 PR 与审查记录，因此本轮只从当前文件移除，未改写
  历史。若需要彻底清除，应另开一次经确认的历史重写。
- 自动更新通道仍关闭，见上文。
