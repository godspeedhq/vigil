#Requires -Version 5.1

<#
.SYNOPSIS
    thread_pools.ps1 - the thread pools of a cluster's nodes, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each node's thread pools, the queues of work Elasticsearch keeps for
    writes, searches, gets and its own housekeeping: threads busy, work waiting
    against the queue's size, and work refused when the queue was full (a client
    sees HTTP 429). The write, search and get pools are always reported; the
    others when they have work busy, waiting or refused. It only reads: it
    changes nothing in the cluster.

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
      up               1 when Elasticsearch answers, else 0
      rejected_total   work refused by every pool of every node, since each
                       started (a counter)
      queued_total     work waiting in every pool now
      active_total     threads busy in every pool now
      active           a pool's threads busy, tagged node=<its name> and
                       pool=<the pool>
      queue            its work waiting, tagged the same
      queue_pct        queue, as a percentage of the queue's size, when it has
                       one
      rejected         its work refused, since the node started (a counter)
      completed        its work done (a counter)
      threads          its threads
      largest          the most threads it has had at once
      pools_not_shown  pools past the first 200 (refusing first), left out

    Example output (the rest are in the same form):
      metric up 1
      metric rejected_total 219
      metric queued_total 0
      metric rejected 113 node=es95b pool=write
      metric rejected 106 node=es95c pool=write
      metric queue 0 node=es95b pool=write
      metric completed 201 node=es95b pool=write

    Reading the results (starting points: tune them to the cluster):
      Healthy  rejected_total flat; queue near 0 most of the time.
      Watch    queue_pct above 50 on the write or search pool: the node falls
               behind.
      Act      rejected rising on write: writes refused, clients see HTTP 429
               (bulk requests partly fail); on search: searches refused.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, Elasticsearch up or down; 1 if a setting is wrong,
      the login is refused, this user may not read what the job needs, or the
      address is not Elasticsearch
#>

$Job = 'thread_pools'
. (Join-Path $PSScriptRoot '_elasticsearch.ps1')

Read-First
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
