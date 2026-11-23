#Requires -Version 5.1

<#
.SYNOPSIS
    storage.ps1 - each RabbitMQ node's disk work: reads, writes, syncs and the time they took; its message store, queue index and metadata store
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads each node's Prometheus page (rabbitmq_prometheus, port 15692), from RABBITMQ_TARGETS
    (<name>=<address> separated by ;): its file
    I/O since it started, as running totals: graph them as rates, and the
    time per operation as the time's rate over the operations' rate.
    RabbitMQ 3.x counts them; 4.0 and later no longer do (their file handle
    cache is gone) and give 0 for each: there, this job says counted 0 and
    reports none of them, rather than zeros that look like an idle disk.

    Metrics:
      nodes                     the nodes named in RABBITMQ_TARGETS
      up                        1 when the node's page answers, else 0,
                                tagged node=<its name>
      counted                   1 when the node counts its file I/O
                                (RabbitMQ 3.x), 0 when it does not (4.0 on)
      read_ops_count            file reads
      read_bytes                bytes read
      read_seconds              time spent reading
      write_ops_count           file writes
      write_bytes               bytes written
      write_seconds             time spent writing
      sync_ops_count            fsyncs: each makes a write durable
      sync_seconds              time spent in them
      seek_ops_count            seeks
      seek_seconds              time spent seeking
      reopen_ops_count          files reopened (too few file handles kept)
      msg_store_reads_count     reads from the message store (classic
                                queues' message bodies)
      msg_store_writes_count    writes to it
      queue_index_reads_count   reads of classic queues' indexes
      queue_index_writes_count  writes to them
      metadata_disk_tx_count    metadata store transactions on disk
      metadata_ram_tx_count     metadata store transactions in memory

    Example output:
      metric nodes 1
      metric up 1 node=rabbit1

    Reading the results (starting points: tune them to the node):
      Healthy  sync_seconds and write_seconds rising slowly against their
               operations: milliseconds each.
      Watch    time per sync (sync_seconds over sync_ops_count, as rates)
               above 10 ms: the disk is slow for quorum queues and
               confirms; reopen_ops_count rising: too few file handles.
      Act      time per sync above 100 ms, or writes stalling while
               messages arrive: publishers wait for confirms, and memory
               grows (rabbitmq_status memory_pct).

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
        if ($_.Exception.Response) { [Console]::Error.WriteLine("storage: $url did not give a page: $($_.Exception.Message)"); return 'error' }
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
        [Console]::Error.WriteLine("storage: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692")
        exit 1
    }
    $name = $entry.Substring(0, $i).Trim() -replace '[^A-Za-z0-9@._:-]', '_'
    $url = $entry.Substring($i + 1).Trim().TrimEnd('/')
    $page = Get-Page ($url + $path)
    if ($null -eq $page) { Write-Output "metric up 0 node=$name"; return $null }
    if ($page -is [string] -and $page -eq 'error') { Write-Output "metric up 0 node=$name"; $script:code = 1; return $null }
    if (-not ($page | Where-Object { $_.StartsWith('rabbitmq_build_info') })) {
        Write-Output "metric up 0 node=$name"
        [Console]::Error.WriteLine("storage: ${name}: $url$path answers, but is not RabbitMQ's Prometheus page")
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

$io = @(
    @('read_ops_count', 'rabbitmq_io_read_ops_total', '0'), @('read_bytes', 'rabbitmq_io_read_bytes_total', '0'),
    @('read_seconds', 'rabbitmq_io_read_time_seconds_total', '0.000'),
    @('write_ops_count', 'rabbitmq_io_write_ops_total', '0'), @('write_bytes', 'rabbitmq_io_write_bytes_total', '0'),
    @('write_seconds', 'rabbitmq_io_write_time_seconds_total', '0.000'),
    @('sync_ops_count', 'rabbitmq_io_sync_ops_total', '0'), @('sync_seconds', 'rabbitmq_io_sync_time_seconds_total', '0.000'),
    @('seek_ops_count', 'rabbitmq_io_seek_ops_total', '0'), @('seek_seconds', 'rabbitmq_io_seek_time_seconds_total', '0.000'),
    @('reopen_ops_count', 'rabbitmq_io_reopen_ops_total', '0'),
    @('msg_store_reads_count', 'rabbitmq_msg_store_read_total', '0'), @('msg_store_writes_count', 'rabbitmq_msg_store_write_total', '0'),
    @('queue_index_reads_count', 'rabbitmq_queue_index_read_ops_total', '0'), @('queue_index_writes_count', 'rabbitmq_queue_index_write_ops_total', '0'),
    @('metadata_disk_tx_count', 'rabbitmq_schema_db_disk_tx_total', '0'), @('metadata_ram_tx_count', 'rabbitmq_schema_db_ram_tx_total', '0'))
foreach ($entry in $targets) {
    $t = Read-Target $entry '/metrics'
    if ($t -isnot [hashtable]) { $t | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }; continue }
    $tag = "node=$($t.Name)"
    $build = $t.Page | Where-Object { $_.StartsWith('rabbitmq_build_info{') } | Select-Object -First 1
    $major = 0
    if ((Label $build 'rabbitmq_version') -match '^(\d+)') { $major = [int]$Matches[1] }
    # 4.0 on: none of these is counted (each is 0).
    if ($major -ge 4) { Write-Output "metric counted 0 $tag"; continue }
    Write-Output "metric counted 1 $tag"
    $s = Get-Sums $t.Page
    foreach ($m in $io) { if ($s.ContainsKey($m[1])) { Write-Output "metric $($m[0]) $(Num $s[$m[1]] $m[2]) $tag" } }
}
exit $code
