#Requires -Version 5.1

<#
.SYNOPSIS
    vm.ps1 - what each Erlang VM says about itself: memory, limits, run queues
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads each node two ways, whichever is set on the job:
      BEAM_PROMETHEUS  <name>=<url> separated by ;: a node's Prometheus page
                       (erlang_vm_*, as prometheus.erl and RabbitMQ give
                       it: RabbitMQ's is http://127.0.0.1:15692/metrics)
      BEAM_DIST        <name>=<node> separated by ;: the node itself, with
                       its cookie (BEAM_COOKIE, a secret), by _beam.escript
                       beside this script, with Erlang's escript.exe
                       (BEAM_ERLANG, where Erlang is, else the PATH's, else
                       the newest under Program Files)
    The metrics are the same either way, tagged source=prometheus or
    source=dist. Prometheus gives no version or uptime; the cookie gives
    both.

    WARNING: a node's cookie lets whoever holds it run anything on that
    node. This pack never changes anything: it only reads, and
    _beam.escript lists every call it makes. Give Vigil the cookie only if
    you accept that.

    Metrics:
        nodes                   the nodes named in BEAM_PROMETHEUS and
                                BEAM_DIST
        up                      1 when the node answers, else 0, tagged
                                node=<its name> and source=<prometheus or
                                dist>
        version                 always 1, tagged the same, otp=<its release>
                                and erts=<its runtime's version> (dist only)
        memory_bytes            memory it has allocated, tagged the same and
                                kind=<total, processes, system, atom,
                                binary, code or ets>
        processes               its processes (Erlang's, not the OS's)
        process_limit           the most it may have (+P)
        process_pct             processes, as a percentage of process_limit
        ports                   its ports: sockets, files and drivers open
        port_limit              the most it may have (+Q)
        port_pct                ports, as a percentage of port_limit
        atoms                   its atoms, which are never freed
        atom_limit              the most it may have (+t): past it, the VM
                                dies
        atom_pct                atoms, as a percentage of atom_limit
        ets_tables              its ETS tables
        ets_limit               the most it may have
        ets_pct                 ets_tables, as a percentage of ets_limit
        schedulers_online       schedulers running Erlang code
        run_queue               processes and ports ready to run, waiting
                                for a scheduler
        dirty_cpu_run_queue     work waiting for a dirty CPU scheduler
        dirty_io_run_queue      work waiting for a dirty I/O scheduler
        reductions_count        reductions, its unit of work (a running
                                total)
        gcs_count               garbage collections (a running total)
        gc_reclaimed_bytes      memory they reclaimed (a running total)
        context_switches_count  process switches (a running total)
        received_bytes          bytes its ports received (a running total)
        sent_bytes              bytes its ports sent (a running total)
        uptime_seconds          how long it has run (dist only)

    Example output:
      metric nodes 1
      metric up 1 node=rabbit source=prometheus
      metric memory_bytes 69603512 node=rabbit source=prometheus kind=total
      metric processes 398 node=rabbit source=prometheus
      metric process_limit 1048576 node=rabbit source=prometheus
      metric process_pct 0.04 node=rabbit source=prometheus
      metric atoms 36289 node=rabbit source=prometheus
      metric atom_pct 0.73 node=rabbit source=prometheus
      metric run_queue 0 node=rabbit source=prometheus

    Reading the results (starting points: tune them to the node):
      Healthy  up 1; process_pct, port_pct, atom_pct and ets_pct low and
               flat; run_queue near 0 most of the time; memory_bytes of
               kind total steady once warmed up.
      Watch    atom_pct rising and never falling: something makes atoms
               from input (list_to_atom), and atoms are never freed;
               process_pct or ets_pct climbing: a leak; run_queue above
               schedulers_online for minutes: the VM is short of CPU;
               kind=binary climbing: large binaries held on to.
      Act      up 0; atom_pct past 80: at 100 the VM dies; process_pct or
               port_pct past 80: at 100 nothing new can start, connections
               are refused; memory_bytes total near the machine's memory.

    Requires: Windows PowerShell 5.1 or PowerShell 7; Erlang/OTP 25 or
      later, for BEAM_DIST
    Exit code: 0 on success, nodes up or down; 1 if escript.exe is missing,
      a setting is wrong, a page is not Erlang's, or a node refused the
      cookie
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$prom = @(([string]$env:BEAM_PROMETHEUS) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$dist = @(([string]$env:BEAM_DIST) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Write-Output "metric nodes $($prom.Count + $dist.Count)"
$code = 0
$inv = [Globalization.CultureInfo]::InvariantCulture

# Prometheus: each page, as Erlang names its own figures.
$names = @{
    'erlang_vm_processes' = 'processes'; 'erlang_vm_process_limit' = 'process_limit'
    'erlang_vm_ports' = 'ports'; 'erlang_vm_port_limit' = 'port_limit'
    'erlang_vm_atoms' = 'atoms'; 'erlang_vm_atom_limit' = 'atom_limit'
    'erlang_vm_memory_ets_tables' = 'ets_tables'; 'erlang_vm_ets_limit' = 'ets_limit'
    'erlang_vm_schedulers_online' = 'schedulers_online'
    'erlang_vm_statistics_run_queues_length' = 'run_queue'
    'erlang_vm_statistics_dirty_cpu_run_queue_length' = 'dirty_cpu_run_queue'
    'erlang_vm_statistics_dirty_io_run_queue_length' = 'dirty_io_run_queue'
    'erlang_vm_statistics_reductions_total' = 'reductions_count'
    'erlang_vm_statistics_garbage_collection_number_of_gcs_total' = 'gcs_count'
    'erlang_vm_statistics_garbage_collection_bytes_reclaimed_total' = 'gc_reclaimed_bytes'
    'erlang_vm_statistics_context_switches_total' = 'context_switches_count'
    'erlang_vm_statistics_bytes_received_total' = 'received_bytes'
    'erlang_vm_statistics_bytes_output_total' = 'sent_bytes'
}
foreach ($entry in $prom) {
    $i = $entry.IndexOf('=')
    if ($i -lt 1 -or $i -eq $entry.Length - 1) {
        [Console]::Error.WriteLine("vm: BEAM_PROMETHEUS: '$entry' is not <name>=<url>, as in rabbit=http://127.0.0.1:15692/metrics")
        exit 1
    }
    $name = $entry.Substring(0, $i).Trim() -replace '[^A-Za-z0-9@._:-]', '_'
    $url = $entry.Substring($i + 1).Trim()
    $tag = "node=$name source=prometheus"
    try { $page = [string](Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15).Content }
    catch {
        Write-Output "metric up 0 $tag"
        # Nothing listening, or no answer in time, is a reading; an answer
        # that is an error (404, 401) is a setting to fix.
        if ($_.Exception.Response) { [Console]::Error.WriteLine("vm: ${name}: $url did not give a page: $($_.Exception.Message)"); $code = 1 }
        continue
    }
    if ($page -notmatch '(?m)^erlang_vm_') {
        Write-Output "metric up 0 $tag"
        [Console]::Error.WriteLine("vm: ${name}: $url answers, but with no erlang_vm_ lines: not an Erlang node's Prometheus page")
        $code = 1
        continue
    }
    Write-Output "metric up 1 $tag"
    $m = @{}; $kind = @{}; $sys = $null; $procs = $null
    foreach ($line in ($page -split "`n")) {
        if ($line.StartsWith('#')) { continue }
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -lt 2) { continue }
        $key = $parts[0]; $v = $parts[1]
        if ($key -eq 'erlang_vm_memory_bytes{kind="system"}') { $sys = $v }
        elseif ($key -eq 'erlang_vm_memory_bytes{kind="processes"}') { $procs = $v }
        elseif ($key -match '^erlang_vm_memory_system_bytes\{usage="(atom|binary|code|ets)"\}$') { $kind[$Matches[1]] = $v }
        elseif ($names.ContainsKey($key)) { $m[$names[$key]] = $v }
    }
    if ($null -ne $sys -and $null -ne $procs) {
        Write-Output ("metric memory_bytes {0} {1} kind=total" -f ([double]::Parse($sys, $inv) + [double]::Parse($procs, $inv)).ToString('0', $inv), $tag)
    }
    if ($null -ne $procs) { Write-Output "metric memory_bytes $procs $tag kind=processes" }
    if ($null -ne $sys) { Write-Output "metric memory_bytes $sys $tag kind=system" }
    foreach ($k in 'atom', 'binary', 'code', 'ets') { if ($kind.ContainsKey($k)) { Write-Output "metric memory_bytes $($kind[$k]) $tag kind=$k" } }
    foreach ($trio in @(('processes', 'process_limit', 'process_pct'), ('ports', 'port_limit', 'port_pct'),
            ('atoms', 'atom_limit', 'atom_pct'), ('ets_tables', 'ets_limit', 'ets_pct'))) {
        foreach ($n in $trio[0], $trio[1]) { if ($m.ContainsKey($n)) { Write-Output "metric $n $($m[$n]) $tag" } }
        if ($m.ContainsKey($trio[0]) -and $m.ContainsKey($trio[1]) -and [double]::Parse($m[$trio[1]], $inv) -gt 0) {
            $pct = 100 * [double]::Parse($m[$trio[0]], $inv) / [double]::Parse($m[$trio[1]], $inv)
            Write-Output "metric $($trio[2]) $($pct.ToString('0.00', $inv)) $tag"
        }
    }
    foreach ($n in 'schedulers_online', 'run_queue', 'dirty_cpu_run_queue', 'dirty_io_run_queue', 'reductions_count',
        'gcs_count', 'gc_reclaimed_bytes', 'context_switches_count', 'received_bytes', 'sent_bytes') {
        if ($m.ContainsKey($n)) { Write-Output "metric $n $($m[$n]) $tag" }
    }
}

# The cookie: _beam.escript, with Erlang's escript.exe, in a home of this
# run's own (Erlang writes a cookie file into its home when it has none:
# never Vigil's).
if ($dist.Count -gt 0) {
    $escript = $null
    if ($env:BEAM_ERLANG) {
        foreach ($c in (Join-Path $env:BEAM_ERLANG 'bin\escript.exe'), (Join-Path $env:BEAM_ERLANG 'escript.exe')) {
            if (Test-Path -LiteralPath $c) { $escript = $c; break }
        }
    }
    if (-not $escript) { $c = Get-Command escript.exe -ErrorAction SilentlyContinue; if ($c) { $escript = $c.Source } }
    if (-not $escript) {
        $escript = @(Get-ChildItem -Path "$env:ProgramFiles\Erlang OTP\bin\escript.exe", "$env:ProgramFiles\erl*\bin\escript.exe" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName })[0]
    }
    if (-not $escript) {
        [Console]::Error.WriteLine('vm: escript not found: BEAM_DIST is read with Erlang/OTP 25 or later (BEAM_ERLANG, where Erlang is, or escript.exe on the PATH)')
        exit 1
    }
    $home_ = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-beam.' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $home_)
    $saved = @{}
    foreach ($n in 'HOME', 'HOMEDRIVE', 'HOMEPATH', 'USERPROFILE') { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    try {
        $env:HOME = $home_; $env:USERPROFILE = $home_
        $env:HOMEDRIVE = $home_.Substring(0, 2); $env:HOMEPATH = $home_.Substring(2)
        & $escript (Join-Path $PSScriptRoot '_beam.escript') vm
        if ($LASTEXITCODE -ne 0) { $code = 1 }
    }
    finally {
        foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
        Remove-Item -LiteralPath $home_ -Recurse -Force -ErrorAction SilentlyContinue
    }
}
exit $code
