//! Fixed-file WSL bridge with a same-user UAC channel for privileged operations.
use std::ffi::OsString;

#[cfg(windows)]
#[path = "elevation.rs"]
mod elevation;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(not(windows), allow(dead_code))]
pub(in crate::application) enum Error {
    Unsupported,
    Unavailable,
    SystemAccount,
    ElevationCancelled,
    ElevationTimedOut,
    IdentityMismatch,
    Launch,
    Timeout,
    Output,
}

impl Error {
    pub(super) const fn message(self) -> &'static str {
        match self {
            Self::Unsupported => "WSL 安全网络仅支持 Windows。",
            Self::Unavailable => "受信任的 WSL 管理资源不可用；请修复 fork 安装包。",
            Self::SystemAccount => "禁止使用 SYSTEM 身份操作用户 WSL。",
            Self::ElevationCancelled => {
                "已取消管理员授权，未执行本次网络变更。请再次点击原操作，并在 Windows UAC 中允许当前用户提权。"
            }
            Self::ElevationTimedOut => {
                "等待管理员授权超时，未发送管理请求。请取消仍显示的 UAC 窗口，再重新执行原操作。"
            }
            Self::IdentityMismatch => {
                "管理员进程身份校验失败，未发送管理请求。请使用当前 Windows 用户授权，不要输入其他管理员账户。"
            }
            Self::Launch => {
                "无法启动 WSL 管理操作。请确认正式安装完整，并允许 Windows 显示管理员授权窗口。"
            }
            Self::Timeout => "WSL 管理操作超时；实际保护状态未知，请刷新状态后再操作。",
            Self::Output => "WSL 管理输出无效或超过大小限制；保护状态未知。",
        }
    }
}

#[cfg(not(windows))]
pub(super) async fn run(_arguments: Vec<OsString>) -> Result<String, Error> {
    Err(Error::Unsupported)
}

#[cfg(windows)]
pub(super) async fn run(arguments: Vec<OsString>) -> Result<String, Error> {
    use std::{process::Stdio, time::Duration};
    use tokio::io::AsyncReadExt;

    let (powershell, script, _verified) = tokio::task::spawn_blocking(trusted_paths)
        .await
        .map_err(|_| Error::Unavailable)??;
    if needs_elevation(&arguments) {
        if !protected_installation(&script) {
            return Err(Error::Unavailable);
        }
        let helper = script
            .parent()
            .ok_or(Error::Unavailable)?
            .join("Invoke-WslSecureEgressElevated.ps1");
        return elevation::run(powershell, helper, arguments).await;
    }
    let directory = script.parent().ok_or(Error::Unavailable)?;
    let mut child = tokio::process::Command::new(powershell)
        .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-File"])
        .arg(&script)
        .args(arguments)
        .current_dir(directory)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(0x08000000)
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| Error::Launch)?;
    let stdout = child.stdout.take().ok_or(Error::Output)?;
    let mut stderr = child.stderr.take().ok_or(Error::Output)?;
    // Read both pipes concurrently; never retain stderr, raw errors or command
    // lines, which may include private profile paths or credentials.
    const LIMIT: u64 = 1024 * 1024;
    let operation = async {
        let output = async {
            let mut bytes = Vec::new();
            stdout.take(LIMIT + 1).read_to_end(&mut bytes).await?;
            Ok::<_, std::io::Error>(bytes)
        };
        let discarded = async { tokio::io::copy(&mut stderr, &mut tokio::io::sink()).await };
        let (bytes, _, status) =
            tokio::try_join!(output, discarded, child.wait()).map_err(|_| Error::Output)?;
        if bytes.len() as u64 > LIMIT {
            return Err(Error::Output);
        }
        // A blocked operation may use a non-zero process exit. The strict JSON
        // contract, rather than an exit code, determines its displayed outcome.
        let text = String::from_utf8(bytes)
            .map(|text| text.trim_start_matches('\u{feff}').to_owned())
            .map_err(|_| Error::Output)?;
        let value: serde_json::Value = serde_json::from_str(&text).map_err(|_| Error::Output)?;
        if !status.success() && !matches!(value["outcome"].as_str(), Some("blocked" | "failed")) {
            return Err(Error::Output);
        }
        Ok(text)
    };
    match tokio::time::timeout(Duration::from_secs(300), operation).await {
        Ok(result) => result,
        Err(_) => {
            let _ = child.kill().await;
            Err(Error::Timeout)
        }
    }
}

fn needs_elevation(arguments: &[OsString]) -> bool {
    arguments.iter().any(|argument| argument == "-Execute")
        || arguments
            .windows(2)
            .any(|pair| pair[0] == "-Action" && pair[1] == "Test")
}

#[cfg(windows)]
fn trusted_paths() -> Result<
    (
        std::path::PathBuf,
        std::path::PathBuf,
        super::payload::Verified,
    ),
    Error,
> {
    use std::{os::windows::fs::MetadataExt, path::PathBuf};
    use windows_sys::Win32::{
        Foundation::CloseHandle,
        Security::{
            GetTokenInformation, IsWellKnownSid, TOKEN_QUERY, TOKEN_USER, TokenUser,
            WinLocalServiceSid, WinLocalSystemSid, WinNetworkServiceSid,
        },
        System::{
            SystemInformation::GetSystemDirectoryW,
            Threading::{GetCurrentProcess, OpenProcessToken},
        },
    };

    // A service must never enumerate or launch a user's distributions. Do not
    // infer identity from environment variables such as USERNAME.
    let mut token = std::ptr::null_mut();
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(Error::SystemAccount);
    }
    let mut needed = 0;
    unsafe { GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut needed) };
    let mut buffer = vec![0usize; (needed as usize).div_ceil(std::mem::size_of::<usize>())];
    let success = unsafe {
        GetTokenInformation(
            token,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            needed,
            &mut needed,
        )
    };
    unsafe { CloseHandle(token) };
    if success == 0 || buffer.is_empty() {
        return Err(Error::SystemAccount);
    }
    let sid = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() }.User.Sid;
    if [WinLocalSystemSid, WinLocalServiceSid, WinNetworkServiceSid]
        .into_iter()
        .any(|kind| unsafe { IsWellKnownSid(sid, kind) } != 0)
    {
        return Err(Error::SystemAccount);
    }

    let mut directory = vec![0u16; 32768];
    let length =
        unsafe { GetSystemDirectoryW(directory.as_mut_ptr(), directory.len() as u32) } as usize;
    if length == 0 || length >= directory.len() {
        return Err(Error::Unavailable);
    }
    let powershell =
        PathBuf::from(String::from_utf16(&directory[..length]).map_err(|_| Error::Unavailable)?)
            .join("WindowsPowerShell/v1.0/powershell.exe");
    if !powershell.is_file() {
        return Err(Error::Unavailable);
    }

    let executable = std::env::current_exe().map_err(|_| Error::Unavailable)?;
    let installed = executable.parent().ok_or(Error::Unavailable)?;
    let resources = installed.join("resources");
    let package = resources.join("wsl-secure-egress");
    let script = package.join("Manage-WslSecureEgress.ps1");
    // Reject junctions/reparse points in the resource chain. There is no debug
    // fallback to cwd, a development checkout, PATH or a user-selected script.
    for path in [&resources, &package, &script] {
        let metadata = std::fs::symlink_metadata(path).map_err(|_| Error::Unavailable)?;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(Error::Unavailable);
        }
    }
    let verified = super::payload::verify(&package).map_err(|_| Error::Unavailable)?;
    Ok((powershell, script, verified))
}

/// Display-only instructions. No shell evaluates this string in the client.
#[cfg(windows)]
pub(super) async fn administrator_command(arguments: Vec<OsString>) -> String {
    let Ok(Ok((powershell, script, _verified))) = tokio::task::spawn_blocking(trusted_paths).await
    else {
        return "# 未找到校验通过的安装资源；请先修复定制版安装包。".into();
    };
    if !protected_installation(&script) {
        return "# 管理员操作仅支持 Program Files 内的正式安装资源；请先修复定制版安装位置。"
            .into();
    }
    administrator_fallback(&powershell, &script, &arguments)
        .unwrap_or_else(|_| "# 路径无法安全编码；请修复正式安装位置。".into())
}

#[cfg(windows)]
fn administrator_arguments(
    script: &std::path::Path,
    arguments: &[OsString],
) -> Result<String, Error> {
    let fixed = ["-NoLogo", "-NoProfile", "-NonInteractive", "-File"];
    fixed
        .iter()
        .map(std::ffi::OsStr::new)
        .chain(std::iter::once(script.as_os_str()))
        .chain(arguments.iter().map(OsString::as_os_str))
        .map(elevation::quote)
        .collect::<Result<Vec<_>, _>>()
        .map(|parts| parts.join(" "))
}

#[cfg(windows)]
fn administrator_fallback(
    powershell: &std::path::Path,
    script: &std::path::Path,
    arguments: &[OsString],
) -> Result<String, Error> {
    // Start-Process joins ArgumentList into one native command line. First use
    // Windows native quoting, then wrap that complete string as one PS literal.
    // No shell in the client evaluates this optional, display-only fallback.
    let literal = |value: &str| format!("'{}'", value.replace('\'', "''"));
    let executable = powershell.to_str().ok_or(Error::Unavailable)?;
    let inner = administrator_arguments(script, arguments)?;
    Ok(format!(
        "# 复制到当前用户的 PowerShell 后手动执行；会显示 UAC，不会静默提权：\n\
         Start-Process -FilePath {} -Verb RunAs -Wait -ArgumentList {}",
        literal(executable),
        literal(&inner),
    ))
}

#[cfg(windows)]
fn protected_installation(script: &std::path::Path) -> bool {
    use windows_sys::Win32::{
        System::Com::CoTaskMemFree,
        UI::Shell::{FOLDERID_ProgramFiles, SHGetKnownFolderPath},
    };
    let mut raw = std::ptr::null_mut();
    if unsafe { SHGetKnownFolderPath(&FOLDERID_ProgramFiles, 0, std::ptr::null_mut(), &mut raw) }
        < 0
    {
        return false;
    }
    let mut length = 0;
    unsafe {
        while *raw.add(length) != 0 {
            length += 1;
        }
    }
    let folder = unsafe { String::from_utf16(std::slice::from_raw_parts(raw, length)) };
    unsafe { CoTaskMemFree(raw.cast()) };
    let Ok(folder) = folder else {
        return false;
    };
    let (Ok(script), Ok(folder)) = (
        script.canonicalize(),
        std::path::Path::new(&folder).canonicalize(),
    ) else {
        return false;
    };
    if !script.starts_with(&folder) {
        return false;
    }
    for path in script.ancestors() {
        if !elevation::protected_permissions(path) {
            return false;
        }
        if path == folder {
            return true;
        }
    }
    false
}

#[cfg(not(windows))]
pub(super) async fn administrator_command(_arguments: Vec<OsString>) -> String {
    "WSL 安全网络仅支持 Windows。".into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn readonly_and_preflight_never_request_uac() {
        for action in ["Doctor", "Status", "Install"] {
            assert!(!needs_elevation(&[
                "-Action".into(),
                action.into(),
                "-ProfilePath".into(),
                "C:\\private\\-Execute.json".into(),
            ]));
        }
        assert!(needs_elevation(&[
            "-Action".into(),
            "Start".into(),
            "-Execute".into()
        ]));
        assert!(needs_elevation(&["-Action".into(), "Test".into()]));
    }

    #[cfg(windows)]
    #[test]
    fn administrator_fallback_preserves_native_paths_and_powershell_literals() {
        use std::{ffi::OsStr, os::windows::ffi::OsStrExt, path::Path};
        use windows_sys::Win32::{Foundation::LocalFree, UI::Shell::CommandLineToArgvW};

        let script = Path::new(r"C:\Program Files\Clash's Rust\Manage-WslSecureEgress.ps1");
        let args = vec![
            OsString::from("-ProfilePath"),
            OsString::from(r#"C:\private folder\a"quoted"\profile.json"#),
            OsString::from("-Distro"),
            OsString::from("a'b c\\"),
        ];
        let inner = administrator_arguments(script, &args).unwrap();
        let command: Vec<u16> = OsStr::new(&format!("powershell.exe {inner}"))
            .encode_wide()
            .chain(Some(0))
            .collect();
        let mut count = 0;
        let raw = unsafe { CommandLineToArgvW(command.as_ptr(), &mut count) };
        assert!(!raw.is_null());
        let values = unsafe { std::slice::from_raw_parts(raw, count as usize) }
            .iter()
            .map(|&text| {
                let mut length = 0;
                unsafe {
                    while *text.add(length) != 0 {
                        length += 1;
                    }
                    String::from_utf16(std::slice::from_raw_parts(text, length)).unwrap()
                }
            })
            .collect::<Vec<_>>();
        unsafe { LocalFree(raw.cast()) };
        assert_eq!(values[5], script.to_str().unwrap());
        assert_eq!(
            values[6..],
            args.iter()
                .map(|arg| arg.to_str().unwrap())
                .collect::<Vec<_>>()
        );
        let fallback = administrator_fallback(
            Path::new(r"C:\Program Files\PowerShell's\powershell.exe"),
            script,
            &args,
        )
        .unwrap();
        assert!(fallback.contains("-FilePath 'C:\\Program Files\\PowerShell''s\\powershell.exe'"));
        assert!(fallback.contains("-Verb RunAs -Wait -ArgumentList '"));
        assert!(fallback.contains("Clash''s Rust"));
        assert!(fallback.contains("\"C:\\Program Files\\"));
        assert!(fallback.ends_with('\''));
    }
}
