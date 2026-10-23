# AI 相关域名与规则管理清单

记录日期：2026-10-15，Asia/Taipei。机器可读版本：[config/ai-domain-inventory.json](../config/ai-domain-inventory.json)。

## 用途与证据边界

本清单完整登记用户指定两篇文章中的目标域名、关键词、IP/ASN、分类规则和明确的反例；另登记其引用的两个 OpenAI 公共规则列表的补充项，以及不应混入 AI 规则的页面资源。重复内容合并，来源保留；根域后缀覆盖的示例子域、HTTP 路径仍单列说明。CSS、协议字段、地区编号及 IP 范围的起止解释不作为独立规则重复登记。

这不是 OpenAI 或 Anthropic 官方发布的完整、永久域名注册表。两篇文章和社区列表均可能变化；文章称“自有”“专用”并不等于本轮完成所有权核验。`dedicated_candidate` 等分类仅表示文章或社区列表关联，未核验项目不能当作官方确认。

清单整理最初只按静态文本读取参考页面与公共规则列表，未运行 JavaScript、页面内检测、Google Analytics，也未因整理清单向 OpenAI、Claude 或 Anthropic 目标发请求。此次后续更新仅离线读取已实施策略常量，不联网、不 SSH、不请求目标。主任务另按用户授权执行实际部署及目标验收，证据分别见 [VPS OpenAI IPv4 出站变更记录](vps-ai-ipv4-change-2026-10-15.md) 和 [VPS Claude IPv4 出站变更记录](vps-claude-ipv4-change-2026-10-15.md)；不能把清单整理的只读边界误解为主任务从未访问目标。

本文件和 JSON 仅用于管理，不是 Clash of Rust 或 sing-box 自动加载的配置，不能整份导入。生成及更新清单没有修改客户端源码、系统网络或客户端 Claude 保护，也没有建立 SSH 连接；服务端的授权策略变更属于上述独立实施记录。

## 来源

- `netcoffee_gpt`：<https://ip.net.coffee/gpt/site.html>，2026-10-15 静态读取 HTTP 200。
- `netcoffee_claude`：<https://ip.net.coffee/claude/site.html>，2026-10-15 静态读取 HTTP 200。
- `v2fly_openai`：<https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/openai>，2026-10-15 静态读取 HTTP 200。
- `blackmatrix_openai`：<https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/OpenAI/OpenAI.list>，2026-10-15 静态读取 HTTP 200；文件自报更新日期 2025-06-06。它是 GPT 文章引用的列表，不代表其所有宽泛规则均适合本次目标。

公共源是可变链接，并非本地保存的永久快照。JSON 的 `source` 关联上述来源标识；`generated_at` 仅是清单生成时间，不代替部署时间或来源内容永久性证明。

## 本轮应用状态

`policy_state` 描述先后获得授权并部署的显式服务端 OpenAI 与 Claude IPv4-only 匹配器，不描述所有历史策略，也不是每个域名的功能验收结果。

- `applied_vps_ipv4_only`：精确列在本轮服务端 `SUFFIXES`、`HOSTS` 或 `REGEX` 中；IPv4-only 解析并拒绝匹配流量使用 IPv6，IPv4 失败不得回退 IPv6。
- `inventory_only`：只登记，未为此匹配器单独新增策略。示例子域可能已被应用的父后缀覆盖，JSON 的 `covered_by_applied_suffix` 会注明。
- `shared_not_newly_forced`：共享或非专属第三方范围，本轮未新增强制 IPv4 策略；不代表既有 geosite、Chrome 或 Claude 原生保护不会匹配它。
- `unsafe_not_applied`：过宽关键词、共享整域、过时/未验证 IP 或 ASN 兜底，以及不可靠的 NTP 建议，未直接套用为新增规则。

部署匹配器按 OpenAI、Claude 两份实施脚本的 `SUFFIXES`、`HOSTS`、`REGEX` 常量分别静态提取，未导入、执行脚本。明确应用共 31 个匹配器：OpenAI 原 20 个（10 后缀、9 精确主机、1 受限正则）保持不变，Claude 新增 11 个（7 后缀、4 精确主机）。JSON 原 `applied_policy_snapshot` 继续保存兼容的 OpenAI 快照，另用 `claude_applied_policy_snapshot` 保存 Claude 快照。

原末尾 `geosite-openai` 等旧规则保留；后续 Claude 策略插入前后所有原规则的相对顺序不变。不在新增严格清单内的目的地仍可能走旧规则，不能把“未新增”解释为“不代理”。客户端现用 HY2 IPv6 接入没有切换；客户端到 VPS 的 IPv6 接入与 VPS 到目标的 IPv4 出站是不同链路。

历史上，最初 OpenAI 部署时 Claude 条目确实只登记、没有新增服务端策略，也没有访问 Claude；这不再代表后续状态。用户随后明确授权 Claude 使用 VPS IPv4，主任务先核验对应出口的 Net.Coffee/ipwho.is 结果均为同一 IP 的德国归属，之后实际 `claude.ai/cdn-cgi/trace` 返回 HTTP 200、IPv4、DE 并匹配预检出口，OpenAI 回归同为 HTTP 200、IPv4、DE，配置经 confirm 确认保留，定向回退看门狗已解除。这些是主任务交付的实施证据，不是本清单独立重跑的网络测试；共享域、关键词、IP/ASN 等其余范围均未新增强制。OpenAI 的出口证据仍不能替代 Claude 对应实际通路的前置检查。

## 来源差异与风险

- GPT 文章漏列当前 v2fly 中的 `chatgpt.site`、`oaistatsig.com`、`openaiassets.blob.core.windows.net`、`openai.qualtrics.com`；本轮清单均保留并注明补充来源。
- 文章建议整个 `webpubsub.azure.com` 后缀，会覆盖其他 Azure 租户。本轮改用 v2fly 的受限 ChatGPT 主机正则；不扩大至整个 Azure 命名空间。
- `client-api.arkoselabs.com`、`host.livekit.cloud`、`turn.livekit.cloud` 和 `browser-intake-datadoghq.com` 缺少专属于 OpenAI 的证明，未新增到严格清单。共享服务可能影响人机验证、语音或监控，需按实际日志另行评估，不能声称所有功能已验收。
- `crixet.com` 虽被文章和 v2fly 收录，本轮未确认其所有权，因此只登记、不新增。历史 `ai.com` 未按旧重定向信息加入。
- 整个 `auth0.com`、`stripe.com`、`sentry.io`、Intercom、Statsig 等服务，以及 `openai`、`datadog`、`sentry`、`sift` 关键词，不等价于某个 AI 产品的专属流量。
- Claude 文章中的 `browser-intake-us5-datadoghq.com` 不是 `datadoghq.com` 的子域；连字符不能当作点。登记该反例，不据此接受宽泛 `datadog` 关键词。
- 文章所称“NTP 返回时区、代理 NTP 可消除时区泄漏”不可靠：标准 NTP 交换时间戳，不返回地理时区。本轮不据此变更 NTP、系统时间或全局 UDP。
- 以下登记的公开目标 CIDR/ASN 来自文章或公共规则列表，不是本机或 VPS 私密地址，当前归属和公告未独立验证。不能将其作为服务器当前地址或可靠专属边界。

## 后续维护

1. 从静态文章、公共列表或经授权的实际连接日志发现新增项；先记录服务、匹配类型、用途、来源日期和共享风险，不自动请求目标站点验证。
2. 在 JSON 中登记条目。没有本轮部署证据时保持未新增状态；不要因条目看起来“相关”就标记 `applied_vps_ipv4_only`，也不要从产品名猜域名。
3. 独立审查是否专属、是否存在更窄主机/正则、是否影响其他服务，特别审查关键词、共享后缀、IP/ASN 和 UDP 范围；未知所有权明确保留未知。
4. 需要实际部署时另行核对授权、关键网址基线、即时备份及定向回退方案，由主任务串行实施并验收；Claude/Anthropic 仍须先满足其实际通路德国出口条件。更新清单不等于获得访问或变更授权。
5. 部署后依据实际匹配器更新 JSON 状态与本文件条目，记录独立证据与未验证范围。禁止将本 JSON 整份转换为启用规则，禁止让来源列表自动扩大生产策略。

## 完整条目

以下列表由同一份 JSON 逐项展开，保持状态、匹配类型和来源可追溯。`domain_suffix` 包含根域及子域，`domain` 只表示精确主机，`domain_regex` 是受限正则；`url_path`、`service_name`、`url` 是管理记录，不能作为域名匹配器直接加载。JSON 中另有英文分类和逐项说明。

### OpenAI: Applied VPS IPv4-only (20)

- `domain_suffix` `openai.com`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`, `blackmatrix_openai`
- `domain_suffix` `chatgpt.com`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`, `blackmatrix_openai`
- `domain_suffix` `chat.com`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`
- `domain_suffix` `sora.com`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`
- `domain_suffix` `oaistatic.com`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`, `blackmatrix_openai`
- `domain_suffix` `oaiusercontent.com`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`, `blackmatrix_openai`
- `domain_suffix` `openai.com.cdn.cloudflare.net`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`
- `domain` `openaicom.imgix.net`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`
- `domain` `openaiapi-site.azureedge.net`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`
- `domain` `production-openaicom-storage.azureedge.net`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`, `blackmatrix_openai`
- `domain` `openaicomproductionae4b.blob.core.windows.net`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`, `blackmatrix_openai`
- `domain` `openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`, `blackmatrix_openai`
- `domain` `openai-api.arkoselabs.com`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `blackmatrix_openai`
- `domain_suffix` `chatgpt.livekit.cloud`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`, `blackmatrix_openai`
- `domain` `o33249.ingest.sentry.io`; state=`applied_vps_ipv4_only`; `netcoffee_gpt`, `v2fly_openai`
- `domain_suffix` `chatgpt.site`; state=`applied_vps_ipv4_only`; `v2fly_openai`
- `domain_suffix` `oaistatsig.com`; state=`applied_vps_ipv4_only`; `v2fly_openai`
- `domain` `openaiassets.blob.core.windows.net`; state=`applied_vps_ipv4_only`; `v2fly_openai`
- `domain` `openai.qualtrics.com`; state=`applied_vps_ipv4_only`; `v2fly_openai`
- `domain_regex` `^chatgpt-async-webps-prod-\S+-\d+\.webpubsub\.azure\.com$`; state=`applied_vps_ipv4_only`; `v2fly_openai`

### OpenAI: Inventory / Shared / Unsafe (40)

- `domain_suffix` `crixet.com`; state=`inventory_only`; `netcoffee_gpt`, `v2fly_openai`
- `domain` `api.openai.com`; state=`inventory_only`; `netcoffee_gpt`; parent coverage: `openai.com`
- `domain` `auth.openai.com`; state=`inventory_only`; `netcoffee_gpt`; parent coverage: `openai.com`
- `domain` `platform.openai.com`; state=`inventory_only`; `netcoffee_gpt`; parent coverage: `openai.com`
- `domain` `ab.chatgpt.com`; state=`inventory_only`; `netcoffee_gpt`; parent coverage: `chatgpt.com`
- `url_path` `chatgpt.com/backend-api`; state=`inventory_only`; `netcoffee_gpt`
- `url_path` `chatgpt.com/backend-api/codex`; state=`inventory_only`; `netcoffee_gpt`
- `domain_suffix` `webpubsub.azure.com`; state=`unsafe_not_applied`; `netcoffee_gpt`
- `domain_suffix` `client-api.arkoselabs.com`; state=`shared_not_newly_forced`; `netcoffee_gpt`, `blackmatrix_openai`
- `domain_suffix` `host.livekit.cloud`; state=`shared_not_newly_forced`; `netcoffee_gpt`, `v2fly_openai`, `blackmatrix_openai`
- `domain_suffix` `turn.livekit.cloud`; state=`shared_not_newly_forced`; `netcoffee_gpt`, `v2fly_openai`, `blackmatrix_openai`
- `domain` `browser-intake-datadoghq.com`; state=`shared_not_newly_forced`; `netcoffee_gpt`, `v2fly_openai`, `blackmatrix_openai`
- `domain_suffix` `stripe.com`; state=`shared_not_newly_forced`; `netcoffee_gpt`, `blackmatrix_openai`
- `domain_suffix` `intercom.io`; state=`shared_not_newly_forced`; `netcoffee_gpt`, `blackmatrix_openai`
- `domain_suffix` `auth0.com`; state=`shared_not_newly_forced`; `netcoffee_gpt`, `blackmatrix_openai`
- `domain_suffix` `ai.com`; state=`inventory_only`; `netcoffee_gpt`, `blackmatrix_openai`
- `service_name` `Statsig`; state=`shared_not_newly_forced`; `netcoffee_gpt`
- `service_name` `LaunchDarkly`; state=`shared_not_newly_forced`; `netcoffee_gpt`
- `service_name` `Segment`; state=`shared_not_newly_forced`; `netcoffee_gpt`
- `geosite` `openai`; state=`inventory_only`; `netcoffee_gpt`
- `rule_set` `geosite-openai`; state=`inventory_only`; `netcoffee_gpt`
- `rule_set` `OpenAI`; state=`inventory_only`; `netcoffee_gpt`
- `domain` `chat.openai.com.cdn.cloudflare.net`; state=`inventory_only`; `blackmatrix_openai`; parent coverage: `openai.com.cdn.cloudflare.net`
- `domain` `static.cloudflareinsights.com`; state=`shared_not_newly_forced`; `blackmatrix_openai`
- `domain_suffix` `algolia.net`; state=`shared_not_newly_forced`; `blackmatrix_openai`
- `domain_suffix` `api.statsig.com`; state=`shared_not_newly_forced`; `blackmatrix_openai`
- `domain_suffix` `events.statsigapi.net`; state=`shared_not_newly_forced`; `blackmatrix_openai`
- `domain_suffix` `featuregates.org`; state=`shared_not_newly_forced`; `blackmatrix_openai`
- `domain_suffix` `identrust.com`; state=`shared_not_newly_forced`; `blackmatrix_openai`
- `domain_suffix` `intercomcdn.com`; state=`shared_not_newly_forced`; `blackmatrix_openai`
- `domain_suffix` `launchdarkly.com`; state=`shared_not_newly_forced`; `blackmatrix_openai`
- `domain_suffix` `observeit.net`; state=`shared_not_newly_forced`; `blackmatrix_openai`
- `domain_suffix` `openaiapi-site.azureedge.net`; state=`inventory_only`; `blackmatrix_openai`
- `domain_suffix` `openaicom.imgix.net`; state=`inventory_only`; `blackmatrix_openai`
- `domain_suffix` `segment.io`; state=`shared_not_newly_forced`; `blackmatrix_openai`
- `domain_suffix` `sentry.io`; state=`shared_not_newly_forced`; `blackmatrix_openai`
- `domain_keyword` `openai`; state=`unsafe_not_applied`; `blackmatrix_openai`
- `ip_cidr` `24.199.123.28/32`; state=`unsafe_not_applied`; `blackmatrix_openai`
- `ip_cidr` `64.23.132.171/32`; state=`unsafe_not_applied`; `blackmatrix_openai`
- `ip_asn` `20473`; state=`unsafe_not_applied`; `blackmatrix_openai`

### Claude: Applied VPS IPv4-only (11)

- `domain_suffix` `anthropic.com`; state=`applied_vps_ipv4_only`; `netcoffee_claude`
- `domain_suffix` `claude.ai`; state=`applied_vps_ipv4_only`; `netcoffee_claude`
- `domain_suffix` `claude.com`; state=`applied_vps_ipv4_only`; `netcoffee_claude`
- `domain_suffix` `clau.de`; state=`applied_vps_ipv4_only`; `netcoffee_claude`
- `domain_suffix` `claudemcpclient.com`; state=`applied_vps_ipv4_only`; `netcoffee_claude`
- `domain_suffix` `claudemcpcontent.com`; state=`applied_vps_ipv4_only`; `netcoffee_claude`
- `domain_suffix` `claudeusercontent.com`; state=`applied_vps_ipv4_only`; `netcoffee_claude`
- `domain` `anthropic.com.cdn.cloudflare.net`; state=`applied_vps_ipv4_only`; `netcoffee_claude`
- `domain` `servd-anthropic-website.b-cdn.net`; state=`applied_vps_ipv4_only`; `netcoffee_claude`
- `domain` `anthropic.auth0.com`; state=`applied_vps_ipv4_only`; `netcoffee_claude`
- `domain` `anthropic-com.ghost.io`; state=`applied_vps_ipv4_only`; `netcoffee_claude`

### Claude: Inventory / Shared / Unsafe (21)

- `domain` `api.anthropic.com`; state=`inventory_only`; `netcoffee_claude`; parent coverage: `anthropic.com`
- `domain` `cdn.anthropic.com`; state=`inventory_only`; `netcoffee_claude`; parent coverage: `anthropic.com`
- `domain` `mcp.anthropic.com`; state=`inventory_only`; `netcoffee_claude`; parent coverage: `anthropic.com`
- `domain` `console.anthropic.com`; state=`inventory_only`; `netcoffee_claude`; parent coverage: `anthropic.com`
- `domain` `workbench.anthropic.com`; state=`inventory_only`; `netcoffee_claude`; parent coverage: `anthropic.com`
- `domain_suffix` `sentry.io`; state=`unsafe_not_applied`; `netcoffee_claude`
- `domain_suffix` `statsigapi.net`; state=`unsafe_not_applied`; `netcoffee_claude`
- `domain_suffix` `intercom.io`; state=`unsafe_not_applied`; `netcoffee_claude`
- `domain_suffix` `intercomcdn.com`; state=`unsafe_not_applied`; `netcoffee_claude`
- `domain` `browser-intake-us5-datadoghq.com`; state=`shared_not_newly_forced`; `netcoffee_claude`
- `domain` `cdn.usefathom.com`; state=`shared_not_newly_forced`; `netcoffee_claude`
- `domain_keyword` `datadog`; state=`unsafe_not_applied`; `netcoffee_claude`
- `domain_keyword` `sentry`; state=`unsafe_not_applied`; `netcoffee_claude`
- `domain_keyword` `sift`; state=`unsafe_not_applied`; `netcoffee_claude`
- `ip_cidr` `160.79.104.0/21`; state=`inventory_only`; `netcoffee_claude`
- `ip_cidr` `2607:6bc0::/32`; state=`inventory_only`; `netcoffee_claude`
- `ip_asn` `399358`; state=`inventory_only`; `netcoffee_claude`
- `geosite` `anthropic`; state=`inventory_only`; `netcoffee_claude`
- `geosite` `category-ntp`; state=`unsafe_not_applied`; `netcoffee_claude`
- `domain_suffix` `datadoghq.com`; state=`inventory_only`; `netcoffee_claude`
- `geosite` `geolocation-!cn`; state=`inventory_only`; `netcoffee_claude`

### References: Not AI Target Rules (10)

- `domain` `ip.net.coffee`; state=`inventory_only`; `netcoffee_gpt`, `netcoffee_claude`
- `domain` `net.coffee`; state=`inventory_only`; `netcoffee_gpt`, `netcoffee_claude`
- `domain` `card.net.coffee`; state=`inventory_only`; `netcoffee_gpt`, `netcoffee_claude`
- `domain` `www.googletagmanager.com`; state=`inventory_only`; `netcoffee_gpt`, `netcoffee_claude`
- `domain` `schema.org`; state=`inventory_only`; `netcoffee_gpt`, `netcoffee_claude`
- `domain` `github.com`; state=`inventory_only`; `netcoffee_gpt`
- `service_name` `npm`; state=`inventory_only`; `netcoffee_gpt`
- `service_name` `pypi`; state=`inventory_only`; `netcoffee_gpt`
- `url` `https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/OpenAI/OpenAI.list`; state=`inventory_only`; `netcoffee_gpt`
- `url` `https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/openai`; state=`inventory_only`; `v2fly_openai`

### Coverage Counts

- Total management entries: 102; OpenAI 60, Claude 32, references 10.
- Explicit newly applied matchers: 31 (OpenAI 20 + Claude 11); remaining inventory entries: 71.
- Policy-state counts: applied_vps_ipv4_only 31; inventory_only 35; shared_not_newly_forced 23; unsafe_not_applied 13.
- Source counts overlap after deduplication: netcoffee_gpt 46; netcoffee_claude 37; v2fly_openai 24; blackmatrix_openai 35.
- All 23 current v2fly OpenAI entries and all 35 cited blackmatrix entries are preserved, including narrow/broad matching differences. Source inclusion is not automatic policy application.
- Generated inventory has no runtime effect. Removing these two inventory files reverts this documentation-only addition; production rollback is separately documented in `vps-ai-ipv4-change-2026-10-15.md` and `vps-claude-ipv4-change-2026-10-15.md`.
