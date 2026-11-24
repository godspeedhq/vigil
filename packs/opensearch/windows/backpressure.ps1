#Requires -Version 5.1

<#
.SYNOPSIS
    backpressure.ps1 - OpenSearch's backpressure and admission control, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports what OpenSearch does on each node to protect itself under load:
    search backpressure (its mode, and the searches and shard searches it
    cancelled for CPU, time or heap), shard indexing pressure (whether it is on
    and enforced, and the writes it refused), and admission control (the
    requests it refused for the node's CPU, I/O or memory), each tagged by node.
    It only reads: it changes nothing in the cluster.

    Reads OpenSearch at OPENSEARCH_URL (default https://localhost:9200), as
    OPENSEARCH_USER with the password in OPENSEARCH_PASSWORD (a secret). The
    login goes in a header made here, never on a command line.
    It speaks HTTP itself, with .NET: nothing to install. Over https, the
    certificate is checked against Windows' trusted CAs, or OPENSEARCH_CACERT, a
    CA file, and against the server's name. What the scripts share is in
    _opensearch.ps1, beside this one.

    Metrics:
      up                         1 when OpenSearch answers, else 0
      search_mode                search backpressure: 0 disabled, 1 monitor
                                 only, 2 enforced; tagged node=<its name> and
                                 mode=<it>
      search_cancellations       searches it cancelled, every kind (a counter),
                                 tagged node
      search_limit_reached       times it would have cancelled but reached its
                                 limit (a counter), tagged node
      search_cancelled_for       shard searches cancelled for one reason (a
                                 counter), tagged node and reason=<cpu_usage,
                                 elapsed_time or heap_usage>
      shard_indexing_enabled     1 when shard indexing pressure is on, tagged
                                 node
      shard_indexing_enforced    1 when it is enforced, not only counted, tagged
                                 node
      shard_indexing_rejections  writes it refused (or, not enforced, would
                                 have), tagged node and limit=<which>
      admission_rejections       requests admission control refused (a counter),
                                 tagged node, controller=<cpu, io or native
                                 memory> and action=<indexing or search>
      nodes_not_shown            nodes past the first 100, by name, left out

    Example output (the rest are in the same form):
      metric up 1
      metric search_mode 1 node=os310a mode=monitor_only
      metric search_cancellations 0 node=os310a
      metric search_cancelled_for 0 node=os310a reason=cpu_usage
      metric search_cancelled_for 0 node=os310a reason=heap_usage
      metric shard_indexing_enabled 0 node=os310a
      metric shard_indexing_enforced 0 node=os310a

    Reading the results (starting points: tune them to the cluster):
      Healthy  search_cancellations and admission_rejections flat.
      Watch    search_cancellations rising in monitor-only mode: enforced, those
               searches would fail; shard_indexing_rejections rising while not
               enforced.
      Act      search_cancellations rising in enforced mode: searches fail;
               admission_rejections rising: the node refuses requests for its
               CPU or I/O.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, OpenSearch up or down; 1 if a setting is wrong, the
      login is refused, this user may not read what the job needs, or the
      address is not OpenSearch
#>

$Job = 'backpressure'
. (Join-Path $PSScriptRoot '_opensearch.ps1')

Read-First
$s = Need-Page '/_nodes/stats/search_backpressure,shard_indexing_pressure,admission_control?filter_path=nodes.*.name,nodes.*.search_backpressure.mode,nodes.*.search_backpressure.search_task.cancellation_stats,nodes.*.search_backpressure.search_shard_task.cancellation_stats,nodes.*.search_backpressure.search_shard_task.resource_tracker_stats.*.cancellation_count,nodes.*.shard_indexing_pressure.enabled,nodes.*.shard_indexing_pressure.enforced,nodes.*.shard_indexing_pressure.total_rejections_breakup,nodes.*.shard_indexing_pressure.total_rejections_breakup_shadow_mode,nodes.*.admission_control'
$all = @(Values $s.nodes | Sort-Object { [string]$_.name })
$modes = @{ 'disabled' = 0; 'monitor_only' = 1; 'enforced' = 2 }
foreach ($x in @($all | Select-Object -First 100)) {
    $t = "node=$(Safe $x.name)"
    $sb = $x.search_backpressure
    if ($sb) {
        $m = if ($modes.ContainsKey([string]$sb.mode)) { $modes[[string]$sb.mode] } else { 0 }
        M 'search_mode' $m "$t mode=$(Safe $sb.mode)"
        M 'search_cancellations' ((N $sb.search_task.cancellation_stats.cancellation_count) + (N $sb.search_shard_task.cancellation_stats.cancellation_count)) $t
        M 'search_limit_reached' ((N $sb.search_task.cancellation_stats.cancellation_limit_reached_count) + (N $sb.search_shard_task.cancellation_stats.cancellation_limit_reached_count)) $t
        foreach ($r in @(Props $sb.search_shard_task.resource_tracker_stats | Sort-Object Name)) {
            if ($null -ne $r.Value -and $null -ne $r.Value.cancellation_count) { M 'search_cancelled_for' $r.Value.cancellation_count "$t reason=$(Safe ($r.Name -replace '_tracker$', ''))" }
        }
    }
    $sip = $x.shard_indexing_pressure
    if ($sip) {
        M 'shard_indexing_enabled' $sip.enabled $t
        M 'shard_indexing_enforced' $sip.enforced $t
        $br = if ($sip.enforced) { $sip.total_rejections_breakup } else { $sip.total_rejections_breakup_shadow_mode }
        foreach ($r in @(Props $br | Sort-Object Name)) { M 'shard_indexing_rejections' $r.Value "$t limit=$(Safe $r.Name)" }
    }
    foreach ($c in @(Props $x.admission_control | Sort-Object Name)) {
        $cn = Safe (($c.Name -replace '^global_', '') -replace '_usage$', '')
        foreach ($r in @(Props $c.Value.transport.rejection_count | Sort-Object Name)) { M 'admission_rejections' $r.Value "$t controller=$cn action=$(Safe $r.Name)" }
    }
}
M 'nodes_not_shown' ([Math]::Max($all.Count - 100, 0))
exit 0
