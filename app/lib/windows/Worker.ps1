#Requires -Version 5.1

# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

<#
.SYNOPSIS
    Vigil worker - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Runs one job once, end to end (SPECIFICATION.md 4.3): claims its launch
    record, records its state, runs the job through its runner, captures its
    output to the job log, classifies the outcome, writes the run's events
    to the spool, writes the final state and releases its run token.

    New-VigilLaunch -Root <dir> -Job <id>
        Writes a launch record for a new run, as the supervisor does before
        it starts a worker. Returns the run id, or $null with a message on
        stderr.
    Invoke-VigilWorker -Root <dir> -Job <id> -RunId <run id>
        Returns @{ Code; Outcome; Reason; Duration }. Code is 0 succeeded,
        1 warning, 2 failed, 3 unknown, and 4 when the launch was abandoned
        or the configuration could not be read (the job did not run).

    Windows only; worker.sh is the Linux and macOS worker. The run token is
    held open exclusively for the worker's whole life (11.2).

    Requires Config.ps1, Validate.ps1, Effective.ps1, Command.ps1,
    Outcome.ps1, Metrics.ps1, Events.ps1, Secrets.ps1 and Fetch.ps1.
#>

# Single-line, at most 500 characters (12.2).
function Get-VigilStateValue {
    param([string]$Value)
    $v = $Value.Replace("`r", ' ').Replace("`n", ' ')
    if ($v.Length -gt 500) { $v = $v.Substring(0, 500) }
    return $v
}

# Atomically writes a [state] file from an ordered dictionary (12.3): a
# temporary file in the same directory, flushed to disk, then renamed over
# the target.
function Write-VigilStateFile {
    param([string]$Path, $Fields)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("[state]`n")
    foreach ($k in $Fields.Keys) {
        [void]$sb.Append(('{0,-16} = {1}' -f $k, (Get-VigilStateValue ([string]$Fields[$k]))).TrimEnd() + "`n")
    }
    Write-VigilFileAtomic -Path $Path -Text $sb.ToString() -Fault 'state.after_temp'
}

# -Fault names the crash point between the temporary file and the rename
# (22.4.1).
function Write-VigilFileAtomic {
    param([string]$Path, [string]$Text, [string]$Fault)
    $tmp = "$Path.tmp.$PID"
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($Text)
    $fs = [System.IO.File]::Open($tmp, 'Create', 'Write', 'None')
    try {
        $fs.Write($bytes, 0, $bytes.Length)
        # To disk before the rename, so a power cut leaves the old file or the new
        # one, never an empty one.
        $fs.Flush($true)
    }
    finally { $fs.Dispose() }
    if ($Fault) { Invoke-VigilFault $Fault }
    # Windows refuses to replace a file while another process has it open
    # without delete sharing, as the supervisor does for a moment while it
    # reads a state file, or a virus scanner might. Retried for up to five
    # seconds: a write given up on here would be lost without a trace, since
    # the callers run with ErrorActionPreference Continue.
    for ($try = 1; ; $try++) {
        try {
            # Replace, not Move: on .NET Framework, which Windows PowerShell 5.1
            # runs on, Move cannot overwrite.
            if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value) }
            else { [System.IO.File]::Move($tmp, $Path) }
            return
        }
        catch [System.IO.IOException] {
            if ($try -ge 50) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}

# Seconds in a validated duration (30s, 5m, 2h, 7d).
function ConvertTo-VigilSeconds {
    param([string]$Duration)
    $n = [long]$Duration.Substring(0, $Duration.Length - 1)
    switch -CaseSensitive ($Duration[-1]) {
        's' { return $n }
        'm' { return $n * 60 }
        'h' { return $n * 3600 }
    }
    return $n * 86400
}

function Get-VigilNow {
    $now = [DateTime]::UtcNow
    $epoch = ConvertTo-VigilEpoch $now
    return @{ Epoch = $epoch; Iso = $now.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture) }
}

# The CPU a run used, in seconds with two decimals (12.2, cpu_seconds): this
# worker's, and its job process's when it started one, as the kernel counts
# them. A job's own children are not counted on Windows: that would take a
# Job Object.
function Get-VigilRunCpu {
    param([double]$Job = 0)
    $s = [System.Diagnostics.Process]::GetCurrentProcess().TotalProcessorTime.TotalSeconds + $Job
    return $s.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-VigilEpoch {
    param([DateTime]$Time)
    $epoch0 = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    return [long][Math]::Floor(($Time.ToUniversalTime() - $epoch0).TotalSeconds)
}

# Windows' own answers about processes, without WMI. WMI refuses a network
# logon that is not an administrator's: an SSH session, or a scheduled task
# run without a stored password. Each WMI read below falls back to these,
# which ask the kernel directly. Compiled once per process, when first
# needed: where WMI refused, and whenever a process tree is ended
# (Stop-VigilProcessTree), so an ordinary run never starts the C#
# compiler. WMI takes seconds to refuse, every time, so once it has, this
# process does not ask it again.
# Tests set VIGIL_TEST_NO_WMI=1 to take the kernel's route, as such a
# logon does.
$Script:VigilWmiRefused = $env:VIGIL_TEST_NO_WMI -ceq '1'
function Initialize-VigilNative {
    if ('VigilNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class VigilNative {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32 {
        public uint dwSize; public uint cntUsage; public uint th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID; public uint cntThreads; public uint th32ParentProcessID; public int pcPriClassBase;
        public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr h, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr h, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageNameW(IntPtr h, int flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, IntPtr buf, int len, out int ret);
    const uint QueryLimited = 0x1000;

    // Every process: its id and its parent's id, or an exception.
    public static int[][] Processes() {
        IntPtr h = CreateToolhelp32Snapshot(2, 0);
        if (h == new IntPtr(-1)) throw new InvalidOperationException("CreateToolhelp32Snapshot: " + Marshal.GetLastWin32Error());
        try {
            var list = new System.Collections.Generic.List<int[]>();
            PROCESSENTRY32 e = new PROCESSENTRY32();
            e.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
            if (!Process32FirstW(h, ref e)) throw new InvalidOperationException("Process32First: " + Marshal.GetLastWin32Error());
            do { list.Add(new int[] { (int)e.th32ProcessID, (int)e.th32ParentProcessID }); } while (Process32NextW(h, ref e));
            return list.ToArray();
        }
        finally { CloseHandle(h); }
    }

    // The parent's id; 0 when there is no such process.
    public static int Parent(int pid) {
        foreach (int[] p in Processes()) { if (p[0] == pid) return p[1]; }
        return 0;
    }

    // The image's file name (ping.exe), or null when it cannot be read.
    public static string ImageName(int pid) {
        IntPtr h = OpenProcess(QueryLimited, false, pid);
        if (h == IntPtr.Zero) return null;
        try {
            StringBuilder sb = new StringBuilder(1024); int n = sb.Capacity;
            if (!QueryFullProcessImageNameW(h, 0, sb, ref n)) return null;
            return System.IO.Path.GetFileName(sb.ToString(0, n));
        }
        finally { CloseHandle(h); }
    }

    // The command line, or null when it cannot be read: another user's
    // process, or one that has gone.
    public static string CommandLine(int pid) {
        IntPtr h = OpenProcess(QueryLimited, false, pid);
        if (h == IntPtr.Zero) return null;
        try {
            int len = 4096;
            for (int i = 0; i < 4; i++) {
                IntPtr buf = Marshal.AllocHGlobal(len);
                try {
                    int need;
                    // 60: ProcessCommandLineInformation, a UNICODE_STRING
                    // followed by its text.
                    int s = NtQueryInformationProcess(h, 60, buf, len, out need);
                    if (s == 0) {
                        int bytes = Marshal.ReadInt16(buf) & 0xffff;
                        IntPtr text = Marshal.ReadIntPtr(buf, IntPtr.Size);
                        return bytes == 0 ? "" : Marshal.PtrToStringUni(text, bytes / 2);
                    }
                    if (need <= len) return null;
                    len = need;
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            return null;
        }
        finally { CloseHandle(h); }
    }

    // Whether any process but skip has needle in its command line.
    public static bool AnyCommandLine(string needle, int skip) {
        foreach (int[] p in Processes()) {
            if (p[0] == skip || p[0] == 0) continue;
            string c = CommandLine(p[0]);
            if (c == null) continue;
            // As a whole argument: "--run-id ...-1" must not match "--run-id ...-10".
            for (int i = c.IndexOf(needle, StringComparison.Ordinal); i >= 0; i = c.IndexOf(needle, i + 1, StringComparison.Ordinal)) {
                int e = i + needle.Length;
                if (e == c.Length || char.IsWhiteSpace(c[e]) || c[e] == '"') return true;
            }
        }
        return false;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

    // Starts cmd hidden, holding none of this process's handles, and out of
    // its job: an SSH session's job ends every process in it at logout, and
    // lets them break away. Returns the id; throws when it cannot.
    public static int StartDetached(string cmd, string dir) {
        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.dwFlags = 1; si.wShowWindow = 0;  // STARTF_USESHOWWINDOW, SW_HIDE
        PROCESS_INFORMATION pi;
        // CREATE_BREAKAWAY_FROM_JOB, CREATE_NO_WINDOW, CREATE_UNICODE_ENVIRONMENT
        if (!CreateProcessW(null, new StringBuilder(cmd), IntPtr.Zero, IntPtr.Zero, false, 0x01000000 | 0x08000000 | 0x400, IntPtr.Zero, dir, ref si, out pi)) {
            int e = Marshal.GetLastWin32Error();
            if (e == 5) throw new InvalidOperationException("this session's job does not let a process outlive it");
            throw new System.ComponentModel.Win32Exception(e);
        }
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        return pi.dwProcessId;
    }
}
'@
}

# Starts command line $CommandLine in $Directory, detached: hidden, holding
# none of this process's handles, outliving this logon, as one started at
# logon would. Through WMI, or where WMI refuses (an SSH session), out of
# this session's job.
function Start-VigilDetached {
    param([string]$CommandLine, [string]$Directory)
    if (-not $Script:VigilWmiRefused) {
        try {
            $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
            $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -ErrorAction Stop -Arguments @{
                CommandLine = $CommandLine; CurrentDirectory = $Directory; ProcessStartupInformation = $si
            }
        }
        catch [Microsoft.Management.Infrastructure.CimException] { $Script:VigilWmiRefused = $true }
        if (-not $Script:VigilWmiRefused) {
            if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create returned $($r.ReturnValue)" }
            return
        }
    }
    Initialize-VigilNative
    [void][VigilNative]::StartDetached($CommandLine, $Directory)
}

# A process's name, start time, parent and command line, from WMI or, when
# WMI refuses, from the kernel; $null when there is no such process. Throws
# when neither can tell. Name and start time are what Get-Process reports,
# which is how the worker records its job (11.5).
function Get-VigilProcessInfo {
    param([int]$Id)
    if (-not $Script:VigilWmiRefused) {
        try {
            $p = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $Id" -ErrorAction Stop)[0]
            if (-not $p) { return $null }
            return @{ ProcessId = $Id; Name = $p.Name; Created = $p.CreationDate; Parent = [int]$p.ParentProcessId; CommandLine = $p.CommandLine }
        }
        catch { $Script:VigilWmiRefused = $true }
    }
    Initialize-VigilNative
    $g = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if (-not $g) { return $null }
    $name = [VigilNative]::ImageName($Id)
    if (-not $name) { throw "process $Id cannot be read" }
    return @{ ProcessId = $Id; Name = $name; Created = $g.StartTime; Parent = [VigilNative]::Parent($Id); CommandLine = [VigilNative]::CommandLine($Id) }
}

# Ends a process and everything under it, from the root down, with the
# tree read from the kernel first (backlog 19). A process counts as a child
# only if it started after its parent, so a reused pid can never draw an
# unrelated process in. taskkill /T ends the children first, so a cmd.exe
# parent could run its script's next line in between; it is also refused
# where WMI is (an SSH session, a task without a stored password).
# Every way is tried until the root is gone: if it is still running two
# seconds after its kill, taskkill /T /F follows on the same tree. The root
# is held open meanwhile, so its pid cannot be given to another process in
# between. taskkill alone is used when the kernel cannot be asked (dynamic
# code not allowed) or the root is already gone. When the first way did not
# end it, $Script:VigilKillReport says why, for the caller to log; it is
# empty otherwise.
$Script:VigilKillReport = ''
function Stop-VigilProcessTree {
    param([int]$Id)
    $Script:VigilKillReport = ''
    $root = $null
    $why = ''
    try {
        Initialize-VigilNative
        $all = [VigilNative]::Processes()
        $root = Get-Process -Id $Id -ErrorAction Stop
        $tree = New-Object 'System.Collections.Generic.List[object]'
        $tree.Add($root)
        for ($i = 0; $i -lt $tree.Count; $i++) {
            $parent = $tree[$i]
            foreach ($p in $all) {
                if ($p[1] -ne $parent.Id -or $p[0] -eq $parent.Id) { continue }
                # Another account's process cannot be read, nor ended here.
                try { $c = Get-Process -Id $p[0] -ErrorAction Stop; if ($c.StartTime -ge $parent.StartTime) { $tree.Add($c) } } catch { }
            }
        }
        # From the root down: a parent ended after its children could carry on
        # in between, as cmd.exe runs its script's next line once ping ends.
        # The tree is already known, so the children are still found.
        for ($i = 0; $i -lt $tree.Count; $i++) {
            try { $tree[$i].Kill() }
            catch { if (-not $why) { $why = "pid $($tree[$i].Id): $($_.Exception.Message)" } }
        }
        if ($root.WaitForExit(2000)) { return }
        if (-not $why) { $why = 'still running 2 seconds after its kill' }
    }
    catch {
        # The root gone already, or the kernel not to be asked.
        if (-not $root) { & taskkill.exe /T /F /PID $Id 2>&1 | Out-Null; return }
        if (-not $why) { $why = $_.Exception.Message }
    }
    try {
        $tk = (& taskkill.exe /T /F /PID $Id 2>&1 | Out-String).Trim() -replace '\s+', ' '
        $ended = $root.WaitForExit(2000)
    }
    catch { $tk = $_.Exception.Message; $ended = $false }
    $Script:VigilKillReport = "the first kill did not end it ($why); taskkill: $tk; $(if ($ended) { 'ended' } else { 'still running' })"
}

# Windows has no kernel boot id; it is derived from the boot time (11.1).
# The kernel is asked first: every worker needs the id, and WMI would make
# each one wait seconds where it refuses. WMI reports the same time, so the
# id is the same either way; it is asked when the kernel cannot be (dynamic
# code is not allowed everywhere).
# The kernel call is built in memory with Reflection.Emit, not compiled with
# Add-Type: Add-Type starts the C# compiler, and every worker asks, so every
# run of every job compiled (backlog 50).
$Script:VigilBootCall = $null
function Get-VigilBootId {
    try {
        if (-not $Script:VigilBootCall) {
            $name = New-Object System.Reflection.AssemblyName 'VigilBoot'
            $asm = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($name, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
            $type = $asm.DefineDynamicModule('VigilBoot').DefineType('VigilBoot', 'Public, Class, Abstract, Sealed')
            # NtQuerySystemInformation(SystemTimeOfDayInformation): its first
            # 8 bytes are the boot time as a FILETIME, what WMI's
            # LastBootUpTime reports.
            $call = $type.DefinePInvokeMethod('NtQuerySystemInformation', 'ntdll.dll', 'Public, Static, PinvokeImpl', 'Standard',
                [int], [type[]]@([int], [byte[]], [int], [int[]]), 'Winapi', 'Unicode')
            $call.SetImplementationFlags('PreserveSig')
            $Script:VigilBootCall = $type.CreateType()
        }
        $b = New-Object byte[] 48
        $s = $Script:VigilBootCall::NtQuerySystemInformation(3, $b, $b.Length, (New-Object int[] 1))
        if ($s -ne 0) { throw "NtQuerySystemInformation: 0x$($s.ToString('x8'))" }
        return "boot-$(ConvertTo-VigilEpoch ([DateTime]::FromFileTimeUtc([BitConverter]::ToInt64($b, 0))))"
    }
    catch { }
    if (-not $Script:VigilWmiRefused) {
        try {
            $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
            return "boot-$(ConvertTo-VigilEpoch $boot)"
        }
        catch { $Script:VigilWmiRefused = $true }
    }
    return ''
}

# The first value of a key in a section, or a default.
function Get-VigilConfigValue {
    param($Parsed, [string]$Section, [string]$Key, [string]$Default)
    foreach ($e in $Parsed.Entries) {
        if ($e.Section -ceq $Section -and $e.Key -ceq $Key) { return $e.Value }
    }
    return $Default
}

# The log file of a day in a directory to write to: the last one, or the
# next in sequence once it has reached [log] max_file_mb (13.1). Log files
# are never truncated or renamed.
function Get-VigilLogFile {
    param($Parsed, [string]$Dir, [string]$Day)
    $max = [long](Get-VigilConfigValue $Parsed 'log' 'max_file_mb' '50') * 1048576
    $n = 0
    $f = Join-Path $Dir "$Day.log"
    while ([System.IO.File]::Exists((Join-Path $Dir "$Day.$($n + 1).log"))) {
        $n++
        $f = Join-Path $Dir "$Day.$n.log"
    }
    if ([System.IO.File]::Exists($f) -and (New-Object System.IO.FileInfo $f).Length -ge $max) { $f = Join-Path $Dir "$Day.$($n + 1).log" }
    return $f
}

# Decodes a job's raw output with the encoding its console used, and writes
# it to a file as UTF-8, a piece at a time. With no raw file (the job never
# started), the file is written empty.
function Copy-VigilJobText {
    param([string]$Raw, $Encoding, [string]$To)
    $writer = New-Object System.IO.StreamWriter($To, $false, (New-Object System.Text.UTF8Encoding $false))
    try {
        if (-not $Encoding -or -not [System.IO.File]::Exists($Raw)) { return }
        # Byte order marks are honoured, as the console's own reader does.
        $reader = New-Object System.IO.StreamReader($Raw, $Encoding, $true)
        try {
            $buf = New-Object char[] 65536
            while (($n = $reader.Read($buf, 0, $buf.Length)) -gt 0) { $writer.Write($buf, 0, $n) }
        }
        finally { $reader.Dispose() }
    }
    finally { $writer.Dispose() }
}

# Writes a job's output to its log, one "<prefix> <line>" each, a piece at a
# time: lines end at LF, a line's trailing CRs are dropped, and empty lines at
# the very end are left out.
function Write-VigilJobLines {
    param([string]$Path, $Encoding, [string]$Prefix, $Writer)
    if (-not $Encoding -or -not [System.IO.File]::Exists($Path)) { return }
    $reader = New-Object System.IO.StreamReader($Path, $Encoding, $true)
    try {
        $buf = New-Object char[] 65536
        $carry = ''
        # Empty lines are held back until a line with text follows them.
        $blank = 0
        $any = $false
        $wrote = $false
        while (($n = $reader.Read($buf, 0, $buf.Length)) -gt 0) {
            $any = $true
            $parts = ($carry + [string]::new($buf, 0, $n)).Split("`n")
            $carry = $parts[$parts.Count - 1]
            for ($i = 0; $i -lt $parts.Count - 1; $i++) {
                if ($parts[$i].Length -eq 0) { $blank++; continue }
                for (; $blank -gt 0; $blank--) { $Writer.Write("$Prefix `r`n") }
                $Writer.Write("$Prefix $($parts[$i].TrimEnd("`r"))`r`n")
                $wrote = $true
            }
        }
        if ($carry.Length -gt 0) {
            for (; $blank -gt 0; $blank--) { $Writer.Write("$Prefix `r`n") }
            $Writer.Write("$Prefix $($carry.TrimEnd("`r"))`r`n")
        }
        # Output of nothing but line ends is one empty line.
        elseif ($any -and -not $wrote) { $Writer.Write("$Prefix `r`n") }
    }
    finally { $reader.Dispose() }
}

# Loads the configuration and resolves the directories. Returns @{ Error }
# or the context the worker needs.
# A run uses the configuration its launch record names (4.3): the last
# valid local one (state\config.valid, 16.3), or with sources the active one
# and its cached scripts (16.5), whatever is saved or activated meanwhile.
# The supervisor validated it before launching, so when its digest is still
# the one the launch records, it is not validated again: validating costs a
# fresh PowerShell process more than a second, and every run is one. A
# launch without one (vigil run, or an older supervisor) gets the
# local file, or with sources the active one, validated here. The fetcher
# always works from the local file.
function Get-VigilWorkerContext {
    param([string]$Root, [string]$Job, [string]$RunId, [string]$StateDir = '')
    $local = ConvertFrom-VigilConfig -Path (Join-Path $Root 'config\vigil.config')
    $dir = {
        param($Section, $Key, $Default)
        $v = Get-VigilConfigValue $parsed $Section $Key $Default
        if ([System.IO.Path]::IsPathRooted($v)) { return $v }
        return Join-Path $Root $v
    }
    # The state directory is always the local file's (6.8), unless the
    # supervisor that launched this worker named its own: a state_dir edited
    # since it started, or a file that can no longer be read, must not send
    # the worker looking for its launch record somewhere else (V-07).
    $parsed = $local
    $state = & $dir 'vigil' 'state_dir' 'state'
    if ($StateDir) { $state = $StateDir }
    $config = ''
    $configSha = ''
    $script = ''
    $boot = ''
    $launch = Join-Path $state "locks\$Job.$RunId.launch"
    if ($RunId -and [System.IO.File]::Exists($launch)) {
        foreach ($l in [System.IO.File]::ReadAllLines($launch)) {
            if ($l -cmatch '^config +=( (.*))?$') { $config = $Matches[2] }
            elseif ($l -cmatch '^config_sha256 +=( (.*))?$') { $configSha = $Matches[2] }
            elseif ($l -cmatch '^script +=( (.*))?$') { $script = $Matches[2] }
            elseif ($l -cmatch '^boot_id +=( (.*))?$') { $boot = $Matches[2] }
        }
    }
    if ($Job -ceq 'vigil_fetch') { $config = '' }
    $fetch = $Job -cne 'vigil_fetch' -and (Test-VigilFetchMode -Parsed $local)
    $records = @()
    $active = $null
    if (-not $config) {
        $records = Test-VigilConfig -Parsed $local
        if ($local.Errors.Count -gt 0 -or @($records | Where-Object { $_.Kind -ceq 'ERROR' }).Count -gt 0) {
            return @{ Error = 'the configuration has errors; run vigil precheck' }
        }
        if ($fetch) {
            $active = Read-VigilActive -Root $Root -State $state
            if (-not $active) { return @{ Error = 'no configuration is active yet: the supervisor fetches it from its sources' } }
            $config = $active.Config
        }
    }
    if ($config) {
        # The digest is of the bytes parsed, read once: a file replaced
        # between a hash and a parse could not pass for the one validated.
        $parsed = ConvertFrom-VigilConfig -Path $config -Digest
        # Not what the supervisor validated (a newer valid configuration
        # was kept since the launch): validated here.
        if (-not $configSha -or $parsed.Sha256 -cne $configSha) { $records = Test-VigilConfig -Parsed $parsed }
        if ($parsed.Errors.Count -gt 0 -or @($records | Where-Object { $_.Kind -ceq 'ERROR' }).Count -gt 0) {
            if ($fetch) { return @{ Error = "the active configuration $config cannot be read" } }
            return @{ Error = "the configuration $config cannot be read" }
        }
    }
    # Only the fetcher's runs and the active configuration's need to be
    # named in a vigil run launch (New-VigilLaunch); a local one is the file.
    if (-not $fetch) { $config = '' }
    if ($fetch) {
        $src = Get-VigilConfigValue $parsed "job.$Job" 'source' ''
        if ($src -and -not $script) {
            if (-not $active) { $active = Read-VigilActive -Root $Root -State $state }
            if ($active) { $script = Get-VigilActiveScript -Root $Root -Active $active -Source $src -File (Get-VigilConfigValue $parsed "job.$Job" 'file' '') }
            if (-not $script) { return @{ Error = "the script of job '$Job' from source.$src is not fetched yet" } }
        }
    }
    if (@('vigil_sender', 'vigil_fetch', 'vigil_logs', 'vigil_update') -cnotcontains $Job -and -not ($parsed.Sections | Where-Object { $_.Name -ceq "job.$Job" })) {
        return @{ Error = "no job '$Job' in the configuration" }
    }
    foreach ($r in $records) {
        if ($r.Kind -ceq 'INVALID' -and $r.Job -ceq $Job) { return @{ Error = "job '$Job' is invalid: $($r.Message)" } }
    }
    return @{
        Error  = ''
        Parsed = $parsed
        State  = $state
        Logs   = & $dir 'log' 'dir' 'logs'
        Spool  = & $dir 'spool' 'dir' 'spool'
        Config = $config
        Script = $script
        Boot   = $boot
    }
}

function New-VigilLaunch {
    param([string]$Root, [string]$Job)
    $ctx = Get-VigilWorkerContext -Root $Root -Job $Job
    if ($ctx.Error) { [Console]::Error.WriteLine("vigil: $($ctx.Error)"); return $null }
    $now = Get-VigilNow
    $rid = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture))-$PID"
    $locks = Join-Path $ctx.State 'locks'
    [void](New-Item -ItemType Directory -Force -Path $locks)
    $text = "[launch]`njob           = $Job`nrun_id        = $rid`nboot_id       = $(Get-VigilBootId)`nlaunch_epoch  = $($now.Epoch)`nlaunch_at     = $($now.Iso)`n"
    if ($ctx.Config) { $text += "config        = $($ctx.Config)`n" }
    if ($ctx.Script) { $text += "script        = $($ctx.Script)`n" }
    Write-VigilFileAtomic -Path (Join-Path $locks "$Job.$rid.launch") -Text $text
    return $rid
}

function Invoke-VigilWorker {
    param([string]$Root, [string]$Job, [string]$RunId, [string]$StateDir = '')

    $ctx = Get-VigilWorkerContext -Root $Root -Job $Job -RunId $RunId -StateDir $StateDir
    if ($ctx.Error) { [Console]::Error.WriteLine("vigil: $($ctx.Error)"); return @{ Code = 4 } }
    $launch = Join-Path $ctx.State "locks\$Job.$RunId.launch"
    $token = Join-Path $ctx.State "locks\$Job.$RunId.token"
    $timeoutMarker = Join-Path $ctx.State "locks\$Job.$RunId.timeout"

    # Claim (11.2), hand over hand: hold the launch record exclusively,
    # create and hold the token exclusively, then close and delete the
    # launch record. If the supervisor deleted the launch first, the job
    # does not run.
    $tokenStream = $null
    try {
        # Another process may have the launch record open for a moment (an
        # antivirus scan, a supervisor probe): retry briefly. A missing
        # record means the launch was abandoned, and fails at once.
        Invoke-VigilFault 'worker.before_claim'
        $launchStream = $null
        for ($try = 1; -not $launchStream; $try++) {
            try { $launchStream = [System.IO.File]::Open($launch, 'Open', 'Read', 'None') }
            catch [System.IO.FileNotFoundException] { throw }
            catch [System.IO.IOException] { if ($try -ge 20) { throw }; Start-Sleep -Milliseconds 100 }
        }
        # CreateNew fails if a token already exists, and share mode None makes the
        # supervisor's probe see it held for as long as this worker lives.
        # Inheritable: the job process gets the handle too, as on Linux and
        # macOS it gets fd 9, so a job whose worker is gone still holds its
        # run, and is never started a second time beside it (11.3, orphaned).
        try { $tokenStream = New-Object System.IO.FileStream -ArgumentList $token, ([System.IO.FileMode]::CreateNew), ([System.IO.FileAccess]::ReadWrite), ([System.IO.FileShare]'None, Inheritable') }
        finally { $launchStream.Dispose() }
        [System.IO.File]::Delete($launch)
    }
    catch {
        if ($tokenStream) { $tokenStream.Dispose(); [System.IO.File]::Delete($token) }
        [Console]::Error.WriteLine("vigil: launch $RunId of $Job was abandoned; not running")
        return @{ Code = 4 }
    }
    Invoke-VigilFault 'worker.after_claim'

    $jobs = Join-Path $ctx.State 'jobs'
    $jobLogs = Join-Path $ctx.Logs "jobs\$Job"
    $incoming = Join-Path $ctx.Spool 'incoming'
    foreach ($d in @($jobs, $jobLogs, $incoming)) { [void](New-Item -ItemType Directory -Force -Path $d) }
    $log = Get-VigilLogFile -Parsed $ctx.Parsed -Dir $jobLogs -Day (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $statePath = Join-Path $jobs "$Job.state"
    $hostName = $env:COMPUTERNAME.ToLowerInvariant()
    $now = Get-VigilNow
    $started = $now.Epoch
    $self = [System.Diagnostics.Process]::GetCurrentProcess()
    # The supervisor wrote the boot id into the launch; working it out again
    # costs a fresh process most of a second.
    $bootId = if ($ctx.Boot) { $ctx.Boot } else { Get-VigilBootId }

    # Vigil's own workers run a function, not a job command (4.5).
    if (@('vigil_sender', 'vigil_fetch', 'vigil_logs', 'vigil_update') -ccontains $Job) {
        $state = [ordered]@{
            schema_version = 1; job = $Job; run_id = $RunId; status = 'running'; reason = ''
            boot_id = $bootId; started_epoch = $started; started_at = $now.Iso
            worker_pid = $PID; worker_name = "$($self.ProcessName).exe"; worker_start = ConvertTo-VigilEpoch $self.StartTime
        }
        # The sender has a fixed max_runtime of 5 minutes (4.5): with one
        # sender at a time, a hung one would stop all delivery. It is its own
        # job process, so the supervisor ends it as it ends a job past its
        # deadline (10.3). VIGIL_TEST_SENDER_LIMIT shortens it for the tests
        # (22.4.7).
        if ($Job -ceq 'vigil_sender') {
            $limit = 300
            if ($env:VIGIL_TEST_SENDER_LIMIT -cmatch '^[0-9]+$') { $limit = [long]$env:VIGIL_TEST_SENDER_LIMIT }
            $state.deadline_epoch = $started + $limit
            $state.job_pid = $PID
            $state.job_name = $state.worker_name
            $state.job_start = $state.worker_start
        }
        Write-VigilStateFile -Path $statePath -Fields $state
        [System.IO.File]::AppendAllText($log, "$($now.Iso) $RunId run start`r`n")
        try {
            if ($Job -ceq 'vigil_fetch') { $r = Invoke-VigilFetch -Ctx $ctx -HostName $hostName -Root $Root -Log $log -RunId $RunId }
            elseif ($Job -ceq 'vigil_logs') { $r = Invoke-VigilLogs -Ctx $ctx -HostName $hostName -Root $Root -Log $log -RunId $RunId }
            elseif ($Job -ceq 'vigil_update') {
                # $app is vigil.ps1's: the app\ this worker was started from.
                $r = Invoke-VigilUpdate -Ctx $ctx -Root $Root -App $(if ($app) { $app } else { Join-Path $Root 'app' }) -Log $log -RunId $RunId
            }
            else { $r = Invoke-VigilSend -Ctx $ctx -HostName $hostName -Root $Root }
        }
        catch { $r = @{ Ok = $false; Reason = "$($Job.Substring(6)) error: $($_.Exception.Message)" } }
        $status = if ($r.Ok) { 'succeeded' } else { 'failed' }
        $now = Get-VigilNow
        $duration = $now.Epoch - $started
        $state.status = $status
        $state.reason = $r.Reason
        $state.ended_epoch = $now.Epoch
        $state.ended_at = $now.Iso
        $state.duration_seconds = $duration
        $state.cpu_seconds = Get-VigilRunCpu
        Write-VigilStateFile -Path $statePath -Fields $state
        $why = if ($r.Reason) { " ($($r.Reason))" } else { '' }
        [System.IO.File]::AppendAllText($log, "$($now.Iso) $RunId run end $status$why in ${duration}s, cpu $($state.cpu_seconds)s`r`n")
        $tokenStream.Dispose()
        # A process the job left running may still hold it: then the supervisor
        # removes it once that process lets go.
        try { [System.IO.File]::Delete($token) } catch { }
        return @{ Code = $(if ($r.Ok) { 0 } else { 2 }); Outcome = $status; Reason = $r.Reason; Duration = $duration }
    }

    $index = New-VigilConfigIndex -Parsed $ctx.Parsed
    $eff = Get-VigilEffectiveJob -Index $index -Id $Job
    $exitCodes = 'standard'
    $maxRuntime = ''
    $missing = @()
    $envPairs = @()
    $required = @()
    $secretRows = @()
    foreach ($row in $eff) {
        switch -CaseSensitive ($row.Key) {
            'exit_codes' { $exitCodes = $row.Value }
            'max_runtime' { $maxRuntime = $row.Value }
            'require_env' { $required += $row.Value }
            'secret' { $secretRows += $row.Value }
            'env' { $envPairs += $row.Value }
        }
    }

    # Secrets for the job (6.5.4), resolved now, for this run only. A secret
    # that cannot be resolved fails the run before it starts; the reason
    # names the reference, never a value.
    $secretValues = [ordered]@{}
    $secretError = ''
    foreach ($s in $secretRows) {
        $eq = $s.IndexOf('=')
        $ref = $s.Substring($eq + 1)
        $r = Resolve-VigilSecret -Root $Root -Parsed $ctx.Parsed -Reference $ref
        if (-not $r.Ok) { $secretError = "secret $ref unavailable: $($r.Why)"; break }
        $secretValues[$s.Substring(0, $eq)] = $r.Value
    }
    # require_env counts the variables those secrets provide, and reads the
    # registry now, so a variable set since Vigil started is seen (6.5.1).
    $freshEnv = [ordered]@{}
    foreach ($name in $required) {
        if ($secretValues.Contains($name)) { continue }
        $v = Get-VigilFreshEnv $name
        if ($null -eq $v) { $missing += $name } else { $freshEnv[$name] = $v }
    }
    $mode = if ($exitCodes -ceq 'nagios') { 'nagios' } else { 'standard' }

    $state = [ordered]@{
        schema_version = 1
        job            = $Job
        run_id         = $RunId
        instance       = Get-VigilConfigValue $ctx.Parsed 'vigil' 'instance' 'vigil'
        status         = 'running'
        reason         = ''
        boot_id        = $bootId
        started_epoch  = $started
        started_at     = $now.Iso
        deadline_epoch = $(if ($maxRuntime) { $started + (ConvertTo-VigilSeconds $maxRuntime) } else { '' })
        worker_pid     = $PID
        worker_name    = "$($self.ProcessName).exe"
        worker_start   = ConvertTo-VigilEpoch $self.StartTime
    }
    Write-VigilStateFile -Path $statePath -Fields $state
    $logLines = New-Object System.Text.StringBuilder
    [void]$logLines.Append("$($now.Iso) $RunId run start`r`n")
    [System.IO.File]::AppendAllText($log, $logLines.ToString())

    $code = '-'
    $jobCpu = 0
    $outcome = 'failed'
    $reason = ''
    $rawOut = Join-Path $jobLogs "$RunId.out.raw"
    $rawErr = Join-Path $jobLogs "$RunId.err.raw"
    $outEncoding = $null
    $errEncoding = $null
    # A script from a source runs from its cached copy (16.5).
    $cmd = Get-VigilJobCommand -Index $index -Id $Job -Platform 'windows' -Root $Root -Cached $ctx.Script
    $file = (Get-VigilIndexValue -Index $index -Section "job.$Job" -Key 'file').Value
    $filePath = Resolve-VigilPath -Path $file -Platform 'windows' -Root $Root
    if ($ctx.Script) { $filePath = $ctx.Script }
    if ($cmd.Error) { $reason = $cmd.Message }
    elseif ($secretError) { $reason = $secretError }
    elseif ($missing.Count -gt 0) { $reason = "missing environment variable $($missing -join ' ')" }
    elseif (-not [System.IO.Directory]::Exists($cmd.Cwd)) { $reason = "working directory not found: $($cmd.Cwd)" }
    elseif (-not [System.IO.File]::Exists($filePath)) {
        $reason = "file not found: $filePath"
        # A pack's job: whether the pack is here, and has it (backlog 67).
        if (-not $ctx.Script) { $why = Get-VigilPackMissing -Root $Root -File $file; if ($why) { $reason = "$reason ($why)" } }
    }
    elseif ($cmd.Program.Contains('\') -and -not [System.IO.File]::Exists($cmd.Program)) { $reason = "not found: $($cmd.Program)" }
    elseif (-not $cmd.Program.Contains('\') -and -not (Get-Command $cmd.Program -CommandType Application -ErrorAction SilentlyContinue)) {
        $reason = "not found: $($cmd.Program)"
    }

    if ($reason.Length -eq 0) {
        # Run the job directly, never through a shell, with its environment.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $cmd.Program
        $psi.Arguments = $cmd.Line
        $psi.WorkingDirectory = $cmd.Cwd
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.EnvironmentVariables['VIGIL_RUN_ID'] = $RunId
        foreach ($k in $freshEnv.Keys) { $psi.EnvironmentVariables[$k] = $freshEnv[$k] }
        foreach ($pair in $envPairs) {
            $eq = $pair.IndexOf('=')
            $psi.EnvironmentVariables[$pair.Substring(0, $eq)] = $pair.Substring($eq + 1)
        }
        # Secrets last: only in this process's environment, never on its
        # command line or on disk.
        foreach ($k in $secretValues.Keys) { $psi.EnvironmentVariables[$k] = $secretValues[$k] }
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $startError = ''
        try { [void]$p.Start() }
        catch { $startError = $_.Exception.InnerException.Message; if (-not $startError) { $startError = $_.Exception.Message } }
        if ($startError) { $reason = "could not start: $startError" }
        else {
            # No input: a job that asks for some gets end of file at once instead of
            # waiting for ever.
            $p.StandardInput.Close()
            # Output goes to files as it comes, as on Linux and macOS, so a job
            # that prints a lot never costs the worker that much memory. Both
            # streams are copied at once, so a job filling one cannot block on
            # the other. The bytes are kept as they are and decoded once the job
            # ends, with the encoding the console would have used.
            $outEncoding = $p.StandardOutput.CurrentEncoding
            $errEncoding = $p.StandardError.CurrentEncoding
            $outFile = [System.IO.File]::Open($rawOut, 'Create', 'Write', 'Read')
            $errFile = [System.IO.File]::Open($rawErr, 'Create', 'Write', 'Read')
            $outTask = $p.StandardOutput.BaseStream.CopyToAsync($outFile)
            $errTask = $p.StandardError.BaseStream.CopyToAsync($errFile)
            $state.job_pid = $p.Id
            # The process's own name (cmd.exe for a .cmd file), which is what
            # ownership is checked against before any kill (11.5).
            try { $state.job_name = "$($p.ProcessName).exe" } catch { $state.job_name = [System.IO.Path]::GetFileName($cmd.Program) }
            try { $state.job_start = ConvertTo-VigilEpoch $p.StartTime } catch { $state.job_start = '' }
            Write-VigilStateFile -Path $statePath -Fields $state
            $p.WaitForExit()
            try { $jobCpu = $p.TotalProcessorTime.TotalSeconds } catch { }
            try { $outTask.Wait(); $errTask.Wait() }
            finally { $outFile.Dispose(); $errFile.Dispose() }
            $code = "$($p.ExitCode)"
            $outcome = Get-VigilOutcome -ExitCodes $exitCodes -Code $code
            if ($outcome -cne 'succeeded') { $reason = "exit code $code" }
            # The supervisor writes a marker before it stops a run for
            # overrunning max_runtime (11.6): whatever the exit code, it timed out.
            if ([System.IO.File]::Exists($timeoutMarker)) { $outcome = 'timed_out'; $reason = "stopped after max_runtime $maxRuntime" }
        }
    }

    $now = Get-VigilNow
    $duration = $now.Epoch - $started

    # Standard output as UTF-8 text, for the metrics parser and the job log.
    $out = Join-Path $jobLogs "$RunId.out"
    Copy-VigilJobText -Raw $rawOut -Encoding $outEncoding -To $out

    $output = ConvertFrom-VigilJobOutput -Mode $mode -Cap $Script:VigilMetricLinesMax -Path $out
    $events = Get-VigilRunEvents -Parsed $ctx.Parsed -Id $Job -Epoch "$($now.Epoch)" -Outcome $outcome -ExitCode $code `
        -Duration "$duration" -HostName $hostName -Os 'windows' -Output $output

    # Events before the final state (4.3, step 7).
    $stem = "$($now.Epoch)-$Job-$RunId.events"
    # Events that cannot be written are said, in the job's log, and the final
    # state is written all the same: a spool that is full or closed must not
    # cost the run its outcome, as an exception here would (V-06).
    try { Write-VigilFileAtomic -Path (Join-Path $incoming $stem) -Text (($events | ForEach-Object { "$_`n" }) -join '') }
    catch {
        try { [System.IO.File]::AppendAllText($log, "$($now.Iso) $RunId events not written to the spool: this run's metrics are lost ($(($_.Exception.Message -replace '\s+', ' ')))`r`n") } catch { }
    }
    Invoke-VigilFault 'worker.after_spool'

    $state.status = $outcome
    $state.reason = $reason
    $state.ended_epoch = $now.Epoch
    $state.ended_at = $now.Iso
    $state.duration_seconds = $duration
    $state.cpu_seconds = Get-VigilRunCpu -Job $jobCpu
    $state.exit_code = if ($code -ceq '-') { '' } else { $code }
    $state.metric_lines = $output.Lines
    $state.invalid_lines = $output.Invalid
    $state.dropped_lines = $output.Dropped
    $state.spool_file = $stem
    Write-VigilStateFile -Path $statePath -Fields $state
    Invoke-VigilFault 'worker.after_state'
    # The job log (13.1): its output, then how it ended.
    $writer = New-Object System.IO.StreamWriter($log, $true, (New-Object System.Text.UTF8Encoding $false))
    try {
        Write-VigilJobLines -Path $out -Encoding (New-Object System.Text.UTF8Encoding $false) -Prefix "$($now.Iso) $RunId out" -Writer $writer
        Write-VigilJobLines -Path $rawErr -Encoding $errEncoding -Prefix "$($now.Iso) $RunId err" -Writer $writer
        $cpu = ", cpu $($state.cpu_seconds)s"
        if ($reason) { $writer.Write("$($now.Iso) $RunId run end $outcome ($reason) in ${duration}s$cpu`r`n") }
        else { $writer.Write("$($now.Iso) $RunId run end $outcome in ${duration}s$cpu`r`n") }
    }
    finally { $writer.Dispose() }
    foreach ($f in @($out, $rawOut, $rawErr)) { if ([System.IO.File]::Exists($f)) { [System.IO.File]::Delete($f) } }
    if ([System.IO.File]::Exists($timeoutMarker)) { [System.IO.File]::Delete($timeoutMarker) }

    # Release the token: close it, then delete it (4.3, step 9).
    $tokenStream.Dispose()
    # A process the job left running may still hold it: then the supervisor
    # removes it once that process lets go.
    try { [System.IO.File]::Delete($token) } catch { }

    $rc = switch ($outcome) { 'succeeded' { 0 } 'warning' { 1 } 'unknown' { 3 } default { 2 } }
    return @{ Code = $rc; Outcome = $outcome; Reason = $reason; Duration = $duration }
}
