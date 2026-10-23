# 2026-10-15 Clash of Rust 版本更新核查

工作目录：`E:\Desktop\workspace\Project\Clash-of-Rust`。
本轮范围：核对并更新 Clash of Rust，保存新会话提示词；不恢复暂停中的 Chrome/WFP/DNS 修复。

## 结果与实际改动

官方 [最新稳定 Release](https://github.com/Fu021/Clash-of-Rust/releases/tag/v0.5.9) 是 **0.5.9**。开始本轮时，机器已经安装并运行了该版本：

- 活动应用：`D:\Clash of Rust\clash-of-rust.exe`，文件版本及产品版本均 0.5.9。
- 活动核心：`D:\Clash of Rust\resources\mihomo.exe`，父进程为上述应用。
- 唯一查到的卸载注册项：HKLM `...\Uninstall\ClashOfRust`，DisplayVersion 0.5.9，InstallLocation `D:\Clash of Rust`。
- 旧 `D:\Clash\clash-of-rust.exe` 仍为 0.5.8，但不在运行。没有卸载旧目录，也没有再安装一份。

因此本轮没有下载或执行安装包，也未做安装包/已安装二进制的哈希对应验证；版本与活动进程归属是本轮已核实证据，不应把它写成“本轮执行了安装升级”。

本轮执行的版本更新是克隆仓库快进：

- 更新前 HEAD：`dab7714`，Cargo.toml 0.5.7。
- 从 origin 获取 main 和稳定 tag v0.5.9。
- `git merge --ff-only v0.5.9`，更新至 `f8a1379da68140f45ae718994153a43fb77a9b84`，Cargo.toml 0.5.9。
- 远端 main 已有更新开发提交；本地选择稳定 tag 与已安装版本对应，不自动编译或部署开发版。
- 没有本地修改上游源码；所有跟踪文件与 tag 一致。保留三份本地交接文件，更新其中 AGENTS 和交接的当前定位，新增本文与提示词。

## 只读网络与配置观察

2026-10-15 08:08（Asia/Taipei）使用正常系统通路、curl 默认证书验证：

- `https://ipgw.neu.edu.cn/`：HTTP 302，TLS 校验结果 0，curl 退出 0。
- `https://api.okinto.com/`：HTTP 200，TLS 校验结果 0，curl 退出 0。

没有临时切代理、指定替代解析、跳过证书校验或使用故障注入。最终连通性另见本文末尾的复核记录。

读取到 loopback 9090 控制器、17890 普通代理，17892 未监听；核心实时 mode=rule、TUN开启。保存偏好为 proxy_mode=tun、run_mode=global、dns_override=true。系统代理 ProxyEnable=0，NRPT 规则数为 0，四条 Strict-DNS 事故规则保持禁用。

新版本保存设置中 `claude_protection` 非空。只确认该记录存在，不转储保护记录、节点、订阅或控制器 secret，也不据此承诺保护实时有效。0.5.9 官方说明新增默认关闭的原生保护，启用后涉及 TUN、DNS、UDP 与规则；当前记录由谁、何时开启未调查，本轮未切换或触发检测。模式差异是否属于其临时覆盖/恢复机制应在后续修复中依据新版源码与 UI 查清。

维护任务 `ClashOfRust-Chrome-Listener` 当前核查为 Ready/Limited。旧维护器默认路径仍是 `D:\Clash\clash-of-rust.exe`，旧安装器也在两处校验 `D:\Clash\resources\mihomo.exe`。它们均与新安装路径不符，不可直接使用；旧代码的 Highest、旧策略备份与探针清理问题继续保留为阻断项。

## 后续边界

本轮没有停止/启动核心或维护任务，没有修改应用/profile、浏览器策略、DNS、TUN、NRPT、路由、防火墙/WFP，没有访问 Claude/Anthropic/检测网页，也未 SSH、提交 Git 或清理旧安装。

未执行构建或上游运行测试，以免运行会调整系统网络或访问禁止站点的集成测试。仅核验官方稳定 tag、安装文件版本、活动进程归属、文档链接/结构及关键网址连通性。Git 仍保留本地未提交文档。

供用户复制的 [新会话提示词](next-session-prompt.md) 要求在新版本基础上先复核原生能力与旧方案，不自动把旧 17892 辅助方案认定为唯一方案。Chrome 全流量、DNS 和断连保护仍未完成验收。

克隆快进可通过本地 reflog 追溯到 `dab7714`；不需要为撤回源码资料更新去卸载应用或回滚网络。若确有退回资料版本的需要，优先另建只读检视位置，保留本地未提交文档，不执行覆盖式 reset/clean。

## 最终复核
- 2026-10-15T08:13:50.5494833+08:00：https://ipgw.neu.edu.cn/，http=302 tls=0，curl exit=0。
- 2026-10-15T08:13:51.8814097+08:00：https://api.okinto.com/，http=200 tls=0，curl exit=0。

## 后续旧版清理

同日 08:33，用户另行明确要求卸载旧版。旧 `D:\Clash` 0.5.8 已完整归档、逐文件核验后移除；未运行旧卸载器，0.5.9 活动安装及唯一卸载注册项、共享配置和订阅均保留，应用与核心未重启。清理前后两个关键网址 DNS/TLS/HTTP 均正常。准确备份路径、恢复方式与尚未完成的本机入口验证见 [交接第 11 节](local-network-handoff-2026-10-15.md)。本文此前“未清理旧安装”描述的是早先版本核查轮次，不再代表当前状态。
