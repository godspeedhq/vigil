#!/usr/bin/env bash
#
# cluster.sh - a cluster as a whole
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
# Reports the cluster as a whole, from its own statistics: indices, shards and
# the replication they have, documents, size and segments; the fields its
# mappings define (too many slow every node); the memory the caches hold; its
# nodes, by role, and the versions they run; processors; its data disks, all
# together; ingest pipelines and plugins. And its license: its type and state,
# and the days until it expires. It only reads: it changes nothing in the
# cluster.
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
#   up                    1 when Elasticsearch answers, else 0
#   indices               indices
#   shards                shards, primaries and replicas
#   primary_shards        primaries
#   replication           replicas a primary, on average
#   docs                  documents, primaries only
#   deleted_docs          documents deleted, not yet merged away
#   store_bytes           the size of every shard
#   segments              Lucene segments
#   fields                fields every mapping defines, together
#   fielddata_bytes       memory field data holds
#   query_cache_bytes     memory the query cache holds
#   nodes                 nodes
#   role_nodes            nodes with a role, tagged role=<it>
#   versions              versions the nodes run
#   version_info          always 1, for each version, tagged version=<it>
#   processors            processors Elasticsearch uses, every node together
#   fs_total_bytes        data disks, every node together
#   fs_free_bytes         of those, free
#   fs_used_pct           of those, used
#   pipelines             ingest pipelines defined
#   plugins               plugins installed
#   license               always 1, tagged type=<basic, trial, platinum,
#                         enterprise...> and status=<active, expired...>
#   license_expires_days  days until the license expires, when it does
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric indices 13
#   metric shards 25
#   metric fields 92
#   metric nodes 3
#   metric role_nodes 3 role=data_hot
#   metric versions 1
#   metric license 1 type=basic status=active
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  versions 1; fields steady.
#   Watch    fields climbing fast: a mapping explosion (dynamic fields from
#            data); replication below 1 on a cluster of more than one node.
#   Act      versions above 1 when no upgrade runs: a node left behind.
#            license_expires_days below 30: renew it.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Elasticsearch up or down; 1 if curl or jq is
#   missing, a setting is wrong, the login is refused, this user may not read
#   what the job needs, or the address is not Elasticsearch

set -u

job=cluster
# shellcheck source=/dev/null
. "$(dirname "$0")/_elasticsearch.sh"

first
need '/_cluster/stats?filter_path=indices.count,indices.shards.total,indices.shards.primaries,indices.shards.replication,indices.docs,indices.store.size_in_bytes,indices.segments.count,indices.mappings.total_field_count,indices.mappings.field_types,indices.fielddata.memory_size_in_bytes,indices.query_cache.memory_size_in_bytes,nodes.count,nodes.versions,nodes.os.allocated_processors,nodes.fs,nodes.ingest.number_of_pipelines,nodes.plugins.name'
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
get '/_license'
rc=$?
case $rc in
    0) jq -r --argjson now "$now" "$jqlib"'.license |
        "metric license 1 type=\(.type | tag) status=\(.status | tag)",
        (if .expiry_date_in_millis then "metric license_expires_days \((.expiry_date_in_millis / 1000 - $now) / 86400 | floor)" else empty end)
    ' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_license' ;;
esac
exit 0
