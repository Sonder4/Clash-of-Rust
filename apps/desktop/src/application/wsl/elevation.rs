//! A local, first-instance pipe transfers arguments only after both peers agree
//! on process identity. The UAC command line contains no profile or endpoint.
use super::Error;
use std::{
    ffi::{OsStr, OsString},
    os::windows::{ffi::OsStrExt, io::AsRawHandle},
    path::PathBuf,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::windows::named_pipe::{NamedPipeServer, ServerOptions},
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, ERROR_CANCELLED, GetLastError, HANDLE, LocalFree, STILL_ACTIVE},
    Security::{
        ACCESS_ALLOWED_ACE, ACE_HEADER, ACL,
        Authorization::{
            ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
            GetNamedSecurityInfoW, SE_FILE_OBJECT,
        },
        DACL_SECURITY_INFORMATION, GetAce, GetTokenInformation, OWNER_SECURITY_INFORMATION,
        SECURITY_ATTRIBUTES, TOKEN_ELEVATION, TOKEN_QUERY, TOKEN_USER, TokenElevation,
        TokenSessionId, TokenUser,
    },
    System::{
        Pipes::GetNamedPipeClientProcessId,
        Threading::{
            GetCurrentProcess, GetExitCodeProcess, GetProcessId, OpenProcess, OpenProcessToken,
            PROCESS_QUERY_LIMITED_INFORMATION,
        },
    },
    UI::{
        Shell::{SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, ShellExecuteExW},
        WindowsAndMessaging::SW_HIDE,
    },
};

const LIMIT: usize = 1024 * 1024;
const REQUEST_LIMIT: usize = 16 * 1024;

/// Check before UAC as well as inside the helper: an authorization dialog may
/// outlive the client request timeout, after its payload locks are released.
pub(super) fn protected_permissions(path: &std::path::Path) -> bool {
    fn trusted(sid: *mut std::ffi::c_void) -> bool {
        let mut text = std::ptr::null_mut();
        if sid.is_null() || unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 {
            return false;
        }
        let _memory = LocalAllocation(text.cast());
        let mut length = 0;
        unsafe {
            while *text.add(length) != 0 {
                length += 1;
            }
        }
        let Ok(text) = (unsafe { String::from_utf16(std::slice::from_raw_parts(text, length)) })
        else {
            return false;
        };
        matches!(
            text.as_str(),
            "S-1-5-18"
                | "S-1-5-32-544"
                | "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"
        )
    }
    let path = wide(path);
    let mut owner = std::ptr::null_mut();
    let mut dacl: *mut ACL = std::ptr::null_mut();
    let mut descriptor = std::ptr::null_mut();
    if unsafe {
        GetNamedSecurityInfoW(
            path.as_ptr(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            std::ptr::null_mut(),
            &mut dacl,
            std::ptr::null_mut(),
            &mut descriptor,
        )
    } != 0
    {
        return false;
    }
    let _descriptor = LocalAllocation(descriptor);
    if dacl.is_null() || !trusted(owner) {
        return false;
    }
    let count = unsafe { (*dacl).AceCount };
    for index in 0..count {
        let mut raw = std::ptr::null_mut();
        if unsafe { GetAce(dacl, index as u32, &mut raw) } == 0 || raw.is_null() {
            return false;
        }
        let header = unsafe { &*raw.cast::<ACE_HEADER>() };
        if header.AceFlags & 0x08 != 0 {
            continue; // INHERIT_ONLY_ACE does not grant access to this object.
        }
        if header.AceType == 1 {
            continue; // An access-denied ACE cannot grant mutation rights.
        }
        if header.AceType != 0
            || (header.AceSize as usize) < std::mem::size_of::<ACCESS_ALLOWED_ACE>()
        {
            return false;
        }
        let allowed = unsafe { &*raw.cast::<ACCESS_ALLOWED_ACE>() };
        // Generic write/all, file data/attributes/delete, WRITE_DAC/WRITE_OWNER.
        if allowed.Mask & 0x500D_0156 != 0
            && !trusted((&allowed.SidStart as *const u32).cast_mut().cast())
        {
            return false;
        }
    }
    true
}

struct Handle(HANDLE);
// Windows process/token handles support concurrent read-only queries. This
// owner closes once at Drop, after all borrowed queries/futures are gone.
unsafe impl Send for Handle {}
unsafe impl Sync for Handle {}
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

struct LocalAllocation(*mut std::ffi::c_void);
impl Drop for LocalAllocation {
    fn drop(&mut self) {
        unsafe { LocalFree(self.0) };
    }
}

struct Identity {
    sid: String,
    session: u32,
    elevated: bool,
}

fn wide(text: impl AsRef<OsStr>) -> Vec<u16> {
    text.as_ref().encode_wide().chain(Some(0)).collect()
}

fn identity(process: HANDLE) -> Result<Identity, Error> {
    let mut raw = std::ptr::null_mut();
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut raw) } == 0 {
        return Err(Error::IdentityMismatch);
    }
    let token = Handle(raw);
    let mut needed = 0;
    unsafe { GetTokenInformation(token.0, TokenUser, std::ptr::null_mut(), 0, &mut needed) };
    if needed == 0 || needed > 65536 {
        return Err(Error::IdentityMismatch);
    }
    let mut user = vec![0usize; (needed as usize).div_ceil(std::mem::size_of::<usize>())];
    if unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            user.as_mut_ptr().cast(),
            needed,
            &mut needed,
        )
    } == 0
    {
        return Err(Error::IdentityMismatch);
    }
    let mut sid = std::ptr::null_mut();
    if unsafe { ConvertSidToStringSidW((*user.as_ptr().cast::<TOKEN_USER>()).User.Sid, &mut sid) }
        == 0
    {
        return Err(Error::IdentityMismatch);
    }
    let allocation = LocalAllocation(sid.cast());
    let mut length = 0;
    unsafe {
        while *sid.add(length) != 0 {
            length += 1;
        }
    }
    let sid = unsafe { String::from_utf16(std::slice::from_raw_parts(sid, length)) }
        .map_err(|_| Error::IdentityMismatch)?;
    drop(allocation);
    if ["S-1-5-18", "S-1-5-19", "S-1-5-20"].contains(&sid.as_str()) {
        return Err(Error::SystemAccount);
    }
    let mut session = 0u32;
    let mut elevation = TOKEN_ELEVATION { TokenIsElevated: 0 };
    if unsafe {
        GetTokenInformation(
            token.0,
            TokenSessionId,
            (&mut session as *mut u32).cast(),
            std::mem::size_of_val(&session) as u32,
            &mut needed,
        )
    } == 0
        || unsafe {
            GetTokenInformation(
                token.0,
                TokenElevation,
                (&mut elevation as *mut TOKEN_ELEVATION).cast(),
                std::mem::size_of_val(&elevation) as u32,
                &mut needed,
            )
        } == 0
    {
        return Err(Error::IdentityMismatch);
    }
    Ok(Identity {
        sid,
        session,
        elevated: elevation.TokenIsElevated != 0,
    })
}

fn pipe(sid: &str, name: &str) -> Result<NamedPipeServer, Error> {
    // No Everyone/Users/Administrators grant: even another administrator must
    // use the caller's SID. The elevated linked token retains that SID.
    let acl = wide(format!("D:P(A;;GA;;;{sid})"));
    let mut descriptor = std::ptr::null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            acl.as_ptr(),
            1,
            &mut descriptor,
            std::ptr::null_mut(),
        )
    } == 0
    {
        return Err(Error::Unavailable);
    }
    let _descriptor = LocalAllocation(descriptor);
    let mut attributes = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor,
        bInheritHandle: 0,
    };
    unsafe {
        ServerOptions::new()
            .first_pipe_instance(true)
            .reject_remote_clients(true)
            .max_instances(1)
            .create_with_security_attributes_raw(
                format!(r"\\.\pipe\{name}"),
                (&mut attributes as *mut SECURITY_ATTRIBUTES).cast(),
            )
    }
    .map_err(|_| Error::Launch)
}

/// Windows command-line quoting, used only for fixed paths and generated IDs.
pub(super) fn quote(value: &OsStr) -> Result<String, Error> {
    let value = value.to_str().ok_or(Error::Unavailable)?;
    if value.contains('\0') {
        return Err(Error::Unavailable);
    }
    let mut output = String::from("\"");
    let mut slashes = 0usize;
    for ch in value.chars() {
        if ch == '\\' {
            slashes += 1;
        } else {
            output.extend(std::iter::repeat_n(
                '\\',
                slashes * if ch == '"' { 2 } else { 1 },
            ));
            slashes = 0;
            if ch == '"' {
                output.push('\\');
            }
            output.push(ch);
        }
    }
    output.extend(std::iter::repeat_n('\\', slashes * 2));
    output.push('"');
    Ok(output)
}

fn launch(powershell: PathBuf, script: PathBuf, name: String) -> Result<Handle, Error> {
    let executable = wide(&powershell);
    let verb = wide("runas");
    let arguments = wide(format!(
        "-NoLogo -NoProfile -NonInteractive -File {} -PipeName {} -ParentProcessId {}",
        quote(script.as_os_str())?,
        quote(OsStr::new(&name))?,
        std::process::id(),
    ));
    let working = wide(powershell.parent().ok_or(Error::Unavailable)?);
    let mut info: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
    info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    info.lpVerb = verb.as_ptr();
    info.lpFile = executable.as_ptr();
    info.lpParameters = arguments.as_ptr();
    info.lpDirectory = working.as_ptr();
    info.nShow = SW_HIDE;
    if unsafe { ShellExecuteExW(&mut info) } == 0 {
        return Err(if unsafe { GetLastError() } == ERROR_CANCELLED {
            Error::ElevationCancelled
        } else {
            Error::Launch
        });
    }
    if info.hProcess.is_null() {
        return Err(Error::Launch);
    }
    Ok(Handle(info.hProcess))
}

fn exit_code(process: &Handle) -> Result<Option<u32>, Error> {
    let mut code = 0;
    if unsafe { GetExitCodeProcess(process.0, &mut code) } == 0 {
        return Err(Error::Output);
    }
    Ok((code != STILL_ACTIVE as u32).then_some(code))
}

async fn await_exit(process: &Handle) -> Result<u32, Error> {
    loop {
        if let Some(code) = exit_code(process)? {
            return Ok(code);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

pub(super) async fn run(
    powershell: PathBuf,
    script: PathBuf,
    arguments: Vec<OsString>,
) -> Result<String, Error> {
    let caller = identity(unsafe { GetCurrentProcess() })?;
    let values = arguments
        .iter()
        .map(|argument| argument.to_str().map(str::to_owned).ok_or(Error::Output))
        .collect::<Result<Vec<_>, _>>()?;
    let request = serde_json::to_vec(&values).map_err(|_| Error::Output)?;
    if request.is_empty() || request.len() > REQUEST_LIMIT {
        return Err(Error::Output);
    }
    let name = format!("ClashOfRust.WslUac.{}", uuid::Uuid::new_v4().simple());
    let mut pipe = pipe(&caller.sid, &name)?;
    let process = tokio::time::timeout(
        Duration::from_secs(120),
        tokio::task::spawn_blocking(move || launch(powershell, script, name)),
    )
    .await
    .map_err(|_| Error::ElevationTimedOut)?
    .map_err(|_| Error::Launch)??;
    let expected_pid = unsafe { GetProcessId(process.0) };
    if expected_pid == 0 {
        return Err(Error::IdentityMismatch);
    }
    let operation = async {
        loop {
            tokio::select! {
                connected = pipe.connect() => connected.map_err(|_| Error::Output)?,
                result = await_exit(&process) => {
                    return Err(if result? == 78 {
                        Error::Unavailable
                    } else {
                        Error::IdentityMismatch
                    });
                }
            }
            let mut peer_pid = 0;
            if unsafe { GetNamedPipeClientProcessId(pipe.as_raw_handle(), &mut peer_pid) } == 0 {
                return Err(Error::IdentityMismatch);
            }
            if peer_pid == expected_pid {
                break;
            }
            // A same-user process may attempt to occupy the name but never
            // receives a request. Disconnect it and continue the bounded wait.
            pipe.disconnect().map_err(|_| Error::Output)?;
        }
        let peer = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, expected_pid) };
        if peer.is_null() {
            return Err(Error::IdentityMismatch);
        }
        let peer = Handle(peer);
        let identity = identity(peer.0)?;
        if identity.sid != caller.sid || identity.session != caller.session || !identity.elevated {
            return Err(Error::IdentityMismatch);
        }
        pipe.write_u32_le(request.len() as u32)
            .await
            .map_err(|_| Error::Output)?;
        pipe.write_all(&request).await.map_err(|_| Error::Output)?;
        pipe.flush().await.map_err(|_| Error::Output)?;
        let length = pipe.read_u32_le().await.map_err(|_| Error::Output)? as usize;
        if length == 0 || length > LIMIT {
            return Err(Error::Output);
        }
        let mut output = vec![0; length];
        pipe.read_exact(&mut output)
            .await
            .map_err(|_| Error::Output)?;
        let text = String::from_utf8(output).map_err(|_| Error::Output)?;
        let value: serde_json::Value = serde_json::from_str(&text).map_err(|_| Error::Output)?;
        if value.get("bridge_error").is_some() {
            return Err(Error::Output);
        }
        let code = await_exit(&process).await?;
        if code != 0 && !matches!(value["outcome"].as_str(), Some("blocked" | "failed")) {
            return Err(Error::Output);
        }
        Ok(text)
    };
    // Do not terminate an administrator process mid firewall transaction. On
    // timeout the caller must refresh state, and the journal remains authority.
    tokio::time::timeout(Duration::from_secs(300), operation)
        .await
        .map_err(|_| Error::Timeout)?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_spaces_quotes_and_trailing_backslashes() {
        assert_eq!(
            quote(OsStr::new(r"C:\Program Files\CoR\a.ps1")).unwrap(),
            r#""C:\Program Files\CoR\a.ps1""#
        );
        assert_eq!(quote(OsStr::new("a\"b\\")).unwrap(), "\"a\\\"b\\\\\"");
        assert!(quote(OsStr::new("bad\0path")).is_err());
    }

    #[tokio::test]
    async fn pipe_rejects_second_server_and_roundtrips_bounded_frame() {
        use tokio::net::windows::named_pipe::ClientOptions;
        let caller = identity(unsafe { GetCurrentProcess() }).unwrap();
        let name = format!("ClashOfRust.WslUac.Test.{}", uuid::Uuid::new_v4().simple());
        let mut server = pipe(&caller.sid, &name).unwrap();
        assert!(pipe(&caller.sid, &name).is_err());
        let mut client = ClientOptions::new()
            .open(format!(r"\\.\pipe\{name}"))
            .unwrap();
        server.connect().await.unwrap();
        client.write_u32_le(7).await.unwrap();
        client.write_all(b"{\"a\":1}").await.unwrap();
        let length = server.read_u32_le().await.unwrap();
        let mut bytes = vec![0; length as usize];
        server.read_exact(&mut bytes).await.unwrap();
        assert_eq!(bytes, b"{\"a\":1}");
        let mut pid = 0;
        assert_ne!(
            unsafe { GetNamedPipeClientProcessId(server.as_raw_handle(), &mut pid) },
            0
        );
        assert_eq!(pid, std::process::id());
    }
}
