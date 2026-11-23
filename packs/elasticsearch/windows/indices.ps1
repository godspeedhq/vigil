#Requires -Version 5.1

<#
.SYNOPSIS
    indices.ps1 - the indices of a cluster, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the cluster's indices, hidden ones and data streams' backing indices
    too: how many, open and closed, green, yellow and red, their documents and
    size, and those with a block (written to no more, or read-only, as
    Elasticsearch leaves them when a disk fills). Then each index, the worst
    first (red, yellow, blocked, closed, then the largest): its health,
    documents, deleted documents, size, shards, replicas, age and blocks. It
    only reads: it changes nothing in the cluster.

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
      up                         1 when Elasticsearch answers, else 0
      indices                    indices
      open                       of those, open
      closed                     closed
      green                      green: every shard assigned
      yellow                     yellow: a replica unassigned
      red                        red: a primary unassigned
      hidden                     indices whose names start with a dot (hidden,
                                 and data streams' backing indices)
      docs                       documents in every index, primaries only
      deleted_docs               documents deleted but not yet merged away
      store_bytes                the size of every index, replicas too
      primary_store_bytes        the size of the primaries alone
      blocked                    indices with a block of any kind
      write_blocked              indices that take no writes: a write, read_only
                                 or read_only_allow_delete block
      health                     an index's health: 0 green, 1 yellow, 2 red;
                                 tagged index=<its name>
      is_open                    1 when it is open, tagged the same
      index_docs                 its documents, primaries only
      deleted_pct                its deleted documents, as a percentage of all
      index_store_bytes          its size, replicas too
      index_primary_store_bytes  its primaries' size
      primaries                  its primary shards
      replicas                   its replicas of each
      age_days                   days since it was created
      block                      always 1, for each block it has, tagged
                                 index=<its name> and block=<the block>
      indices_not_shown          indices past the first 100, the worst first,
                                 left out

    Example output (the rest are in the same form):
      metric up 1
      metric indices 13
      metric red 1
      metric yellow 1
      metric write_blocked 2
      metric health 2 index=archive-red
      metric block 1 index=blocked block=write

    Reading the results (starting points: tune them to the cluster):
      Healthy  red 0; yellow 0 (on a cluster of more than one node);
               write_blocked 0.
      Watch    deleted_pct above 30 on a large index: space held by deleted
               documents until merges; an index far larger than the rest.
      Act      red above 0: data unreachable (the shards job says why);
               write_blocked above 0: writes to it fail, often after a disk
               passed the flood stage (free space, then clear the block).

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, Elasticsearch up or down; 1 if a setting is wrong,
      the login is refused, this user may not read what the job needs, or the
      address is not Elasticsearch
#>

$Job = 'indices'
. (Join-Path $PSScriptRoot '_elasticsearch.ps1')

Read-First
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
