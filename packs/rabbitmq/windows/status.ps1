#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - each RabbitMQ node: up, its limits and alarms, its clients
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads each node's Prometheus page (the rabbitmq_prometheus plugin, on by
    default, port 15692). The nodes are in RABBITMQ_TARGETS,
    <name>=<address> separated by ;, the address as http://host:15692 (or
    https://, with a certificate Windows trusts), set by the job.
    Read-only: a page any client may read, no login, no cookie.

    Metrics:
      nodes                    the nodes named in RABBITMQ_TARGETS
      up                       1 when the node's page answers, else 0, tagged
                               node=<its name>
      version                  always 1, tagged node=<the same>,
                               rabbitmq=<its version>, erlang=<Erlang/OTP's>,
                               rabbitmq_node=<its node name> and
                               cluster=<its cluster's name>
      memory_used_bytes        memory the node uses (resident)
      memory_limit_bytes       its memory high watermark: past it, publishers
                               are blocked
      memory_pct               memory_used_bytes, as a percentage of the limit
      disk_free_bytes          free disk where it keeps its data
      disk_free_limit_bytes    its free disk limit: below it, publishers are
                               blocked
      alarm_memory             1 when the memory alarm is on: publishers
                               blocked, cluster-wide
      alarm_disk               1 when the free disk alarm is on: the same
      alarm_fds                1 when it has run out of file descriptors
      fds_used                 file descriptors open: connections, files
      fds_max                  the most it may open
      fd_pct                   fds_used, as a percentage of fds_max
      erlang_processes         Erlang processes (a queue, a connection and a
                               channel each take some)
      erlang_processes_limit   the most it may have
      erlang_process_pct       erlang_processes, as a percentage of the limit
      run_queue                Erlang work waiting for a scheduler
      uptime_seconds           how long the node has run
      unreachable_peers        cluster members it cannot reach
      connections              client connections open now
      channels                 channels open now
      consumers                consumers now
      queues                   queues on this node
      publishers               publishers now

    Example output:
      metric nodes 1
      metric up 1 node=win
      metric version 1 node=win rabbitmq=4.4.1 erlang=28.5 rabbitmq_node=rabbit@APHC-LPT-1 cluster=rabbit@APHC-LPT-1
      metric memory_used_bytes 72777728 node=win
      metric memory_limit_bytes 10236388147 node=win
      metric memory_pct 0.71 node=win
      metric disk_free_bytes 781859110912 node=win
      metric disk_free_limit_bytes 50000000 node=win
      metric alarm_memory 0 node=win
      metric alarm_disk 0 node=win
      metric fds_used 0 node=win
      metric fds_max 65536 node=win
      metric fd_pct 0.00 node=win
      metric erlang_processes 490 node=win

    Reading the results (starting points: tune them to the node):
      Healthy  up 1; every alarm 0; memory_pct below 60; disk_free_bytes far
               above disk_free_limit_bytes; fd_pct below 70;
               unreachable_peers 0.
      Watch    memory_pct above 80: near the watermark; disk_free_bytes
               under twice its limit; fd_pct above 80; connections or
               channels climbing without falling back: a client leaking them.
      Act      up 0; alarm_memory or alarm_disk 1: every publisher in the
               cluster is blocked until it clears; alarm_fds 1: no new
               connection is accepted; unreachable_peers above 0: a node is
               down or cut off (a partition).

    Requires: bash, and the rabbitmq_prometheus plugin (on by default)
    Exit code: 0 on success, nodes up or down; 1 if a setting is wrong, or a page answers but is not RabbitMQ's
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$inv = [Globalization.CultureInfo]::InvariantCulture
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$targets = @(([string]$env:RABBITMQ_TARGETS) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Write-Output "metric nodes $($targets.Count)"
$code = 0

# Get-Page <url>: the page's lines; $null when nothing answers (a reading);
# 'error' when it answers wrong (a setting to fix), said on stderr.
function Get-Page([string]$url) {
    try { return @(([string](Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30).Content) -split "`n" | ForEach-Object { $_.TrimEnd("`r") }) }
    catch {
        if ($_.Exception.Response) { [Console]::Error.WriteLine("status: $url did not give a page: $($_.Exception.Message)"); return 'error' }
        return $null
    }
}
# A label's value in a Prometheus line, or ''.
function Label([string]$line, [string]$key) {
    if ($line -match ('[{,]' + $key + '="([^"]*)"')) { return $Matches[1] }
    return ''
}
# A tag's value: no spaces, quotes or control characters, never empty.
function Safe([string]$s) {
    $s = $s -replace '[^A-Za-z0-9@._:/+-]', '_'
    if (-not $s) { return 'none' }
    if ($s.Length -gt 120) { return $s.Substring(0, 120) }
    return $s
}
# The number as Vigil reads it.
function Num([double]$v, [string]$f = '0') { return $v.ToString($f, $inv) }
# Each target: name, address, and the page at $path, or why not.
function Read-Target([string]$entry, [string]$path) {
    $i = $entry.IndexOf('=')
    if ($i -lt 1 -or $i -eq $entry.Length - 1) {
        [Console]::Error.WriteLine("status: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692")
        exit 1
    }
    $name = $entry.Substring(0, $i).Trim() -replace '[^A-Za-z0-9@._:-]', '_'
    $url = $entry.Substring($i + 1).Trim().TrimEnd('/')
    $page = Get-Page ($url + $path)
    if ($null -eq $page) { Write-Output "metric up 0 node=$name"; return $null }
    if ($page -is [string] -and $page -eq 'error') { Write-Output "metric up 0 node=$name"; $script:code = 1; return $null }
    if (-not ($page | Where-Object { $_.StartsWith('rabbitmq_build_info') })) {
        Write-Output "metric up 0 node=$name"
        [Console]::Error.WriteLine("status: ${name}: $url$path answers, but is not RabbitMQ's Prometheus page")
        $script:code = 1
        return $null
    }
    Write-Output "metric up 1 node=$name"
    return @{ Name = $name; Url = $url; Page = $page }
}
# Sums by metric name (labels dropped), and which names were seen.
function Get-Sums($page) {
    $s = @{}
    foreach ($l in $page) {
        if (-not $l -or $l.StartsWith('#')) { continue }
        $p = $l -split '\s+'
        if ($p.Count -lt 2) { continue }
        $b = $p[0] -replace '\{.*$', ''
        $v = 0.0
        if (-not [double]::TryParse($p[1], [Globalization.NumberStyles]::Float, $inv, [ref]$v)) { continue }
        if ($s.ContainsKey($b)) { $s[$b] += $v } else { $s[$b] = $v }
    }
    return $s
}

foreach ($entry in $targets) {
    $t = Read-Target $entry '/metrics'
    # What it printed (up 1 or 0), then the node's page, if it gave one.
    $t | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
    $t = @($t | Where-Object { $_ -is [hashtable] })[0]
    if (-not $t) { continue }
    $tag = "node=$($t.Name)"
    $s = Get-Sums $t.Page
    $build = $t.Page | Where-Object { $_.StartsWith('rabbitmq_build_info{') } | Select-Object -First 1
    $id = $t.Page | Where-Object { $_.StartsWith('rabbitmq_identity_info{') } | Select-Object -First 1
    $rv = Safe (Label $build 'rabbitmq_version'); $ev = Safe (Label $build 'erlang_version')
    $nn = Safe (Label $id 'rabbitmq_node'); $cl = Safe (Label $id 'rabbitmq_cluster')
    Write-Output "metric version 1 $tag rabbitmq=$rv erlang=$ev rabbitmq_node=$nn cluster=$cl"
    function Out-M($m, $b) { if ($s.ContainsKey($b)) { Write-Output "metric $m $(Num $s[$b]) $tag" } }
    function Out-P($m, $a, $b) { if ($s.ContainsKey($a) -and $s.ContainsKey($b) -and $s[$b] -gt 0) { Write-Output "metric $m $(Num (100 * $s[$a] / $s[$b]) '0.00') $tag" } }
    Out-M memory_used_bytes rabbitmq_process_resident_memory_bytes
    Out-M memory_limit_bytes rabbitmq_resident_memory_limit_bytes
    Out-P memory_pct rabbitmq_process_resident_memory_bytes rabbitmq_resident_memory_limit_bytes
    Out-M disk_free_bytes rabbitmq_disk_space_available_bytes
    Out-M disk_free_limit_bytes rabbitmq_disk_space_available_limit_bytes
    Out-M alarm_memory rabbitmq_alarms_memory_used_watermark
    Out-M alarm_disk rabbitmq_alarms_free_disk_space_watermark
    Out-M alarm_fds rabbitmq_alarms_file_descriptor_limit
    Out-M fds_used rabbitmq_process_open_fds
    Out-M fds_max rabbitmq_process_max_fds
    Out-P fd_pct rabbitmq_process_open_fds rabbitmq_process_max_fds
    Out-M erlang_processes rabbitmq_erlang_processes_used
    Out-M erlang_processes_limit rabbitmq_erlang_processes_limit
    Out-P erlang_process_pct rabbitmq_erlang_processes_used rabbitmq_erlang_processes_limit
    Out-M run_queue rabbitmq_erlang_scheduler_run_queue
    Out-M uptime_seconds rabbitmq_erlang_uptime_seconds
    Out-M unreachable_peers rabbitmq_unreachable_cluster_peers_count
    Out-M connections rabbitmq_connections
    Out-M channels rabbitmq_channels
    Out-M consumers rabbitmq_consumers
    Out-M queues rabbitmq_queues
    Out-M publishers rabbitmq_global_publishers
}
exit $code
