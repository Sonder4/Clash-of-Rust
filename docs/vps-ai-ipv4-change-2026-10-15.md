# VPS OpenAI IPv4 出站变更记录

日期：2026-10-15。本机操作时间为 Asia/Taipei。此记录不包含服务器地址或凭据。

本文记录截至 09:26 的 OpenAI 变更。用户后来另行授权的 Claude IPv4 配置与最新回退见 [后续 Claude 变更](vps-claude-ipv4-change-2026-10-15.md)；本文“Claude 未新增”等表述为此前历史状态，不代表后续未实施。

## 授权与定位

用户明确授权 SSH 连接 VPS 并完成配置，随后要求根据两个 `site.html` 建立可维护域名清单。本机已有别名实际为 `ciallo`（用户表述 caillo）；安全比较其 SSH HostName 与当前应用节点端点一致后，使用已有密钥和 `StrictHostKeyChecking=yes` 连接。未读取禁止的密钥文档。授权覆盖本文操作，不再沿用早先仅文档/暂停范围；Claude/Anthropic 的对应德国出口门槛仍有效。

实际服务端为 `/etc/sing-box/sing-box`，版本 `1.15.0-alpha.1`，生产启动参数 `run -C /etc/sing-box/conf`。原规则对 `api.openai.com` 使用 `prefer_ipv4`，对 `geosite-openai` 使用 `prefer_ipv6`，二者都不是严格 IPv4-only。这解释了客户端到 VPS 即使使用 IPv4，目标网站仍可能观察到 VPS IPv6。

## 实际修改

仅修改远端 `/etc/sing-box/conf/03_route.json`。

在原 sniff 前后分别插入专属域名分类策略：

1. 分类到的 IPv6 字面量拒绝。
2. 域名执行 `resolve strategy=ipv4_only`。
3. 再次拒绝分类到的 IPv6。
4. 路由现有 `direct`。

前置分类保留 CONNECT 原始域名的权威性，避免被 TLS/ECH 外层域名遮蔽；后置分类覆盖能嗅探识别的 IP 请求。该版本 resolve 错误直接终止连接，不会回落到旧策略使用 IPv6。

保留原私网/元数据地址防护、legacy claude-browser 规则及原 sniff；原 OpenAI 三条规则留在新策略之后，维持未纳入专属清单的旧行为。未改 DNS 配置分片或全局 DNS 设置，仅调整目标路由的 IPv4-only 解析策略；outbound、WARP endpoint、订阅、入站、端口和防火墙未改，未禁用任一侧系统 IPv6。未改客户端配置/源码、Chrome 策略或本机网络规则，未重启本机核心，未安装软件，未操作 CC Switch。

完整来源清单及应用状态见 [域名清单](ai-domain-inventory-2026-10-15.md) 和 [机器可读清单](../config/ai-domain-inventory.json)。共享第三方域名、关键词和 ASN 不直接套用为专属规则。Claude 条目仅登记，本轮未新增其服务端 IPv4 策略，也未访问 Claude。

## 备份与回退

远端私密目录：`/var/backups/clash-of-rust-ai-ipv4/20261015T091948Z`。目录标签来自 VPS 自身时钟，不替代本机操作时间。

- `03_route.before.json`：隔离验收时原始目标文件。
- `03_route.immediate-before.json`：紧邻写入前再次复制，并核对哈希的恢复文件。
- `03_route.candidate.json`、`full-config-check/`：候选及实际配置分片的校验副本。
- `manifest.json`、`service-before.txt`、`stage.log`：哈希、状态及隔离证据，仅留远端私密目录。
- `rollback.py`：共享锁和当前候选哈希保护的单文件恢复程序；备份哈希不匹配或发生后续修改时拒绝覆盖。

生产应用前开启 3 分钟定向回退看门狗。复验关键地址和实际目标出口后确认保留，解除计时器；最终确认 timer inactive、未执行回退。

该版本 SIGHUP 会 close/recreate 实例，不是无损重载。应用期间 SSH 回显连接曾异常退出一次；没有盲目重试 apply。重连只读确认候选已写入、应用记录已完成、服务 active，然后复验并 confirm。现有代理连接可能需要重连，不能声称完全无中断。

需要恢复时，先取得关键地址基线，确认没有后续配置变更，再通过同一已核实 SSH 别名执行远端：

```text
python3 /var/backups/clash-of-rust-ai-ipv4/20261015T091948Z/rollback.py
```

手工调用不受 `verified` 标记阻止，但仍受候选/备份哈希及锁保护。它只恢复本轮目标路由文件，校验配置，服务 active 时 reload、已退出时 start，并检查 active。恢复会短暂重连，随后必须复验两关键网址。不要用全量旧备份覆盖后来修改。

## 验证

- 09:09、09:16、09:20、09:22 和 09:26 正常主机通路复验：校园认证 HTTP 302、API HTTP 200、DNS 正常、TLS 校验值 0。API 活跃连接实际为 `DIRECT`，校园认证正常本地通路保持可用。
- 隔离实例仅监听 VPS loopback HTTP，移除复制配置的 endpoints/services、experimental、NTP，不改变生产 endpoint。正例 ChatGPT trace 为 HTTP 200、IPv4、`loc=DE`，地址匹配 VPS 已分配 IPv4。
- AAAA-only 控制先确认有 AAAA 且无 A；同连接日志命中 `resolve(ipv4_only)`，然后 `empty result`，无出站。该测试域名没有写入生产配置。
- IPv6 字面量测试的同连接日志显示嗅探到 `chatgpt.com`，随后命中 `ip_version=6 => reject`，无出站。不把任意超时/证书错误当作拒绝成功。
- 生产经本机 `127.0.0.1:17890` 请求 `chatgpt.com/cdn-cgi/trace`：HTTP 200、IPv4、`loc=DE`；Net.Coffee 及 ipwho.is 对同一精确 IPv4 均返回 Germany/DE。
- 09:25 左右使用用户原 Chrome PID 20236、窗口 199360 实际访问该只读 trace：页面 `loc=DE`，IP 在本地比较为 IPv4 且匹配当前 VPS 节点端点。未另开窗口，Chrome 留在 trace 页面；另一个最小化 Net.Coffee 窗口未操作。Cua 会话已结束。
- 最终远端逐分片比较与已校验生产快照一致，候选哈希正确，测试域名不在生产，旧规则保留，服务 active。

## 剩余边界

- 保证范围是列明专属域名的服务器端分类策略，不等于共享客服、支付、语音基础设施和未来新域名全部受覆盖。
- 未知 IP 字面量、无法嗅探的 ECH/QUIC 无法可靠归属，保持原行为。未做实际 UDP/QUIC 端到端验收。
- 未完成本机 DNS 泄漏、核心退出/断网隔离和任意 Wi-Fi 零泄漏验收，不能宣布应用全部功能或绝对零泄漏已通过。
- Claude 原通路仍可能使用此前地区库冲突的 IPv6。OpenAI 的德国 IPv4 证据不自动授权访问 Claude。两个参考页仅静态读取，未执行其 JavaScript 或运行 Claude 全量检测。
