#Requires -Version 5.1

<#
.SYNOPSIS
    operations.ps1 - the work each node of a cluster does, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports, for each node, what its shards hold and the work it does, as
    counters to make rates of: documents indexed and deleted, and how long it
    took; search queries and fetches, and how long; gets; merges, refreshes and
    flushes; the query, request and field data caches, their hits, misses and
    evictions; segments; and the translog. The rate of index_total is the
    indexing rate; query_time_ms over query_total, the average query time. It
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
      up                          1 when Elasticsearch answers, else 0
      docs                        documents in the node's shards, tagged
                                  node=<its name>
      store_bytes                 the size of the node's shards
      index_total                 documents indexed (a counter)
      index_time_ms               time spent indexing (a counter)
      index_current               documents being indexed now
      index_failed                documents that failed to index (a counter)
      delete_total                documents deleted (a counter)
      index_throttle_ms           time indexing was throttled for merges (a
                                  counter)
      query_total                 search queries, each shard counted (a counter)
      query_time_ms               time spent in them (a counter)
      query_current               queries running now
      fetch_total                 fetches of search hits (a counter)
      fetch_time_ms               time spent in them (a counter)
      scroll_current              scrolls open now
      open_contexts               search contexts open now (scrolls and
                                  point-in-time searches)
      get_total                   gets by id (a counter)
      get_missing                 of those, for documents that were not there (a
                                  counter)
      get_time_ms                 time spent in gets (a counter)
      merges_current              segment merges running now
      merges_total                merges (a counter)
      merges_time_ms              time spent merging (a counter)
      merges_throttled_ms         time merges were throttled (a counter)
      refresh_total               refreshes (a counter)
      refresh_time_ms             time spent refreshing (a counter)
      flush_total                 flushes (a counter)
      flush_time_ms               time spent flushing (a counter)
      query_cache_bytes           memory the query cache holds
      query_cache_hits            query cache hits (a counter)
      query_cache_misses          its misses (a counter)
      query_cache_evictions       its evictions (a counter)
      request_cache_bytes         memory the request cache holds
      request_cache_hits          request cache hits (a counter)
      request_cache_misses        its misses (a counter)
      request_cache_evictions     its evictions (a counter)
      fielddata_bytes             memory field data holds
      fielddata_evictions         its evictions (a counter)
      segments                    Lucene segments in the node's shards
      translog_ops                operations in the translog
      translog_bytes              its size
      translog_uncommitted_bytes  of that, not yet committed to Lucene
      nodes_not_shown             nodes past the first 100, by name, left out

    Example output (the rest are in the same form):
      metric up 1
      metric docs 25 node=es95a
      metric index_total 19 node=es95a
      metric index_time_ms 241 node=es95a
      metric query_total 10 node=es95a
      metric query_time_ms 329 node=es95a
      metric fetch_total 1 node=es95a

    Reading the results (starting points: tune them to the cluster):
      Healthy  index_failed flat; query_time_ms rising in step with query_total;
               merges_throttled_ms and index_throttle_ms flat.
      Watch    query_time_ms rising faster than query_total: queries slow down;
               index_throttle_ms rising: merges cannot keep up with indexing;
               query_cache_evictions or fielddata_evictions climbing.
      Act      index_failed rising: documents refused (mapping conflicts, ingest
               failures); open_contexts climbing without end: scrolls or
               point-in-time searches never closed.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, Elasticsearch up or down; 1 if a setting is wrong,
      the login is refused, this user may not read what the job needs, or the
      address is not Elasticsearch
#>

$Job = 'operations'
. (Join-Path $PSScriptRoot '_elasticsearch.ps1')

Read-First
$s = Need-Page '/_nodes/stats/indices?filter_path=nodes.*.name,nodes.*.indices.docs,nodes.*.indices.fielddata,nodes.*.indices.flush,nodes.*.indices.get,nodes.*.indices.indexing,nodes.*.indices.merges,nodes.*.indices.query_cache,nodes.*.indices.refresh,nodes.*.indices.request_cache,nodes.*.indices.search,nodes.*.indices.segments,nodes.*.indices.store,nodes.*.indices.translog'
$all = @(Values $s.nodes | Sort-Object { [string]$_.name })
foreach ($x in @($all | Select-Object -First 100)) {
    $t = "node=$(Safe $x.name)"
    M 'docs' $x.indices.docs.count $t
    M 'store_bytes' $x.indices.store.size_in_bytes $t
    M 'index_total' $x.indices.indexing.index_total $t
    M 'index_time_ms' $x.indices.indexing.index_time_in_millis $t
    M 'index_current' $x.indices.indexing.index_current $t
    M 'index_failed' $x.indices.indexing.index_failed $t
    M 'delete_total' $x.indices.indexing.delete_total $t
    M 'index_throttle_ms' $x.indices.indexing.throttle_time_in_millis $t
    M 'query_total' $x.indices.search.query_total $t
    M 'query_time_ms' $x.indices.search.query_time_in_millis $t
    M 'query_current' $x.indices.search.query_current $t
    M 'fetch_total' $x.indices.search.fetch_total $t
    M 'fetch_time_ms' $x.indices.search.fetch_time_in_millis $t
    M 'scroll_current' $x.indices.search.scroll_current $t
    M 'open_contexts' $x.indices.search.open_contexts $t
    M 'get_total' $x.indices.get.total $t
    M 'get_missing' $x.indices.get.missing_total $t
    M 'get_time_ms' $x.indices.get.time_in_millis $t
    M 'merges_current' $x.indices.merges.current $t
    M 'merges_total' $x.indices.merges.total $t
    M 'merges_time_ms' $x.indices.merges.total_time_in_millis $t
    M 'merges_throttled_ms' $x.indices.merges.total_throttled_time_in_millis $t
    M 'refresh_total' $x.indices.refresh.total $t
    M 'refresh_time_ms' $x.indices.refresh.total_time_in_millis $t
    M 'flush_total' $x.indices.flush.total $t
    M 'flush_time_ms' $x.indices.flush.total_time_in_millis $t
    M 'query_cache_bytes' $x.indices.query_cache.memory_size_in_bytes $t
    M 'query_cache_hits' $x.indices.query_cache.hit_count $t
    M 'query_cache_misses' $x.indices.query_cache.miss_count $t
    M 'query_cache_evictions' $x.indices.query_cache.evictions $t
    M 'request_cache_bytes' $x.indices.request_cache.memory_size_in_bytes $t
    M 'request_cache_hits' $x.indices.request_cache.hit_count $t
    M 'request_cache_misses' $x.indices.request_cache.miss_count $t
    M 'request_cache_evictions' $x.indices.request_cache.evictions $t
    M 'fielddata_bytes' $x.indices.fielddata.memory_size_in_bytes $t
    M 'fielddata_evictions' $x.indices.fielddata.evictions $t
    M 'segments' $x.indices.segments.count $t
    M 'translog_ops' $x.indices.translog.operations $t
    M 'translog_bytes' $x.indices.translog.size_in_bytes $t
    M 'translog_uncommitted_bytes' $x.indices.translog.uncommitted_size_in_bytes $t
}
M 'nodes_not_shown' ([Math]::Max($all.Count - 100, 0))
exit 0
