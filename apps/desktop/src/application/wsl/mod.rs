//! Native WSL control surface. Effects run on the worker, never the UI thread.
use super::*;
use clash_client_core::wsl::{self as contract, Backend, Operation, Report, WslSettings};
use clash_client_ui::{DetailItem, UiData, WslDistributionItem, models::ViewModels};

#[cfg(any(windows, test))]
mod payload;
mod runner;

#[derive(Debug, Clone)]
pub(super) enum Event {
    Tick,
    Input(String, String),
    Action(String, String),
    RestoreConfirmed(WslSettings),
    ProfileSelected(Result<Option<std::path::PathBuf>, ()>),
    Finished(Operation, Box<Result<Report, Failure>>, String),
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app() -> App {
        App::initial_state(Err(anyhow::anyhow!("isolated WSL state test")), None)
    }

    fn request(action: contract::Action) -> contract::Request {
        contract::Request {
            action,
            execute: action.mutating(),
            backend: Backend::WireGuard,
            profile_path: r"C:\Private\egress.json".into(),
            ..Default::default()
        }
    }

    fn report(action: contract::Action, outcome: &str) -> Report {
        Report::parse(
            &serde_json::json!({
                "schema_version":1, "operation_id":uuid::Uuid::new_v4().to_string(),
                "generation":1, "action":action, "outcome":outcome,
                "protection":"unknown", "phase":"failed", "backend":"WireGuard",
                "message":"", "distributions":[], "checks":[], "logs":[]
            })
            .to_string(),
        )
        .unwrap()
    }

    #[test]
    fn failed_mutation_report_locks_and_readonly_failures_do_not_unlock() {
        let mut app = app();
        let ticket = app
            .wsl
            .evidence
            .begin(request(contract::Action::Start))
            .unwrap();
        let _ = app.wsl_event(Event::Finished(
            ticket,
            Box::new(Ok(report(contract::Action::Start, "failed"))),
            String::new(),
        ));
        assert!(app.wsl.inspection_required);
        let ticket = app
            .wsl
            .evidence
            .begin(request(contract::Action::Doctor))
            .unwrap();
        let _ = app.wsl_event(Event::Finished(
            ticket,
            Box::new(Err(Failure::Runner(runner::Error::Unavailable))),
            String::new(),
        ));
        assert!(app.wsl.inspection_required);
        let ticket = app
            .wsl
            .evidence
            .begin(request(contract::Action::Status))
            .unwrap();
        let _ = app.wsl_event(Event::Finished(
            ticket,
            Box::new(Ok(report(contract::Action::Status, "succeeded"))),
            String::new(),
        ));
        assert!(
            app.wsl.inspection_required,
            "the synthetic status uses a failed phase and cannot settle recovery"
        );
    }

    #[test]
    fn only_explicit_terminal_status_phases_settle_recovery() {
        for phase in [
            "uninstalled",
            "restored",
            "installed_closed",
            "connected_unverified",
        ] {
            let mut app = app();
            app.wsl.inspection_required = true;
            let ticket = app
                .wsl
                .evidence
                .begin(request(contract::Action::Status))
                .unwrap();
            let raw = serde_json::json!({
                "schema_version":1, "operation_id":uuid::Uuid::new_v4().to_string(),
                "generation":1, "action":"Status", "outcome":"succeeded",
                "protection":"unknown", "phase":phase, "backend":"WireGuard",
                "message":"inspected", "distributions":[], "checks":[], "logs":[]
            });
            let _ = app.wsl_event(Event::Finished(
                ticket,
                Box::new(Ok(Report::parse(&raw.to_string()).unwrap())),
                String::new(),
            ));
            assert!(
                !app.wsl.inspection_required,
                "phase {phase} should settle recovery"
            );
        }
    }

    #[test]
    fn rejected_mutation_report_locks_without_retaining_evidence() {
        let mut app = app();
        let ticket = app
            .wsl
            .evidence
            .begin(request(contract::Action::Start))
            .unwrap();
        let _ = app.wsl_event(Event::Finished(
            ticket,
            Box::new(Ok(report(contract::Action::Stop, "succeeded"))),
            String::new(),
        ));
        assert!(app.wsl.inspection_required);
        assert!(!app.wsl.evidence.busy());
        assert!(app.wsl.evidence.report().is_none());
    }

    #[test]
    fn expired_mutation_callback_cannot_lock_a_newer_readonly_operation() {
        let mut app = app();
        let old = app
            .wsl
            .evidence
            .begin(request(contract::Action::Start))
            .unwrap();
        app.wsl
            .evidence
            .fail(&old, contract::Error::HelperFailed)
            .unwrap();
        let current = app
            .wsl
            .evidence
            .begin(request(contract::Action::Status))
            .unwrap();
        let _ = app.wsl_event(Event::Finished(
            old,
            Box::new(Ok(report(contract::Action::Start, "failed"))),
            String::new(),
        ));
        assert!(!app.wsl.inspection_required);
        assert!(app.wsl.evidence.busy());
        app.wsl
            .evidence
            .fail(&current, contract::Error::HelperFailed)
            .unwrap();
    }

    #[test]
    fn late_core_initialization_preserves_an_active_wsl_ticket_or_edited_draft() {
        let mut state = State::new(WslSettings::default());
        let saved = WslSettings {
            backend: Backend::WireGuard,
            ..Default::default()
        };
        state.load_preferences(saved.clone());
        assert_eq!(state.draft.backend, Backend::WireGuard);
        let ticket = state
            .evidence
            .begin(request(contract::Action::Start))
            .unwrap();
        state.load_preferences(WslSettings::default());
        assert!(state.evidence.busy());
        assert_eq!(state.draft.backend, Backend::WireGuard);
        state
            .evidence
            .fail(&ticket, contract::Error::HelperFailed)
            .unwrap();
        state.edit("profile-path", r"C:\Private\edited.json".into());
        state.load_preferences(saved);
        assert_eq!(state.draft.profile_path, r"C:\Private\edited.json");
    }

    #[test]
    fn fresh_status_report_is_the_explicit_recovery_event() {
        let mut app = app();
        app.wsl.inspection_required = true;
        let ticket = app
            .wsl
            .evidence
            .begin(request(contract::Action::Status))
            .unwrap();
        let raw = serde_json::json!({
            "schema_version":1, "operation_id":uuid::Uuid::new_v4().to_string(),
            "generation":1, "action":"Status", "outcome":"succeeded",
            "protection":"unknown", "phase":"installed_closed", "backend":"WireGuard",
            "message":"inspected", "distributions":[], "checks":[], "logs":[]
        });
        let _ = app.wsl_event(Event::Finished(
            ticket,
            Box::new(Ok(Report::parse(&raw.to_string()).unwrap())),
            String::new(),
        ));
        assert!(!app.wsl.inspection_required);
    }

    fn deployed_report(action: contract::Action) -> Report {
        let mut result = report(action, "succeeded");
        result.phase = "connected_unverified".into();
        result.generation = 42;
        result
    }

    #[test]
    fn observed_wireguard_replaces_legacy_tailscale_preference_without_reentering_secrets() {
        let mut state = State::new(WslSettings {
            backend: Backend::Tailscale,
            profile_path: r"C:\Private\installed.json".into(),
            ..Default::default()
        });
        state.observe(&deployed_report(contract::Action::Status));
        assert_eq!(state.draft.backend, Backend::WireGuard);
        let request = state.request(contract::Action::Start, true);
        assert_eq!(request.profile_path, r"C:\Private\installed.json");
        assert!(request.endpoint_ipv4.is_empty());
        assert!(request.endpoint_port.is_empty());
        assert!(request.distro.is_empty());
        assert!(request.validate().is_ok());
        state.load_preferences(WslSettings {
            backend: Backend::Tailscale,
            ..Default::default()
        });
        assert_eq!(state.draft.backend, Backend::WireGuard);
    }

    #[test]
    fn installation_edits_cannot_override_reconnect_or_readonly_requests() {
        let mut state = State::new(WslSettings {
            profile_path: r"C:\Private\installed.json".into(),
            ..Default::default()
        });
        state.observe(&deployed_report(contract::Action::Status));
        state.edit("profile-path", "unfinished path".into());
        state.edit("endpoint-ipv4", "unfinished endpoint".into());
        state.edit("distro", "unfinished distro".into());
        for action in [
            contract::Action::Doctor,
            contract::Action::Status,
            contract::Action::Start,
            contract::Action::Stop,
            contract::Action::Test,
            contract::Action::Rollback,
        ] {
            let request = state.request(action, action.mutating());
            if action == contract::Action::Start {
                assert_eq!(request.profile_path, r"C:\Private\installed.json");
                assert!(request.validate().is_ok(), "{action:?}");
            } else {
                assert!(request.validate().is_ok(), "{action:?}");
                assert!(request.profile_path.is_empty());
            }
            assert!(request.endpoint_ipv4.is_empty());
            assert!(request.distro.is_empty());
        }
        assert!(
            state
                .request(contract::Action::Install, true)
                .validate()
                .is_err()
        );
        assert_eq!(state.deployment.as_ref().unwrap().generation, 42);
    }

    #[test]
    fn successful_refresh_preserves_last_operation_feedback_and_tracks_restoration() {
        let mut app = app();
        app.wsl.last_operation = "已取消 Windows 管理员授权；没有执行管理操作。".into();
        let ticket = app
            .wsl
            .evidence
            .begin(request(contract::Action::Status))
            .unwrap();
        let _ = app.wsl_event(Event::Finished(
            ticket,
            Box::new(Ok(deployed_report(contract::Action::Status))),
            String::new(),
        ));
        assert!(app.wsl.last_operation.contains("已取消"));
        assert!(app.wsl.deployment.is_some());
        let ticket = app
            .wsl
            .evidence
            .begin(request(contract::Action::Status))
            .unwrap();
        let mut restored = deployed_report(contract::Action::Status);
        restored.phase = "restored".into();
        let _ = app.wsl_event(Event::Finished(
            ticket,
            Box::new(Ok(restored)),
            String::new(),
        ));
        assert!(app.wsl.deployment.is_none());
        assert!(app.wsl.inspected);
    }

    #[test]
    fn private_profile_selection_cancellation_and_invalid_paths_do_not_change_draft() {
        let mut app = app();
        let original = app.wsl.draft.clone();
        app.wsl.profile_picker_open = true;
        let _ = app.wsl_event(Event::ProfileSelected(Ok(None)));
        assert!(!app.wsl.controls_busy());
        assert_eq!(app.wsl.draft, original);
        app.wsl.profile_picker_open = true;
        let _ = app.wsl_event(Event::ProfileSelected(Ok(Some(std::path::PathBuf::from(
            r"\\server\share\private.json",
        )))));
        assert_eq!(app.wsl.draft, original);
        assert!(app.wsl.message.contains("本地磁盘"));
    }

    #[test]
    fn stale_deployment_callback_cannot_replace_current_installation_metadata() {
        let mut app = app();
        let old = app
            .wsl
            .evidence
            .begin(request(contract::Action::Status))
            .unwrap();
        app.wsl
            .evidence
            .fail(&old, contract::Error::HelperFailed)
            .unwrap();
        app.wsl.observe(&deployed_report(contract::Action::Status));
        let current = app
            .wsl
            .evidence
            .begin(request(contract::Action::Status))
            .unwrap();
        let mut stale = deployed_report(contract::Action::Status);
        stale.phase = "restored".into();
        let _ = app.wsl_event(Event::Finished(old, Box::new(Ok(stale)), String::new()));
        assert!(app.wsl.deployment.is_some());
        assert!(app.wsl.evidence.busy());
        app.wsl
            .evidence
            .fail(&current, contract::Error::HelperFailed)
            .unwrap();
    }

    #[test]
    fn installed_deployment_refuses_reinstall_without_overwriting_snapshot() {
        let mut app = app();
        app.wsl.observe(&deployed_report(contract::Action::Status));
        let _ = app.wsl_event(Event::Action("Install".into(), "execute".into()));
        assert!(!app.wsl.evidence.busy());
        assert!(app.wsl.message.contains("回滚快照"));
    }

    #[test]
    fn uac_cancellation_keeps_a_retry_available_and_retains_specific_feedback() {
        let mut app = app();
        let ticket = app
            .wsl
            .evidence
            .begin(request(contract::Action::Start))
            .unwrap();
        let _ = app.wsl_event(Event::Finished(
            ticket,
            Box::new(Err(Failure::Runner(runner::Error::ElevationCancelled))),
            String::new(),
        ));
        assert!(app.wsl.cancelled);
        assert!(!app.wsl.inspection_required);
        assert!(!app.wsl.evidence.busy());
        assert!(app.wsl.last_operation.contains("已取消管理员授权"));
        assert_eq!(app.wsl.evidence.protection(), contract::Protection::Blocked);
    }

    #[test]
    fn old_results_are_not_displayed_as_current_security_evidence() {
        let mut state = State::new(WslSettings::default());
        assert!(!state.evidence_fresh());
        state.observe(&deployed_report(contract::Action::Status));
        assert!(state.evidence_fresh());
        state.last_observed = Some(std::time::Instant::now() - Duration::from_secs(31));
        assert!(!state.evidence_fresh());
        assert!(
            state.deployment.is_some(),
            "installation metadata is not proof"
        );
    }

    #[test]
    fn incomplete_endpoint_closure_never_claims_that_protection_remains_effective() {
        let mut report = deployed_report(contract::Action::Start);
        report.phase = "closure_unverified".into();
        report.outcome = contract::Outcome::Failed;
        let (feedback, guidance) = operation_feedback(&report);
        assert!(feedback.contains("保护状态未知"));
        assert!(guidance.contains("endpoint_closure"));
        assert!(!feedback.contains("已保留"));
    }

    #[cfg(windows)]
    #[test]
    fn visible_wsl_page_polls_readonly_and_never_overlaps_an_operation() {
        let mut app = app();
        app.visible = true;
        app.page = Page::Wsl;
        let _ = app.wsl_event(Event::Tick);
        assert!(app.wsl.evidence.busy());
        let generation = app.wsl.evidence.generation;
        let _ = app.wsl_event(Event::Tick);
        assert_eq!(app.wsl.evidence.generation, generation);
        app.visible = false;
        let _ = app.wsl_event(Event::Tick);
        assert_eq!(app.wsl.evidence.generation, generation);
    }
}

#[derive(Debug, Clone, Copy)]
pub(super) enum Failure {
    Runner(runner::Error),
    Contract(contract::Error),
    Preferences,
}
impl Failure {
    fn message(self) -> String {
        match self {
            Self::Runner(error) => error.message().into(),
            Self::Contract(error) => error.to_string(),
            Self::Preferences => "无法保存 WSL 连接偏好；管理操作未执行。".into(),
        }
    }
}

fn validation_message(error: contract::Error) -> &'static str {
    match error {
        contract::Error::MissingProfile => {
            "首次安装需要本机私密 WireGuard JSON 配置文件；仅填写 VPS 地址和端口不够。"
        }
        contract::Error::UnsupportedBackend => {
            "严格隔离模式暂不支持 Tailscale 安装或连接；请选择固定 Endpoint WireGuard。"
        }
        contract::Error::InvalidProfilePath => {
            "配置路径必须是本地磁盘上的 JSON 绝对路径，不接受网络共享、相对路径或命令字符。"
        }
        contract::Error::InvalidEndpoint => "端点必须是公开 IPv4 字面地址。",
        contract::Error::InvalidPort => "端点端口必须是 1–65535 之间的十进制整数。",
        contract::Error::MissingEndpoint => {
            "IPv4 与端口必须一起填写，或一起留空使用私密配置中的值。"
        }
        contract::Error::InvalidDistro => "发行版名称无效；仅接受字母、数字、点、下划线和连字符。",
        contract::Error::DockerDesktopUnsupported => {
            "不能将 Docker Desktop 内部发行版作为管理发行版。"
        }
        _ => "请求未通过安全校验；管理操作未执行，请检查输入并刷新状态。",
    }
}

fn operation_feedback(report: &Report) -> (String, String) {
    use contract::{Action, Outcome};
    if report.phase == "closure_unverified" {
        return (
            "管理操作失败，且无法确认外层端点已关闭；当前保护状态未知。".into(),
            "停止使用 WSL 联网应用，先运行 Doctor 并查看 endpoint_closure 与失败阶段，再定向修复。"
                .into(),
        );
    }
    let failed_host_policy = report
        .checks
        .iter()
        .any(|check| check.id == "host_policy" && check.result.eq_ignore_ascii_case("FAIL"));
    if failed_host_policy {
        return (
            "主机保护审计未通过；不能声明 WSL 已受保护。".into(),
            "查看本代次检查与日志，运行 Doctor 定位策略差异；请勿通过关闭保护恢复直连。".into(),
        );
    }
    match (report.action, report.outcome) {
        (Action::Status | Action::Doctor, Outcome::Succeeded) => (
            if matches!(report.phase.as_str(), "uninstalled" | "restored") {
                "未安装活动的 WSL 保护；首次部署需要 WireGuard 私密 JSON 配置。"
            } else {
                "已读取实际部署状态；连接、出口与安全验收分别显示。"
            }
            .into(),
            "连接使用已安装的受保护配置；需要实测时点击测试。".into(),
        ),
        (Action::Start, Outcome::Succeeded) => (
            "连接操作已完成；是否能正常联网及出口位置请查看测试结果。".into(),
            "点击测试核验当前隧道、DNS、IPv6 与出口；后台连接不等于完整安全验收。".into(),
        ),
        (Action::Stop, Outcome::Succeeded) => (
            "隧道已断开，原有防直连保护保留。".into(),
            "点击连接恢复隧道；恢复原网络需独立确认。".into(),
        ),
        (Action::Install, Outcome::Succeeded) => (
            "安装已完成；保护保持关闭外部直连，下一步连接并测试。".into(),
            "点击连接，按 Windows 提示完成 UAC，再运行测试。".into(),
        ),
        (Action::Install, _) if report.phase == "preflight" => (
            "安装预检已完成；没有应用网络变更，请查看检查结果。".into(),
            "修复 FAIL/BLOCKED 项后执行安装；私密配置内容不会显示在页面。".into(),
        ),
        (Action::Test, Outcome::Succeeded) => (
            if report.functional_ready() {
                "本代次测试满足全部已定义验收条件。"
            } else {
                "实测已执行；仍有安全或功能验收项目未满足，请查看各项结果。"
            }
            .into(),
            "PASS 仅代表对应的已执行项目；NOT_RUN、BLOCKED 与未执行的重启测试不计通过。".into(),
        ),
        (Action::Test, Outcome::NotRun) => (
            "测试未执行；不能根据隧道进程或静态配置判断出口可用。".into(),
            "查看 NOT_RUN 项与运行条件，完成连接后重试测试。".into(),
        ),
        (_, Outcome::Blocked | Outcome::Failed) => (
            if report.message == "[redacted]" || report.message.is_empty() {
                "管理操作未完成；保护状态需要重新检查，请查看本代次检查与日志。".into()
            } else {
                report.message.clone()
            },
            "先刷新状态与 Doctor；根据本代次检查修复前置条件后重试，恢复原网络仍需独立确认。"
                .into(),
        ),
        _ => (
            report.message.clone(),
            "查看本代次检查；未执行或未验证的项目不会计为通过。".into(),
        ),
    }
}

fn recovery_guidance(report: &Report) -> Option<&str> {
    let blocked = |id: &str| {
        report.checks.iter().any(|check| {
            check.id == id
                && matches!(
                    check.result.to_ascii_uppercase().as_str(),
                    "FAIL" | "BLOCKED"
                )
        })
    };
    if report.phase == "closure_unverified" {
        Some(
            "先停止使用 WSL 联网应用，运行 Doctor 并检查 endpoint_closure；当前不能确认外层端点已关闭。",
        )
    } else if blocked("windows_network_preserved") {
        Some(
            "Windows 必保连接检查失败；先修复现有 DNS、TLS 或 HTTP 通路，再重试。此时不应继续修改网络策略。",
        )
    } else if blocked("private_profile") {
        Some(
            "点击选择文件，指定本地私密 WireGuard JSON，再运行安装预检；地址与端口不能替代密钥配置。",
        )
    } else if blocked("configuration_match") {
        Some(
            "草稿与受保护安装配置不一致。先刷新状态；已有部署使用连接按钮，不要重复安装或覆盖回滚快照。",
        )
    } else if blocked("manager_distribution") {
        Some(
            "请先通过 Windows 官方 wsl --install 流程准备配置声明的 WSL2 发行版，并使 manager_distro 与已注册名称一致。",
        )
    } else if blocked("linux_dependencies") {
        Some(
            "在管理发行版安装 python3、iproute2、nftables、wireguard-tools、bubblewrap、util-linux，然后重新运行安装预检。",
        )
    } else if blocked("functional_egress")
        && !report
            .checks
            .iter()
            .any(|check| check.id == "virtual_interfaces")
    {
        Some(
            "严格隔离测试未能启动。点击连接并完成 UAC，更新主机范围审计后重试测试；不要绕过过期证明。",
        )
    } else if report.generation > 0
        && report.backend == Backend::Tailscale
        && !matches!(report.phase.as_str(), "uninstalled" | "restored")
    {
        Some(
            "检测到旧 Tailscale 部署；当前严格模式不能连接此后端。保留保护，停止全部 WSL 后单独确认恢复，再以 WireGuard 重新安装。",
        )
    } else {
        report
            .checks
            .iter()
            .find(|check| {
                check.id == "recovery_action"
                    && !check.detail.is_empty()
                    && check.detail != "[redacted]"
            })
            .map(|check| check.detail.as_str())
    }
}

pub(super) struct State {
    pub(super) draft: WslSettings,
    installed_profile_path: String,
    pub(super) evidence: contract::State,
    message: String,
    administrator_command: String,
    deployment: Option<Deployment>,
    inspected: bool,
    draft_edited: bool,
    profile_picker_open: bool,
    last_observed: Option<std::time::Instant>,
    next_refresh: std::time::Instant,
    last_operation: String,
    guidance: String,
    cancelled: bool,
    // A timeout cannot establish that Linux descendants have exited. Permit
    // only read-only inspection until a new broker report has been accepted.
    inspection_required: bool,
}

/// Last inspected installation metadata, deliberately separate from live
/// security evidence and from the user's installation draft.
#[derive(Debug, Clone)]
struct Deployment {
    backend: Backend,
    generation: u64,
    phase: String,
}

impl State {
    pub(super) fn new(draft: WslSettings) -> Self {
        Self {
            installed_profile_path: draft.profile_path.clone(),
            draft,
            evidence: contract::State::default(),
            message: "尚未检查；完整冷启动验收未完成，当前不声明已建立保护。".into(),
            administrator_command: String::new(),
            deployment: None,
            inspected: false,
            draft_edited: false,
            profile_picker_open: false,
            last_observed: None,
            next_refresh: std::time::Instant::now(),
            last_operation: "尚未执行管理操作。".into(),
            guidance: "打开本页后自动只读检查；首次安装需要本机私密 WireGuard JSON 配置。".into(),
            cancelled: false,
            inspection_required: false,
        }
    }

    pub(super) fn load_preferences(&mut self, draft: WslSettings) {
        if !self.draft_edited && !self.evidence.busy() {
            if self.deployment.is_none() {
                self.installed_profile_path.clone_from(&draft.profile_path);
            }
            self.draft = draft;
            if let Some(deployment) = &self.deployment {
                self.draft.backend = deployment.backend;
            }
        }
    }

    fn controls_busy(&self) -> bool {
        self.evidence.busy() || self.profile_picker_open
    }

    fn evidence_fresh(&self) -> bool {
        self.last_observed
            .is_some_and(|observed| observed.elapsed() <= Duration::from_secs(30))
    }

    fn observe(&mut self, report: &Report) {
        self.last_observed = Some(std::time::Instant::now());
        if report.outcome != contract::Outcome::Succeeded {
            return;
        }
        if matches!(report.phase.as_str(), "uninstalled" | "restored") {
            self.deployment = None;
            self.installed_profile_path.clear();
            self.inspected = true;
        } else if report.generation != 0
            && matches!(
                report.phase.as_str(),
                "installed_closed"
                    | "connected_unverified"
                    | "verified"
                    | "failed_closed_requested"
                    | "blocked"
                    | "failed"
                    | "preparing"
                    | "closure_unverified"
            )
        {
            self.deployment = Some(Deployment {
                backend: report.backend,
                generation: report.generation,
                phase: report.phase.clone(),
            });
            self.inspected = true;
            if !self.draft_edited {
                self.draft.backend = report.backend;
            }
        }
    }

    fn request(&self, action: contract::Action, execute: bool) -> contract::Request {
        if action == contract::Action::Install {
            self.draft.request(action, execute)
        } else if action == contract::Action::Start {
            let mut request = contract::Request::installed(
                action,
                self.deployment
                    .as_ref()
                    .map_or(self.draft.backend, |deployment| deployment.backend),
                execute,
            );
            request
                .profile_path
                .clone_from(&self.installed_profile_path);
            request
        } else {
            contract::Request::installed(
                action,
                self.deployment
                    .as_ref()
                    .map_or(self.draft.backend, |deployment| deployment.backend),
                execute,
            )
        }
    }

    fn edit(&mut self, key: &str, value: String) {
        if self.controls_busy() {
            return;
        }
        self.administrator_command.clear();
        if let Err(error) = self.evidence.invalidate() {
            self.message = error.to_string();
            return;
        }
        if value.len() > 1024 || value.chars().any(char::is_control) {
            self.message = "输入无效；旧代次证据已废弃。".into();
            return;
        }
        match key {
            "backend" => {
                match value.as_str() {
                    "Tailscale" => {
                        self.message = "严格全 WSL 模式暂不支持 Tailscale 安装；请使用固定 Endpoint WireGuard。".into();
                        return;
                    }
                    "WireGuard" => self.draft.backend = Backend::WireGuard,
                    _ => {
                        self.message = "后端无效；旧代次证据已废弃。".into();
                        return;
                    }
                }
            }
            "endpoint-ipv4" => self.draft.endpoint_ipv4 = value,
            "endpoint-port" => self.draft.endpoint_port = value,
            "distro" => self.draft.distro = value,
            "profile-path" => self.draft.profile_path = value,
            _ => {
                self.message = "未知配置字段；旧代次证据已废弃。".into();
                return;
            }
        }
        self.draft_edited = true;
        self.message = "安装草稿已编辑；现有部署不受影响。连接与断开始终使用已安装配置。".into();
        self.guidance = "先选择私密 JSON 文件并运行安装预检；仅安装会应用这些字段。".into();
    }
}

impl App {
    pub(super) fn wsl_event(&mut self, event: Event) -> Task<Message> {
        match event {
            Event::Tick => {
                if cfg!(windows)
                    && self.visible
                    && self.page == Page::Wsl
                    && !self.exiting
                    && self.confirmation.is_none()
                    && !self.wsl.controls_busy()
                    && std::time::Instant::now() >= self.wsl.next_refresh
                {
                    let request = self.wsl.request(contract::Action::Status, false);
                    return self.start_wsl_request(request);
                }
            }
            Event::ProfileSelected(result) => {
                if !self.wsl.profile_picker_open {
                    return Task::none();
                }
                self.wsl.profile_picker_open = false;
                if self.exiting {
                    return Task::none();
                }
                match result {
                    Ok(Some(path)) => {
                        let Some(path) = path.to_str() else {
                            self.wsl.message =
                                "配置路径无法编码；请选择有效的本地 JSON 文件。".into();
                            return Task::none();
                        };
                        let candidate = WslSettings {
                            profile_path: path.into(),
                            ..Default::default()
                        };
                        if let Err(error) = candidate.validate() {
                            self.wsl.message = validation_message(error).into();
                        } else {
                            self.wsl.edit("profile-path", path.into());
                            self.wsl.guidance = "文件路径已通过本地语法校验；安装预检将验证 JSON、权限与配置一致性，不展示密钥。".into();
                        }
                    }
                    Ok(None) => self.wsl.message = "已取消选择文件；配置未变更。".into(),
                    Err(()) => {
                        self.wsl.message =
                            "无法打开文件选择器；可直接填写本地 JSON 绝对路径。".into()
                    }
                }
            }
            Event::Finished(ticket, result, command) => {
                let automatic = ticket.request.action == contract::Action::Status;
                let mut result_feedback = None;
                let accepted = match *result {
                    Ok(report) => {
                        let failed = report.outcome == contract::Outcome::Failed;
                        result_feedback = Some(operation_feedback(&report));
                        let accepted = self.wsl.evidence.apply(&ticket, report);
                        if accepted.is_ok()
                            && ticket.request.execute
                            && ticket.request.action == contract::Action::Install
                            && self.wsl.evidence.report().is_some_and(|report| {
                                report.outcome == contract::Outcome::Succeeded
                            })
                        {
                            self.wsl
                                .installed_profile_path
                                .clone_from(&ticket.request.profile_path);
                        }
                        if ticket.request.execute
                            && (failed || accepted.is_err())
                            && accepted != Err(contract::Error::StaleOperation)
                        {
                            self.wsl.inspection_required = true;
                        }
                        accepted
                    }
                    Err(error) => {
                        let accepted = self
                            .wsl
                            .evidence
                            .fail(&ticket, contract::Error::HelperFailed);
                        if accepted.is_ok() {
                            self.wsl.cancelled =
                                matches!(error, Failure::Runner(runner::Error::ElevationCancelled));
                            self.wsl.message = error.message();
                            if !automatic {
                                self.wsl.last_operation = self.wsl.message.clone();
                                self.wsl.guidance = "可重试刚才的操作；若超时或输出无效，先刷新状态与 Doctor，确认后再重试。".into();
                            }
                            self.wsl.inspection_required |= ticket.request.execute
                                && matches!(
                                    error,
                                    Failure::Runner(runner::Error::Timeout | runner::Error::Output)
                                        | Failure::Contract(_)
                                );
                        }
                        accepted
                    }
                };
                // Stale callbacks never overwrite a newer operation's status,
                // administrator instructions, busy state, or list generation.
                if let Err(error) = accepted {
                    if error != contract::Error::StaleOperation {
                        self.wsl.message = error.to_string();
                    }
                    return Task::none();
                }
                self.wsl.administrator_command = command;
                if let Some(report) = self.wsl.evidence.report().cloned() {
                    self.wsl.observe(&report);
                    self.wsl.message.clone_from(&report.message);
                    if let Some((feedback, guidance)) = result_feedback {
                        self.wsl.message = feedback.clone();
                        if !automatic {
                            self.wsl.last_operation = feedback;
                            self.wsl.guidance = guidance;
                        }
                    }
                    if let Some(guidance) = recovery_guidance(&report) {
                        self.wsl.guidance = guidance.into();
                    }
                    // Status is the explicit read-only recovery event. It may
                    // clear the interlock only after a fresh, parsed broker
                    // report says that no mutation is active.
                    if self.wsl.evidence.inspection_is_settled() {
                        self.wsl.inspection_required = false;
                    }
                }
                self.wsl.next_refresh = std::time::Instant::now() + Duration::from_secs(15);
            }
            Event::Input(key, value) => {
                if !self.exiting && self.confirmation.is_none() {
                    self.wsl.edit(&key, value);
                }
            }
            Event::Action(action, mode) => {
                if self.exiting || self.wsl.controls_busy() || self.confirmation.is_some() {
                    return Task::none();
                }
                if action == "ChooseProfile" {
                    #[cfg(windows)]
                    {
                        self.wsl.profile_picker_open = true;
                        return Task::perform(
                            async {
                                clash_of_rust::file_dialog::choose_wsl_profile()
                                    .await
                                    .map_err(|_| ())
                            },
                            |result| Message::Wsl(Event::ProfileSelected(result)),
                        );
                    }
                    #[cfg(not(windows))]
                    return Task::none();
                }
                let action = match action.as_str() {
                    "Doctor" => contract::Action::Doctor,
                    "Status" => contract::Action::Status,
                    "Install" => contract::Action::Install,
                    "Start" => contract::Action::Start,
                    "Stop" => contract::Action::Stop,
                    "Test" => contract::Action::Test,
                    "Rollback" => contract::Action::Rollback,
                    "Uninstall" => contract::Action::Uninstall,
                    _ => {
                        let _ = self.wsl.evidence.invalidate();
                        self.wsl.message = "未知 WSL 操作；未执行。".into();
                        return Task::none();
                    }
                };
                if mode == "restore-confirm" && action == contract::Action::Rollback {
                    return self.ask(
                        "恢复 WSL 原网络并撤销本轮保护？",
                        "仅在全部 WSL 发行版已手动停止时恢复本轮快照。恢复后 WSL 可能恢复直接联网；Docker Desktop 数据将保留。取消将保留保护。".into(),
                        "恢复原网络",
                        desktop_view::Pending::WslRestore(self.wsl.draft.clone()),
                    );
                }
                if !matches!(mode.as_str(), "preview" | "execute") {
                    let _ = self.wsl.evidence.invalidate();
                    self.wsl.message = "执行模式无效；未执行。".into();
                    return Task::none();
                }
                if action == contract::Action::Install
                    && mode == "execute"
                    && self.wsl.deployment.is_some()
                {
                    self.wsl.message =
                        "此计算机已有 WSL 部署；请直接连接，避免覆盖原始回滚快照。".into();
                    self.wsl.guidance =
                        "使用连接、测试或 Doctor；迁移安装需先定向恢复现有部署。".into();
                    return Task::none();
                }
                if matches!(action, contract::Action::Start | contract::Action::Test)
                    && self.wsl.deployment.is_none()
                {
                    self.wsl.message = if self.wsl.inspected {
                        "尚未安装 WSL 安全网络；请先选择私密 JSON 配置并完成安装预检。"
                    } else {
                        "尚未确认实际部署；请先刷新状态或等待自动检查，再连接或测试。"
                    }
                    .into();
                    return Task::none();
                }
                let request = self.wsl.request(action, mode == "execute");
                return self.start_wsl_request(request);
            }
            Event::RestoreConfirmed(draft) => {
                if self.exiting || self.wsl.evidence.busy() || draft != self.wsl.draft {
                    return Task::none();
                }
                let mut request = self.wsl.request(contract::Action::Rollback, true);
                request.restore_original_network = true;
                return self.start_wsl_request(request);
            }
        }
        Task::none()
    }

    fn start_wsl_request(&mut self, request: contract::Request) -> Task<Message> {
        if !cfg!(windows) {
            let _ = self.wsl.evidence.invalidate();
            self.wsl.message = runner::Error::Unsupported.message().into();
            return Task::none();
        }
        if self.wsl.inspection_required
            && !matches!(
                request.action,
                contract::Action::Doctor | contract::Action::Status
            )
        {
            self.wsl.message = "上次管理操作状态未知；请先刷新状态或运行 Doctor。只有新的状态报告确认没有进行中的变更后，才允许继续管理。".into();
            return Task::none();
        }
        let ticket = match self.wsl.evidence.begin(&request) {
            Ok(ticket) => ticket,
            Err(error) => {
                self.wsl.message = validation_message(error).into();
                self.wsl.last_operation = self.wsl.message.clone();
                self.wsl.guidance = "修改安装草稿后先运行安装预检；已安装环境可直接连接，不需要再次填写端点或密钥路径。".into();
                return Task::none();
            }
        };
        self.wsl.administrator_command.clear();
        self.wsl.cancelled = false;
        self.wsl.next_refresh = std::time::Instant::now() + Duration::from_secs(15);
        self.wsl.message = if request.execute || request.action == contract::Action::Test {
            "正在异步执行；如需管理员权限，Windows 将显示 UAC 授权。请完成或取消授权后等待结果。"
        } else {
            "正在只读检查，不启动已停止的 WSL 发行版。"
        }
        .into();
        let settings = self.wsl.draft.clone();
        let persist_preferences = request.action == contract::Action::Install;
        let engine = self.engine.clone();
        Task::perform(
            async move {
                let arguments = match request.arguments() {
                    Ok(arguments) => arguments
                        .into_iter()
                        .map(std::ffi::OsString::from)
                        .collect::<Vec<_>>(),
                    Err(error) => return (ticket, Err(Failure::Contract(error)), String::new()),
                };
                // Persist preferences on the worker under the existing engine lock;
                // preserve all unrelated settings and never regenerate network config.
                if persist_preferences && let Some(engine) = engine {
                    let mut engine = engine.lock().await;
                    let mut saved = engine.settings.clone();
                    saved.wsl = settings;
                    if engine.store.save_settings(&saved).is_err() {
                        return (ticket, Err(Failure::Preferences), String::new());
                    }
                    engine.settings = saved;
                }
                let command = if request.execute || request.action == contract::Action::Test {
                    runner::administrator_command(arguments.clone()).await
                } else {
                    String::new()
                };
                let result = runner::run(arguments)
                    .await
                    .map_err(Failure::Runner)
                    .and_then(|raw| Report::parse(&raw).map_err(Failure::Contract));
                (ticket, result, command)
            },
            |(ticket, result, command)| {
                Message::Wsl(Event::Finished(ticket, Box::new(result), command))
            },
        )
    }

    pub(super) fn present_wsl(&self, data: &UiData<'_>, models: &mut ViewModels) {
        let state = &self.wsl;
        data.set_wsl_supported(cfg!(windows));
        data.set_wsl_busy(state.controls_busy());
        data.set_wsl_installed(state.deployment.is_some());
        data.set_wsl_backend(state.draft.backend.as_str().into());
        data.set_wsl_deployed_backend(
            state
                .deployment
                .as_ref()
                .map_or("尚未确认", |deployment| deployment.backend.as_str())
                .into(),
        );
        data.set_wsl_deployment(
            state
                .deployment
                .as_ref()
                .map_or_else(
                    || {
                        if state.inspected {
                            "未安装".to_owned()
                        } else {
                            "尚未检查".to_owned()
                        }
                    },
                    |deployment| {
                        format!(
                            "{} · generation {} · {}",
                            deployment.backend.as_str(),
                            deployment.generation,
                            deployment.phase
                        )
                    },
                )
                .into(),
        );
        data.set_wsl_monitor(
            state
                .last_observed
                .map_or_else(
                    || "本页打开时自动检查，此后每 15 秒刷新。".to_owned(),
                    |observed| {
                        format!(
                            "每 15 秒自动只读刷新 · 上次结果 {} 秒前",
                            observed.elapsed().as_secs()
                        )
                    },
                )
                .into(),
        );
        data.set_wsl_last_operation(state.last_operation.as_str().into());
        data.set_wsl_guidance(state.guidance.as_str().into());
        data.set_wsl_endpoint_ipv4(state.draft.endpoint_ipv4.as_str().into());
        data.set_wsl_endpoint_port(state.draft.endpoint_port.as_str().into());
        data.set_wsl_distro(state.draft.distro.as_str().into());
        data.set_wsl_profile_path(state.draft.profile_path.as_str().into());
        data.set_wsl_message(state.message.as_str().into());
        data.set_wsl_admin_command(state.administrator_command.as_str().into());
        data.set_wsl_generation(
            state
                .evidence
                .service_generation()
                .unwrap_or(0)
                .to_string()
                .into(),
        );
        let fresh = state.evidence_fresh();
        data.set_wsl_protection(
            if fresh {
                state.evidence.protection().as_str()
            } else {
                "blocked"
            }
            .into(),
        );
        let report = state.evidence.report();
        data.set_wsl_status(
            if state.cancelled {
                "cancelled"
            } else if state.evidence.last_error.is_some() {
                "failed"
            } else {
                report.map_or("not_run", |r| r.outcome.as_str())
            }
            .into(),
        );
        data.set_wsl_phase(
            if state.evidence.busy() {
                "running"
            } else {
                report.map_or("idle", |r| r.phase.as_str())
            }
            .into(),
        );
        let connected = fresh
            && report.is_some_and(|report| match report.backend {
                Backend::Tailscale => report.tailscale_connected(),
                Backend::WireGuard => report.check_passed("wireguard_connected"),
            });
        data.set_wsl_tunnel(
            if connected {
                "已验证连接"
            } else {
                "unknown · 未验证"
            }
            .into(),
        );
        data.set_wsl_exit(
            if fresh && state.evidence.german_exit_verified() {
                "DE · IPv4 已验证"
            } else {
                "unknown · 德国 IPv4 未验证"
            }
            .into(),
        );
        data.set_wsl_functional(
            if fresh && state.evidence.functional_ready() {
                "verified"
            } else {
                "Blocked · 完整验收未完成"
            }
            .into(),
        );
        if !self.visible || self.page != Page::Wsl {
            models.clear_wsl_results();
            return;
        }
        let distributions = report.map_or_else(Vec::new, |report| {
            report
                .distributions
                .iter()
                .map(|d| WslDistributionItem {
                    name: d.name.as_str().into(),
                    state: d.state.as_str().into(),
                    coverage: d.coverage.as_str().into(),
                })
                .collect()
        });
        let checks = report.map_or_else(Vec::new, |report| {
            report
                .checks
                .iter()
                .map(|check| DetailItem {
                    label: check.id.as_str().into(),
                    value: format!("{} · {}", check.result, check.detail).into(),
                })
                .collect()
        });
        let logs = report.map_or_else(Vec::new, |report| {
            report
                .logs
                .iter()
                .map(|line| line.as_str().into())
                .collect()
        });
        // Model generation uses the local epoch: input edits clear evidence even
        // while the broker's independent millisecond generation is unchanged.
        let _ = models.set_wsl_results(state.evidence.generation, distributions, checks, logs);
    }
}
