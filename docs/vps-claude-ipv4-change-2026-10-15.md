# Claude 的 VPS IPv4 出站配置

日期：2026-10-15，操作时间 09:35–09:41，Asia/Taipei。

## 目标与范围

用户明确要求 Claude 也优先使用 VPS IPv4，同时保留本机通过 IPv6 连接 VPS。沿用前一轮 OpenAI 的严格策略：列明目标只经 VPS IPv4 出站，无可用 IPv4 时失败，不回退 IPv6。不是全局禁用 IPv6，也不是把客户端换成 IPv4 节点。

本轮仍只修改远端 `/etc/sing-box/conf/03_route.json`。追加 7 个后缀和 4 个精确主机：

```text
domain_suffix:
  anthropic.com
  claude.ai
  claude.com
  clau.de
  claudemcpclient.com
  claudemcpcontent.com
  claudeusercontent.com

domain:
  anthropic.com.cdn.cloudflare.net
  servd-anthropic-website.b-cdn.net
  anthropic.auth0.com
  anthropic-com.ghost.io
```

`domain_suffix` 覆盖根域及子域，包括 `api.anthropic.com` 等入口。关联主机来自已登记的文章清单，不代表独立完成全部所有权认证。

共享客服、遥测、关键词及 ASN/IP 规则没有新增。现有应用名单另含但来源清单未列的 `claude.app` 未默默追加；未知新域名仍需核验登记。本轮不是全部关联服务或未来域名的无限覆盖保证。

## 原规则与 IPv6 连接保持

- 对新增分类在原 sniff 前后分别加入 IPv6 拒绝、IPv4-only 解析、IPv6 拒绝、现有 direct 出站四条策略，避免权威域名被 ECH 外层名称遮蔽，并覆盖能嗅探分类的 IP 请求。
- 原 19 条规则的内容及相对顺序全部保留，包括前轮 OpenAI 严格 IPv4 规则、旧 fallback、私网/元数据防护和 legacy claude-browser 路由。移除新增的 8 条后，与本轮紧邻备份中的原规则逐项相等。
- 本机实际 Claude 保护组为固定 Selector，叶节点为 Hysteria2，服务器端点为 IPv6。实际凭据匹配 VPS HY2 入站的未命名用户，不是先行终结的 `claude-browser` 用户；后者的历史 gateway 不受本次新增策略覆盖。
- 未改客户端节点、应用设置、DNS 配置分片、全局 DNS、入站、出站、端口、订阅、防火墙、网卡或系统 IPv6；仅改变列明目标的服务器端解析/路由策略。未重启本机应用或核心，未操作 CC Switch。

## 隔离验收与生产访问门槛

隔离实例只监听 VPS loopback，移除复制配置的 endpoints/services、experimental 和 NTP，生产配置不动。它临时将中立 `one.one.one.one` 及 AAAA-only 控制加入相同分类器，测试完成后结束自有进程：

- Cloudflare trace 为 HTTP 200、IPv4、DE，地址匹配 VPS 已分配 IPv4。
- AAAA-only 控制确认无 A 且有 AAAA；同连接日志证明 `resolve(ipv4_only)` 后返回 empty result，没有出站。
- 中立 Cloudflare IPv6 字面量带对应 SNI 测试，同连接日志证明 sniff 后命中 `ip_version=6 => reject`，没有出站。
- 没有在隔离验收中访问 Claude；这两个测试域名未进入生产路由。

生产访问 Claude 前逐项核验：

1. 已生效候选哈希、11 项分类器、IPv4-only 解析和 direct 路由正确，服务 active。
2. 实际客户端 Claude 保护组仍固定 HY2 IPv6；中立 `api.ipify.org` 命中同一保护组。最初尝试核验 `api4.ipify.org` 时发现它不属该组，验证程序安全停止，没有因此访问 Claude；随后改用实际受同组保护的 `api.ipify.org`。
3. 同通路中立探针得到 IPv4；Net.Coffee 和 ipwho.is 对同一精确地址均返回 DE，无冲突。
4. 在 VPS 仅解析 `claude.ai`、`api.anthropic.com` 的 A 记录，逐个检查源路由首选 IPv4 与刚核验的德国出口一致，并确认该地址已分配给 VPS。

全部通过后才经本机代理请求一次 `https://claude.ai/cdn-cgi/trace`：HTTP 200、IPv4、`loc=DE`，地址与前置核验完全相同。随后 ChatGPT trace 回归同样为 HTTP 200、相同 IPv4、DE。没有运行全量检测、登录或请求业务 API。

补充浏览器观察时，用户已将原 Chrome 窗口切换为其他页面；未切换、刷新、恢复或关闭任何窗口，立即结束 Cua 会话。因此本轮的 Claude 实际目标证据来自经同一核心/保护通路的 HTTP 客户端，不冒充新的 Chrome 页面实测。

## 应用、备份与回退

私密远端目录：`/var/backups/clash-of-rust-claude-ipv4/20261015T093651Z`。目录标签来自 VPS 时钟；操作时间以本机日志为准。

- `03_route.immediate-before.json`：本轮紧邻写入前快照，包含已生效的 OpenAI 配置。
- `03_route.before.json`、`03_route.candidate.json`、`manifest.json`：原始、候选和哈希记录。
- `full-config-check/`、`stage.log`、`service-before.txt`：私密配置校验和隔离证据，不纳入 Git。
- `apply-helper.py`、`rollback.py`：本轮应用/恢复程序，仅保存在该私密目录。

为避免共享服务重载截断 SSH 回显，通过一次性 3 秒延迟任务排队应用。应用时再次检查服务、备份和候选哈希，启用 3 分钟定向回退看门狗，随后重载。该版本重载仍可能让代理连接短暂重连；延迟任务不是无损重载保证。

完成生产地区门槛、Claude 实际出口和 OpenAI 回归后才 confirm。最终检查已 verified、未 rolled-back、watchdog timer inactive、服务 active，所有配置分片与校验快照一致。

如确需撤回本轮 Claude 配置，先取两个关键网址的新基线，确认没有后续变更，再在已核实 VPS 上执行：

```text
python3 /var/backups/clash-of-rust-claude-ipv4/20261015T093651Z/rollback.py
```

此恢复只回到本轮即时快照，保留前轮 OpenAI 配置。程序以共享锁及候选/备份哈希防止覆盖后来变更，恢复配置并 reload（若服务已退出则 start），之后检查 active。恢复会短暂重连，需再次核验两个关键地址。前轮 OpenAI 的回退脚本因当前文件不再等于它的候选哈希，会拒绝直接覆盖；不要绕过保护。

## 关键连通性及剩余限制

09:35、09:37、09:39 及 09:41:25，正常主机通路 DNS 正常，校园认证 HTTP 302、API HTTP 200，TLS 证书校验值均为 0。关键通路没有改道或跳过证书验证。

共享第三方、不能归属的 IP 字面量、无法嗅探的 ECH/QUIC、旧 legacy gateway 用户和未来新增域名不在本轮保证范围。未进行全量功能、UDP/QUIC、DNS 泄漏或断连保护验收，不能宣布全部功能或任意网络零泄漏。

域名管理状态同步到 [清单](ai-domain-inventory-2026-10-15.md) 与 [JSON](../config/ai-domain-inventory.json)：OpenAI 20 加 Claude 11，共 31 个明确应用的匹配器。台账仍不是自动部署入口。
