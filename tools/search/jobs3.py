# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The elasticsearch and opensearch packs' jobs, continued: operations,
ingest, tasks, snapshots and cluster (tools/search/jobs.py says how they are
written)."""
from jobs import job, M, JOBS

# ---------------------------------------------------------------- operations
OPS = [
    # name, the path under each node's indices, what it is
    ('docs', 'docs.count', "documents in the node's shards"),
    ('store_bytes', 'store.size_in_bytes', "the size of the node's shards"),
    ('index_total', 'indexing.index_total', 'documents indexed (a counter)'),
    ('index_time_ms', 'indexing.index_time_in_millis', 'time spent indexing (a counter)'),
    ('index_current', 'indexing.index_current', 'documents being indexed now'),
    ('index_failed', 'indexing.index_failed', 'documents that failed to index (a counter)'),
    ('delete_total', 'indexing.delete_total', 'documents deleted (a counter)'),
    ('index_throttle_ms', 'indexing.throttle_time_in_millis', 'time indexing was throttled for merges (a counter)'),
    ('query_total', 'search.query_total', 'search queries, each shard counted (a counter)'),
    ('query_time_ms', 'search.query_time_in_millis', 'time spent in them (a counter)'),
    ('query_current', 'search.query_current', 'queries running now'),
    ('fetch_total', 'search.fetch_total', 'fetches of search hits (a counter)'),
    ('fetch_time_ms', 'search.fetch_time_in_millis', 'time spent in them (a counter)'),
    ('scroll_current', 'search.scroll_current', 'scrolls open now'),
    ('open_contexts', 'search.open_contexts', 'search contexts open now (scrolls and point-in-time searches)'),
    ('get_total', 'get.total', 'gets by id (a counter)'),
    ('get_missing', 'get.missing_total', 'of those, for documents that were not there (a counter)'),
    ('get_time_ms', 'get.time_in_millis', 'time spent in gets (a counter)'),
    ('merges_current', 'merges.current', 'segment merges running now'),
    ('merges_total', 'merges.total', 'merges (a counter)'),
    ('merges_time_ms', 'merges.total_time_in_millis', 'time spent merging (a counter)'),
    ('merges_throttled_ms', 'merges.total_throttled_time_in_millis', 'time merges were throttled (a counter)'),
    ('refresh_total', 'refresh.total', 'refreshes (a counter)'),
    ('refresh_time_ms', 'refresh.total_time_in_millis', 'time spent refreshing (a counter)'),
    ('flush_total', 'flush.total', 'flushes (a counter)'),
    ('flush_time_ms', 'flush.total_time_in_millis', 'time spent flushing (a counter)'),
    ('query_cache_bytes', 'query_cache.memory_size_in_bytes', 'memory the query cache holds'),
    ('query_cache_hits', 'query_cache.hit_count', 'query cache hits (a counter)'),
    ('query_cache_misses', 'query_cache.miss_count', 'its misses (a counter)'),
    ('query_cache_evictions', 'query_cache.evictions', 'its evictions (a counter)'),
    ('request_cache_bytes', 'request_cache.memory_size_in_bytes', 'memory the request cache holds'),
    ('request_cache_hits', 'request_cache.hit_count', 'request cache hits (a counter)'),
    ('request_cache_misses', 'request_cache.miss_count', 'its misses (a counter)'),
    ('request_cache_evictions', 'request_cache.evictions', 'its evictions (a counter)'),
    ('fielddata_bytes', 'fielddata.memory_size_in_bytes', 'memory field data holds'),
    ('fielddata_evictions', 'fielddata.evictions', 'its evictions (a counter)'),
    ('segments', 'segments.count', 'Lucene segments in the node\'s shards'),
    ('translog_ops', 'translog.operations', 'operations in the translog'),
    ('translog_bytes', 'translog.size_in_bytes', 'its size'),
    ('translog_uncommitted_bytes', 'translog.uncommitted_size_in_bytes', 'of that, not yet committed to Lucene'),
]
OPS_PATH = ('/_nodes/stats/indices?filter_path=nodes.*.name,' +
            ','.join(sorted({'nodes.*.indices.' + p.split('.')[0] for _, p, _ in OPS})))
sh_ops = '\n'.join('        "metric %s \\(.indices.%s | n) \\($t)",' % (n, p) for n, p, _ in OPS).rstrip(',')
ps_ops = '\n'.join("    M '%s' $x.indices.%s $t" % (n, p) for n, p, _ in OPS)
job(job='operations', metric='operations', when='run_every   = 1m', runtime='50s',
    title="the work each node of a cluster does",
    what="Reports, for each node, what its shards hold and the work it does, as counters to make rates "
         "of: documents indexed and deleted, and how long it took; search queries and fetches, and how "
         "long; gets; merges, refreshes and flushes; the query, request and field data caches, their hits, "
         "misses and evictions; segments; and the translog. The rate of index_total is the indexing rate; "
         "query_time_ms over query_total, the average query time.",
    metrics=M(('up', '1 when @P@ answers, else 0'),
              *[(n, d + (', tagged node=<its name>' if i == 0 else '')) for i, (n, _, d) in enumerate(OPS)],
              ('nodes_not_shown', 'nodes past the first 100, by name, left out')),
    healthy="index_failed flat; query_time_ms rising in step with query_total; merges_throttled_ms and "
            "index_throttle_ms flat.",
    watch="query_time_ms rising faster than query_total: queries slow down; index_throttle_ms rising: "
          "merges cannot keep up with indexing; query_cache_evictions or fielddata_evictions climbing.",
    act="index_failed rising: documents refused (mapping conflicts, ingest failures); open_contexts climbing "
        "without end: scrolls or point-in-time searches never closed.",
    sh=r'''first
need '@OPS_PATH@'
jq -r "$jqlib"'
    [.nodes[]] | sort_by(.name) |
    (.[0:100][] | "node=\(.name | tag)" as $t |
@SH_OPS@),
    "metric nodes_not_shown \([length - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
''',
    ps=r'''Read-First
$s = Need-Page '@OPS_PATH@'
$all = @(Values $s.nodes | Sort-Object { [string]$_.name })
foreach ($x in @($all | Select-Object -First 100)) {
    $t = "node=$(Safe $x.name)"
@PS_OPS@
}
M 'nodes_not_shown' ([Math]::Max($all.Count - 100, 0))
exit 0
''')
for k in ('sh', 'ps'):
    JOBS[-1][k] = JOBS[-1][k].replace('@OPS_PATH@', OPS_PATH).replace('@SH_OPS@', sh_ops).replace('@PS_OPS@', ps_ops)

# ---------------------------------------------------------------- ingest
job(job='ingest', metric='ingest', when='run_every   = 1m', runtime='50s',
    title="the ingest pipelines of a cluster",
    what="Reports the documents the cluster's ingest pipelines have taken, failed and taken time over, "
         "every node together, and each pipeline that has run, those that failed most first: its "
         "documents, its failures and their share, and its average time.",
    metrics=M(('up', '1 when @P@ answers, else 0'),
              ('count', 'documents through any pipeline, every node (a counter)'),
              ('failed', 'of those, failed (a counter)'),
              ('time_ms', 'time spent in pipelines (a counter)'),
              ('current', 'documents in a pipeline now'),
              ('failed_pct', 'failed, as a percentage of count'),
              ('pipelines', 'pipelines that have run'),
              ('pipeline_count', "a pipeline's documents, tagged pipeline=<its name> (a counter)"),
              ('pipeline_failed', 'its failures (a counter)'),
              ('pipeline_failed_pct', 'its failures, as a percentage of its documents'),
              ('pipeline_time_ms', 'its time (a counter)'),
              ('pipeline_avg_ms', 'its average time a document'),
              ('pipelines_not_shown', 'pipelines past the first 100, left out')),
    healthy="failed flat.",
    watch="pipeline_avg_ms rising: a pipeline slows every write through it.",
    act="pipeline_failed rising: documents refused, or indexed with an error (a grok pattern that no "
        "longer matches, a field of a type the pipeline did not expect).",
    sh=r'''first
need '/_nodes/stats/ingest?filter_path=nodes.*.ingest.total,nodes.*.ingest.pipelines.*.count,nodes.*.ingest.pipelines.*.failed,nodes.*.ingest.pipelines.*.time_in_millis,nodes.*.ingest.pipelines.*.current'
jq -r "$jqlib"'
    [.nodes[]?.ingest] as $i |
    ([$i[].total.count | n] | add // 0) as $c | ([$i[].total.failed | n] | add // 0) as $f |
    "metric count \($c)",
    "metric failed \($f)",
    "metric time_ms \([$i[].total.time_in_millis | n] | add // 0)",
    "metric current \([$i[].total.current | n] | add // 0)",
    "metric failed_pct \(pct($f; $c))",
    ([$i[].pipelines // {} | to_entries[]] | group_by(.key) |
        map({name: .[0].key, count: (map(.value.count | n) | add), failed: (map(.value.failed | n) | add), time: (map(.value.time_in_millis | n) | add)})
        | map(select(.count > 0 or .failed > 0)) | sort_by(-.failed, -.count, .name) |
        "metric pipelines \(length)",
        (.[0:100][] | "pipeline=\(.name | tag)" as $t |
            "metric pipeline_count \(.count) \($t)",
            "metric pipeline_failed \(.failed) \($t)",
            "metric pipeline_failed_pct \(pct(.failed; .count)) \($t)",
            "metric pipeline_time_ms \(.time) \($t)",
            "metric pipeline_avg_ms \(if .count > 0 then (.time / .count | r2) else 0 end) \($t)"),
        "metric pipelines_not_shown \([length - 100, 0] | max)")
' "$work/body" || exit 1
exit 0
''',
    ps=r'''Read-First
$s = Need-Page '/_nodes/stats/ingest?filter_path=nodes.*.ingest.total,nodes.*.ingest.pipelines.*.count,nodes.*.ingest.pipelines.*.failed,nodes.*.ingest.pipelines.*.time_in_millis,nodes.*.ingest.pipelines.*.current'
$ing = @(Values $s.nodes | ForEach-Object { $_.ingest })
$c = 0; $f = 0; $tm = 0; $cur = 0
$by = @{}
foreach ($i in $ing) {
    $c += N $i.total.count; $f += N $i.total.failed; $tm += N $i.total.time_in_millis; $cur += N $i.total.current
    foreach ($p in (Props $i.pipelines)) {
        if (-not $by.ContainsKey($p.Name)) { $by[$p.Name] = [pscustomobject]@{ name = $p.Name; count = 0.0; failed = 0.0; time = 0.0 } }
        $e = $by[$p.Name]; $e.count += N $p.Value.count; $e.failed += N $p.Value.failed; $e.time += N $p.Value.time_in_millis
    }
}
M 'count' $c
M 'failed' $f
M 'time_ms' $tm
M 'current' $cur
M 'failed_pct' (Pct $f $c)
$pl = @($by.Values | Where-Object { $_.count -gt 0 -or $_.failed -gt 0 } | Sort-Object @{ Expression = { $_.failed }; Descending = $true }, @{ Expression = { $_.count }; Descending = $true }, @{ Expression = { $_.name } })
M 'pipelines' $pl.Count
foreach ($x in @($pl | Select-Object -First 100)) {
    $t = "pipeline=$(Safe $x.name)"
    M 'pipeline_count' $x.count $t
    M 'pipeline_failed' $x.failed $t
    M 'pipeline_failed_pct' (Pct $x.failed $x.count) $t
    M 'pipeline_time_ms' $x.time $t
    M 'pipeline_avg_ms' $(if ($x.count -gt 0) { R2 ($x.time / $x.count) } else { 0 }) $t
}
M 'pipelines_not_shown' ([Math]::Max($pl.Count - 100, 0))
exit 0
''')

# ---------------------------------------------------------------- tasks
job(job='tasks', metric='tasks', when='run_every   = 1m', runtime='50s',
    title="the tasks a cluster runs, and the cluster tasks waiting",
    what="Reports the tasks running in the cluster, as @P@ lists them (searches, bulk writes, reindexing, "
         "updates and deletes by query, snapshots, force merges...): how many, the longest, those running "
         "past a minute, those cancelled but still running, and how many of each kind. Then the 20 "
         "longest, with how long each has run; for reindexing and by-query work, what it reads and writes "
         "(never a search's query). Then the cluster tasks waiting for the elected @MW@, the oldest first. "
         "The task list itself, persistent tasks and a task's children are left out.",
    metrics=M(('up', '1 when @P@ answers, else 0'),
              ('tasks', 'tasks running'),
              ('longest_seconds', 'how long the longest has run'),
              ('over_60s', 'tasks running for more than a minute'),
              ('cancellable', 'tasks that may be cancelled'),
              ('cancelled', 'tasks cancelled but still running'),
              ('searches', 'searches running'),
              ('action_tasks', 'tasks of a kind, tagged action=<it> (the 10 most)'),
              ('running_seconds', 'how long a task has run, tagged action=<it>, node=<where it runs> and '
                                  'what=<for reindexing and by-query work, what it reads and writes; else none>'),
              ('tasks_not_shown', 'tasks past the 20 longest, left out'),
              ('pending', 'cluster tasks waiting for the @MW@'),
              ('pending_oldest_ms', 'how long the oldest has waited'),
              ('pending_ms', 'how long one has waited, tagged priority=<it> and source=<what asked for it> (the 20 oldest)')),
    healthy="over_60s 0, but for reindexing, snapshots and force merges you started; pending 0.",
    watch="searches running for minutes: an expensive query (searches, and the running_seconds of "
          "indices:data/read/search); cancelled above 0 for long.",
    act="pending above 0 and pending_oldest_ms in seconds: the @MW@ falls behind, and mappings, "
        "settings and shard moves wait; a search running for many minutes, holding memory and threads.",
    sh=r'''first
need '/_cat/nodes?format=json&full_id=true&h=id,name'
cp "$work/body" "$work/cat"
need '/_tasks?detailed=true&group_by=none&filter_path=tasks.action,tasks.node,tasks.running_time_in_nanos,tasks.cancellable,tasks.cancelled,tasks.description,tasks.parent_task_id'
jq -r --slurpfile cat "$work/cat" "$jqlib"'
    ($cat[0] | map({key: .id, value: .name}) | from_entries) as $nm |
    [.tasks[]? | select(.parent_task_id == null and (.action | startswith("cluster:monitor/tasks/lists") | not) and (.action | endswith("[c]") | not))
        | . + {s: ((.running_time_in_nanos | n) / 1e9 | floor)}] | sort_by(-.s, .action) |
    "metric tasks \(length)",
    "metric longest_seconds \(.[0].s // 0)",
    "metric over_60s \([.[] | select(.s > 60)] | length)",
    "metric cancellable \([.[] | select(.cancellable)] | length)",
    "metric cancelled \([.[] | select(.cancelled == true)] | length)",
    "metric searches \([.[] | select(.action | startswith("indices:data/read/search"))] | length)",
    (group_by(.action) | sort_by(-length, .[0].action) | .[0:10][] | "metric action_tasks \(length) action=\(.[0].action | tag)"),
    (.[0:20][] | "metric running_seconds \(.s) action=\(.action | tag) node=\($nm[.node] // .node | tag) what=\(if (.action | test("reindex|byquery")) then (.description // "" | tag) else "none" end)"),
    "metric tasks_not_shown \([length - 20, 0] | max)"
' "$work/body" || exit 1
need '/_cluster/pending_tasks'
jq -r "$jqlib"'
    [.tasks[]?] | sort_by(-(.time_in_queue_millis | n)) |
    "metric pending \(length)",
    "metric pending_oldest_ms \(.[0].time_in_queue_millis // 0 | n)",
    (.[0:20][] | "metric pending_ms \(.time_in_queue_millis | n) priority=\(.priority | tag) source=\(.source | tag)")
' "$work/body" || exit 1
exit 0
''',
    ps=r'''Read-First
$nm = @{}
foreach ($k in @(Need-Page '/_cat/nodes?format=json&full_id=true&h=id,name')) { $nm[[string]$k.id] = [string]$k.name }
$s = Need-Page '/_tasks?detailed=true&group_by=none&filter_path=tasks.action,tasks.node,tasks.running_time_in_nanos,tasks.cancellable,tasks.cancelled,tasks.description,tasks.parent_task_id'
$all = @(@($s.tasks) | Where-Object { $_ -and -not $_.parent_task_id -and -not ([string]$_.action).StartsWith('cluster:monitor/tasks/lists') -and -not ([string]$_.action).EndsWith('[c]') } |
    ForEach-Object { $_ | Add-Member -NotePropertyName s -NotePropertyValue ([Math]::Floor((N $_.running_time_in_nanos) / 1e9)) -Force; $_ } |
    Sort-Object @{ Expression = { $_.s }; Descending = $true }, @{ Expression = { [string]$_.action } })
M 'tasks' $all.Count
M 'longest_seconds' $(if ($all.Count) { $all[0].s } else { 0 })
M 'over_60s' (@($all | Where-Object { $_.s -gt 60 }).Count)
M 'cancellable' (@($all | Where-Object { $_.cancellable }).Count)
M 'cancelled' (@($all | Where-Object { $_.cancelled -eq $true }).Count)
M 'searches' (@($all | Where-Object { ([string]$_.action).StartsWith('indices:data/read/search') }).Count)
foreach ($g in @($all | Group-Object { [string]$_.action } | Sort-Object @{ Expression = { $_.Count }; Descending = $true }, @{ Expression = { $_.Name } } | Select-Object -First 10)) {
    M 'action_tasks' $g.Count "action=$(Safe $g.Name)"
}
foreach ($x in @($all | Select-Object -First 20)) {
    $node = if ($nm.ContainsKey([string]$x.node)) { $nm[[string]$x.node] } else { $x.node }
    $what = if ([string]$x.action -match 'reindex|byquery') { Safe $x.description } else { 'none' }
    M 'running_seconds' $x.s "action=$(Safe $x.action) node=$(Safe $node) what=$what"
}
M 'tasks_not_shown' ([Math]::Max($all.Count - 20, 0))
$p = Need-Page '/_cluster/pending_tasks'
$pt = @(@($p.tasks) | Where-Object { $_ } | Sort-Object @{ Expression = { N $_.time_in_queue_millis }; Descending = $true })
M 'pending' $pt.Count
M 'pending_oldest_ms' $(if ($pt.Count) { $pt[0].time_in_queue_millis } else { 0 })
foreach ($x in @($pt | Select-Object -First 20)) { M 'pending_ms' $x.time_in_queue_millis "priority=$(Safe $x.priority) source=$(Safe $x.source)" }
exit 0
''')

# ---------------------------------------------------------------- snapshots
job(job='snapshots', metric='snapshots', when='cron        = 7/15 * * * *', runtime='10m',
    title="the snapshots in a cluster's repositories",
    what="Reports the cluster's snapshot repositories and, for each (the first 20, by name), its snapshots: "
         "how many, how many failed or partial, the last one's state, age, length and failed shards, and "
         "how long since the last that succeeded. Then the snapshots being taken now. A repository the "
         "cluster cannot read is reported so, not failed.",
    metrics=M(('up', '1 when @P@ answers, else 0'),
              ('repositories', 'snapshot repositories'),
              ('running', 'snapshots being taken now'),
              ('readable', '1 when the cluster could list a repository, tagged repository=<its name>'),
              ('snapshots', 'its snapshots, tagged the same'),
              ('failed', 'of those, failed'),
              ('partial', 'partial: some shards missing'),
              ('last_status', "the last one's state: 0 SUCCESS, 1 IN_PROGRESS, 2 PARTIAL, 3 FAILED, 4 other; "
                              "tagged repository and status=<it>"),
              ('last_age_seconds', 'since the last one ended (or started, while it runs)'),
              ('last_duration_seconds', 'how long it took'),
              ('last_failed_shards', 'its shards that failed'),
              ('last_success_age_seconds', 'since the last that succeeded ended; absent when none has'),
              ('repositories_not_shown', 'repositories past the first 20, left out')),
    healthy="last_status 0; last_success_age_seconds within your snapshot schedule.",
    watch="partial above 0; last_duration_seconds growing.",
    act="last_success_age_seconds past your schedule, or absent: no good backup; last_status 3; readable 0: "
        "the repository is gone or broken.",
    sh=r'''first
need '/_snapshot?filter_path=*.type'
cp "$work/body" "$work/repos"
get '/_snapshot/_status?filter_path=snapshots.snapshot'
rc=$?
case $rc in
    0) jq -r '"metric running \([.snapshots[]?] | length)"' "$work/body" || exit 1 ;;
    3) echo "metric running 0" ;;
    *) why "$rc" '/_snapshot/_status' ;;
esac
jq -r '"metric repositories \(keys | length)", "metric repositories_not_shown \([(keys | length) - 20, 0] | max)"' "$work/repos" || exit 1
jq -r 'keys | sort | .[0:20][]' "$work/repos" > "$work/names" || exit 1
while IFS= read -r repo; do
    enc=$(jq -rn --arg r "$repo" '$r | @uri')
    get "/_cat/snapshots/$enc?format=json&h=id,status,start_epoch,end_epoch,failed_shards,total_shards"
    rc=$?
    case $rc in
        0) ;;
        2 | 4 | 5) why "$rc" "/_cat/snapshots/$enc" ;;
        *) jq -rn --arg r "$repo" "$jqlib"'"metric readable 0 repository=\($r | tag)"'; continue ;;
    esac
    jq -r --arg repo "$repo" --argjson now "$now" "$jqlib"'
        def scode: {"SUCCESS": 0, "IN_PROGRESS": 1, "PARTIAL": 2, "FAILED": 3}[.] // 4;
        "repository=\($repo | tag)" as $t |
        map(. + {s: (.start_epoch | n), e: (.end_epoch | n)}) | sort_by(.s) |
        "metric readable 1 \($t)",
        "metric snapshots \(length) \($t)",
        "metric failed \([.[] | select(.status == "FAILED")] | length) \($t)",
        "metric partial \([.[] | select(.status == "PARTIAL")] | length) \($t)",
        (.[-1] // empty |
            "metric last_status \(.status | scode) \($t) status=\(.status | tag)",
            "metric last_age_seconds \(if .e > 0 then $now - .e else $now - .s end | if . < 0 then 0 else . end) \($t)",
            (if .e > 0 then "metric last_duration_seconds \(.e - .s) \($t)" else empty end),
            "metric last_failed_shards \(.failed_shards | n) \($t)"),
        ([.[] | select(.status == "SUCCESS")][-1] // empty | "metric last_success_age_seconds \([$now - .e, 0] | max) \($t)")
    ' "$work/body" || exit 1
done < "$work/names"
exit 0
''',
    ps=r'''Read-First
$repos = Need-Page '/_snapshot?filter_path=*.type'
$p = Get-Page '/_snapshot/_status?filter_path=snapshots.snapshot'
if ($p.State -eq 'ok') { M 'running' (@(@($p.Data.snapshots) | Where-Object { $_ }).Count) }
elseif ($p.State -eq 'unsupported') { M 'running' 0 }
else { Stop-Why $p.State '/_snapshot/_status' }
$names = @(Props $repos | ForEach-Object { $_.Name } | Sort-Object)
M 'repositories' $names.Count
M 'repositories_not_shown' ([Math]::Max($names.Count - 20, 0))
$code = @{ 'SUCCESS' = 0; 'IN_PROGRESS' = 1; 'PARTIAL' = 2; 'FAILED' = 3 }
foreach ($repo in @($names | Select-Object -First 20)) {
    $t = "repository=$(Safe $repo)"
    $path = "/_cat/snapshots/$([Uri]::EscapeDataString($repo))?format=json&h=id,status,start_epoch,end_epoch,failed_shards,total_shards"
    $r = Get-Page $path
    if ($r.State -in 'down', 'forbidden', 'nomaster') { Stop-Why $r.State $path }
    if ($r.State -ne 'ok') { M 'readable' 0 $t; continue }
    $all = @(@($r.Data) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ status = [string]$_.status; s = (N $_.start_epoch); e = (N $_.end_epoch); failed = (N $_.failed_shards) } } | Sort-Object s)
    M 'readable' 1 $t
    M 'snapshots' $all.Count $t
    M 'failed' (@($all | Where-Object { $_.status -eq 'FAILED' }).Count) $t
    M 'partial' (@($all | Where-Object { $_.status -eq 'PARTIAL' }).Count) $t
    if ($all.Count) {
        $l = $all[-1]
        $c = if ($code.ContainsKey($l.status)) { $code[$l.status] } else { 4 }
        M 'last_status' $c "$t status=$(Safe $l.status)"
        $age = if ($l.e -gt 0) { $script:Now - $l.e } else { $script:Now - $l.s }
        M 'last_age_seconds' ([Math]::Max($age, 0)) $t
        if ($l.e -gt 0) { M 'last_duration_seconds' ($l.e - $l.s) $t }
        M 'last_failed_shards' $l.failed $t
    }
    $ok = @($all | Where-Object { $_.status -eq 'SUCCESS' })
    if ($ok.Count) { M 'last_success_age_seconds' ([Math]::Max($script:Now - $ok[-1].e, 0)) $t }
}
exit 0
''')

# ---------------------------------------------------------------- cluster
CLUSTER_STATS = ('/_cluster/stats?filter_path=indices.count,indices.shards.total,indices.shards.primaries,'
                 'indices.shards.replication,indices.docs,indices.store.size_in_bytes,indices.segments.count,'
                 'indices.mappings.total_field_count,indices.mappings.field_types,indices.fielddata.memory_size_in_bytes,'
                 'indices.query_cache.memory_size_in_bytes,nodes.count,nodes.versions,nodes.os.allocated_processors,'
                 'nodes.fs,nodes.ingest.number_of_pipelines,nodes.plugins.name')
job(job='cluster', metric='cluster', when='cron        = 3/5 * * * *', runtime='4m',
    title="a cluster as a whole",
    what="Reports the cluster as a whole, from its own statistics: indices, shards and the replication "
         "they have, documents, size and segments; the fields its mappings define (too many slow every "
         "node); the memory the caches hold; its nodes, by role, and the versions they run; processors; "
         "its data disks, all together; ingest pipelines and plugins.@CLUSTER_EXTRA_WHAT@",
    metrics=M(('up', '1 when @P@ answers, else 0'),
              ('indices', 'indices'),
              ('shards', 'shards, primaries and replicas'),
              ('primary_shards', 'primaries'),
              ('replication', 'replicas a primary, on average'),
              ('docs', 'documents, primaries only'),
              ('deleted_docs', 'documents deleted, not yet merged away'),
              ('store_bytes', 'the size of every shard'),
              ('segments', 'Lucene segments'),
              ('fields', 'fields every mapping defines, together'),
              ('fielddata_bytes', 'memory field data holds'),
              ('query_cache_bytes', 'memory the query cache holds'),
              ('nodes', 'nodes'),
              ('role_nodes', 'nodes with a role, tagged role=<it>'),
              ('versions', 'versions the nodes run'),
              ('version_info', 'always 1, for each version, tagged version=<it>'),
              ('processors', 'processors @P@ uses, every node together'),
              ('fs_total_bytes', 'data disks, every node together'),
              ('fs_free_bytes', 'of those, free'),
              ('fs_used_pct', 'of those, used'),
              ('pipelines', 'ingest pipelines defined'),
              ('plugins', 'plugins installed'),
              *[('@CLUSTER_EXTRA_METRICS@', '')]),
    healthy="versions 1; fields steady.",
    watch="fields climbing fast: a mapping explosion (dynamic fields from data); replication below 1 on a "
          "cluster of more than one node.",
    act="versions above 1 when no upgrade runs: a node left behind.@CLUSTER_EXTRA_ACT@",
    sh=r'''first
need '@CLUSTER_STATS@'
jq -r "$jqlib"'
    "metric indices \(.indices.count | n)",
    "metric shards \(.indices.shards.total | n)",
    "metric primary_shards \(.indices.shards.primaries | n)",
    "metric replication \(.indices.shards.replication | n | r2)",
    "metric docs \(.indices.docs.count | n)",
    "metric deleted_docs \(.indices.docs.deleted | n)",
    "metric store_bytes \(.indices.store.size_in_bytes | n)",
    "metric segments \(.indices.segments.count | n)",
    "metric fields \(.indices.mappings.total_field_count // ([.indices.mappings.field_types[]?.count | n] | add) // 0)",
    "metric fielddata_bytes \(.indices.fielddata.memory_size_in_bytes | n)",
    "metric query_cache_bytes \(.indices.query_cache.memory_size_in_bytes | n)",
    "metric nodes \(.nodes.count.total | n)",
    (.nodes.count | to_entries | sort_by(.key)[] | select(.key != "total") | "metric role_nodes \(.value | n) role=\(.key | tag)"),
    "metric versions \([.nodes.versions[]?] | length)",
    (.nodes.versions[]? | "metric version_info 1 version=\(. | tag)"),
    "metric processors \(.nodes.os.allocated_processors | n)",
    "metric fs_total_bytes \(.nodes.fs.total_in_bytes | n)",
    "metric fs_free_bytes \(.nodes.fs.available_in_bytes | n)",
    "metric fs_used_pct \(pct((.nodes.fs.total_in_bytes | n) - (.nodes.fs.available_in_bytes | n); .nodes.fs.total_in_bytes))",
    "metric pipelines \(.nodes.ingest.number_of_pipelines | n)",
    "metric plugins \([.nodes.plugins[]?.name] | unique | length)"
' "$work/body" || exit 1
@CLUSTER_EXTRA_SH@exit 0
''',
    ps=r'''Read-First
$s = Need-Page '@CLUSTER_STATS@'
$i = $s.indices
M 'indices' $i.count
M 'shards' $i.shards.total
M 'primary_shards' $i.shards.primaries
M 'replication' (R2 $i.shards.replication)
M 'docs' $i.docs.count
M 'deleted_docs' $i.docs.deleted
M 'store_bytes' $i.store.size_in_bytes
M 'segments' $i.segments.count
$fields = $i.mappings.total_field_count
if ($null -eq $fields) { $fields = (@($i.mappings.field_types) | Where-Object { $_ } | ForEach-Object { N $_.count } | Measure-Object -Sum).Sum }
M 'fields' $fields
M 'fielddata_bytes' $i.fielddata.memory_size_in_bytes
M 'query_cache_bytes' $i.query_cache.memory_size_in_bytes
$n = $s.nodes
M 'nodes' $n.count.total
foreach ($r in @(Props $n.count | Where-Object { $_.Name -ne 'total' } | Sort-Object Name)) { M 'role_nodes' $r.Value "role=$(Safe $r.Name)" }
$v = @(@($n.versions) | Where-Object { $_ })
M 'versions' $v.Count
foreach ($x in $v) { Write-Output "metric version_info 1 version=$(Safe $x)" }
M 'processors' $n.os.allocated_processors
M 'fs_total_bytes' $n.fs.total_in_bytes
M 'fs_free_bytes' $n.fs.available_in_bytes
M 'fs_used_pct' (Pct ((N $n.fs.total_in_bytes) - (N $n.fs.available_in_bytes)) $n.fs.total_in_bytes)
M 'pipelines' $n.ingest.number_of_pipelines
M 'plugins' (@(@($n.plugins) | Where-Object { $_ } | ForEach-Object { [string]$_.name } | Sort-Object -Unique).Count)
@CLUSTER_EXTRA_PS@exit 0
''')
for k in ('sh', 'ps'):
    JOBS[-1][k] = JOBS[-1][k].replace('@CLUSTER_STATS@', CLUSTER_STATS)
