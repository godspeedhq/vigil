#Requires -Version 5.1

<#
.SYNOPSIS
    memory.ps1 - what each RabbitMQ node's memory is used for: connections, channels, queues of each type, the metadata store, binaries, the rest
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads each node's memory breakdown (rabbitmq_prometheus,
    /metrics/memory-breakdown, port 15692), from RABBITMQ_TARGETS
    (<name>=<address> separated by ;): RabbitMQ's own account of its memory,
    by what holds it. rabbitmq_status memory_pct says how near the watermark
    it is; this says why.

    Metrics:
      nodes                     the nodes named in RABBITMQ_TARGETS
      up                        1 when the node's page answers, else 0,
                                tagged node=<its name>
      connection_readers_bytes  connections' readers (one per connection)
      connection_writers_bytes  connections' writers
      channels_bytes            channels
      connection_other_bytes    other connection processes
      classic_queues_bytes      classic queues' processes
      quorum_queues_bytes       quorum queues' processes
      quorum_queues_dlx_bytes   quorum queues' dead lettering
      quorum_ets_bytes          quorum queues' tables
      streams_bytes             streams' processes, readers and coordinator
      binaries_bytes            binaries: message bodies, mostly
      message_index_bytes       the message store's index
      metadata_store_bytes      the metadata store (Khepri, or Mnesia)
      metrics_bytes             RabbitMQ's own metrics
      management_bytes          the management plugin's statistics
      plugins_bytes             plugins
      code_bytes                loaded code
      atoms_bytes               the atom table
      other_processes_bytes     other Erlang processes
      other_tables_bytes        other ETS tables
      other_system_bytes        other system memory
      allocated_unused_bytes    allocated by the runtime, not in use
      reserved_unallocated_bytes  reserved by the runtime, not allocated

    Example output:
      metric nodes 1
      metric up 1 node=rabbit1

    Reading the results (starting points: tune them to the node):
      Healthy  binaries_bytes and the queues' bytes rising and falling with
               the messages held; the rest steady.
      Watch    binaries_bytes climbing while queues are short: a consumer
               holding messages unacknowledged; connection_readers_bytes
               and channels_bytes climbing: clients leaking connections or
               channels; management_bytes large: the management plugin's
               statistics, on a busy node.
      Act      one part climbing toward rabbitmq_status memory_limit_bytes:
               that is what will set off the memory alarm, which blocks
               every publisher.

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
        if ($_.Exception.Response) { [Console]::Error.WriteLine("memory: $url did not give a page: $($_.Exception.Message)"); return 'error' }
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
        [Console]::Error.WriteLine("memory: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692")
        exit 1
    }
    $name = $entry.Substring(0, $i).Trim() -replace '[^A-Za-z0-9@._:-]', '_'
    $url = $entry.Substring($i + 1).Trim().TrimEnd('/')
    $page = Get-Page ($url + $path)
    if ($null -eq $page) { Write-Output "metric up 0 node=$name"; return $null }
    if ($page -is [string] -and $page -eq 'error') { Write-Output "metric up 0 node=$name"; $script:code = 1; return $null }
    if (-not ($page | Where-Object { $_.StartsWith('rabbitmq_build_info') })) {
        Write-Output "metric up 0 node=$name"
        [Console]::Error.WriteLine("memory: ${name}: $url$path answers, but is not RabbitMQ's Prometheus page")
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

$parts = @(
    @('connection_readers_bytes', 'rabbitmq_memory_client_connection_reader_bytes'),
    @('connection_writers_bytes', 'rabbitmq_memory_client_connection_writer_bytes'),
    @('channels_bytes', 'rabbitmq_memory_client_connection_channel_bytes'),
    @('connection_other_bytes', 'rabbitmq_memory_client_connection_other_bytes'),
    @('classic_queues_bytes', 'rabbitmq_memory_classic_queue_erlang_process_bytes'),
    @('quorum_queues_bytes', 'rabbitmq_memory_quorum_queue_erlang_process_bytes'),
    @('quorum_queues_dlx_bytes', 'rabbitmq_memory_quorum_queue_dlx_erlang_process_bytes'),
    @('quorum_ets_bytes', 'rabbitmq_memory_quorum_queue_ets_table_bytes'),
    @('streams_bytes', 'rabbitmq_memory_stream_erlang_process_bytes', 'rabbitmq_memory_stream_replica_reader_erlang_process_bytes', 'rabbitmq_memory_stream_coordinator_erlang_process_bytes'),
    @('binaries_bytes', 'rabbitmq_memory_binary_heap_bytes'),
    @('message_index_bytes', 'rabbitmq_memory_message_index_bytes'),
    @('metadata_store_bytes', 'rabbitmq_memory_modern_metadata_store_bytes', 'rabbitmq_memory_modern_metadata_store_ets_table_bytes', 'rabbitmq_memory_classic_metadata_store_bytes'),
    @('metrics_bytes', 'rabbitmq_memory_metrics_bytes'),
    @('management_bytes', 'rabbitmq_memory_management_stats_db_bytes'),
    @('plugins_bytes', 'rabbitmq_memory_plugin_bytes'),
    @('code_bytes', 'rabbitmq_memory_code_module_bytes'),
    @('atoms_bytes', 'rabbitmq_memory_atom_table_bytes'),
    @('other_processes_bytes', 'rabbitmq_memory_other_erlang_process_bytes'),
    @('other_tables_bytes', 'rabbitmq_memory_other_ets_table_bytes'),
    @('other_system_bytes', 'rabbitmq_memory_other_system_bytes'),
    @('allocated_unused_bytes', 'rabbitmq_memory_runtime_allocated_unused_bytes'),
    @('reserved_unallocated_bytes', 'rabbitmq_memory_runtime_reserved_unallocated_bytes'))
foreach ($entry in $targets) {
    $t = Read-Target $entry '/metrics/memory-breakdown'
    if ($t -isnot [hashtable]) { $t | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }; continue }
    $tag = "node=$($t.Name)"
    $s = Get-Sums $t.Page
    foreach ($part in $parts) {
        $found = $false; $sum = 0.0
        foreach ($b in $part[1..($part.Count - 1)]) { if ($s.ContainsKey($b)) { $found = $true; $sum += $s[$b] } }
        if ($found) { Write-Output "metric $($part[0]) $(Num $sum) $tag" }
    }
}
exit $code
