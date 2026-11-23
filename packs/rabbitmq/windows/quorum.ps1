#Requires -Version 5.1

<#
.SYNOPSIS
    quorum.ps1 - each quorum queue's Raft log, on every node that holds it: leader changes, commit latency, how far behind each copy is
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads each node's detailed Prometheus page (rabbitmq_prometheus,
    /metrics/detailed, port 15692), from RABBITMQ_TARGETS
    (<name>=<address> separated by ;): the Raft figures of each quorum queue
    it holds a copy of, leader or follower, and of RabbitMQ's own metadata
    store (Khepri, tagged system=rabbit_khepri), whose majority the cluster
    needs to change anything. Past 100 on a node, those furthest behind,
    and the rest counted.

    Metrics:
      nodes              the nodes named in RABBITMQ_TARGETS
      up                 1 when the node's page answers, else 0, tagged
                         node=<its name>
      members            the quorum queues this node holds a copy of, and
                         its metadata store
      leaders            of those, the ones it leads
      term               the queue's Raft term: it rises at each election
                         of a new leader, tagged node=<its name>,
                         vhost=<its vhost>, queue=<its name> and
                         role=<leader or follower> (the metadata store:
                         system=rabbit_khepri)
      commit_latency_seconds  how long the last command took to commit
      commit_lag         log entries written here and not yet committed
      apply_lag          entries committed and not yet applied here
      segments           the log's segment files on disk
      members_not_shown  past 100, how many were left out

    Example output:
      metric nodes 1
      metric up 1 node=rabbit1

    Reading the results (starting points: tune them to the cluster):
      Healthy  term steady; commit_latency_seconds in milliseconds;
               commit_lag and apply_lag near 0; leaders spread over the
               nodes.
      Watch    term rising: leaders being elected again and again (a node
               restarting, or the network flapping); commit_latency_seconds
               climbing: the disks or the network are slow; every leader on
               one node: it takes all the work.
      Act      commit_lag or apply_lag growing on one copy: it is falling
               behind and may need a snapshot; members lower than the
               queues you expect here: a copy is gone (a node was removed).

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
        if ($_.Exception.Response) { [Console]::Error.WriteLine("quorum: $url did not give a page: $($_.Exception.Message)"); return 'error' }
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
        [Console]::Error.WriteLine("quorum: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692")
        exit 1
    }
    $name = $entry.Substring(0, $i).Trim() -replace '[^A-Za-z0-9@._:-]', '_'
    $url = $entry.Substring($i + 1).Trim().TrimEnd('/')
    $page = Get-Page ($url + $path)
    if ($null -eq $page) { Write-Output "metric up 0 node=$name"; return $null }
    if ($page -is [string] -and $page -eq 'error') { Write-Output "metric up 0 node=$name"; $script:code = 1; return $null }
    if (-not ($page | Where-Object { $_.StartsWith('rabbitmq_build_info') })) {
        Write-Output "metric up 0 node=$name"
        [Console]::Error.WriteLine("quorum: ${name}: $url$path answers, but is not RabbitMQ's Prometheus page")
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
    $t = Read-Target $entry '/metrics/detailed?family=ra_metrics&family=queue_metrics'
    if ($t -isnot [hashtable]) { $t | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }; continue }
    $tag = "node=$($t.Name)"
    $role = @{}; $q = @{}
    foreach ($l in $t.Page) {
        $p = $l -split '\s+'
        if ($l.StartsWith('rabbitmq_detailed_queue_info{')) {
            if ((Label $p[0] 'queue_type') -eq 'rabbit_quorum_queue') { $role[(Label $p[0] 'vhost') + "`t" + (Label $p[0] 'queue')] = Label $p[0] 'membership' }
            continue
        }
        if (-not $l.StartsWith('rabbitmq_detailed_raft_')) { continue }
        $base = ($p[0] -replace '\{.*$', '') -replace '^rabbitmq_detailed_raft_', ''
        # A queue, by its vhost and name; else one of RabbitMQ's own (its
        # metadata store, Khepri), by its module.
        $key = if (Label $p[0] 'queue') { (Label $p[0] 'vhost') + "`t" + (Label $p[0] 'queue') } else { "system`t" + (Label $p[0] 'module') }
        if (-not $q.ContainsKey($key)) { $q[$key] = @{} }
        $v = 0.0; [void][double]::TryParse($p[1], [Globalization.NumberStyles]::Float, $inv, [ref]$v)
        $q[$key][$base] = $v
    }
    # Of RabbitMQ's own Raft systems, the members (Khepri), not its log writers.
    $rows = @($q.GetEnumerator() | Where-Object { -not $_.Key.StartsWith("system`t") -or $_.Value.ContainsKey('term') } |
            Sort-Object { ([double]$_.Value['last_written_index'] - [double]$_.Value['last_applied']) } -Descending)
    $leaders = @($rows | Where-Object { $role[$_.Key] -eq 'leader' }).Count
    Write-Output "metric members $($rows.Count) $tag"
    Write-Output "metric leaders $leaders $tag"
    foreach ($r in ($rows | Select-Object -First 100)) {
        $k = $r.Key.Split("`t"); $v = $r.Value
        if ($k[0] -eq 'system') { $qt = "$tag system=$(Safe $k[1])" }
        else { $ro = if ($role[$r.Key]) { $role[$r.Key] } else { 'member' }; $qt = "$tag vhost=$(Safe $k[0]) queue=$(Safe $k[1]) role=$ro" }
        Write-Output "metric term $(Num ([double]$v['term'])) $qt"
        if ($v.ContainsKey('commit_latency_seconds')) { Write-Output "metric commit_latency_seconds $(Num $v['commit_latency_seconds'] '0.000000') $qt" }
        Write-Output "metric commit_lag $(Num ([Math]::Max(0, [double]$v['last_written_index'] - [double]$v['commit_index']))) $qt"
        Write-Output "metric apply_lag $(Num ([Math]::Max(0, [double]$v['commit_index'] - [double]$v['last_applied']))) $qt"
        if ($v.ContainsKey('num_segments')) { Write-Output "metric segments $(Num $v['num_segments']) $qt" }
    }
    Write-Output "metric members_not_shown $([Math]::Max(0, $rows.Count - 100)) $tag"
}
exit $code
