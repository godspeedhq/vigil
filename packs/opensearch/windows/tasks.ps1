#Requires -Version 5.1

<#
.SYNOPSIS
    tasks.ps1 - the tasks a cluster runs, and the cluster tasks waiting, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the tasks running in the cluster, as OpenSearch lists them
    (searches, bulk writes, reindexing, updates and deletes by query, snapshots,
    force merges...): how many, the longest, those running past a minute, those
    cancelled but still running, and how many of each kind. Then the 20 longest,
    with how long each has run; for reindexing and by-query work, what it reads
    and writes (never a search's query). Then the cluster tasks waiting for the
    elected cluster manager, the oldest first. The task list itself, persistent
    tasks and a task's children are left out. It only reads: it changes nothing
    in the cluster.

    Reads OpenSearch at OPENSEARCH_URL (default https://localhost:9200), as
    OPENSEARCH_USER with the password in OPENSEARCH_PASSWORD (a secret). The
    login goes in a header made here, never on a command line.
    It speaks HTTP itself, with .NET: nothing to install. Over https, the
    certificate is checked against Windows' trusted CAs, or OPENSEARCH_CACERT, a
    CA file, and against the server's name. What the scripts share is in
    _opensearch.ps1, beside this one.

    Metrics:
      up                 1 when OpenSearch answers, else 0
      tasks              tasks running
      longest_seconds    how long the longest has run
      over_60s           tasks running for more than a minute
      cancellable        tasks that may be cancelled
      cancelled          tasks cancelled but still running
      searches           searches running
      action_tasks       tasks of a kind, tagged action=<it> (the 10 most)
      running_seconds    how long a task has run, tagged action=<it>,
                         node=<where it runs> and what=<for reindexing and
                         by-query work, what it reads and writes; else none>
      tasks_not_shown    tasks past the 20 longest, left out
      pending            cluster tasks waiting for the cluster manager
      pending_oldest_ms  how long the oldest has waited
      pending_ms         how long one has waited, tagged priority=<it> and
                         source=<what asked for it> (the 20 oldest)

    Example output (the rest are in the same form):
      metric up 1
      metric tasks 1
      metric longest_seconds 46
      metric action_tasks 1 action=indices:data/write/reindex
      metric running_seconds 46 action=indices:data/write/reindex node=os310a what=reindex_from__logs-ok__to__logs-slow_

    Reading the results (starting points: tune them to the cluster):
      Healthy  over_60s 0, but for reindexing, snapshots and force merges you
               started; pending 0.
      Watch    searches running for minutes: an expensive query (searches, and
               the running_seconds of indices:data/read/search); cancelled above
               0 for long.
      Act      pending above 0 and pending_oldest_ms in seconds: the cluster
               manager falls behind, and mappings, settings and shard moves
               wait; a search running for many minutes, holding memory and
               threads.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, OpenSearch up or down; 1 if a setting is wrong, the
      login is refused, this user may not read what the job needs, or the
      address is not OpenSearch
#>

$Job = 'tasks'
. (Join-Path $PSScriptRoot '_opensearch.ps1')

Read-First
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
