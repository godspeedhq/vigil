# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The jobs of one pack alone: Elasticsearch's lifecycle (ILM, SLM, data
stream lifecycle) and features (transforms, Watcher, enrich); OpenSearch's
backpressure (tools/search/jobs.py says how they are written)."""
from jobs import job, M

# ---------------------------------------------------------------- lifecycle (Elasticsearch)
ILM_EXPLAIN = ('/*,.*/_ilm/explain?only_managed=true&filter_path=indices.*.index,indices.*.policy,indices.*.phase,'
               'indices.*.action,indices.*.step,indices.*.failed_step,indices.*.step_info.reason,'
               'indices.*.step_info.type,indices.*.failed_step_retry_count,indices.*.step_time_millis')
job(job='lifecycle', metric='lifecycle', when='cron        = 2/5 * * * *', runtime='4m', only='es',
    title="Elasticsearch's lifecycles: ILM, SLM and data streams'",
    what="Reports Elasticsearch's index lifecycle management (ILM): whether it runs, the indices it manages "
         "and in which phase, those whose step failed (with the step and Elasticsearch's reason) and those "
         "on one step for more than a day. Then snapshot lifecycle management (SLM): whether it runs, and "
         "each policy's last success and failure, whether it is failing now and why, its snapshots taken "
         "and failed, and its next run. Then the data stream lifecycle: the data streams it manages, and "
         "their backing indices in error.",
    metrics=M(('up', '1 when Elasticsearch answers, else 0'),
              ('ilm_running', '1 when ILM runs, tagged mode=<RUNNING, STOPPING or STOPPED>'),
              ('ilm_managed', 'indices ILM manages'),
              ('ilm_errors', 'of those, with a failed step'),
              ('ilm_stuck', 'on one step (not the wait for a rollover) for more than a day'),
              ('ilm_in_phase', 'indices in a phase, tagged phase=<hot, warm, cold, frozen or delete>'),
              ('ilm_error', 'always 1, for each index whose step failed, tagged index, policy, step=<the step '
                            'that failed> and reason=<Elasticsearch\'s reason> (the first 100)'),
              ('ilm_error_retries', 'times its step was retried, tagged index'),
              ('ilm_step_age_seconds', 'how long a stuck index has been on its step, tagged index and step (the 20 longest)'),
              ('slm_running', '1 when SLM runs, tagged mode=<it>'),
              ('slm_policies', 'SLM policies'),
              ('slm_failing', '1 when a policy\'s last run failed, tagged policy=<its name> and reason=<why>'),
              ('slm_last_success_age_seconds', 'since its last snapshot that succeeded, tagged policy'),
              ('slm_last_failure_age_seconds', 'since its last failure, tagged policy'),
              ('slm_taken', 'snapshots it has taken (a counter), tagged policy'),
              ('slm_failed', 'snapshots it failed to take (a counter), tagged policy'),
              ('slm_next_seconds', 'until its next run, tagged policy'),
              ('dlm_data_streams', 'data streams the data stream lifecycle manages (8.11 and later)'),
              ('dlm_backing_indices', 'their backing indices'),
              ('dlm_errors', 'of those, in error'),
              ('dlm_error', "a data stream's backing indices in error, tagged data_stream=<its name>")),
    healthy="ilm_running and slm_running 1; ilm_errors 0; slm_failing 0 everywhere; dlm_errors 0.",
    watch="ilm_stuck above 0: an index waits on a step (a shrink with no node to go to, a replica that "
          "will not allocate); slm_last_success_age_seconds past the policy's schedule.",
    act="ilm_errors above 0: indices not rolled over, not deleted (disks fill); slm_failing 1: no new "
        "snapshots (the reason says why); ilm_running 0 left after maintenance.",
    sh=r'''first
get '/_ilm/status'
rc=$?
case $rc in
    0) jq -r "$jqlib"'"metric ilm_running \(if .operation_mode == "RUNNING" then 1 else 0 end) mode=\(.operation_mode | tag)"' "$work/body" || exit 1 ;;
    3) ;;
    *) why "$rc" '/_ilm/status' ;;
esac
get '@ILM_EXPLAIN@'
rc=$?
case $rc in
    0) jq -r --argjson now "$now" "$jqlib"'
        [.indices[]?] |
        "metric ilm_managed \(length)",
        "metric ilm_errors \([.[] | select(.step == "ERROR")] | length)",
        ([.[] | select(.step != "ERROR" and .step != "complete" and .step != "check-rollover-ready" and .step_time_millis != null)
            | . + {age: ($now - (.step_time_millis / 1000) | floor)} | select(.age > 86400)] | sort_by(-.age, .index) |
            "metric ilm_stuck \(length)",
            (.[0:20][] | "metric ilm_step_age_seconds \(.age) index=\(.index | tag) step=\(.step | tag)")),
        (group_by(.phase // "none")[] | "metric ilm_in_phase \(length) phase=\(.[0].phase // "none" | tag)"),
        ([.[] | select(.step == "ERROR")] | sort_by(.index) | .[0:100][] | "index=\(.index | tag)" as $t |
            "metric ilm_error 1 \($t) policy=\(.policy | tag) step=\(.failed_step | tag) reason=\(.step_info.reason // .step_info.type // "" | tag)",
            "metric ilm_error_retries \(.failed_step_retry_count | n) \($t)")
    ' "$work/body" || exit 1 ;;
    3) ;;
    *) why "$rc" '/_ilm/explain' ;;
esac
get '/_slm/status'
rc=$?
case $rc in
    0) jq -r "$jqlib"'"metric slm_running \(if .operation_mode == "RUNNING" then 1 else 0 end) mode=\(.operation_mode | tag)"' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_slm/status' ;;
esac
get '/_slm/policy'
rc=$?
case $rc in
    0) jq -r --argjson now "$now" "$jqlib"'
        "metric slm_policies \(length)",
        (to_entries | sort_by(.key)[] | "policy=\(.key | tag)" as $t | .value |
            (.last_success.time // .last_success.start_time) as $ok | .last_failure.time as $bad |
            "metric slm_failing \(if $bad != null and ($ok == null or $bad > $ok) then 1 else 0 end) \($t) reason=\(if $bad != null and ($ok == null or $bad > $ok) then (.last_failure.details // "" | (fromjson? | .reason) // . | tag) else "none" end)",
            (if $ok then "metric slm_last_success_age_seconds \([$now - $ok / 1000 | floor, 0] | max) \($t)" else empty end),
            (if $bad then "metric slm_last_failure_age_seconds \([$now - $bad / 1000 | floor, 0] | max) \($t)" else empty end),
            "metric slm_taken \(.stats.snapshots_taken | n) \($t)",
            "metric slm_failed \(.stats.snapshots_failed | n) \($t)",
            (if .next_execution_millis then "metric slm_next_seconds \([.next_execution_millis / 1000 - $now | floor, 0] | max) \($t)" else empty end))
    ' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_slm/policy' ;;
esac
get '/_lifecycle/stats'
rc=$?
case $rc in
    0) jq -r "$jqlib"'
        "metric dlm_data_streams \(.data_stream_count | n)",
        "metric dlm_backing_indices \([.data_streams[]?.backing_indices_in_total | n] | add // 0)",
        "metric dlm_errors \([.data_streams[]?.backing_indices_in_error | n] | add // 0)",
        ([.data_streams[]? | select((.backing_indices_in_error | n) > 0)] | sort_by(.name)[] | "metric dlm_error \(.backing_indices_in_error) data_stream=\(.name | tag)")
    ' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_lifecycle/stats' ;;
esac
exit 0
''',
    ps=r'''Read-First
$p = Get-Page '/_ilm/status'
if ($p.State -eq 'ok') { M 'ilm_running' $(if ($p.Data.operation_mode -eq 'RUNNING') { 1 } else { 0 }) "mode=$(Safe $p.Data.operation_mode)" }
elseif ($p.State -ne 'unsupported') { Stop-Why $p.State '/_ilm/status' }
$p = Get-Page '@ILM_EXPLAIN@'
if ($p.State -eq 'ok') {
    $all = @(Values $p.Data.indices)
    M 'ilm_managed' $all.Count
    $err = @($all | Where-Object { $_.step -eq 'ERROR' } | Sort-Object { [string]$_.index })
    M 'ilm_errors' $err.Count
    $stuck = @($all | Where-Object { $_.step -notin 'ERROR', 'complete', 'check-rollover-ready' -and $null -ne $_.step_time_millis } |
        ForEach-Object { [pscustomobject]@{ index = [string]$_.index; step = $_.step; age = [Math]::Floor($script:Now - (N $_.step_time_millis) / 1000) } } |
        Where-Object { $_.age -gt 86400 } | Sort-Object @{ Expression = { $_.age }; Descending = $true }, @{ Expression = { $_.index } })
    M 'ilm_stuck' $stuck.Count
    foreach ($x in @($stuck | Select-Object -First 20)) { M 'ilm_step_age_seconds' $x.age "index=$(Safe $x.index) step=$(Safe $x.step)" }
    foreach ($g in @($all | Group-Object { if ($_.phase) { [string]$_.phase } else { 'none' } } | Sort-Object Name)) { M 'ilm_in_phase' $g.Count "phase=$(Safe $g.Name)" }
    foreach ($x in @($err | Select-Object -First 100)) {
        $t = "index=$(Safe $x.index)"
        $why = if ($x.step_info.reason) { $x.step_info.reason } elseif ($x.step_info.type) { $x.step_info.type } else { '' }
        Write-Output "metric ilm_error 1 $t policy=$(Safe $x.policy) step=$(Safe $x.failed_step) reason=$(Safe $why)"
        M 'ilm_error_retries' $x.failed_step_retry_count $t
    }
} elseif ($p.State -ne 'unsupported') { Stop-Why $p.State '/_ilm/explain' }
$p = Get-Page '/_slm/status'
if ($p.State -eq 'ok') { M 'slm_running' $(if ($p.Data.operation_mode -eq 'RUNNING') { 1 } else { 0 }) "mode=$(Safe $p.Data.operation_mode)" }
elseif ($p.State -notin 'unsupported', 'forbidden') { Stop-Why $p.State '/_slm/status' }
$p = Get-Page '/_slm/policy'
if ($p.State -eq 'ok') {
    $pol = @(Props $p.Data | Sort-Object Name)
    M 'slm_policies' $pol.Count
    foreach ($e in $pol) {
        $t = "policy=$(Safe $e.Name)"
        $v = $e.Value
        $ok = if ($v.last_success.time) { N $v.last_success.time } elseif ($v.last_success.start_time) { N $v.last_success.start_time } else { $null }
        $bad = if ($v.last_failure.time) { N $v.last_failure.time } else { $null }
        $failing = ($null -ne $bad -and ($null -eq $ok -or $bad -gt $ok))
        $reason = 'none'
        if ($failing) {
            $d = [string]$v.last_failure.details
            try { $r = ($d | ConvertFrom-Json).reason; if ($r) { $d = $r } } catch { }
            $reason = Safe $d
        }
        M 'slm_failing' $(if ($failing) { 1 } else { 0 }) "$t reason=$reason"
        if ($null -ne $ok) { M 'slm_last_success_age_seconds' ([Math]::Max([Math]::Floor($script:Now - $ok / 1000), 0)) $t }
        if ($null -ne $bad) { M 'slm_last_failure_age_seconds' ([Math]::Max([Math]::Floor($script:Now - $bad / 1000), 0)) $t }
        M 'slm_taken' $v.stats.snapshots_taken $t
        M 'slm_failed' $v.stats.snapshots_failed $t
        if ($v.next_execution_millis) { M 'slm_next_seconds' ([Math]::Max([Math]::Floor((N $v.next_execution_millis) / 1000 - $script:Now), 0)) $t }
    }
} elseif ($p.State -notin 'unsupported', 'forbidden') { Stop-Why $p.State '/_slm/policy' }
$p = Get-Page '/_lifecycle/stats'
if ($p.State -eq 'ok') {
    $ds = @(@($p.Data.data_streams) | Where-Object { $_ })
    M 'dlm_data_streams' $p.Data.data_stream_count
    M 'dlm_backing_indices' (($ds | ForEach-Object { N $_.backing_indices_in_total } | Measure-Object -Sum).Sum)
    M 'dlm_errors' (($ds | ForEach-Object { N $_.backing_indices_in_error } | Measure-Object -Sum).Sum)
    foreach ($x in @($ds | Where-Object { (N $_.backing_indices_in_error) -gt 0 } | Sort-Object { [string]$_.name })) { M 'dlm_error' $x.backing_indices_in_error "data_stream=$(Safe $x.name)" }
} elseif ($p.State -notin 'unsupported', 'forbidden') { Stop-Why $p.State '/_lifecycle/stats' }
exit 0
'''.replace('@ILM_EXPLAIN@', ILM_EXPLAIN))
from jobs import JOBS
JOBS[-1]['sh'] = JOBS[-1]['sh'].replace('@ILM_EXPLAIN@', ILM_EXPLAIN)

# ---------------------------------------------------------------- features (Elasticsearch)
job(job='features', metric='features', when='cron        = 4/5 * * * *', runtime='4m', only='es',
    title="Elasticsearch's transforms, Watcher and enrich",
    what="Reports the Elasticsearch features that run on their own: its transforms (how many, started and "
         "failed, and each failed one's reason, and each one's health), Watcher (on how many nodes it "
         "runs, its watches, and the watches waiting to run), and the enrich processor's coordinators "
         "(lookups queued and in flight) and the enrich policies being executed. A feature that is off, "
         "or that this user may not read, prints nothing.",
    metrics=M(('up', '1 when Elasticsearch answers, else 0'),
              ('transforms', 'transforms'),
              ('transforms_started', 'of those, started or indexing'),
              ('transforms_failed', 'failed'),
              ('transform_failed', 'always 1, for each failed transform, tagged transform=<its id> and reason=<why>'),
              ('transform_health', "a transform's health: 0 green, 1 yellow, 2 red, 3 unknown; tagged transform"),
              ('transforms_not_shown', 'transforms past the first 100, left out'),
              ('watcher_nodes', 'nodes Watcher runs on'),
              ('watcher_started', 'of those, nodes where it is started'),
              ('watches', 'watches'),
              ('watches_queued', 'watch runs waiting for a thread'),
              ('enrich_queued', 'enrich lookups queued on the coordinators'),
              ('enrich_in_flight', 'enrich lookups in flight'),
              ('enrich_executing', 'enrich policies being executed')),
    healthy="transforms_failed 0; watcher_started equal to watcher_nodes; watches_queued near 0.",
    watch="transform_health 1; enrich_queued rising: ingest waits for enrich lookups.",
    act="transforms_failed above 0: the transform stopped (the reason says why); watcher_started 0: no "
        "watch runs, and no alert of Watcher's fires.",
    sh=r'''first
get '/_transform/_stats?size=1000&filter_path=count,transforms.id,transforms.state,transforms.reason,transforms.health.status'
rc=$?
case $rc in
    0) jq -r "$jqlib"'
        [.transforms[]?] | sort_by(.id) |
        "metric transforms \(length)",
        "metric transforms_started \([.[] | select(.state == "started" or .state == "indexing")] | length)",
        "metric transforms_failed \([.[] | select(.state == "failed")] | length)",
        (.[0:100][] | "transform=\(.id | tag)" as $t |
            (if .state == "failed" then "metric transform_failed 1 \($t) reason=\(.reason // "" | tag)" else empty end),
            (if .health.status then "metric transform_health \(.health.status | code) \($t)" else empty end)),
        "metric transforms_not_shown \([length - 100, 0] | max)"
    ' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_transform/_stats' ;;
esac
get '/_watcher/stats?filter_path=stats.watcher_state,stats.watch_count,stats.execution_thread_pool'
rc=$?
case $rc in
    0) jq -r "$jqlib"'
        [.stats[]?] |
        "metric watcher_nodes \(length)",
        "metric watcher_started \([.[] | select(.watcher_state == "started")] | length)",
        "metric watches \([.[].watch_count | n] | add // 0)",
        "metric watches_queued \([.[].execution_thread_pool.queue_size | n] | add // 0)"
    ' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_watcher/stats' ;;
esac
get '/_enrich/_stats'
rc=$?
case $rc in
    0) jq -r "$jqlib"'
        "metric enrich_queued \([.coordinator_stats[]?.queue_size | n] | add // 0)",
        "metric enrich_in_flight \([.coordinator_stats[]?.remote_requests_current | n] | add // 0)",
        "metric enrich_executing \([.executing_policies[]?] | length)"
    ' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_enrich/_stats' ;;
esac
exit 0
''',
    ps=r'''Read-First
$p = Get-Page '/_transform/_stats?size=1000&filter_path=count,transforms.id,transforms.state,transforms.reason,transforms.health.status'
if ($p.State -eq 'ok') {
    $all = @(@($p.Data.transforms) | Where-Object { $_ } | Sort-Object { [string]$_.id })
    M 'transforms' $all.Count
    M 'transforms_started' (@($all | Where-Object { $_.state -in 'started', 'indexing' }).Count)
    M 'transforms_failed' (@($all | Where-Object { $_.state -eq 'failed' }).Count)
    foreach ($x in @($all | Select-Object -First 100)) {
        $t = "transform=$(Safe $x.id)"
        if ($x.state -eq 'failed') { Write-Output "metric transform_failed 1 $t reason=$(Safe $x.reason)" }
        if ($x.health.status) { M 'transform_health' (Code $x.health.status) $t }
    }
    M 'transforms_not_shown' ([Math]::Max($all.Count - 100, 0))
} elseif ($p.State -notin 'unsupported', 'forbidden') { Stop-Why $p.State '/_transform/_stats' }
$p = Get-Page '/_watcher/stats?filter_path=stats.watcher_state,stats.watch_count,stats.execution_thread_pool'
if ($p.State -eq 'ok') {
    $st = @(@($p.Data.stats) | Where-Object { $_ })
    M 'watcher_nodes' $st.Count
    M 'watcher_started' (@($st | Where-Object { $_.watcher_state -eq 'started' }).Count)
    M 'watches' (($st | ForEach-Object { N $_.watch_count } | Measure-Object -Sum).Sum)
    M 'watches_queued' (($st | ForEach-Object { N $_.execution_thread_pool.queue_size } | Measure-Object -Sum).Sum)
} elseif ($p.State -notin 'unsupported', 'forbidden') { Stop-Why $p.State '/_watcher/stats' }
$p = Get-Page '/_enrich/_stats'
if ($p.State -eq 'ok') {
    $co = @(@($p.Data.coordinator_stats) | Where-Object { $_ })
    M 'enrich_queued' (($co | ForEach-Object { N $_.queue_size } | Measure-Object -Sum).Sum)
    M 'enrich_in_flight' (($co | ForEach-Object { N $_.remote_requests_current } | Measure-Object -Sum).Sum)
    M 'enrich_executing' (@(@($p.Data.executing_policies) | Where-Object { $_ }).Count)
} elseif ($p.State -notin 'unsupported', 'forbidden') { Stop-Why $p.State '/_enrich/_stats' }
exit 0
''')

# ---------------------------------------------------------------- backpressure (OpenSearch)
job(job='backpressure', metric='backpressure', when='run_every   = 1m', runtime='50s', only='os',
    title="OpenSearch's backpressure and admission control",
    what="Reports what OpenSearch does on each node to protect itself under load: search backpressure "
         "(its mode, and the searches and shard searches it cancelled for CPU, time or heap), shard "
         "indexing pressure (whether it is on and enforced, and the writes it refused), and admission "
         "control (the requests it refused for the node's CPU, I/O or memory), each tagged by node.",
    metrics=M(('up', '1 when OpenSearch answers, else 0'),
              ('search_mode', 'search backpressure: 0 disabled, 1 monitor only, 2 enforced; tagged node=<its name> and mode=<it>'),
              ('search_cancellations', 'searches it cancelled, every kind (a counter), tagged node'),
              ('search_limit_reached', 'times it would have cancelled but reached its limit (a counter), tagged node'),
              ('search_cancelled_for', 'shard searches cancelled for one reason (a counter), tagged node and '
                                       'reason=<cpu_usage, elapsed_time or heap_usage>'),
              ('shard_indexing_enabled', '1 when shard indexing pressure is on, tagged node'),
              ('shard_indexing_enforced', '1 when it is enforced, not only counted, tagged node'),
              ('shard_indexing_rejections', 'writes it refused (or, not enforced, would have), tagged node and limit=<which>'),
              ('admission_rejections', 'requests admission control refused (a counter), tagged node, '
                                       'controller=<cpu, io or native memory> and action=<indexing or search>'),
              ('nodes_not_shown', 'nodes past the first 100, by name, left out')),
    healthy="search_cancellations and admission_rejections flat.",
    watch="search_cancellations rising in monitor-only mode: enforced, those searches would fail; "
          "shard_indexing_rejections rising while not enforced.",
    act="search_cancellations rising in enforced mode: searches fail; admission_rejections rising: the node "
        "refuses requests for its CPU or I/O.",
    sh=r'''first
need '/_nodes/stats/search_backpressure,shard_indexing_pressure,admission_control?filter_path=nodes.*.name,nodes.*.search_backpressure.mode,nodes.*.search_backpressure.search_task.cancellation_stats,nodes.*.search_backpressure.search_shard_task.cancellation_stats,nodes.*.search_backpressure.search_shard_task.resource_tracker_stats.*.cancellation_count,nodes.*.shard_indexing_pressure.enabled,nodes.*.shard_indexing_pressure.enforced,nodes.*.shard_indexing_pressure.total_rejections_breakup,nodes.*.shard_indexing_pressure.total_rejections_breakup_shadow_mode,nodes.*.admission_control'
jq -r "$jqlib"'
    [.nodes[]] | sort_by(.name) |
    (.[0:100][] | "node=\(.name | tag)" as $t |
        (.search_backpressure // empty |
            "metric search_mode \({"disabled": 0, "monitor_only": 1, "enforced": 2}[.mode] // 0) \($t) mode=\(.mode | tag)",
            "metric search_cancellations \((.search_task.cancellation_stats.cancellation_count | n) + (.search_shard_task.cancellation_stats.cancellation_count | n)) \($t)",
            "metric search_limit_reached \((.search_task.cancellation_stats.cancellation_limit_reached_count | n) + (.search_shard_task.cancellation_stats.cancellation_limit_reached_count | n)) \($t)",
            (.search_shard_task.resource_tracker_stats // {} | to_entries | sort_by(.key)[] | select(.value.cancellation_count != null) |
                "metric search_cancelled_for \(.value.cancellation_count | n) \($t) reason=\(.key | sub("_tracker$"; "") | tag)")),
        (.shard_indexing_pressure // empty |
            "metric shard_indexing_enabled \(.enabled | n) \($t)",
            "metric shard_indexing_enforced \(.enforced | n) \($t)",
            ((if .enforced then .total_rejections_breakup else .total_rejections_breakup_shadow_mode end) // {} | to_entries | sort_by(.key)[] |
                "metric shard_indexing_rejections \(.value | n) \($t) limit=\(.key | tag)")),
        (.admission_control // {} | to_entries | sort_by(.key)[] | .key as $c |
            (.value.transport.rejection_count // {}) | to_entries | sort_by(.key)[] |
            "metric admission_rejections \(.value | n) \($t) controller=\($c | sub("^global_"; "") | sub("_usage$"; "") | tag) action=\(.key | tag)")),
    "metric nodes_not_shown \([length - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
''',
    ps=r'''Read-First
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
''')
