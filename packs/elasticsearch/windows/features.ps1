#Requires -Version 5.1

<#
.SYNOPSIS
    features.ps1 - Elasticsearch's transforms, Watcher and enrich, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the Elasticsearch features that run on their own: its transforms
    (how many, started and failed, and each failed one's reason, and each one's
    health), Watcher (on how many nodes it runs, its watches, and the watches
    waiting to run), and the enrich processor's coordinators (lookups queued and
    in flight) and the enrich policies being executed. A feature that is off, or
    that this user may not read, prints nothing. It only reads: it changes
    nothing in the cluster.

    Reads Elasticsearch at ELASTICSEARCH_URL (default https://localhost:9200),
    as ELASTICSEARCH_USER with the password in ELASTICSEARCH_PASSWORD (a
    secret), or with an API key in ELASTICSEARCH_API_KEY (a secret: the encoded
    form Elasticsearch gives). The login goes in a header made here, never on a
    command line.
    It speaks HTTP itself, with .NET: nothing to install. Over https, the
    certificate is checked against Windows' trusted CAs, or
    ELASTICSEARCH_CACERT, a CA file, and against the server's name. What the
    scripts share is in _elasticsearch.ps1, beside this one.

    Metrics:
      up                    1 when Elasticsearch answers, else 0
      transforms            transforms
      transforms_started    of those, started or indexing
      transforms_failed     failed
      transform_failed      always 1, for each failed transform, tagged
                            transform=<its id> and reason=<why>
      transform_health      a transform's health: 0 green, 1 yellow, 2 red, 3
                            unknown; tagged transform
      transforms_not_shown  transforms past the first 100, left out
      watcher_nodes         nodes Watcher runs on
      watcher_started       of those, nodes where it is started
      watches               watches
      watches_queued        watch runs waiting for a thread
      enrich_queued         enrich lookups queued on the coordinators
      enrich_in_flight      enrich lookups in flight
      enrich_executing      enrich policies being executed

    Example output (the rest are in the same form):
      metric up 1
      metric transforms 1
      metric transforms_started 0
      metric transforms_failed 0
      metric watcher_nodes 3
      metric watcher_started 3
      metric enrich_queued 0

    Reading the results (starting points: tune them to the cluster):
      Healthy  transforms_failed 0; watcher_started equal to watcher_nodes;
               watches_queued near 0.
      Watch    transform_health 1; enrich_queued rising: ingest waits for enrich
               lookups.
      Act      transforms_failed above 0: the transform stopped (the reason says
               why); watcher_started 0: no watch runs, and no alert of Watcher's
               fires.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, Elasticsearch up or down; 1 if a setting is wrong,
      the login is refused, this user may not read what the job needs, or the
      address is not Elasticsearch
#>

$Job = 'features'
. (Join-Path $PSScriptRoot '_elasticsearch.ps1')

Read-First
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
