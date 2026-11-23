#Requires -Version 5.1

<#
.SYNOPSIS
    cluster.ps1 - a cluster as a whole, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the cluster as a whole, from its own statistics: indices, shards and
    the replication they have, documents, size and segments; the fields its
    mappings define (too many slow every node); the memory the caches hold; its
    nodes, by role, and the versions they run; processors; its data disks, all
    together; ingest pipelines and plugins. And its license: its type and state,
    and the days until it expires. It only reads: it changes nothing in the
    cluster.

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
      indices               indices
      shards                shards, primaries and replicas
      primary_shards        primaries
      replication           replicas a primary, on average
      docs                  documents, primaries only
      deleted_docs          documents deleted, not yet merged away
      store_bytes           the size of every shard
      segments              Lucene segments
      fields                fields every mapping defines, together
      fielddata_bytes       memory field data holds
      query_cache_bytes     memory the query cache holds
      nodes                 nodes
      role_nodes            nodes with a role, tagged role=<it>
      versions              versions the nodes run
      version_info          always 1, for each version, tagged version=<it>
      processors            processors Elasticsearch uses, every node together
      fs_total_bytes        data disks, every node together
      fs_free_bytes         of those, free
      fs_used_pct           of those, used
      pipelines             ingest pipelines defined
      plugins               plugins installed
      license               always 1, tagged type=<basic, trial, platinum,
                            enterprise...> and status=<active, expired...>
      license_expires_days  days until the license expires, when it does

    Example output (the rest are in the same form):
      metric up 1
      metric indices 13
      metric shards 25
      metric fields 92
      metric nodes 3
      metric role_nodes 3 role=data_hot
      metric versions 1
      metric license 1 type=basic status=active

    Reading the results (starting points: tune them to the cluster):
      Healthy  versions 1; fields steady.
      Watch    fields climbing fast: a mapping explosion (dynamic fields from
               data); replication below 1 on a cluster of more than one node.
      Act      versions above 1 when no upgrade runs: a node left behind.
               license_expires_days below 30: renew it.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, Elasticsearch up or down; 1 if a setting is wrong,
      the login is refused, this user may not read what the job needs, or the
      address is not Elasticsearch
#>

$Job = 'cluster'
. (Join-Path $PSScriptRoot '_elasticsearch.ps1')

Read-First
$s = Need-Page '/_cluster/stats?filter_path=indices.count,indices.shards.total,indices.shards.primaries,indices.shards.replication,indices.docs,indices.store.size_in_bytes,indices.segments.count,indices.mappings.total_field_count,indices.mappings.field_types,indices.fielddata.memory_size_in_bytes,indices.query_cache.memory_size_in_bytes,nodes.count,nodes.versions,nodes.os.allocated_processors,nodes.fs,nodes.ingest.number_of_pipelines,nodes.plugins.name'
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
$p = Get-Page '/_license'
if ($p.State -eq 'ok') {
    $l = $p.Data.license
    Write-Output "metric license 1 type=$(Safe $l.type) status=$(Safe $l.status)"
    if ($l.expiry_date_in_millis) { M 'license_expires_days' ([Math]::Floor(((N $l.expiry_date_in_millis) / 1000 - $script:Now) / 86400)) }
} elseif ($p.State -notin 'unsupported', 'forbidden') { Stop-Why $p.State '/_license' }
exit 0
