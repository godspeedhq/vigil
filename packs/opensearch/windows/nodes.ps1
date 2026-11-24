#Requires -Version 5.1

<#
.SYNOPSIS
    nodes.ps1 - each node of a cluster, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the cluster's nodes, by role and version, and each node as
    OpenSearch sees it: its version and roles, whether it is the elected cluster
    manager, its CPU and load, memory, open files against the limit, its data
    disk, HTTP and transport connections and traffic, and indexing pressure: the
    memory held by writes in flight against the limit, and the writes refused
    for it. Never its JVM's heap or garbage collection: those are the jvm
    pack's. It only reads: it changes nothing in the cluster.

    Reads OpenSearch at OPENSEARCH_URL (default https://localhost:9200), as
    OPENSEARCH_USER with the password in OPENSEARCH_PASSWORD (a secret). The
    login goes in a header made here, never on a command line.
    It speaks HTTP itself, with .NET: nothing to install. Over https, the
    certificate is checked against Windows' trusted CAs, or OPENSEARCH_CACERT, a
    CA file, and against the server's name. What the scripts share is in
    _opensearch.ps1, beside this one.

    Metrics:
      up                             1 when OpenSearch answers, else 0
      nodes                          nodes in the cluster
      master_eligible                of those, nodes that may be elected cluster
                                     manager
      data_nodes                     nodes that hold data
      ingest_nodes                   nodes that run ingest pipelines
      coordinating_only              nodes with no role: they only route
                                     requests
      versions                       OpenSearch versions among the nodes: more
                                     than 1 during an upgrade, or one left
                                     behind
      info                           always 1, tagged node=<its name>,
                                     version=<its version> and roles=<its roles,
                                     as _cat/nodes abbreviates them>
      cluster_manager                1 when the node is the elected cluster
                                     manager, tagged node=<its name>
      cpu_pct                        the CPU in use on the node's machine (or
                                     container), tagged the same
      load_1m                        its load average over a minute, tagged the
                                     same (not on Windows)
      load_5m                        over 5 minutes
      load_15m                       over 15 minutes
      mem_used_pct                   the machine's (or container's) memory in
                                     use
      process_cpu_pct                the CPU OpenSearch's process uses
      open_fds                       files it has open
      max_fds                        files it may have open
      fds_pct                        open_fds, as a percentage of max_fds
      disk_total_bytes               the size of the node's data disks
      disk_free_bytes                of that, free for OpenSearch
      disk_used_pct                  the data disks in use
      http_open                      HTTP connections open
      http_opened                    HTTP connections opened since it started (a
                                     counter)
      transport_open                 connections open to the other nodes
      transport_rx_bytes             bytes received from the other nodes (a
                                     counter)
      transport_tx_bytes             bytes sent to them (a counter)
      indexing_pressure_bytes        memory held by writes in flight on the node
      indexing_pressure_limit_bytes  the most it may hold
      indexing_pressure_pct          indexing_pressure_bytes, as a percentage of
                                     the limit
      indexing_rejections            writes refused for it, since the node
                                     started (a counter)
      nodes_not_shown                nodes past the first 100, by name, left out

    Example output (the rest are in the same form):
      metric up 1
      metric nodes 3
      metric versions 1
      metric info 1 node=os310a version=3.10.0 roles=dimr
      metric cluster_manager 0 node=os310a

    Reading the results (starting points: tune them to the cluster):
      Healthy  nodes as many as you run; versions 1; fds_pct and disk_used_pct
               well below 80; indexing_rejections flat.
      Watch    cpu_pct high on one node only: a hot shard; fds_pct above 80;
               disk_used_pct nearing the disk watermarks (the allocation job);
               indexing_pressure_pct above 50.
      Act      nodes below what you run: a node left; versions above 1 when no
               upgrade runs; indexing_rejections rising: writes refused, clients
               see HTTP 429.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, OpenSearch up or down; 1 if a setting is wrong, the
      login is refused, this user may not read what the job needs, or the
      address is not OpenSearch
#>

$Job = 'nodes'
. (Join-Path $PSScriptRoot '_opensearch.ps1')

Read-First
$cat = @(Need-Page '/_cat/nodes?format=json&full_id=true&h=id,name,version,node.role,cluster_manager')
$c = @{}
foreach ($k in $cat) { $c[[string]$k.id] = $k }
$s = Need-Page '/_nodes/stats/os,process,fs,http,transport,indexing_pressure?filter_path=nodes.*.name,nodes.*.roles,nodes.*.os.cpu.percent,nodes.*.os.cpu.load_average,nodes.*.os.mem.used_percent,nodes.*.process.cpu.percent,nodes.*.process.open_file_descriptors,nodes.*.process.max_file_descriptors,nodes.*.fs.total,nodes.*.http.current_open,nodes.*.http.total_opened,nodes.*.transport.server_open,nodes.*.transport.rx_size_in_bytes,nodes.*.transport.tx_size_in_bytes,nodes.*.indexing_pressure.memory'
$all = @(Props $s.nodes | ForEach-Object { $v = $_.Value; $v | Add-Member -NotePropertyName id -NotePropertyValue $_.Name -Force; $v } | Sort-Object { [string]$_.name })
M 'nodes' $all.Count
M 'master_eligible' (@($all | Where-Object { @($_.roles) -contains 'master' -or @($_.roles) -contains 'cluster_manager' }).Count)
M 'data_nodes' (@($all | Where-Object { @(@($_.roles) | Where-Object { "$_" -like 'data*' }).Count -gt 0 }).Count)
M 'ingest_nodes' (@($all | Where-Object { @($_.roles) -contains 'ingest' }).Count)
M 'coordinating_only' (@($all | Where-Object { @($_.roles).Count -eq 0 }).Count)
M 'versions' (@($cat | ForEach-Object { [string]$_.version } | Sort-Object -Unique).Count)
foreach ($x in @($all | Select-Object -First 100)) {
    $t = "node=$(Safe $x.name)"
    $k = $c[[string]$x.id]
    Write-Output "metric info 1 $t version=$(Safe $k.version) roles=$(Safe $k.'node.role')"
    M 'cluster_manager' $(if ($k -and $k.cluster_manager -eq '*') { 1 } else { 0 }) $t
    M 'cpu_pct' $x.os.cpu.percent $t
    if ($x.os.cpu.load_average) {
        M 'load_1m' $x.os.cpu.load_average.'1m' $t
        M 'load_5m' $x.os.cpu.load_average.'5m' $t
        M 'load_15m' $x.os.cpu.load_average.'15m' $t
    }
    M 'mem_used_pct' $x.os.mem.used_percent $t
    M 'process_cpu_pct' $x.process.cpu.percent $t
    M 'open_fds' $x.process.open_file_descriptors $t
    M 'max_fds' $x.process.max_file_descriptors $t
    M 'fds_pct' (Pct $x.process.open_file_descriptors $x.process.max_file_descriptors) $t
    M 'disk_total_bytes' $x.fs.total.total_in_bytes $t
    M 'disk_free_bytes' $x.fs.total.available_in_bytes $t
    M 'disk_used_pct' (Pct ((N $x.fs.total.total_in_bytes) - (N $x.fs.total.available_in_bytes)) $x.fs.total.total_in_bytes) $t
    M 'http_open' $x.http.current_open $t
    M 'http_opened' $x.http.total_opened $t
    M 'transport_open' $x.transport.server_open $t
    M 'transport_rx_bytes' $x.transport.rx_size_in_bytes $t
    M 'transport_tx_bytes' $x.transport.tx_size_in_bytes $t
    $ip = $x.indexing_pressure.memory
    if ($ip) {
        $b = (N $ip.current.combined_coordinating_and_primary_in_bytes) + (N $ip.current.replica_in_bytes)
        M 'indexing_pressure_bytes' $b $t
        M 'indexing_pressure_limit_bytes' $ip.limit_in_bytes $t
        M 'indexing_pressure_pct' (Pct $b $ip.limit_in_bytes) $t
        M 'indexing_rejections' ((N $ip.total.coordinating_rejections) + (N $ip.total.primary_rejections) + (N $ip.total.replica_rejections)) $t
    }
}
M 'nodes_not_shown' ([Math]::Max($all.Count - 100, 0))
exit 0
