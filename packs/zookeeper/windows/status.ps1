#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - ZooKeeper servers: up and serving, leader and followers in sync, latency, outstanding requests, znodes and watches, fsync and JVM pauses, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each ZooKeeper server in ZOOKEEPER_SERVERS (default
    localhost:2181), each tagged server=<host:port>: whether it answers, and
    whether it serves (a server cut off from its quorum answers, and serves
    nothing); its version and role (leader, follower, observer, standalone);
    read-only mode; latency; connections and requests waiting; znodes,
    watches, ephemeral nodes and the data they hold; file descriptors; the
    longest fsync and JVM pause; elections, failed logins, requests
    throttled and errors; and on the leader, its followers and how many are
    in sync. Then the ensemble as this machine sees it: servers up, serving,
    and how many are leader (one, and only one, when all is well). Name
    every server of an ensemble on one machine, or each its own on each.

    Reads ZooKeeper's four-letter words on its client port: ruok, mntr and
    isro, each over a connection of its own, with PowerShell alone.
    ZooKeeper answers only the words in its whitelist, which since 3.5.3 is
    srvr alone: the servers need 4lw.commands.whitelist=mntr,ruok,isro (or
    *) in zoo.cfg. The words are plain text on the client port: a port that
    takes TLS alone (secureClientPort) cannot be read this way.

    Metrics:
      servers                    servers named in ZOOKEEPER_SERVERS
      servers_up                 of those, answering
      servers_serving            of those, serving requests
      leaders                    of those, leader: 1 for an ensemble
                                 (standalone servers are not counted)
      up                         1 when the server answers ruok, else 0
      serving                    1 when it serves requests (it answered
                                 mntr), else 0: it has no quorum
      info                       always 1, tagged version=<3.9.7>
                                 role=<leader, follower, observer,
                                 standalone, readonly>
      readonly                   1 in read-only mode (cut off from its
                                 quorum, with readonlymode.enabled): it
                                 serves reads, and refuses writes
      uptime_seconds             since it started
      latency_avg_ms             time to answer a request, on average
      latency_max_ms             the longest (since it started, or since
                                 srst)
      connections                clients connected
      outstanding_requests       requests waiting to be processed
      znodes                     znodes in its tree
      watches                    watches set by clients
      ephemerals                 ephemeral znodes (each held by a session)
      data_bytes                 the data its znodes hold, approximately
      fds_open                   file descriptors open
      fds_pct                    fds_open, of the most it may open
      fsync_max_ms               the longest write to its transaction log
                                 took (since it started)
      jvm_pause_max_ms           the longest the JVM stopped it (garbage
                                 collection, since it started)
      packets_received_count     packets received (a running total)
      packets_sent_count         packets sent (a running total)
      elections_count            times it looked for a leader (a running
                                 total)
      auth_failed_count          logins refused (a running total)
      throttled_count            requests throttled (a running total)
      errors_count               errors it could not recover from (a
                                 running total)
      quorum_size                servers of the ensemble that vote
      followers                  on the leader: followers and observers
                                 connected
      followers_synced           on the leader: followers in sync
      pending_syncs              on the leader: followers still syncing

    Example output (the rest are in the same form):
      metric servers 3
      metric servers_serving 3
      metric leaders 1
      metric up 1 server=zk1:2181
      metric info 1 server=zk1:2181 version=3.9.7 role=leader
      metric latency_avg_ms 0.4 server=zk1:2181
      metric followers_synced 2 server=zk1:2181

    Reading the results (starting points: tune them to the ensemble):
      Healthy  servers_serving equal to servers; leaders 1; on the leader,
               followers_synced the quorum less one; latency_avg_ms below 10;
               outstanding_requests near 0; fds_pct below 50.
      Watch    latency_avg_ms past 50; outstanding_requests above 10 for
               several runs; fsync_max_ms past 1000 (a slow disk: sessions
               time out); jvm_pause_max_ms past 1000; elections_count rising;
               watches or znodes growing without end; fds_pct past 70.
      Act      up 0; serving 0 (no quorum: clients of this server get
               nothing); leaders 0 or above 1; readonly 1 (writes refused);
               followers_synced below a majority; auth_failed_count rising.

    Requires: PowerShell 5.1 or later
    Exit code: 0 on success, servers up or down; 1 when a server refuses a
      four-letter word (not in its whitelist), or ZOOKEEPER_SERVERS is wrong

    Example (vigil.config):
      [job.zookeeper_status]
      file        = packs/zookeeper/status.ps1
      metric_name = zookeeper
      run_every   = 1m
      env         = ZOOKEEPER_SERVERS=zk1:2181; zk2:2181; zk3:2181
#>

$ErrorActionPreference = 'Stop'

$list = @(([string]$env:ZOOKEEPER_SERVERS) -split '[\s;,]+' | Where-Object { $_ })
if ($list.Count -eq 0) { $list = @('localhost:2181') }

# Word <host> <port> <word>: its answer, or $null when nothing answers
# within 5 seconds.
function Word([string]$h, [int]$port, [string]$w) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.ConnectAsync($h, $port)
        if (-not $connect.Wait(5000) -or -not $client.Connected) { return $null }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $b = [System.Text.Encoding]::ASCII.GetBytes($w)
        $stream.Write($b, 0, $b.Length)
        $buffer = New-Object System.IO.MemoryStream
        $chunk = New-Object byte[] 8192
        while (($n = $stream.Read($chunk, 0, $chunk.Length)) -gt 0) { $buffer.Write($chunk, 0, $n) }
        [System.Text.Encoding]::UTF8.GetString($buffer.ToArray())
    }
    catch { $null }
    finally { $client.Close() }
}
function Refused([string]$a) { $a -match 'is not executed because it is not in the whitelist' }
# Two decimals at most, written with a dot.
function R2([double]$x) { [Math]::Round($x, 2).ToString([System.Globalization.CultureInfo]::InvariantCulture) }

$n = 0; $upN = 0; $servingN = 0; $leaders = 0; $failed = @()
foreach ($s in $list) {
    if ($s -match '^\[(.+)\]:(\d+)$') { $hostName = $Matches[1]; $port = $Matches[2] }
    elseif ($s -match ':.*:') { $hostName = $s; $port = '2181' }
    elseif ($s -match '^([^:]+):(.*)$') { $hostName = $Matches[1]; $port = $Matches[2] }
    else { $hostName = $s; $port = '2181' }
    if ($port -notmatch '^\d+$') { [Console]::Error.WriteLine("status: ZOOKEEPER_SERVERS: '$s' is not host or host:port"); exit 1 }
    $n++
    $t = "server=${hostName}:$port"
    $a = Word $hostName ([int]$port) 'ruok'
    if ($null -eq $a) { Write-Output "metric up 0 $t"; Write-Output "metric serving 0 $t"; continue }
    $no = @()
    if (Refused $a) { $no += 'ruok' }
    elseif ($a -ne 'imok') { Write-Output "metric up 0 $t"; Write-Output "metric serving 0 $t"; continue }
    $upN++
    Write-Output "metric up 1 $t"
    $m = Word $hostName ([int]$port) 'mntr'
    if ($null -ne $m -and (Refused $m)) { $no += 'mntr' }
    if ($no.Count -gt 0) { $failed += "${hostName}:$port refuses $($no -join ', ')" }
    if ($null -eq $m -or (Refused $m)) { Write-Output "metric serving 0 $t"; continue }
    if ($m -notmatch '(?m)^zk_server_state') { Write-Output "metric serving 0 $t"; continue }
    $servingN++
    Write-Output "metric serving 1 $t"
    $ro = ''
    $i = Word $hostName ([int]$port) 'isro'
    if ($null -ne $i -and -not (Refused $i)) { $ro = $i.Trim() }
    $v = @{}
    foreach ($line in ($m -split "`n")) {
        $f = $line.TrimEnd("`r") -split "`t", 2
        if ($f.Count -eq 2) { $v[$f[0]] = $f[1] }
    }
    function Num($key) { $x = 0.0; if ($v.ContainsKey($key) -and [double]::TryParse($v[$key], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { $x } else { 0.0 } }
    function Out($name, $key, $scale) { if ($v.ContainsKey($key)) { Write-Output "metric $name $(R2 ((Num $key) / $scale)) $t" } }
    $ver = ([string]$v['zk_version']) -replace '[-, ].*$', '' -replace '[^A-Za-z0-9._-]', '_'
    $role = ([string]$v['zk_server_state']) -replace '[^A-Za-z]', ''
    if ($role -eq 'leader') { $leaders++ }
    Write-Output "metric info 1 $t version=$(if ($ver) { $ver } else { 'unknown' }) role=$(if ($role) { $role } else { 'unknown' })"
    if ($ro -eq 'ro') { Write-Output "metric readonly 1 $t" } elseif ($ro -eq 'rw') { Write-Output "metric readonly 0 $t" }
    Out 'uptime_seconds' 'zk_uptime' 1000
    Out 'latency_avg_ms' 'zk_avg_latency' 1
    Out 'latency_max_ms' 'zk_max_latency' 1
    Out 'connections' 'zk_num_alive_connections' 1
    Out 'outstanding_requests' 'zk_outstanding_requests' 1
    Out 'znodes' 'zk_znode_count' 1
    Out 'watches' 'zk_watch_count' 1
    Out 'ephemerals' 'zk_ephemerals_count' 1
    Out 'data_bytes' 'zk_approximate_data_size' 1
    Out 'fds_open' 'zk_open_file_descriptor_count' 1
    if ((Num 'zk_max_file_descriptor_count') -gt 0) { Write-Output "metric fds_pct $(R2 (100 * (Num 'zk_open_file_descriptor_count') / (Num 'zk_max_file_descriptor_count'))) $t" }
    Out 'fsync_max_ms' 'zk_max_fsynctime' 1
    Out 'jvm_pause_max_ms' 'zk_max_jvm_pause_time_ms' 1
    Out 'packets_received_count' 'zk_packets_received' 1
    Out 'packets_sent_count' 'zk_packets_sent' 1
    Out 'elections_count' 'zk_looking_count' 1
    Out 'auth_failed_count' 'zk_auth_failed_count' 1
    Out 'throttled_count' 'zk_throttled_ops' 1
    Out 'errors_count' 'zk_unrecoverable_error_count' 1
    Out 'quorum_size' 'zk_quorum_size' 1
    if ($role -eq 'leader') {
        Out 'followers' 'zk_learners' 1
        Out 'followers_synced' 'zk_synced_followers' 1
        Out 'pending_syncs' 'zk_pending_syncs' 1
    }
}
Write-Output "metric servers $n"
Write-Output "metric servers_up $upN"
Write-Output "metric servers_serving $servingN"
Write-Output "metric leaders $leaders"
if ($failed.Count -gt 0) {
    [Console]::Error.WriteLine("status: $($failed -join '; '): add the words to its whitelist in zoo.cfg, 4lw.commands.whitelist=mntr,ruok,isro, and restart it (packs/zookeeper/README.md)")
    exit 1
}
exit 0
