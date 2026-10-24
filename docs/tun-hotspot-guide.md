# TUN × 热点(ICS) 完整排查与操作指南

- 日期：2026-10-24（全天排查，30+ 轮受控实验）
- 关联：[详细分析文档](clash-tun-failure-analysis-2026-10-24.md) §12.1–12.26 | [mihomo #3186](https://github.com/MetaCubeX/mihomo/issues/3186)
- 状态：**根因已定位，上游已知未修，本机已有可用配置**

---

## 1. 问题概述

| 症状 | 触发条件 |
|---|---|
| 国内网站全部超时、DNS 部分失败 | Windows 移动热点(ICS) + mihomo TUN 同时开启 |
| 国外网站经 VPS 大部分可用但吞吐下降 58–74% | 同上 |
| "只有上行没有下行" | TUN 开启后内核自身出站回环 |

## 2. 根因（已确认，上游 mihomo #3186）

**Windows 热点/ICS 启用的 WinNAT 在 WFP 层压制 mihomo 对自身流量的豁免**——凡未绑定物理网卡的出站（DNS 模块、DIRECT 直连）被重定向回自己的 TUN，形成回环超时。绑定网卡的节点拨号不受影响但降速。

| 拨号类型 | 豁免方式 | 热点关 | 热点开 |
|---|---|---|---|
| 节点拨号（国外流量） | 主动绑定物理网卡 | ✅ 正常 | ✅ 存活但吞吐-58~74% |
| DIRECT 拨号（国内流量） | WFP 自豁免 | ✅ 正常 | ❌ 回环超时 |
| DNS 模块（域名解析） | WFP 自豁免 | ✅ 正常 | ❌ 回环（IP式DoH可救） |

## 3. 排查时间线（关键节点）

| 时段 | 事件 | 结论 |
|---|---|---|
| 00:06–02:39 | 用户独立五组对照实验 | 排除订阅、网卡、WFP 脚本残留 |
| 02:05–03:40 | 本代理首轮诊断 | 定案"内核自出站回环"；IP排除路由可救 |
| 03:42–05:15 | 内核 A/B + 官方0.6.2部署 | 排除内核版本；官方版同样失败 |
| 11:20–12:50 | 合并上游0.6.3 + TUN修复部署 | IP式DoH+自动排除生效 |
| 13:10–14:40 | 环境隔离 → **发现真凶** | 禁用VirtNet/TAP后TUN全通 → **热点才是元凶** |
| 14:50–15:10 | A/B/C三面实证 | 热点开关=症状开关；确认ICS/WinNAT破坏自豁免 |
| 15:20–16:10 | 深度体检（两窗口对照） | 20站矩阵+吞吐量化+58条SynSent证据 |
| 16:20–17:50 | 机制分析+上游核实 | mihomo #3186 已知未修；补充评论已提交 |
| 18:10–19:00 | 国内走节点方案验证 | 全局模式下全通；DeepSeek修复 |

## 4. 本机所有修改清单

### 4.1 代码修改（`merge-upstream-0.6.3` 分支，提交 `cca5c14`）
- 合并上游 0.6.3（34提交），保留 WSL Secure Egress
- **已回退**：IP式DoH默认（用户要求恢复上游原版域名式DoH）
- **保留**：生成器自动注入 `route-exclude-address`（节点IP+DNS IP+本地网段）

### 4.2 订阅配置（profile `28b1ea79`）
| 修改 | 目的 | 状态 |
|---|---|---|
| `DOMAIN-SUFFIX,deepseek.com,XUAN-VPS` | DeepSeek 经节点（绕开 CM CDN 问题） | **当前生效** |
| `DOMAIN-SUFFIX,bigmodel.cn,DIRECT` + campus DNS 钉扎 | bigmodel 校园直连 | **当前生效** |
| `DOMAIN-SUFFIX,z.ai,DIRECT` + campus DNS 钉扎 | zcode 校园直连 | **当前生效** |
| `route-exclude-address`: 校园网段 + AI 端点 IP | TUN 下直连豁免 | **当前生效** |
| ~~deepseek campus DNS 钉扎~~ | ~~已移除（导致 CM CDN 问题）~~ | 已删除 |

### 4.3 系统级
- 卸载 VirtNet/TAP 驱动（已证明无罪但仍卸载，无使用者）
- Windows 还原点 `before-remove-VirtNet-TAP-drivers`
- 驱动备份 `D:\Clash\backups\driver-orphan-20261024`

## 5. 最终可用配置（三档）

### 日常（热点关）— 推荐默认
```
cor proxy system   # 系统代理模式
cor mode rule      # 规则分流
```
全部功能正常，国内外全通，延迟最优。

### 热点 + TUN 共存 — 需要共享网络时
```
cor proxy system   # 先确保系统代理
cor mode global    # 切全局（控制器可达时切！）
cor proxy tun      # 再开 TUN
（开热点）           # 随时可开
```
国内公网+国外+AI 全通（经 VPS 绕行），延迟升高、吞吐约半速。**校园内网不可达**。

### 热点 + 不开 TUN — 备选
```
cor proxy system   # 系统代理模式（不开 TUN）
（开热点）           # 手机连热点（但流量不经 VPS）
```
PC 一切正常，手机流量直接出校园（不经 mihomo）。

## 6. 已知遗留问题

| 问题 | 状态 | 说明 |
|---|---|---|
| mihomo #3186 热点×TUN 硬冲突 | **上游未修** | [issue](https://github.com/MetaCubeX/mihomo/issues/3186)，已提交补充评论 |
| 校园内网在全局模式下不可达 | 架构限制 | 纯内网服务任何 VPS 都到不了 |
| api.deepseek.com 偶尔 CM CDN 抖动 | 低频 | 经节点可绕开（当前配置） |
| GUI 偶发空白窗口 | control.json 残留 | 删 `%LOCALAPPDATA%\clash-of-rust\ClashOfRust\data\control.json` 后重启 |
| PowerShell `Invoke-WebRequest` 4xx 误报 ERR | 测试工具 | 用 `curl` 验证真实状态码 |

## 7. 常用操作速查

```powershell
# 日常
cor start                    # 启动内核（CLI 模式）
cor status                   # 查看状态
cor proxy system             # 系统代理
cor mode rule                # 规则模式

# 热点场景
cor mode global              # 切全局（先切！）
cor proxy tun                # 开 TUN
cor proxy system             # 回系统代理
cor mode rule                # 回规则模式

# GUI
# 直接打开 D:\Clash\Clash of Rust\clash-of-rust.exe

# 故障排查
curl -x http://127.0.0.1:17890 https://www.baidu.com/   # 测试代理
curl https://api.deepseek.com/                           # 测试 AI 端点
Get-NetAdapter -IncludeHidden | ?{ $_.Name -eq "Meta" } # TUN 状态
```
