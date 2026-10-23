# Claude CLI / Desktop 离线网络目标分析

日期：2026-10-15，Asia/Taipei。范围：本机已安装程序及允许的网络配置字段，不登录账号、不执行模型请求。

## 1. 结论与边界

- 本机全局 CLI 为 **2.1.299**；Windows Desktop 安装包为 **2.19675.1**。两者不是同一程序，Desktop Code 也不能直接等同于全局 npm CLI。
- 官方 API、OAuth、下载、资源、浏览器/设备桥接及 Artifact/MCP 页面所需的主要官方域名，已经落在客户端原生保护域名和此前 VPS IPv4-only 后缀范围内。无需为这些已覆盖子域重复加规则，也无需因此重装 Clash of Rust。
- **不能据此宣布 CLI/Desktop 的所有流量已被监控，或所有流量均为德国 IPv4。** 本轮只得到安装代码、配置及本地规则状态，没有发起目标请求或登录，也没有进程到连接的运行证据。
- 共享存储、遥测、云平台、第三方 MCP、工具和工作区依赖不等于 Claude 专属域名。它们不全部属于此前 VPS 的 11 个严格 IPv4 匹配器；不能把 `googleapis.com`、`amazonaws.com`、`github.com` 等整域强制改路由来冒充“完整覆盖”。
- 管理清单：[84 条分类记录 JSON](../config/claude-app-endpoints-2026-10-15.json)。其中有主机、通配域、模板、文档及示例，**不是 84 个当前正在连接的网站**，也不是可直接导入的规则文件。

用户收紧要求后取消原计划的受限 CLI 请求和 Desktop 启动观察，没有执行模型测试。此前调查运行过 CLI `--help`，不涉及账号登录或模型调用；收紧后也不再执行 help。

## 2. 样本与方法

CLI 安装目标：`C:\Users\xuan\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe`。

- 版本：2.1.299。
- 大小：269231264 字节。
- SHA-256：`295b49ec092f31a7de9c6ff286d9d8f120a4f029b9ad9a5ac0b12c35cbf4df2b`。
- 方法：普通离线字面量和二进制内嵌代码短片段检查，保留文件字节偏移；**不是完整原生反编译或执行跟踪**。

Desktop 安装目标：`C:\Users\xuan\AppData\Local\AnthropicClaude\app-2.19675.1\resources\app.asar`。

- 包元数据：`@ant/desktop` 2.19675.1；入口 `.vite/build/index.pre.js`。
- 大小：43091042 字节；ASAR 条目 406。
- SHA-256：`37e9d113862178af8a802d1e20db3bcc081d11056e4d8de5b83b9040f9050f8e`。
- REA Evidence：`ev_59d52a414bb51a136ca6fe95f9eec312eb99dde2c18a0aece8ea4906e6673257`。
- REA 检查 357 份相关文件，解析 341 份 JavaScript，语法解析失败 0；但应用图/语义图 **partial**，658 条限制，包含内存/结果预算限制，不能称为完整控制流分析。
- REA 发现 6 个 unpacked 原生文件的实测哈希与 ASAR 声明不一致。初次 fail 模式中止，随后显式记录不一致继续离线分析；没有执行原生模块。签名/打包后处理可能导致此现象，但本轮没有确认原因，既不能断言篡改，也不能保证这些文件可信。
- SHA 只是本轮样本指纹，不是官方签名或下载来源的独立认证。网络目标用途还通过格式化 ASAR 读取与代码邻域人工核对补充；下列偏移证据不冒充 REA 运行证据。

Desktop-3p 本地缓存下有 Code 版本目录 2.1.280、2.1.284、2.1.288；未运行程序，**不能据此确定当前选中哪个版本**。未解析 WSL 内的程序及 VM 内完整镜像。

## 3. CLI 的主要地址

以下为代码支持的生产默认值或条件性请求，不表示每次执行都连接。

- `https://api.anthropic.com/v1/messages`：模型消息 API；SDK 还含 `/v1/messages/count_tokens` 等路径。
- `https://platform.claude.com/oauth/authorize`、`https://platform.claude.com/v1/oauth/token`：平台 OAuth 授权/令牌入口。
- `https://claude.com/cai/oauth/authorize`：Claude 账号授权入口；`https://claude.ai/oauth/claude-code-client-metadata` 为 OAuth 客户端元数据。
- `https://api.anthropic.com/api/oauth/claude_cli/create_api_key`、`/api/oauth/claude_cli/roles`：API key/角色相关逻辑。
- `https://mcp-proxy.anthropic.com/v1/mcp/{server_id}`：托管 MCP 代理，取决于功能和账号配置。
- `https://downloads.claude.ai/claude-code-releases`：原生版本检查/下载；同域 `/plugins/claude-plugins-official/...` 用于官方插件市场内容。
- `https://downloads.claude.ai/model-catalog/v1/catalog.json` 及签名文件 `.raw-sig.json`：模型目录元数据。
- `wss://bridge.claudeusercontent.com`：Chrome/设备桥接；开发配置可选择 localhost 或 staging，不能混为正常生产目标。
- `https://api.anthropic.com/api/event_logging/v2/batch`：第一方事件上报，受策略、部署模式及遥测开关影响。
- `https://http-intake.logs.us5.datadoghq.com/api/v2/logs`、`https://browser-intake-us5-datadoghq.com/api/v2/logs`：代码包含 Datadog 日志/错误上报逻辑；存在禁用、BYOC 和合规条件，不代表当前已发送。
- `https://storage.googleapis.com/{published_bucket}/plugin-stats/plugin-details.json`：插件详情/统计目录；这是共享存储主机，不是模型请求入口。
- `code.claude.com`、`support.claude.com`、`status.claude.com` 等有文档、帮助或状态链接；出现链接不等于启动自动连接。

关键纠偏：本机 2.1.299 的有界字面量搜索没有找到 `statsig.com`、`api.statsig.com` 或 `statsig.anthropic.com` 完整地址。仍有 `statsig` 目录名等遗留字符串，不能据此把旧版网上清单当作新版必连地址；零字面量命中也不证明动态地址永远不存在。

关键 CLI 文件字节偏移：

- `219976705`：生产 OAuth/API 主机常量；`219977587`：MCP 代理。
- `224014079`：SDK message POST 路径；`224167565` 起：provider 分支和 base URL 选择。
- `232438838`：官方插件下载；`232455465`：GCS 插件目录；`233262667`、`233314474`：原生版本下载；`237185208`：模型目录。
- `223344980`：事件上报 endpoint；`227701123`、`227717210`：Datadog 上报。
- `240092632`：生产/本地/staging 桥接选择。

## 4. Desktop / Code 的主要地址

### 官方核心及功能地址

- `https://claude.ai`：正常生产主窗口默认 origin；代码里的 `claudeAiUrl` 开发配置不等于发布版本一定采用它。
- `https://api.anthropic.com`：API/OAuth/部分更新 feed。Code 还有 `/v1/sessions` 或 `/v1/code/sessions` 条件路径，具体 base URL 可受会话响应/部署配置影响。
- `https://platform.claude.com`、`https://claude.com`：共享 OAuth/平台相关代码；本轮未访问。
- `https://downloads.claude.ai/releases/...`：安装包下载；`/vms/linux/...`：适用工作区 VM 组件；`/claude-code-releases`：Code 引擎相关资源；模型目录也在该域。
- `https://releases.claude.com/api/desktop/.../update`：开启 `updateViaUpdatesHost` 时使用的可选 feed，不能说默认必连。
- `https://assets.claude.ai`：静态资源；`https://assets-proxy.anthropic.com/claude-ai/v2/ping.txt`：资源预热/连通逻辑。
- `wss://bridge.claudeusercontent.com`：浏览器扩展、设备或 Office 等桥接，路径含运行时设备信息，不将真实 ID 写入清单。
- `www.claudeusercontent.com`、`*.frame.claudeusercontent.com`：Artifact 预览；`*.claudemcpcontent.com`、`sandbox.claudemcpcontent.com`：MCP App 小组件；`pivot.claude.ai/manifest.xml`：Office 插件入口。
- `https://microsoft365.mcp.claude.com/mcp`：可选 Microsoft 365 MCP。是否实际启用取决于配置。

### 共享服务与外部集成

- `o1158394.ingest.us.sentry.io`、`*.sentry.io`：Desktop 崩溃/错误上报；不公布 DSN userinfo 或凭据。
- `browser-intake-datadoghq.com`、`browser-intake-us3-datadoghq.com`、`browser-intake-us5-datadoghq.com`、`browser-intake-ap1-datadoghq.com`、`browser-intake-ap2-datadoghq.com`、`browser-intake-datadoghq.eu`、`browser-intake-ddog-gov.com`：包内 Datadog 候选清单；不代表本机同时访问全部区域。
- `storage.googleapis.com`：包括服务返回的签名导出 URL；路径/签名是动态数据，不能静态穷举。
- `www.google.com/s2/favicons`、`*.gstatic.com/faviconV2`：连接器图标；`cdnjs.cloudflare.com`、`fonts.googleapis.com`、`cdn.jsdelivr.net`：Artifact 资产依赖。
- `mcp.box.com`、`api.box.com`、`mcp.figma.com` 等：可选连接器。远程 MCP、插件和配置服务器可以引入任意其他域名。
- GitHub、npm、PyPI、Ubuntu、Rust crate、Playwright 等域名出现在工作区依赖清单。仅在相应工具/安装操作需要时使用，不应标为“Claude 模型 API 必连”。

Desktop ASAR 内关键证据均为成员内字节偏移：

- `.vite/build/index.chunk-DVtu79Rf.js` `677000` 附近：主机常量及云平台模板；`1118600` 附近：按功能区分的出站依赖表。
- 同成员 `1917996`：生产主窗口 URL；`3100294`：Desktop OAuth 生产配置；`4071262`、`5332060`：生产 WSS 桥接。
- 同成员 `1795469`：Code 资源下载基址；`5898480`：会话 API 路径；`6659506`：签名导出主机允许逻辑。
- `.vite/build/index.chunk-BaivF2vS.js` `270476` 起：共享 OAuth/API 主机常量。
- `.vite/build/index.pre.js` `1075595`：Sentry 初始化。

## 5. 第三方 provider 与动态目标

本机 CLI 的 provider 分支明确支持下列非默认目标；Desktop 也有其中 Bedrock/Mantle、Vertex、Foundry 和网关的配置逻辑。

- Bedrock：`bedrock-runtime.{region}.amazonaws.com`，可能另有 control-plane、STS、SSO/OIDC、FIPS/分区变体。
- Mantle：`bedrock-mantle.{region}.api.aws`。
- CLI Anthropic on AWS：`aws-external-anthropic.{region}.api.aws`。
- Vertex：`{region}-aiplatform.googleapis.com`、`aiplatform.googleapis.com`、`aiplatform.{eu_or_us}.rep.googleapis.com`；身份服务可涉及 Google OAuth/STS/IAM。
- CLI Anthropic on Google Cloud：`claude.googleapis.com`。
- Foundry：`{resource}.services.ai.azure.com`，身份服务可涉及 `login.microsoftonline.com`。
- 网关/自定义 base URL：可被 `ANTHROPIC_BASE_URL`、对应 provider base URL、Desktop `inference.baseUrl`、远端 managed 配置等替换。
- OpenTelemetry：可按 `OTEL_EXPORTER_OTLP_*_ENDPOINT` 或 Desktop `otlp.endpoint` 指向任意收集器。
- WebFetch、Shell、插件、hooks、MCP、远程 SSH/云会话、VM 内部进程发起的目标不受官方域名清单穷举；远程机器上的流量也不能归因于本机 Clash。

不得因名称包含 Claude 就把 `claude.googleapis.com` 或 `aws-external-anthropic.*.api.aws` 当作已经被 `claude.com`/`anthropic.com` 后缀覆盖。包中的 staging、localhost、FedStart allowlist、文档示例另作分类，不加入默认必连规则。

## 6. 本机静态配置核查

只对允许的 9 份 JSON 和 User/Machine 环境变量作结构化白名单提取：CLI settings/config、相关 Desktop config 与 Claude-3p configLibrary。只输出 URL scheme/host/port 和字段位置，丢弃 userinfo/path/query/fragment，未读取聊天、会话、日志、credentials 或受保护存储；不触碰 CC Switch。

- 9 份 JSON 成功解析；白名单中未发现非空显式 proxy/base URL/provider/MCP URL 覆盖；User/Machine 同类环境变量亦未发现非空值。
- 包括 Desktop nested 与 flat 字段及 `managedConfig` 的白名单处理；Claude-3p configLibrary 的 `entries` 为空。
- 不代表不存在 key/token，也不代表可以推断采用哪种账号或 provider；这些敏感值没有输出。
- 没有解密受保护存储，也未检查用户每个终端/启动器的瞬时注入环境、注册表全部 managed policy、每个项目配置或远端配置；不能把“本次未发现”说成“绝无自定义服务”。

## 7. Clash / VPS 的覆盖和更新需求

10:11:00 只读查询本地控制器：`rule`、TUN 开启、mixed port 17890、`find-process-mode=off`。没有 DNS/目标连接、核心 PATCH、重启、模式切换或 SSH。

对官方主机的本地域名规则映射：`anthropic.com`、`claude.ai`、`claude.com`、`claudeusercontent.com`、`claudemcpcontent.com` 后缀进入原生保护 Selector，当前所选节点为 Hysteria2 IPv6。它是目标域名匹配，不是 Chrome 专属 AppId 匹配。因此，**若 CLI/Desktop 的请求进入这个核心且可分类为这些域名，也适用同样规则**。

此前 VPS 已部署的 7 后缀包含这些目标；本机至 VPS IPv6 和 VPS 至目标 IPv4 是不同阶段，没有矛盾。新发现的 `downloads`、`releases`、`platform`、`bridge`、`assets-proxy` 等子域无需重复新增匹配器。这里引用的是[已记录 VPS 策略](vps-claude-ipv4-change-2026-10-15.md)，本轮没有重新 SSH 或测量出口。

覆盖缺口应按层次区分：

- Sentry、部分 Datadog 当前客户端已有保护匹配，但**不在此前 VPS 严格 IPv4 的 11 匹配器范围内**；不能承诺其目标连接不使用 VPS IPv6。
- `storage.googleapis.com`、若干外部 connector/provider 等不在 Claude 专属匹配器内。域名层离线审计显示某些会落普通策略；IP/GEO/逻辑规则没有执行解析评估，不能把简化结果当作最终实时命中。
- v0.5.9 强制 `find-process-mode=off`，连接 UI/API 也不支持完整进程归属。搜不到 Claude 进程名不等于绕过 TUN；反过来，有 TUN 也不能证明所有子进程、VM 或远程任务均被接管。
- Desktop 的显式代理配置说明列出更新下载、Windows 登录 broker、部分 VM/辅助脚本/系统浏览器等不使用该显式代理的路径。这**不等于绕过 TUN**；只是不能靠单个 `HTTPS_PROXY` 覆盖全部组件。

因此本轮建议是：**先维护离线分类台账，不重装、不改上游源码、不为“全覆盖”直接扩大共享整域规则。** 若以后要对某个确认使用的外部端点也保证 VPS IPv4，必须单独评估最小主机范围、客户端选择及服务端规则，并按网络安全约定取得基线、备份、回退后实施。没有这一步，不宣称已补齐。

## 8. 变更、验证与回退

本轮仅新增本报告、84 条 JSON 管理清单，并更新[本机交接](local-network-handoff-2026-10-15.md)。离线工具和大体积证据存于 Git 忽略的 `.local-tools/`；不提交程序副本或原始用户配置。

验证：JSON 可解析、主机+分类唯一、记录具有证据位置、无运行观测冒充；文档相对链接存在；白名单脱敏合成测试通过。本轮未改变网络，所以没有触发关键站点/Claude 外站测试来“验证文档”，无需网络回退。此前 VPS 和浏览器修复保持原样。

未完成：实际程序连接归属、当前完整出口测量、动态 Web/MCP/provider/VM/WSL 目标穷举、离线断连保护测试和 unpacked 原生文件哈希不一致的来源认证。它们不应在不登录/不运行目标的本轮范围内被虚构为通过。
