#!/usr/bin/env bash
#
# operations.sh - the work each node of a cluster does
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Reports, for each node, what its shards hold and the work it does, as
# counters to make rates of: documents indexed and deleted, and how long it
# took; search queries and fetches, and how long; gets; merges, refreshes and
# flushes; the query, request and field data caches, their hits, misses and
# evictions; segments; and the translog. The rate of index_total is the
# indexing rate; query_time_ms over query_total, the average query time. It
# only reads: it changes nothing in the cluster.
#
# Reads Elasticsearch at ELASTICSEARCH_URL (default https://localhost:9200),
# as ELASTICSEARCH_USER with the password in ELASTICSEARCH_PASSWORD (a
# secret), or with an API key in ELASTICSEARCH_API_KEY (a secret: the encoded
# form Elasticsearch gives), with curl and jq. The login goes to curl on its
# standard input, never on a command line.
# Over https, the certificate is checked against ELASTICSEARCH_CACERT, a CA
# file, when it is set, else the system's CAs. What the scripts share is in
# _elasticsearch.sh, beside this one.
#
# Metrics:
#   up                          1 when Elasticsearch answers, else 0
#   docs                        documents in the node's shards, tagged
#                               node=<its name>
#   store_bytes                 the size of the node's shards
#   index_total                 documents indexed (a counter)
#   index_time_ms               time spent indexing (a counter)
#   index_current               documents being indexed now
#   index_failed                documents that failed to index (a counter)
#   delete_total                documents deleted (a counter)
#   index_throttle_ms           time indexing was throttled for merges (a
#                               counter)
#   query_total                 search queries, each shard counted (a counter)
#   query_time_ms               time spent in them (a counter)
#   query_current               queries running now
#   fetch_total                 fetches of search hits (a counter)
#   fetch_time_ms               time spent in them (a counter)
#   scroll_current              scrolls open now
#   open_contexts               search contexts open now (scrolls and
#                               point-in-time searches)
#   get_total                   gets by id (a counter)
#   get_missing                 of those, for documents that were not there (a
#                               counter)
#   get_time_ms                 time spent in gets (a counter)
#   merges_current              segment merges running now
#   merges_total                merges (a counter)
#   merges_time_ms              time spent merging (a counter)
#   merges_throttled_ms         time merges were throttled (a counter)
#   refresh_total               refreshes (a counter)
#   refresh_time_ms             time spent refreshing (a counter)
#   flush_total                 flushes (a counter)
#   flush_time_ms               time spent flushing (a counter)
#   query_cache_bytes           memory the query cache holds
#   query_cache_hits            query cache hits (a counter)
#   query_cache_misses          its misses (a counter)
#   query_cache_evictions       its evictions (a counter)
#   request_cache_bytes         memory the request cache holds
#   request_cache_hits          request cache hits (a counter)
#   request_cache_misses        its misses (a counter)
#   request_cache_evictions     its evictions (a counter)
#   fielddata_bytes             memory field data holds
#   fielddata_evictions         its evictions (a counter)
#   segments                    Lucene segments in the node's shards
#   translog_ops                operations in the translog
#   translog_bytes              its size
#   translog_uncommitted_bytes  of that, not yet committed to Lucene
#   nodes_not_shown             nodes past the first 100, by name, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric docs 25 node=es95a
#   metric index_total 19 node=es95a
#   metric index_time_ms 241 node=es95a
#   metric query_total 10 node=es95a
#   metric query_time_ms 329 node=es95a
#   metric fetch_total 1 node=es95a
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  index_failed flat; query_time_ms rising in step with query_total;
#            merges_throttled_ms and index_throttle_ms flat.
#   Watch    query_time_ms rising faster than query_total: queries slow down;
#            index_throttle_ms rising: merges cannot keep up with indexing;
#            query_cache_evictions or fielddata_evictions climbing.
#   Act      index_failed rising: documents refused (mapping conflicts, ingest
#            failures); open_contexts climbing without end: scrolls or
#            point-in-time searches never closed.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Elasticsearch up or down; 1 if curl or jq is
#   missing, a setting is wrong, the login is refused, this user may not read
#   what the job needs, or the address is not Elasticsearch

set -u

job=operations
# shellcheck source=/dev/null
. "$(dirname "$0")/_elasticsearch.sh"

first
need '/_nodes/stats/indices?filter_path=nodes.*.name,nodes.*.indices.docs,nodes.*.indices.fielddata,nodes.*.indices.flush,nodes.*.indices.get,nodes.*.indices.indexing,nodes.*.indices.merges,nodes.*.indices.query_cache,nodes.*.indices.refresh,nodes.*.indices.request_cache,nodes.*.indices.search,nodes.*.indices.segments,nodes.*.indices.store,nodes.*.indices.translog'
jq -r "$jqlib"'
    [.nodes[]] | sort_by(.name) |
    (.[0:100][] | "node=\(.name | tag)" as $t |
        "metric docs \(.indices.docs.count | n) \($t)",
        "metric store_bytes \(.indices.store.size_in_bytes | n) \($t)",
        "metric index_total \(.indices.indexing.index_total | n) \($t)",
        "metric index_time_ms \(.indices.indexing.index_time_in_millis | n) \($t)",
        "metric index_current \(.indices.indexing.index_current | n) \($t)",
        "metric index_failed \(.indices.indexing.index_failed | n) \($t)",
        "metric delete_total \(.indices.indexing.delete_total | n) \($t)",
        "metric index_throttle_ms \(.indices.indexing.throttle_time_in_millis | n) \($t)",
        "metric query_total \(.indices.search.query_total | n) \($t)",
        "metric query_time_ms \(.indices.search.query_time_in_millis | n) \($t)",
        "metric query_current \(.indices.search.query_current | n) \($t)",
        "metric fetch_total \(.indices.search.fetch_total | n) \($t)",
        "metric fetch_time_ms \(.indices.search.fetch_time_in_millis | n) \($t)",
        "metric scroll_current \(.indices.search.scroll_current | n) \($t)",
        "metric open_contexts \(.indices.search.open_contexts | n) \($t)",
        "metric get_total \(.indices.get.total | n) \($t)",
        "metric get_missing \(.indices.get.missing_total | n) \($t)",
        "metric get_time_ms \(.indices.get.time_in_millis | n) \($t)",
        "metric merges_current \(.indices.merges.current | n) \($t)",
        "metric merges_total \(.indices.merges.total | n) \($t)",
        "metric merges_time_ms \(.indices.merges.total_time_in_millis | n) \($t)",
        "metric merges_throttled_ms \(.indices.merges.total_throttled_time_in_millis | n) \($t)",
        "metric refresh_total \(.indices.refresh.total | n) \($t)",
        "metric refresh_time_ms \(.indices.refresh.total_time_in_millis | n) \($t)",
        "metric flush_total \(.indices.flush.total | n) \($t)",
        "metric flush_time_ms \(.indices.flush.total_time_in_millis | n) \($t)",
        "metric query_cache_bytes \(.indices.query_cache.memory_size_in_bytes | n) \($t)",
        "metric query_cache_hits \(.indices.query_cache.hit_count | n) \($t)",
        "metric query_cache_misses \(.indices.query_cache.miss_count | n) \($t)",
        "metric query_cache_evictions \(.indices.query_cache.evictions | n) \($t)",
        "metric request_cache_bytes \(.indices.request_cache.memory_size_in_bytes | n) \($t)",
        "metric request_cache_hits \(.indices.request_cache.hit_count | n) \($t)",
        "metric request_cache_misses \(.indices.request_cache.miss_count | n) \($t)",
        "metric request_cache_evictions \(.indices.request_cache.evictions | n) \($t)",
        "metric fielddata_bytes \(.indices.fielddata.memory_size_in_bytes | n) \($t)",
        "metric fielddata_evictions \(.indices.fielddata.evictions | n) \($t)",
        "metric segments \(.indices.segments.count | n) \($t)",
        "metric translog_ops \(.indices.translog.operations | n) \($t)",
        "metric translog_bytes \(.indices.translog.size_in_bytes | n) \($t)",
        "metric translog_uncommitted_bytes \(.indices.translog.uncommitted_size_in_bytes | n) \($t)"),
    "metric nodes_not_shown \([length - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
