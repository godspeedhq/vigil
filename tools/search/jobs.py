# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The jobs of the elasticsearch and opensearch packs, for tools/search/gen.py:
what each reports, its metrics, how to read them, and its code for bash (with
jq) and for PowerShell. In the text and the code, @P@ is the product's name,
@p@ the pack's, @E@ the prefix of its settings, @M@ the elected node's metric
(master, or cluster_manager), @MW@ its name in words, @MCAT@ the _cat page
that names it. only='es' or 'os' marks a job of one pack alone."""

M = lambda *pairs: list(pairs)

JOBS = []


def job(**j):
    JOBS.append(j)


# ---------------------------------------------------------------- status
job(job='status', metric='', when='run_every   = 1m', runtime='50s',
    title="a cluster's health",
    what="Reports whether @P@ answers, its version, the cluster's health (green, yellow or red), its nodes, "
         "its shards (active, relocating, initializing, unassigned, and unassigned primaries), the cluster "
         "tasks waiting and for how long, and which node is the elected @MW@.",
    metrics=M(('up', '1 when @P@ answers, else 0'),
              ('version', 'always 1, tagged version=<its version> and cluster=<its name>'),
              ('status', "the cluster's health: 0 green, 1 yellow (a replica unassigned), 2 red (a primary "
                         "unassigned: data missing), 3 when there is no elected @MW@; tagged status=<it>"),
              ('timed_out', '1 when the health check timed out'),
              ('nodes', 'nodes in the cluster'),
              ('data_nodes', 'of those, nodes that hold data'),
              ('active_primary_shards', 'primary shards active'),
              ('active_shards', 'shards active, primaries and replicas'),
              ('active_shards_pct', 'shards active, as a percentage of all'),
              ('relocating_shards', 'shards moving between nodes'),
              ('initializing_shards', 'shards being created or recovered'),
              ('unassigned_shards', 'shards on no node'),
              ('unassigned_primary_shards', 'of those, primaries (when @P@ says)'),
              ('delayed_unassigned_shards', 'unassigned shards whose allocation waits, on purpose, for a node to come back'),
              ('pending_tasks', 'cluster tasks waiting for the @MW@'),
              ('task_max_wait_ms', 'how long the oldest of those has waited'),
              ('in_flight_fetch', 'shard information being fetched from the nodes'),
              ('@M@', '1 when a node is the elected @MW@, tagged node=<its name>; 0 when none is')),
    healthy="up 1; status 0; unassigned_shards 0; pending_tasks 0.",
    watch="status 1 for long: replicas unassigned, one node from losing data; relocating_shards or "
          "initializing_shards for long; task_max_wait_ms in seconds.",
    act="up 0; status 2: primaries unassigned, data unreachable (the shards job says which, and why); "
        "@M@ 0 or status 3: no elected @MW@, the cluster changes nothing.",
    sh=r'''first
jq -r "$jqlib"'"metric version 1 version=\(.version.number | tag) cluster=\(.cluster_name | tag)"' "$work/root" || exit 1
health='/_cluster/health?timeout=10s&master_timeout=10s'
get "$health"
rc=$?
case $rc in
    0) ;;
    5) echo "metric status 3 status=no_@MT@"; echo "metric @M@ 0"; exit 0 ;;
    *) why "$rc" "$health" ;;
esac
jq -r "$jqlib"'
    "metric status \(.status | code) status=\(.status | tag)",
    "metric timed_out \(.timed_out | n)",
    "metric nodes \(.number_of_nodes | n)",
    "metric data_nodes \(.number_of_data_nodes | n)",
    "metric active_primary_shards \(.active_primary_shards | n)",
    "metric active_shards \(.active_shards | n)",
    "metric active_shards_pct \(.active_shards_percent_as_number | n | r2)",
    "metric relocating_shards \(.relocating_shards | n)",
    "metric initializing_shards \(.initializing_shards | n)",
    "metric unassigned_shards \(.unassigned_shards | n)",
    (if .unassigned_primary_shards != null then "metric unassigned_primary_shards \(.unassigned_primary_shards)" else empty end),
    "metric delayed_unassigned_shards \(.delayed_unassigned_shards | n)",
    "metric pending_tasks \(.number_of_pending_tasks | n)",
    "metric task_max_wait_ms \(.task_max_waiting_in_queue_millis | n)",
    "metric in_flight_fetch \(.number_of_in_flight_fetch | n)"
' "$work/body" || exit 1
need '@MCAT@?format=json&h=id,node'
jq -r "$jqlib"'if length > 0 and .[0].node != null and .[0].node != "-" then "metric @M@ 1 node=\(.[0].node | tag)" else "metric @M@ 0" end' "$work/body" || exit 1
exit 0
''',
    ps=r'''Read-First
Write-Output "metric version 1 version=$(Safe $script:Root.version.number) cluster=$(Safe $script:Root.cluster_name)"
$health = '/_cluster/health?timeout=10s&master_timeout=10s'
$p = Get-Page $health
if ($p.State -eq 'nomaster') { Write-Output 'metric status 3 status=no_@MT@'; Write-Output 'metric @M@ 0'; exit 0 }
if ($p.State -ne 'ok') { Stop-Why $p.State $health }
$h = $p.Data
M 'status' (Code $h.status) "status=$(Safe $h.status)"
M 'timed_out' $h.timed_out
M 'nodes' $h.number_of_nodes
M 'data_nodes' $h.number_of_data_nodes
M 'active_primary_shards' $h.active_primary_shards
M 'active_shards' $h.active_shards
M 'active_shards_pct' (R2 $h.active_shards_percent_as_number)
M 'relocating_shards' $h.relocating_shards
M 'initializing_shards' $h.initializing_shards
M 'unassigned_shards' $h.unassigned_shards
if ($null -ne $h.unassigned_primary_shards) { M 'unassigned_primary_shards' $h.unassigned_primary_shards }
M 'delayed_unassigned_shards' $h.delayed_unassigned_shards
M 'pending_tasks' $h.number_of_pending_tasks
M 'task_max_wait_ms' $h.task_max_waiting_in_queue_millis
M 'in_flight_fetch' $h.number_of_in_flight_fetch
$m = @(Need-Page '@MCAT@?format=json&h=id,node')
if ($m.Count -gt 0 -and $m[0].node -and $m[0].node -ne '-') { M '@M@' 1 "node=$(Safe $m[0].node)" } else { M '@M@' 0 }
exit 0
''')

# ---------------------------------------------------------------- health
job(job='health', metric='health', when='run_every   = 1m', runtime='50s', only='es',
    title="Elasticsearch's own health report",
    what="Reports Elasticsearch's own health report (8.7 and later): its overall status, and each indicator's "
         "(the master, shard availability, disk, shard capacity, repositories, ILM, SLM, data stream lifecycle "
         "and more) with what Elasticsearch says is wrong, in its words. It asks for the short form "
         "(verbose=false), as Elasticsearch advises for polling.",
    metrics=M(('up', '1 when Elasticsearch answers, else 0'),
              ('served', '1 when this Elasticsearch has a health report (8.7 and later), else 0'),
              ('status', 'the overall status: 0 green, 1 yellow, 2 red, 3 unknown; tagged status=<it>'),
              ('indicators_red', 'indicators red'),
              ('indicators_yellow', 'indicators yellow'),
              ('indicator', "each indicator's status, the same codes, tagged indicator=<its name> and "
                            "symptom=<what Elasticsearch says>")),
    healthy="status 0; every indicator 0.",
    watch="An indicator at 1: its symptom says what (disk filling, shards near the limit, a lifecycle "
          "stalled).",
    act="status 2: an indicator red; its symptom says what, and Elasticsearch's own health report (GET "
        "_health_report/<indicator>) says what to do.",
    sh=r'''first
get '/_health_report?verbose=false'
rc=$?
case $rc in
    0) ;;
    3) echo "metric served 0"; exit 0 ;;
    *) why "$rc" '/_health_report' ;;
esac
jq -r "$jqlib"'
    "metric served 1",
    "metric status \(.status | code) status=\(.status | tag)",
    "metric indicators_red \([.indicators[] | select(.status == "red")] | length)",
    "metric indicators_yellow \([.indicators[] | select(.status == "yellow")] | length)",
    (.indicators | to_entries | sort_by(.key)[] | "metric indicator \(.value.status | code) indicator=\(.key | tag) symptom=\(.value.symptom | tag)")
' "$work/body" || exit 1
exit 0
''',
    ps=r'''Read-First
$p = Get-Page '/_health_report?verbose=false'
if ($p.State -eq 'unsupported') { M 'served' 0; exit 0 }
if ($p.State -ne 'ok') { Stop-Why $p.State '/_health_report' }
$h = $p.Data
M 'served' 1
M 'status' (Code $h.status) "status=$(Safe $h.status)"
$ind = @(Props $h.indicators | Sort-Object Name)
M 'indicators_red' (@($ind | Where-Object { $_.Value.status -eq 'red' }).Count)
M 'indicators_yellow' (@($ind | Where-Object { $_.Value.status -eq 'yellow' }).Count)
foreach ($i in $ind) { M 'indicator' (Code $i.Value.status) "indicator=$(Safe $i.Name) symptom=$(Safe $i.Value.symptom)" }
exit 0
''')

# ---------------------------------------------------------------- nodes
NODES_STATS = ('/_nodes/stats/os,process,fs,http,transport,indexing_pressure?filter_path=nodes.*.name,nodes.*.roles,'
               'nodes.*.os.cpu.percent,nodes.*.os.cpu.load_average,nodes.*.os.mem.used_percent,'
               'nodes.*.process.cpu.percent,nodes.*.process.open_file_descriptors,'
               'nodes.*.process.max_file_descriptors,nodes.*.fs.total,nodes.*.http.current_open,'
               'nodes.*.http.total_opened,nodes.*.transport.server_open,nodes.*.transport.rx_size_in_bytes,'
               'nodes.*.transport.tx_size_in_bytes,nodes.*.indexing_pressure.memory')
job(job='nodes', metric='nodes', when='run_every   = 1m', runtime='50s',
    title="each node of a cluster",
    what="Reports the cluster's nodes, by role and version, and each node as @P@ sees it: its version and "
         "roles, whether it is the elected @MW@, its CPU and load, memory, open files against the limit, "
         "its data disk, HTTP and transport connections and traffic, and indexing pressure: the memory "
         "held by writes in flight against the limit, and the writes refused for it. Never its JVM's heap "
         "or garbage collection: those are the jvm pack's.",
    metrics=M(('up', '1 when @P@ answers, else 0'),
              ('nodes', 'nodes in the cluster'),
              ('master_eligible', 'of those, nodes that may be elected @MW@'),
              ('data_nodes', 'nodes that hold data'),
              ('ingest_nodes', 'nodes that run ingest pipelines'),
              ('coordinating_only', 'nodes with no role: they only route requests'),
              ('versions', "@P@ versions among the nodes: more than 1 during an upgrade, or one left behind"),
              ('info', 'always 1, tagged node=<its name>, version=<its version> and roles=<its roles, as _cat/nodes abbreviates them>'),
              ('@M@', '1 when the node is the elected @MW@, tagged node=<its name>'),
              ('cpu_pct', "the CPU in use on the node's machine (or container), tagged the same"),
              ('load_1m', 'its load average over a minute, tagged the same (not on Windows)'),
              ('load_5m', 'over 5 minutes'),
              ('load_15m', 'over 15 minutes'),
              ('mem_used_pct', "the machine's (or container's) memory in use"),
              ('process_cpu_pct', "the CPU @P@'s process uses"),
              ('open_fds', 'files it has open'),
              ('max_fds', 'files it may have open'),
              ('fds_pct', 'open_fds, as a percentage of max_fds'),
              ('disk_total_bytes', "the size of the node's data disks"),
              ('disk_free_bytes', 'of that, free for @P@'),
              ('disk_used_pct', 'the data disks in use'),
              ('http_open', 'HTTP connections open'),
              ('http_opened', 'HTTP connections opened since it started (a counter)'),
              ('transport_open', 'connections open to the other nodes'),
              ('transport_rx_bytes', 'bytes received from the other nodes (a counter)'),
              ('transport_tx_bytes', 'bytes sent to them (a counter)'),
              ('indexing_pressure_bytes', 'memory held by writes in flight on the node'),
              ('indexing_pressure_limit_bytes', 'the most it may hold'),
              ('indexing_pressure_pct', 'indexing_pressure_bytes, as a percentage of the limit'),
              ('indexing_rejections', 'writes refused for it, since the node started (a counter)'),
              ('nodes_not_shown', 'nodes past the first 100, by name, left out')),
    healthy="nodes as many as you run; versions 1; fds_pct and disk_used_pct well below 80; indexing_rejections "
            "flat.",
    watch="cpu_pct high on one node only: a hot shard; fds_pct above 80; disk_used_pct nearing the disk "
          "watermarks (the allocation job); indexing_pressure_pct above 50.",
    act="nodes below what you run: a node left; versions above 1 when no upgrade runs; indexing_rejections "
        "rising: writes refused, clients see HTTP 429.",
    sh=r'''first
need '/_cat/nodes?format=json&full_id=true&h=id,name,version,node.role,@M@'
cp "$work/body" "$work/cat"
need '@NODES_STATS@'
jq -r --slurpfile cat "$work/cat" "$jqlib"'
    ($cat[0] | map({key: .id, value: .}) | from_entries) as $c |
    [.nodes | to_entries[] | .value + {id: .key}] | sort_by(.name) |
    "metric nodes \(length)",
    "metric master_eligible \([.[] | select(.roles | index("master") or index("cluster_manager"))] | length)",
    "metric data_nodes \([.[] | select(any(.roles[]; startswith("data")))] | length)",
    "metric ingest_nodes \([.[] | select(.roles | index("ingest"))] | length)",
    "metric coordinating_only \([.[] | select((.roles | length) == 0)] | length)",
    "metric versions \([$c[].version] | unique | length)",
    (.[0:100][] | "node=\(.name | tag)" as $t | ($c[.id] // {}) as $k |
        "metric info 1 \($t) version=\($k.version | tag) roles=\($k["node.role"] | tag)",
        "metric @M@ \(if $k.@M@ == "*" then 1 else 0 end) \($t)",
        "metric cpu_pct \(.os.cpu.percent | n) \($t)",
        (.os.cpu.load_average // empty | "metric load_1m \(.["1m"] | n) \($t)", "metric load_5m \(.["5m"] | n) \($t)", "metric load_15m \(.["15m"] | n) \($t)"),
        "metric mem_used_pct \(.os.mem.used_percent | n) \($t)",
        "metric process_cpu_pct \(.process.cpu.percent | n) \($t)",
        "metric open_fds \(.process.open_file_descriptors | n) \($t)",
        "metric max_fds \(.process.max_file_descriptors | n) \($t)",
        "metric fds_pct \(pct(.process.open_file_descriptors; .process.max_file_descriptors)) \($t)",
        "metric disk_total_bytes \(.fs.total.total_in_bytes | n) \($t)",
        "metric disk_free_bytes \(.fs.total.available_in_bytes | n) \($t)",
        "metric disk_used_pct \(pct((.fs.total.total_in_bytes | n) - (.fs.total.available_in_bytes | n); .fs.total.total_in_bytes)) \($t)",
        "metric http_open \(.http.current_open | n) \($t)",
        "metric http_opened \(.http.total_opened | n) \($t)",
        "metric transport_open \(.transport.server_open | n) \($t)",
        "metric transport_rx_bytes \(.transport.rx_size_in_bytes | n) \($t)",
        "metric transport_tx_bytes \(.transport.tx_size_in_bytes | n) \($t)",
        (.indexing_pressure.memory // empty |
            ((.current.combined_coordinating_and_primary_in_bytes | n) + (.current.replica_in_bytes | n)) as $b |
            "metric indexing_pressure_bytes \($b) \($t)",
            "metric indexing_pressure_limit_bytes \(.limit_in_bytes | n) \($t)",
            "metric indexing_pressure_pct \(pct($b; .limit_in_bytes)) \($t)",
            "metric indexing_rejections \((.total.coordinating_rejections | n) + (.total.primary_rejections | n) + (.total.replica_rejections | n)) \($t)")),
    "metric nodes_not_shown \([length - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
''',
    ps=r'''Read-First
$cat = @(Need-Page '/_cat/nodes?format=json&full_id=true&h=id,name,version,node.role,@M@')
$c = @{}
foreach ($k in $cat) { $c[[string]$k.id] = $k }
$s = Need-Page '@NODES_STATS@'
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
    M '@M@' $(if ($k -and $k.@M@ -eq '*') { 1 } else { 0 }) $t
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
'''.replace('@NODES_STATS@', NODES_STATS))
JOBS[-1]['sh'] = JOBS[-1]['sh'].replace('@NODES_STATS@', NODES_STATS)

# ---------------------------------------------------------------- thread_pools
job(job='thread_pools', metric='thread_pools', when='run_every   = 1m', runtime='50s',
    title="the thread pools of a cluster's nodes",
    what="Reports each node's thread pools, the queues of work @P@ keeps for writes, searches, gets and its "
         "own housekeeping: threads busy, work waiting against the queue's size, and work refused when the "
         "queue was full (a client sees HTTP 429). The write, search and get pools are always reported; the "
         "others when they have work busy, waiting or refused.",
    metrics=M(('up', '1 when @P@ answers, else 0'),
              ('rejected_total', 'work refused by every pool of every node, since each started (a counter)'),
              ('queued_total', 'work waiting in every pool now'),
              ('active_total', 'threads busy in every pool now'),
              ('active', "a pool's threads busy, tagged node=<its name> and pool=<the pool>"),
              ('queue', 'its work waiting, tagged the same'),
              ('queue_pct', "queue, as a percentage of the queue's size, when it has one"),
              ('rejected', 'its work refused, since the node started (a counter)'),
              ('completed', 'its work done (a counter)'),
              ('threads', 'its threads'),
              ('largest', 'the most threads it has had at once'),
              ('pools_not_shown', 'pools past the first 200 (refusing first), left out')),
    healthy="rejected_total flat; queue near 0 most of the time.",
    watch="queue_pct above 50 on the write or search pool: the node falls behind.",
    act="rejected rising on write: writes refused, clients see HTTP 429 (bulk requests partly fail); on "
        "search: searches refused.",
    sh=r'''first
need '/_cat/thread_pool?format=json&h=node_name,name,active,queue,queue_size,rejected,completed,largest,size'
jq -r "$jqlib"'
    map(.active |= n | .queue |= n | .rejected |= n | .completed |= n | .size |= n | .largest |= n) |
    "metric rejected_total \([.[].rejected] | add // 0)",
    "metric queued_total \([.[].queue] | add // 0)",
    "metric active_total \([.[].active] | add // 0)",
    ([.[] | select(.name == "write" or .name == "search" or .name == "get" or .active > 0 or .queue > 0 or .rejected > 0)]
        | sort_by(-.rejected, -.queue, .node_name, .name) |
        (.[0:200][] | "node=\(.node_name | tag) pool=\(.name | tag)" as $t |
            "metric active \(.active) \($t)",
            "metric queue \(.queue) \($t)",
            (if (.queue_size | n) > 0 then "metric queue_pct \(pct(.queue; .queue_size)) \($t)" else empty end),
            "metric rejected \(.rejected) \($t)",
            "metric completed \(.completed) \($t)",
            "metric threads \(.size) \($t)",
            "metric largest \(.largest) \($t)"),
        "metric pools_not_shown \([length - 200, 0] | max)")
' "$work/body" || exit 1
exit 0
''',
    ps=r'''Read-First
$all = @(Need-Page '/_cat/thread_pool?format=json&h=node_name,name,active,queue,queue_size,rejected,completed,largest,size')
M 'rejected_total' (($all | ForEach-Object { N $_.rejected } | Measure-Object -Sum).Sum)
M 'queued_total' (($all | ForEach-Object { N $_.queue } | Measure-Object -Sum).Sum)
M 'active_total' (($all | ForEach-Object { N $_.active } | Measure-Object -Sum).Sum)
$sel = @($all | Where-Object { $_.name -in 'write', 'search', 'get' -or (N $_.active) -gt 0 -or (N $_.queue) -gt 0 -or (N $_.rejected) -gt 0 } |
    Sort-Object @{ Expression = { N $_.rejected }; Descending = $true }, @{ Expression = { N $_.queue }; Descending = $true }, @{ Expression = { [string]$_.node_name } }, @{ Expression = { [string]$_.name } })
foreach ($x in @($sel | Select-Object -First 200)) {
    $t = "node=$(Safe $x.node_name) pool=$(Safe $x.name)"
    M 'active' $x.active $t
    M 'queue' $x.queue $t
    if ((N $x.queue_size) -gt 0) { M 'queue_pct' (Pct $x.queue $x.queue_size) $t }
    M 'rejected' $x.rejected $t
    M 'completed' $x.completed $t
    M 'threads' $x.size $t
    M 'largest' $x.largest $t
}
M 'pools_not_shown' ([Math]::Max($sel.Count - 200, 0))
exit 0
''')

# ---------------------------------------------------------------- breakers
job(job='breakers', metric='breakers', when='run_every   = 1m', runtime='50s',
    title="the circuit breakers of a cluster's nodes",
    what="Reports each node's circuit breakers, the limits @P@ sets on the memory a request, field data, "
         "requests in flight and the node as a whole (the parent) may take: what each holds against its "
         "limit, and how often it tripped, refusing a request rather than running out of memory.",
    metrics=M(('up', '1 when @P@ answers, else 0'),
              ('tripped_total', 'trips of every breaker of every node, since each started (a counter)'),
              ('max_used_pct', 'the fullest breaker, as a percentage of its limit'),
              ('estimated_bytes', 'what a breaker holds, tagged node=<its name> and breaker=<the breaker>'),
              ('limit_bytes', 'its limit, tagged the same'),
              ('used_pct', 'estimated_bytes, as a percentage of the limit'),
              ('tripped', 'its trips, since the node started (a counter)'),
              ('breakers_not_shown', 'breakers past the first 600, left out')),
    healthy="tripped_total flat; the parent breaker's used_pct below 85.",
    watch="the parent breaker's used_pct above 85: the node is short of memory for what it is asked.",
    act="tripped rising: requests refused (HTTP 429, circuit_breaking_exception); on parent, the node's "
        "memory is too small for its load; on fielddata, a text field aggregated.",
    sh=r'''first
need '/_nodes/stats/breaker?filter_path=nodes.*.name,nodes.*.breakers'
jq -r "$jqlib"'
    [.nodes[] | .name as $nm | .breakers | to_entries[] |
        {node: $nm, breaker: .key, est: (.value.estimated_size_in_bytes | n), lim: (.value.limit_size_in_bytes | n), tripped: (.value.tripped | n)}]
    | sort_by(.node, .breaker) |
    "metric tripped_total \([.[].tripped] | add // 0)",
    "metric max_used_pct \([.[] | pct(.est; .lim)] | max // 0)",
    (.[0:600][] | "node=\(.node | tag) breaker=\(.breaker | tag)" as $t |
        "metric estimated_bytes \(.est) \($t)",
        "metric limit_bytes \(.lim) \($t)",
        "metric used_pct \(pct(.est; .lim)) \($t)",
        "metric tripped \(.tripped) \($t)"),
    "metric breakers_not_shown \([length - 600, 0] | max)"
' "$work/body" || exit 1
exit 0
''',
    ps=r'''Read-First
$s = Need-Page '/_nodes/stats/breaker?filter_path=nodes.*.name,nodes.*.breakers'
$all = @(foreach ($nd in (Values $s.nodes)) {
    foreach ($b in (Props $nd.breakers)) {
        [pscustomobject]@{ node = [string]$nd.name; breaker = $b.Name; est = (N $b.Value.estimated_size_in_bytes); lim = (N $b.Value.limit_size_in_bytes); tripped = (N $b.Value.tripped) }
    }
}) | Sort-Object node, breaker
$all = @($all)
M 'tripped_total' (($all | ForEach-Object { $_.tripped } | Measure-Object -Sum).Sum)
$max = 0
foreach ($x in $all) { $p = Pct $x.est $x.lim; if ($p -gt $max) { $max = $p } }
M 'max_used_pct' $max
foreach ($x in @($all | Select-Object -First 600)) {
    $t = "node=$(Safe $x.node) breaker=$(Safe $x.breaker)"
    M 'estimated_bytes' $x.est $t
    M 'limit_bytes' $x.lim $t
    M 'used_pct' (Pct $x.est $x.lim) $t
    M 'tripped' $x.tripped $t
}
M 'breakers_not_shown' ([Math]::Max($all.Count - 600, 0))
exit 0
''')

# ---------------------------------------------------------------- indices
job(job='indices', metric='indices', when='cron        = 1/5 * * * *', runtime='4m',
    title="the indices of a cluster",
    what="Reports the cluster's indices, hidden ones and data streams' backing indices too: how many, open "
         "and closed, green, yellow and red, their documents and size, and those with a block (written to "
         "no more, or read-only, as @P@ leaves them when a disk fills). Then each index, the worst first "
         "(red, yellow, blocked, closed, then the largest): its health, documents, deleted documents, size, "
         "shards, replicas, age and blocks.",
    metrics=M(('up', '1 when @P@ answers, else 0'),
              ('indices', 'indices'),
              ('open', 'of those, open'),
              ('closed', 'closed'),
              ('green', 'green: every shard assigned'),
              ('yellow', 'yellow: a replica unassigned'),
              ('red', 'red: a primary unassigned'),
              ('hidden', "indices whose names start with a dot (hidden, and data streams' backing indices)"),
              ('docs', 'documents in every index, primaries only'),
              ('deleted_docs', 'documents deleted but not yet merged away'),
              ('store_bytes', 'the size of every index, replicas too'),
              ('primary_store_bytes', 'the size of the primaries alone'),
              ('blocked', 'indices with a block of any kind'),
              ('write_blocked', 'indices that take no writes: a write, read_only or read_only_allow_delete block'),
              ('health', "an index's health: 0 green, 1 yellow, 2 red; tagged index=<its name>"),
              ('is_open', '1 when it is open, tagged the same'),
              ('index_docs', 'its documents, primaries only'),
              ('deleted_pct', 'its deleted documents, as a percentage of all'),
              ('index_store_bytes', 'its size, replicas too'),
              ('index_primary_store_bytes', 'its primaries\' size'),
              ('primaries', 'its primary shards'),
              ('replicas', 'its replicas of each'),
              ('age_days', 'days since it was created'),
              ('block', 'always 1, for each block it has, tagged index=<its name> and block=<the block>'),
              ('indices_not_shown', 'indices past the first 100, the worst first, left out')),
    healthy="red 0; yellow 0 (on a cluster of more than one node); write_blocked 0.",
    watch="deleted_pct above 30 on a large index: space held by deleted documents until merges; an index "
          "far larger than the rest.",
    act="red above 0: data unreachable (the shards job says why); write_blocked above 0: writes to it fail, "
        "often after a disk passed the flood stage (free space, then clear the block).",
    sh=r'''first
need '/_cat/indices?format=json&bytes=b&expand_wildcards=all&h=health,status,index,pri,rep,docs.count,docs.deleted,store.size,pri.store.size,creation.date'
cp "$work/body" "$work/cat"
need '/_settings?filter_path=*.settings.index.blocks&expand_wildcards=all'
jq -r --slurpfile cat "$work/cat" --argjson now "$now" "$jqlib"'
    . as $b |
    [$cat[0][] | {name: .index, health: .health, status: .status, pri: (.pri | n), rep: (.rep | n),
        docs: (.["docs.count"] | n), del: (.["docs.deleted"] | n), size: (.["store.size"] | n),
        psize: (.["pri.store.size"] | n), created: (.["creation.date"] | n),
        blocks: [($b[.index].settings.index.blocks // {}) | to_entries[] | select(.value == "true" or .value == true) | .key]}] |
    "metric indices \(length)",
    "metric open \([.[] | select(.status == "open")] | length)",
    "metric closed \([.[] | select(.status == "close")] | length)",
    "metric green \([.[] | select(.health == "green")] | length)",
    "metric yellow \([.[] | select(.health == "yellow")] | length)",
    "metric red \([.[] | select(.health == "red")] | length)",
    "metric hidden \([.[] | select(.name | startswith("."))] | length)",
    "metric docs \([.[].docs] | add // 0)",
    "metric deleted_docs \([.[].del] | add // 0)",
    "metric store_bytes \([.[].size] | add // 0)",
    "metric primary_store_bytes \([.[].psize] | add // 0)",
    "metric blocked \([.[] | select(.blocks | length > 0)] | length)",
    "metric write_blocked \([.[] | select(.blocks | any(. == "write" or . == "read_only" or . == "read_only_allow_delete"))] | length)",
    (sort_by((if .health == "red" then 0 elif .health == "yellow" then 1 elif (.blocks | length) > 0 then 2 elif .status == "close" then 3 else 4 end), -.size, .name)
        | .[0:100][] | "index=\(.name | tag)" as $t |
        (if .health == "green" or .health == "yellow" or .health == "red" then "metric health \(.health | code) \($t)" else empty end),
        "metric is_open \(if .status == "open" then 1 else 0 end) \($t)",
        "metric index_docs \(.docs) \($t)",
        "metric deleted_pct \(pct(.del; .docs + .del)) \($t)",
        "metric index_store_bytes \(.size) \($t)",
        "metric index_primary_store_bytes \(.psize) \($t)",
        "metric primaries \(.pri) \($t)",
        "metric replicas \(.rep) \($t)",
        (if .created > 0 then "metric age_days \(($now * 1000 - .created) / 86400000 | floor) \($t)" else empty end),
        (.blocks | sort[] | "metric block 1 \($t) block=\(. | tag)")),
    "metric indices_not_shown \([length - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
''',
    ps=r'''Read-First
$cat = @(Need-Page '/_cat/indices?format=json&bytes=b&expand_wildcards=all&h=health,status,index,pri,rep,docs.count,docs.deleted,store.size,pri.store.size,creation.date')
$b = Need-Page '/_settings?filter_path=*.settings.index.blocks&expand_wildcards=all'
$all = @(foreach ($i in $cat) {
    $bl = @()
    $ib = $null
    if ($b) { $e = $b.PSObject.Properties[[string]$i.index]; if ($e) { $ib = $e.Value.settings.index.blocks } }
    foreach ($p in (Props $ib)) { if ("$($p.Value)" -eq 'true' -or "$($p.Value)" -eq 'True') { $bl += $p.Name } }
    [pscustomobject]@{ name = [string]$i.index; health = [string]$i.health; status = [string]$i.status; pri = (N $i.pri); rep = (N $i.rep)
        docs = (N $i.'docs.count'); del = (N $i.'docs.deleted'); size = (N $i.'store.size'); psize = (N $i.'pri.store.size'); created = (N $i.'creation.date'); blocks = $bl }
})
M 'indices' $all.Count
M 'open' (@($all | Where-Object { $_.status -eq 'open' }).Count)
M 'closed' (@($all | Where-Object { $_.status -eq 'close' }).Count)
M 'green' (@($all | Where-Object { $_.health -eq 'green' }).Count)
M 'yellow' (@($all | Where-Object { $_.health -eq 'yellow' }).Count)
M 'red' (@($all | Where-Object { $_.health -eq 'red' }).Count)
M 'hidden' (@($all | Where-Object { $_.name.StartsWith('.') }).Count)
M 'docs' (($all | ForEach-Object { $_.docs } | Measure-Object -Sum).Sum)
M 'deleted_docs' (($all | ForEach-Object { $_.del } | Measure-Object -Sum).Sum)
M 'store_bytes' (($all | ForEach-Object { $_.size } | Measure-Object -Sum).Sum)
M 'primary_store_bytes' (($all | ForEach-Object { $_.psize } | Measure-Object -Sum).Sum)
M 'blocked' (@($all | Where-Object { $_.blocks.Count -gt 0 }).Count)
M 'write_blocked' (@($all | Where-Object { @($_.blocks | Where-Object { $_ -in 'write', 'read_only', 'read_only_allow_delete' }).Count -gt 0 }).Count)
$rank = { if ($_.health -eq 'red') { 0 } elseif ($_.health -eq 'yellow') { 1 } elseif ($_.blocks.Count -gt 0) { 2 } elseif ($_.status -eq 'close') { 3 } else { 4 } }
$sorted = @($all | Sort-Object @{ Expression = $rank }, @{ Expression = { $_.size }; Descending = $true }, @{ Expression = { $_.name } })
foreach ($x in @($sorted | Select-Object -First 100)) {
    $t = "index=$(Safe $x.name)"
    if ($x.health -in 'green', 'yellow', 'red') { M 'health' (Code $x.health) $t }
    M 'is_open' $(if ($x.status -eq 'open') { 1 } else { 0 }) $t
    M 'index_docs' $x.docs $t
    M 'deleted_pct' (Pct $x.del ($x.docs + $x.del)) $t
    M 'index_store_bytes' $x.size $t
    M 'index_primary_store_bytes' $x.psize $t
    M 'primaries' $x.pri $t
    M 'replicas' $x.rep $t
    if ($x.created -gt 0) { M 'age_days' ([Math]::Floor(($script:Now * 1000 - $x.created) / 86400000)) $t }
    foreach ($bk in @($x.blocks | Sort-Object)) { Write-Output "metric block 1 $t block=$(Safe $bk)" }
}
M 'indices_not_shown' ([Math]::Max($all.Count - 100, 0))
exit 0
''')
