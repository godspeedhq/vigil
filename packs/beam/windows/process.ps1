#Requires -Version 5.1

<#
.SYNOPSIS
    process.ps1 - every Erlang VM on this machine, as Windows sees it
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Finds each Erlang VM (erl.exe or werl.exe, which run the emulator
    inside themselves; a service's too, under erlsrv) and reports its
    memory, CPU, threads, handles and uptime, named by its node name
    (-sname or -name, on its command line or in its -args_file), else by
    what it was started with (-s rabbit: rabbit, as RabbitMQ names itself
    once started), else by its process id. It reads nothing else from a
    command line: one may hold the cookie, and this script says only
    whether it does. Another account's command line needs an administrator
    (Vigil's service is one); without it, each VM is named by its process
    id.

    Metrics:
        beams                   the Erlang VMs running on this machine
        running                 always 1, tagged node=<its node name, else
                                its -s module, else pid<n>> and
                                erts=<the runtime's version, 16.1.2>
        rss_bytes               memory it holds (its working set), tagged
                                node=<the same>
        cpu_seconds             CPU time it has used, user and kernel
        threads                 its threads (schedulers, dirty schedulers,
                                async and others)
        open_files              handles it has open: files, sockets and the
                                rest
        open_files_max          not on Windows: a process has no handle
                                limit to read
        uptime_seconds          how long it has run
        cookie_on_command_line  1 when -setcookie is on its command line,
                                which an administrator here can read,
                                else 0
        beams_not_shown         past the first 100 VMs, how many were left
                                out

    Example output:
      metric beams 2
      metric running 1 node=pid67664
      metric rss_bytes 106344448 node=pid67664
      metric cpu_seconds 5.75 node=pid67664
      metric threads 55 node=pid67664
      metric open_files 302 node=pid67664
      metric uptime_seconds 47 node=pid67664
      metric cookie_on_command_line 0 node=pid67664

    Reading the results (starting points: tune them to the node):
      Healthy  beams as many as you run; rss_bytes steady over days;
               uptime_seconds rising.
      Watch    rss_bytes climbing for hours without falling back;
               open_files climbing with it: handles leaking;
               cookie_on_command_line 1: an administrator here can read
               the cookie (use the .erlang.cookie file instead).
      Act      beams lower than you run: a VM is gone (beam.crashdumps
               says why); uptime_seconds back near 0: it restarted.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, VMs or none
#>

$ErrorActionPreference = 'Stop'

# A tag's value: no spaces, quotes or control characters.
function Clean([string]$s) {
    $s = ($s -replace '["''`]', '') -replace '[^A-Za-z0-9@._:/+=,-]', '_'
    if ($s.Length -gt 120) { $s = $s.Substring(0, 120) }
    $s
}

# A command line's words, as Windows splits them: quotes group, and are
# dropped.
function Words([string]$line) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($line, '"([^"]*)"|(\S+)')) {
        if ($m.Groups[1].Success) { $out.Add($m.Groups[1].Value) } else { $out.Add($m.Groups[2].Value) }
    }
    , $out.ToArray()
}

# The node name a VM was given: -sname or -name, on its command line, else
# in its -args_file (when this account can read it), else its -s module.
function NodeOf([string[]]$w) {
    for ($i = 0; $i -lt $w.Count - 1; $i++) {
        if ($w[$i] -eq '-sname' -or $w[$i] -eq '-name') { return $w[$i + 1] }
    }
    for ($i = 0; $i -lt $w.Count - 1; $i++) {
        if ($w[$i] -ne '-args_file') { continue }
        try {
            foreach ($l in [System.IO.File]::ReadAllLines($w[$i + 1])) {
                if ($l -match '^\s*-s?name\s+(\S+)') { return $Matches[1] }
            }
        }
        catch { }
    }
    for ($i = 0; $i -lt $w.Count - 1; $i++) {
        if ($w[$i] -eq '-s' -and -not $w[$i + 1].StartsWith('-')) { return $w[$i + 1] }
    }
    ''
}

$now = [datetime]::UtcNow
$rows = New-Object System.Collections.Generic.List[object]
try {
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='erl.exe' OR Name='werl.exe'")) {
        $rows.Add([pscustomobject]@{
                Id = [int]$p.ProcessId; Line = [string]$p.CommandLine; Path = [string]$p.ExecutablePath
                Rss = [long]$p.WorkingSetSize; Cpu = ([long]$p.KernelModeTime + [long]$p.UserModeTime) / 1e7
                Threads = [int]$p.ThreadCount; Handles = [int]$p.HandleCount
                Start = $(if ($p.CreationDate) { $p.CreationDate.ToUniversalTime() } else { $null })
            })
    }
}
catch {
    # CIM refuses an account logged on over the network that is not an
    # administrator: the processes, without their command lines.
    foreach ($p in @(Get-Process -Name erl, werl -ErrorAction SilentlyContinue)) {
        $cpu = $null; $start = $null; $path = ''
        try { $cpu = $p.TotalProcessorTime.TotalSeconds } catch { }
        try { $start = $p.StartTime.ToUniversalTime() } catch { }
        try { $path = [string]$p.Path } catch { }
        $rows.Add([pscustomobject]@{
                Id = $p.Id; Line = ''; Path = $path; Rss = $p.WorkingSet64; Cpu = $cpu
                Threads = $p.Threads.Count; Handles = $p.HandleCount; Start = $start
            })
    }
}

$out = New-Object System.Collections.Generic.List[string]
$shown = 0
foreach ($r in ($rows | Sort-Object Id)) {
    if ($shown -ge 100) { continue }
    $shown++
    $w = Words $r.Line
    $node = NodeOf $w
    $node = if ($node) { Clean $node } else { "pid$($r.Id)" }
    $erts = ''
    if ($r.Path -match '[\\/]erts-([0-9][0-9.]*)[\\/]') { $erts = " erts=$($Matches[1])" }
    $cookie = if ($w -contains '-setcookie') { 1 } else { 0 }
    $tag = "node=$node"
    $out.Add("metric running 1 $tag$erts")
    $out.Add("metric rss_bytes $($r.Rss) $tag")
    if ($null -ne $r.Cpu) { $out.Add(('metric cpu_seconds {0} {1}' -f ([double]$r.Cpu).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture), $tag)) }
    $out.Add("metric threads $($r.Threads) $tag")
    $out.Add("metric open_files $($r.Handles) $tag")
    if ($r.Start) { $out.Add("metric uptime_seconds $([long]($now - $r.Start).TotalSeconds) $tag") }
    $out.Add("metric cookie_on_command_line $cookie $tag")
}

Write-Output "metric beams $($rows.Count)"
$out | ForEach-Object { Write-Output $_ }
Write-Output "metric beams_not_shown $($rows.Count - $shown)"
exit 0
