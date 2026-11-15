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
    Integration test: the base pack on this machine (SPECIFICATION.md 18.10).
.DESCRIPTION
    vigil init turns it on, each job runs, and its metrics reach a backend.
    The twin of base-pack.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$shell = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil base.$PID"
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Invoke-Vigil {
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root @args 2>&1
    return @{ Code = $LASTEXITCODE; Text = (@($out | ForEach-Object { "$_" }) -join "`n") }
}

function Test-Reports {
    param([string]$Metric)
    $f = "$root\metrics\vigil.prom"
    return [string]([System.IO.File]::Exists($f) -and [System.IO.File]::ReadAllText($f) -cmatch "(?m)^$Metric")
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
[void](New-Item -ItemType Directory -Force -Path "$work\root\packs\base")
$work = (Resolve-Path -LiteralPath $work).ProviderPath
$root = "$work\root"

try {
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app'), (Join-Path $repo 'vendor') -Destination $root
    Copy-Item -LiteralPath (Join-Path $repo 'packs\base\pack.config') -Destination "$root\packs\base"
    Get-ChildItem -LiteralPath (Join-Path $repo 'packs\base\windows') -File | Copy-Item -Destination "$root\packs\base"

    $r = Invoke-Vigil init --instance base --backend file
    Test-Equal 'init turns on the base pack' '0' ([string]$r.Code)
    Test-Equal 'precheck is happy' '0' ([string](Invoke-Vigil precheck).Code)
    Test-Equal 'no load job: Windows has no load average' 'False' ([string](Test-Path -LiteralPath "$root\packs\base\load.ps1"))

    # No run may start the C# compiler (backlog 50): Add-Type starts csc.exe
    # on Windows PowerShell, and doing it on every run of every job was a
    # steady CPU cost. A watcher looks at this test's own descendants only
    # (another Vigil on the machine may compile). The process tree comes from
    # the kernel, which answers where WMI does not; the test compiles that
    # helper here, before it starts watching. PowerShell 7 compiles inside
    # the process instead, with no sign another process can see (it loads
    # Roslyn at start either way), so there the check covers the job
    # scripts, which the base pack runs with powershell.exe.
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class BasePackTree {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Entry {
        public uint Size; public uint Usage; public uint Pid; public IntPtr Heap; public uint Module; public uint Threads;
        public uint Parent; public int Priority; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Exe;
    }
    [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr h, ref Entry e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr h, ref Entry e);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    // Every process below root: "pid name".
    public static List<string> Below(int root) {
        var all = new List<Entry>();
        IntPtr h = CreateToolhelp32Snapshot(2, 0);
        try {
            Entry e = new Entry(); e.Size = (uint)Marshal.SizeOf(typeof(Entry));
            for (bool ok = Process32FirstW(h, ref e); ok; ok = Process32NextW(h, ref e)) all.Add(e);
        } finally { CloseHandle(h); }
        var found = new List<string>(); var pids = new HashSet<uint> { (uint)root };
        for (bool more = true; more; ) {
            more = false;
            foreach (Entry x in all) {
                if (pids.Contains(x.Parent) && x.Pid != x.Parent && pids.Add(x.Pid)) { found.Add(x.Pid + " " + x.Exe); more = true; }
            }
        }
        return found;
    }
}
'@
    $stop = "$work\stop-watching"
    $watcher = [powershell]::Create().AddScript({
        param($Stop, $Root)
        $seen = @{}
        while (-not [System.IO.File]::Exists($Stop)) {
            foreach ($p in [BasePackTree]::Below($Root)) {
                $id, $name = $p.Split(' ', 2)
                if ($name -ieq 'csc.exe') { $seen["csc $id"] = 1 }
            }
            Start-Sleep -Milliseconds 20
        }
        @($seen.Keys) -join ', '
    }).AddArgument($stop).AddArgument($PID)
    $watching = $watcher.BeginInvoke()

    foreach ($j in @('cpu', 'memory', 'disk', 'network', 'services')) {
        $r = Invoke-Vigil run "base_$j"
        Test-Equal "base_$j runs" '0' ([string]$r.Code)
        if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    }
    [System.IO.File]::WriteAllText($stop, '')
    Test-Equal 'no run started the C# compiler' '' ([string]@($watcher.EndInvoke($watching))[0])
    $watcher.Dispose()

    # The sender delivers from the spool.
    foreach ($i in 1..3) {
        [void](Invoke-Vigil supervise --once)
        Start-Sleep -Seconds 3
    }
    Test-Equal 'CPU reaches the backend' 'True' (Test-Reports 'system_cpu_used_pct')
    Test-Equal 'memory reaches the backend' 'True' (Test-Reports 'system_memory_used_pct')
    Test-Equal 'disk reaches the backend' 'True' (Test-Reports 'system_disk_used_pct')
    Test-Equal 'network reaches the backend' 'True' (Test-Reports 'system_network_rx_bytes')
}
finally {
    Start-Sleep -Seconds 2
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
