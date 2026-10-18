#Requires -Version 5.1
# A fixed installed UAC helper. No request data is accepted on the command line.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^ClashOfRust\.WslUac\.[a-f0-9]{32}$')][string]$PipeName,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ParentProcessId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class CorWslUacPeer {
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint length);

    private static bool TrustedOwner(string sid) {
        return sid == "S-1-5-18" || sid == "S-1-5-32-544" ||
               sid == "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";
    }
    private static bool ProtectedObject(string path) {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0) return false;
        FileSystemSecurity acl = (attributes & FileAttributes.Directory) != 0
            ? (FileSystemSecurity)new DirectoryInfo(path).GetAccessControl()
            : new FileInfo(path).GetAccessControl();
        if (!TrustedOwner(acl.GetOwner(typeof(SecurityIdentifier)).Value)) return false;
        var writes = FileSystemRights.WriteData | FileSystemRights.AppendData |
            FileSystemRights.WriteExtendedAttributes | FileSystemRights.WriteAttributes |
            FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.Delete |
            FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier))) {
            if (rule.AccessControlType == AccessControlType.Allow &&
                (rule.PropagationFlags & PropagationFlags.InheritOnly) == 0 &&
                (rule.FileSystemRights & writes) != 0 && !TrustedOwner(rule.IdentityReference.Value))
                return false;
        }
        return true;
    }
    public static bool ProtectedInstallation(string executable, string package) {
        try {
            var programFiles = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles));
            var installed = Path.GetDirectoryName(Path.GetFullPath(executable));
            if (!installed.StartsWith(programFiles + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                !ProtectedObject(executable)) return false;
            var current = Path.GetFullPath(package);
            while (!String.Equals(current, programFiles, StringComparison.OrdinalIgnoreCase)) {
                if (!current.StartsWith(programFiles + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                    !ProtectedObject(current)) return false;
                current = Path.GetDirectoryName(current);
            }
            if (!ProtectedObject(programFiles)) return false;
            foreach (var entry in Directory.GetFileSystemEntries(package)) {
                if (!ProtectedObject(entry)) return false;
                if ((File.GetAttributes(entry) & FileAttributes.Directory) != 0) {
                    foreach (var nested in Directory.GetFileSystemEntries(entry))
                        if (!ProtectedObject(nested)) return false;
                }
            }
            return true;
        } catch { return false; }
    }

    public static bool Validate(SafePipeHandle pipe, uint expectedPid, string executable) {
        uint serverPid;
        if (!GetNamedPipeServerProcessId(pipe, out serverPid) || serverPid != expectedPid) return false;
        var current = WindowsIdentity.GetCurrent();
        if (current.IsSystem || current.User == null ||
            !new WindowsPrincipal(current).IsInRole(WindowsBuiltInRole.Administrator)) return false;
        var process = OpenProcess(0x1000, false, serverPid);
        if (process == IntPtr.Zero) return false;
        IntPtr token = IntPtr.Zero;
        try {
            var image = new StringBuilder(32768);
            uint length = (uint)image.Capacity;
            if (!QueryFullProcessImageName(process, 0, image, ref length) ||
                !String.Equals(Path.GetFullPath(image.ToString()), Path.GetFullPath(executable),
                               StringComparison.OrdinalIgnoreCase)) return false;
            if (!OpenProcessToken(process, 8, out token)) return false;
            using (var parent = new WindowsIdentity(token)) {
                if (parent.User == null || parent.IsSystem ||
                    parent.User.Value != current.User.Value) return false;
            }
            return Process.GetCurrentProcess().SessionId == Process.GetProcessById((int)serverPid).SessionId;
        } finally {
            if (token != IntPtr.Zero) CloseHandle(token);
            CloseHandle(process);
            current.Dispose();
        }
    }

    public static byte[] ReadFrame(Stream pipe, int limit) {
        byte[] size = ReadExact(pipe, 4);
        uint length = BitConverter.ToUInt32(size, 0);
        if (length == 0 || length > limit) throw new InvalidDataException();
        return ReadExact(pipe, (int)length);
    }
    private static byte[] ReadExact(Stream pipe, int count) {
        byte[] bytes = new byte[count];
        int offset = 0;
        while (offset < count) {
            var pending = pipe.ReadAsync(bytes, offset, count - offset);
            if (!pending.Wait(30000)) throw new TimeoutException();
            int read = pending.Result;
            if (read == 0) throw new EndOfStreamException();
            offset += read;
        }
        return bytes;
    }
    public static void WriteFrame(Stream pipe, string text) {
        byte[] bytes = new UTF8Encoding(false, true).GetBytes(text);
        if (bytes.Length == 0 || bytes.Length > 1048576) throw new InvalidDataException();
        byte[] size = BitConverter.GetBytes(bytes.Length);
        pipe.Write(size, 0, size.Length);
        pipe.Write(bytes, 0, bytes.Length);
        pipe.Flush();
    }
}
'@

function Convert-BridgeArguments {
    param([object]$Values)
    if ($Values -isnot [array] -or $Values.Count -gt 20) { throw 'Invalid arguments' }
    $parameters = @{}
    $switches = @('-Execute','-RestoreOriginalNetwork')
    $valueFlags = @('-Action','-Backend','-Distro','-ProfilePath','-EndpointIPv4','-EndpointPort')
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $flag = $Values[$i]
        if ($flag -isnot [string] -or $flag -notin ($switches + $valueFlags)) { throw 'Invalid arguments' }
        $key = $flag.Substring(1)
        if ($parameters.ContainsKey($key)) { throw 'Invalid arguments' }
        if ($flag -in $switches) { $parameters[$key] = $true; continue }
        $i++
        if ($i -ge $Values.Count -or $Values[$i] -isnot [string] -or
            $Values[$i].Length -gt 2048 -or $Values[$i].Contains([char]0)) { throw 'Invalid arguments' }
        $parameters[$key] = $Values[$i]
    }
    $testing = $parameters['Action'] -eq 'Test'
    if (($parameters['Action'] -notin @('Install','Start','Stop','Rollback','Uninstall','Test')) -or
        (-not $testing -and -not $parameters['Execute']) -or
        ($testing -and ($parameters.ContainsKey('Execute') -or $parameters.ContainsKey('RestoreOriginalNetwork'))) -or
        $parameters['Backend'] -notin @('WireGuard','Tailscale')) {
        throw 'Invalid arguments'
    }
    if ($parameters.ContainsKey('Distro') -and
        ($parameters.Distro -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$' -or
         $parameters.Distro.EndsWith('.'))) { throw 'Invalid distribution' }
    if ($parameters.ContainsKey('EndpointPort') -and
        ($parameters.EndpointPort -notmatch '^[1-9][0-9]{0,4}$' -or
         [int]$parameters.EndpointPort -gt 65535)) { throw 'Invalid port' }
    if ($parameters.ContainsKey('EndpointIPv4')) {
        $address = $null
        if (-not [Net.IPAddress]::TryParse($parameters.EndpointIPv4, [ref]$address) -or
            $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            $address.ToString() -cne $parameters.EndpointIPv4) { throw 'Invalid endpoint' }
        $octets = $address.GetAddressBytes()
        if ($octets[0] -in @(0,10,127) -or $octets[0] -ge 224 -or
            ($octets[0] -eq 169 -and $octets[1] -eq 254) -or
            ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
            ($octets[0] -eq 192 -and $octets[1] -eq 168) -or
            ($octets[0] -eq 100 -and $octets[1] -ge 64 -and $octets[1] -le 127) -or
            ($octets[0] -eq 198 -and $octets[1] -in @(18,19))) { throw 'Invalid endpoint' }
    }
    if ($parameters.ContainsKey('ProfilePath')) {
        $path = $parameters.ProfilePath
        if ($path.Length -gt 1024 -or $path -notmatch '^[a-zA-Z]:\\.+\.json$' -or
            $path.Substring(2) -match '[\x00-\x1f:/\"''`$%;&|<>*?!]') { throw 'Invalid profile path' }
        foreach ($component in $path.Substring(3).Split('\')) {
            $stem = $component.Split('.')[0]
            if (-not $component -or $component -in @('.','..') -or
                $component -match '^[ ]|[. ]$' -or $stem -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
                throw 'Invalid profile path'
            }
        }
    }
    return $parameters
}

$pipe = $null
$exitCode = 1
try {
    $expectedApp = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\clash-of-rust.exe'))
    if (-not [CorWslUacPeer]::ProtectedInstallation($expectedApp, $PSScriptRoot)) { exit 78 }
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $PipeName,
        [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous,
        [Security.Principal.TokenImpersonationLevel]::Identification)
    $pipe.Connect(30000)
    if (-not [CorWslUacPeer]::Validate($pipe.SafePipeHandle, $ParentProcessId, $expectedApp)) {
        throw 'Peer identity rejected'
    }
    $bytes = [CorWslUacPeer]::ReadFrame($pipe, 16384)
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    $values = ConvertFrom-Json -InputObject $encoding.GetString($bytes)
    $parameters = Convert-BridgeArguments $values
    Import-Module (Join-Path $PSScriptRoot 'WslSecureEgress.psm1') -Force -DisableNameChecking
    try {
        $response = Invoke-WslEgressOperation @parameters
    } catch {
        $response = New-WslEgressResponse -Action $parameters.Action -Backend $parameters.Backend `
            -Outcome failed -Phase failed `
            -Message 'Operation failed; inspect the protected local journal before retrying.'
    }
    $json = $response | ConvertTo-Json -Depth 12 -Compress
    [CorWslUacPeer]::WriteFrame($pipe, $json)
    $exitCode = if ($response.outcome -eq 'failed') { 1 } elseif ($response.outcome -eq 'blocked') { 2 } else { 0 }
} catch {
    # Never relay exceptions: paths, profile contents and credentials are private.
    if ($null -ne $pipe -and $pipe.IsConnected) {
        try { [CorWslUacPeer]::WriteFrame($pipe, '{"bridge_error":"validation_or_transport"}') } catch {}
    }
} finally {
    if ($null -ne $pipe) { $pipe.Dispose() }
}
exit $exitCode
