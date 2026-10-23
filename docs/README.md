# 项目文档索引

本仓库是 [Fu021/Clash-of-Rust](https://github.com/Fu021/Clash-of-Rust) 的 fork，包含上游
Clash of Rust 客户端与 **WSL Secure Egress / Clash of WSL** 分支工作。

本文档是仓库 `docs/` 的总入口。详细技术结论以各文档为准；状态标记：

- **现行**：当前仍适用，可作为操作或设计依据。
- **历史**：记录某次实际运行，不作为当前状态或验收结论。
- **已被取代**：保留追溯价值，内容已被后续文档覆盖。
- **NOT_RUN / BLOCKED**：未执行或受阻，不能当作通过。

## 1. 先读

| 文档 | 内容 | 状态 |
| --- | --- | --- |
| [完整过程文档](PROJECT_PROCESS_2026-10.md) | 需求、计划、实施、验证与未完成项的总过程线 | 现行 |
| [本机配置交接](local-network-handoff-2026-10-15.md) | 本机网络、Clash、WSL、VPS 与回退记录 | 现行 |
| [WSL Secure Egress 产品文档](wsl-secure-egress/README.md) | 功能定位、状态、文档入口 | 现行 |
| [本机运维脚本索引](../scripts/wsl-secure-egress/local-ops/README.md) | 迁移、自动恢复、诊断脚本的用途与回退 | 现行 |
| [安全模型](wsl-secure-egress/SECURITY_MODEL.md) | 信任边界、强制层与非目标 | 现行 |
| [操作指南](wsl-secure-egress/OPERATIONS.md) | 安装、连接、状态、测试、恢复、卸载 | 现行 |

## 2. 需求、调研与设计（2026-10-15）

| 文档 | 内容 |
| --- | --- |
| [需求、证据及方案总纲](wsl-vps-requirements-and-plan-2026-10-15.md) | 用户要求原文、R01–R13 可验证要求、证据等级 |
| [网络架构专家报告](wsl-vps-network-architecture-2026-10-15.md) | 同核心固定入口、透明接管、NAT、DNS 与可行性闸门 |
| [身份与威胁模型](wsl-vps-identity-threat-model-2026-10-15.md) | 公网身份、本地命令、浏览器/CLI/WSLg 边界 |
| [GitHub 项目调查与选型](wsl-vps-github-project-survey-2026-10-15.md) | 透明 TCP/UDP、namespace、DNS 候选与限制 |
| [独立验收与红队评审](wsl-vps-validation-and-review-2026-10-15.md) | 官方证据、测试矩阵 VR-01–VR-17、回退门槛 |
| [接续分析与实施前缺口](wsl-vps-followup-assessment-2026-10-15.md) | 新增要求与实施前缺口 |
| [可视化总览](wsl-vps-design-overview-2026-10-15.html) | 离线 HTML 架构分层与闸门 |
| [WSL 3.0 网络更新与全流量方案](wsl-3-network-updates-and-implementation-plan-2026-10-15.md) | 早期全流量方案 |
| [实施计划（英文）](wsl-secure-egress-plan.md) | 已接受的实施规格与阶段 |
| [WSL 托管网络功能请求](issues/wsl-managed-network-feature-request.md) | 功能请求记录 |

## 3. 产品规范、接口与变更

| 文档 | 内容 | 状态 |
| --- | --- | --- |
| [产品 README](wsl-secure-egress/README.md) | 功能、状态、信任资源、快速开始 | 现行 |
| [安全模型](wsl-secure-egress/SECURITY_MODEL.md) | 威胁边界、强制层、非目标 | 现行 |
| [操作指南](wsl-secure-egress/OPERATIONS.md) | 生命周期与运维 | 现行 |
| [兼容性](wsl-secure-egress/COMPATIBILITY.md) | Windows/WSL 版本、网络模式、不支持项 | 现行 |
| [Linux helper 契约](../scripts/wsl-secure-egress/linux/CONTRACT.md) | Windows 与 Linux 的固定 API | 现行 |
| [WSL 变更](wsl-secure-egress/WSL_CHANGES.md) | Linux 数据面、boot guard、生命周期 | 现行 |
| [Windows 变更](wsl-secure-egress/WINDOWS_CHANGES.md) | Hyper-V 防火墙、profile、guardian、恢复边界 | 现行 |
| [Clash of Rust 变更](wsl-secure-egress/CLASH_UI_CHANGES.md) | UI/控制器最小改动 | 现行 |
| [上游对比](wsl-secure-egress/UPSTREAM_COMPARISON.md) | 与上游主线的差异 | 现行 |
| [审查偏差说明](wsl-secure-egress/REVIEW_DEVIATIONS.md) | 分支范围与审查结论偏差 | 历史 |

## 4. 部署、自动化与工具

| 文档 | 内容 |
| --- | --- |
| [部署手册](wsl-secure-egress/DEPLOY_RUNBOOK.md) | 管理员事务与证据要求 |
| [管理员作业](wsl-secure-egress/ADMIN_JOB.md) | `COR-Full-AdminJob` 的构造与边界 |
| [自动化入口](wsl-secure-egress/AUTOMATION.md) | 命令行与脚本入口 |
| [工作区工具](wsl-secure-egress/WORKSPACE_TOOLS.md) | VPS 门控的 Chrome、Codex CLI、Claude Code CLI/Desktop 安装 |
| [Clash of WSL 组件](../clash-of-wsl/README.md) | 独立安装与常驻服务 |
| [本机脚本索引](../scripts/wsl-secure-egress/local-ops/README.md) | 本机迁移、自动恢复、诊断脚本 |

## 5. 运行与验证记录

| 文档 | 内容 | 状态 |
| --- | --- | --- |
| [测试状态](wsl-secure-egress/TEST_STATUS.md) | 各次实际测试结果与 `NOT_RUN` 项 | 现行（以最新条目为准） |
| [2026-10-18 本机实测](wsl-secure-egress/LOCAL_TEST_2026-10-18.md) | 模型厂商连接与应用可用性 | 历史 |
| [2026-10-19 本地测试记录](wsl-secure-egress/LOCAL_TEST_LOG_2026-10-19.md) | 本地测试日志 | 历史 |
| [2026-10-19 实机验证](wsl-secure-egress/LIVE_VALIDATION_2026-10-19.md) | NAT、UAC、实时状态 | 历史 |
| [2026-10-19 Claude 清理](wsl-secure-egress/LIVE_CLAUDE_CLEANUP_2026-10-19.md) | WSL 内 Claude 相关清理 | 历史 |
| [2026-10-19 工作总结](wsl-secure-egress/WORK_SUMMARY_2026-10-19.md) | 当轮完成项与阻塞 | 历史 |
| [2026-10-19 Ubuntu 26.04 状态](wsl-secure-egress/UBUNTU26_STATUS_2026-10-19.md) | 安装基线 | 已被取代 |
| [2026-10-23 运行态诊断](wsl-secure-egress/DIAGNOSIS_2026-10-23.md) | 迁移前的阻塞与根因分析 | 历史 |
| [2026-10-23 26.04 迁移](wsl-secure-egress/UBUNTU26-MIGRATION-2026-10-23.md) | 迁移、六个根因、失败关闭与主机地址暴露面 | 现行 |
| [2026-10-22 代码审查](wsl-secure-egress/CODE_REVIEW_2026-10-22.md) | 代码级审查记录 | 历史 |
| [2026-10-18 PR #2 审查](wsl-secure-egress/PR_REVIEW_2026-10-18.md) | PR 审查与修复 | 历史 |
| [2026-10-23 Ubuntu-22.04 清理方案](wsl-secure-egress/ubuntu22-cleanup-plan-2026-10-23.md) | 空间清理计划（未执行） | 待执行 |

## 6. 本机网络、VPS 与 AI 域名专项

| 文档 | 内容 | 状态 |
| --- | --- | --- |
| [本机配置交接](local-network-handoff-2026-10-15.md) | 本机网络与回退总记录 | 现行 |
| [版本更新核查](local-update-2026-10-15.md) | 0.5.9 安装与克隆同步 | 历史 |
| [AI 域名与规则清单](ai-domain-inventory-2026-10-15.md) | 已应用/仅登记/共享规则分类 | 现行 |
| [JSON 台账](../config/ai-domain-inventory.json) | 域名管理台账（非部署入口） | 现行 |
| [Claude CLI/Desktop 离线网络分析](claude-app-static-network-audit-2026-10-15.md) | 静态目标分析 | 历史 |
| [Claude 地区线索检测](claude-region-detection.md) | 地区判定线索 | 历史 |
| [VPS OpenAI IPv4 变更](vps-ai-ipv4-change-2026-10-15.md) | 定向路由与回退 | 历史 |
| [VPS Claude IPv4 变更](vps-claude-ipv4-change-2026-10-15.md) | 定向路由与回退 | 历史 |
| [XUAN VPS 资料检索指南](xuan-vps-reference.md) | 旧项目资料定位方法 | 现行（只读参考） |
| [新会话提示词](next-session-prompt.md) | 后续任务模板 | 模板 |

## 7. 上游记录

- [GitHub Actions 工作流](workflows.md)
- [发布说明](releases/)（0.4.x–0.6.x 上游版本记录）

## 8. 维护约定

- 新增运行记录时，先更新 [TEST_STATUS.md](wsl-secure-egress/TEST_STATUS.md)，再在本索引
  与 [完整过程文档](PROJECT_PROCESS_2026-10.md) 中补充入口。
- 未执行的测试写 `NOT_RUN` / `BLOCKED`；不得把超时、不可用或间接证据写成 `PASS`。
- 文档中的端点与主机地址按项目约定处理；本索引和过程文档不复制真实地址。
- 任何会改变 Windows/WSL 网络的操作，先读
  [本机配置交接](local-network-handoff-2026-10-15.md) 与
  [本机脚本索引](../scripts/wsl-secure-egress/local-ops/README.md) 的前置条件。
