#Requires -Version 5.1

<#
.SYNOPSIS
    resources.ps1 - each running container: CPU, memory against its limit, processes, network and disk
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Each running container by name (the first 100; DOCKER_MOST sets another
    number): the CPU time it has used, its memory and how near its limit that
    is, its processes, and what it has sent, received, read and written.

    Reads the Docker engine's API at DOCKER_HOST
    (npipe:////./pipe/docker_engine by default) with .NET alone. Every request
    is a GET: nothing is started, stopped, removed or pruned.

    Metrics:
      up                            1 when the engine answers, else 0 (and
                                    nothing more is read)
      containers_measured           running containers measured
      memory_total_bytes            memory they use, together
      memory_fullest_pct            the fullest of those with a memory limit:
                                    its memory, as a share of its limit
      cpu_throttled_containers      containers held back at their CPU limit at
                                    least once since they started
      cpu_seconds_count             CPU time it has used since it started, in
                                    seconds (a running total: its rate is the
                                    processors it uses), tagged name=<the
                                    container's name>
      cpu_throttled_seconds_count   time it was held back at its CPU limit (a
                                    running total), tagged name=<the
                                    container's name>
      memory_bytes                  memory it uses, without the file cache
                                    that can be given back, tagged name=<the
                                    container's name>
      memory_limit_bytes            its memory limit, 0 when it has none,
                                    tagged name=<the container's name>
      memory_pct                    for one with a limit: its memory, as a
                                    share of it, tagged name=<the container's
                                    name>
      pids                          processes and threads in it, tagged
                                    name=<the container's name>
      network_rx_bytes_count        bytes it received, over its networks (a
                                    running total), tagged name=<the
                                    container's name>
      network_tx_bytes_count        bytes it sent (a running total), tagged
                                    name=<the container's name>
      block_read_bytes_count        bytes it read from disk (a running total),
                                    tagged name=<the container's name>
      block_write_bytes_count       bytes it wrote to disk (a running total),
                                    tagged name=<the container's name>
      containers_not_shown          past the first 100 by name (DOCKER_MOST),
                                    how many were not measured

    Example output:
      metric up 1
      metric containers_measured 11
      metric memory_total_bytes 838373376
      metric memory_fullest_pct 1.41
      metric cpu_throttled_containers 1
      metric cpu_seconds_count 4.112 name=vigilit_busy
      metric cpu_throttled_seconds_count 9.003 name=vigilit_busy
      metric memory_bytes 471040 name=vigilit_busy
      metric memory_limit_bytes 0 name=vigilit_busy
      metric pids 1 name=vigilit_busy
      metric network_rx_bytes_count 3054 name=vigilit_busy
      metric network_tx_bytes_count 126 name=vigilit_busy
      metric block_read_bytes_count 0 name=vigilit_busy
      metric block_write_bytes_count 0 name=vigilit_busy
      metric cpu_seconds_count 0.142 name=vigilit_ok
      metric cpu_throttled_seconds_count 0 name=vigilit_ok
      metric memory_bytes 946176 name=vigilit_ok
      metric memory_limit_bytes 67108864 name=vigilit_ok
      metric memory_pct 1.41 name=vigilit_ok
      metric pids 2 name=vigilit_ok
      metric network_rx_bytes_count 4384 name=vigilit_ok
      metric network_tx_bytes_count 126 name=vigilit_ok
      metric block_read_bytes_count 0 name=vigilit_ok
      metric block_write_bytes_count 811008 name=vigilit_ok
      metric cpu_seconds_count 0.41 name=vigilit_unhealthy
      metric cpu_throttled_seconds_count 0 name=vigilit_unhealthy
      metric memory_bytes 495616 name=vigilit_unhealthy
      metric memory_limit_bytes 0 name=vigilit_unhealthy
      metric pids 1 name=vigilit_unhealthy
      metric network_rx_bytes_count 3920 name=vigilit_unhealthy
      metric network_tx_bytes_count 126 name=vigilit_unhealthy
      metric block_read_bytes_count 0 name=vigilit_unhealthy
      metric block_write_bytes_count 0 name=vigilit_unhealthy
      metric cpu_seconds_count 0.066 name=vigilit_writes
      metric cpu_throttled_seconds_count 0 name=vigilit_writes
      metric memory_bytes 512000 name=vigilit_writes
      metric memory_limit_bytes 0 name=vigilit_writes
      metric pids 1 name=vigilit_writes
      metric network_rx_bytes_count 2970 name=vigilit_writes
      metric network_tx_bytes_count 126 name=vigilit_writes
      metric block_read_bytes_count 0 name=vigilit_writes
      metric block_write_bytes_count 655360 name=vigilit_writes
      metric containers_not_shown 0

    Reading the results (starting points: tune them to the machine):
      Healthy  memory_pct well under 100; memory_bytes steady for a container
               doing steady work; cpu_throttled_seconds_count flat.
      Watch    memory_bytes climbing run after run with no more work to do: a
               leak, on its way to the limit. cpu_throttled_seconds_count
               rising: its CPU limit holds it back. pids climbing: processes
               or threads that are never reaped.
      Act      memory_fullest_pct above 90: a container about to be killed for
               memory (memory_pct says which). pids near the limit of the
               machine.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, the engine up or down; 1 if DOCKER_HOST is wrong,
      this account may not use the engine, or what answers is not a Docker
      engine
#>

$Job = 'resources'
. (Join-Path $PSScriptRoot '_docker.ps1')

Test-Engine
$i = Get-Json '/info'
# A container between two starts has nothing to measure.
$all = Get-Json '/containers/json'
$list = By-Name @(@($all) | Where-Object { $_.State -cne 'restarting' })
$win = ("$($i.OSType)" -ceq 'windows')
$s = New-Object System.Collections.Generic.List[object]
foreach ($one in @($list | Select-Object -First $script:Most)) {
    $d = Get-Json "/containers/$($one.Id)/stats?stream=false&one-shot=true" -Missing
    # The name the list gives it: the statistics of some engines leave it out.
    if ($null -ne $d -and $d.cpu_stats) { $d['name'] = (Name-Of $one); $s.Add($d) }
}
# Memory in use, as docker stats counts it: without the file cache that can
# be given back (cgroup v2: inactive_file; v1: total_inactive_file). A
# Windows container: its private working set.
function Mem($d) {
    $m = $d.memory_stats
    if (-not $m) { return [double]0 }
    if ($win) { return (N $m.privateworkingset) }
    $cache = [double]0
    if ($m.stats) { if ($null -ne $m.stats.inactive_file) { $cache = N $m.stats.inactive_file } elseif ($null -ne $m.stats.total_inactive_file) { $cache = N $m.stats.total_inactive_file } }
    return [Math]::Max((N $m.usage) - $cache, 0)
}
# A limit of its own: where there is none, the engine reports the memory of the machine.
function Limit($d) {
    $l = [double]0
    if ($d.memory_stats) { $l = N $d.memory_stats.limit }
    if ($win -or $l -eq 0 -or $l -ge (N $i.MemTotal)) { return [double]0 }
    return $l
}
function Sum($Items, [string]$Key) { $t = [double]0; foreach ($x in @($Items)) { if ($null -ne $x) { $t += (N $x[$Key]) } }; return $t }
function Blk($d, [string]$Op) {
    if ($win) { if ($Op -ceq 'read') { return (N $d.storage_stats.read_size_bytes) }; return (N $d.storage_stats.write_size_bytes) }
    $t = [double]0
    if ($d.blkio_stats) { foreach ($x in @($d.blkio_stats.io_service_bytes_recursive)) { if ($null -ne $x -and "$($x.op)".ToLowerInvariant() -ceq $Op) { $t += (N $x.value) } } }
    return $t
}
$total = [double]0; $fullest = [double]0; $throttled = 0
foreach ($d in $s) {
    $total += (Mem $d)
    $l = Limit $d
    if ($l -gt 0) { $fullest = [Math]::Max($fullest, (Mem $d) * 100 / $l) }
    if ($d.cpu_stats.throttling_data -and (N $d.cpu_stats.throttling_data.throttled_periods) -gt 0) { $throttled++ }
}
"metric containers_measured $($s.Count)"
"metric memory_total_bytes $(Num $total)"
"metric memory_fullest_pct $(Num $fullest)"
"metric cpu_throttled_containers $throttled"
foreach ($d in $s) {
    $n = Safe (Name-Of $d)
    $cpu = [double]0
    if ($d.cpu_stats.cpu_usage) { $cpu = (N $d.cpu_stats.cpu_usage.total_usage) / $(if ($win) { 10000000 } else { 1000000000 }) }
    $thr = [double]0
    if ($d.cpu_stats.throttling_data) { $thr = (N $d.cpu_stats.throttling_data.throttled_time) / 1000000000 }
    $l = Limit $d
    $nets = @(); if ($d.networks) { $nets = @($d.networks.Values) }
    $pids = [double]0
    if ($d.pids_stats -and $null -ne $d.pids_stats.current) { $pids = N $d.pids_stats.current } elseif ($null -ne $d.num_procs) { $pids = N $d.num_procs }
    "metric cpu_seconds_count $(Num $cpu) name=$n"
    "metric cpu_throttled_seconds_count $(Num $thr) name=$n"
    "metric memory_bytes $(Num (Mem $d)) name=$n"
    "metric memory_limit_bytes $(Num $l) name=$n"
    if ($l -gt 0) { "metric memory_pct $(Num ((Mem $d) * 100 / $l)) name=$n" }
    "metric pids $(Num $pids) name=$n"
    "metric network_rx_bytes_count $(Num (Sum $nets 'rx_bytes')) name=$n"
    "metric network_tx_bytes_count $(Num (Sum $nets 'tx_bytes')) name=$n"
    "metric block_read_bytes_count $(Num (Blk $d 'read')) name=$n"
    "metric block_write_bytes_count $(Num (Blk $d 'write')) name=$n"
}
"metric containers_not_shown $([Math]::Max($list.Length - $script:Most, 0))"
exit 0
