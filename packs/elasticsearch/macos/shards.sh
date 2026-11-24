#!/usr/bin/env bash
#
# shards.sh - the shards of a cluster, and why one is unassigned
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
# Reports every shard by state (started, relocating, initializing, unassigned,
# primaries and replicas apart), the largest shards (by size and by documents,
# against the limits Elasticsearch advises), each node's share, and each
# unassigned shard, primaries first, with why and since when. For the first of
# them, it asks Elasticsearch to explain (_cluster/allocation/explain) and
# reports the reason it gives. Then the shard recoveries in progress, and how
# far each has come. It only reads: it changes nothing in the cluster.
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
#   up                     1 when Elasticsearch answers, else 0
#   shards                 shards, primaries and replicas
#   primaries              of those, primaries
#   replicas               replicas
#   started                shards started
#   relocating             shards moving to another node
#   initializing           shards being created or recovered
#   unassigned             shards on no node
#   unassigned_primaries   of those, primaries: their data is unreachable
#   unassigned_replicas    replicas
#   largest_shard_bytes    the largest shard
#   largest_shard_docs     the most documents in a shard
#   shards_over_50gb       shards larger than 50 GB, the most Elasticsearch
#                          advises
#   shards_over_200m_docs  shards of more than 200 million documents, the most
#                          Elasticsearch advises
#   node_shards            shards on a node, tagged node=<its name>
#   unassigned_seconds     how long a shard has been unassigned, tagged
#                          index=<it>, shard=<its number>, prirep=<p or r> and
#                          reason=<why Elasticsearch unassigned it>
#   unassigned_not_shown   unassigned shards past the first 100, left out
#   explained              always 1, for the first unassigned shard:
#                          Elasticsearch's explanation, tagged index, shard,
#                          prirep, can_allocate=<no, yes, throttled,
#                          awaiting_info...>, decider=<what refused it> and
#                          why=<its words>
#   recoveries             shard recoveries in progress
#   recovery_pct           how far one has come, in bytes, tagged index,
#                          shard, type=<why it recovers> and stage=<where it
#                          is>
#   recovery_ms            how long it has run, tagged the same
#   recoveries_not_shown   recoveries past the first 50, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric unassigned 4
#   metric unassigned_primaries 2
#   metric unassigned_seconds 121 index=archive-red shard=0 prirep=p reason=INDEX_CREATED
#   metric unassigned_seconds 122 index=orders shard=0 prirep=r reason=INDEX_CREATED
#   metric explained 1 index=archive-red shard=0 prirep=p can_allocate=no decider=filter why=node_does_not_match_index_setting__index.routing.allocation.require__filters___name:_nowhere__
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  unassigned 0; relocating and initializing 0 most of the time;
#            shards_over_50gb 0.
#   Watch    unassigned_replicas above 0 for minutes: a node gone, or replicas
#            the cluster cannot place (explained says why); recoveries running
#            for long; shards_over_50gb above 0: split the index, or roll it
#            over sooner.
#   Act      unassigned_primaries above 0: data unreachable; explained says
#            why (a node gone, a disk full, a filter no node matches, a
#            corrupt shard).
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Elasticsearch up or down; 1 if curl or jq is
#   missing, a setting is wrong, the login is refused, this user may not read
#   what the job needs, or the address is not Elasticsearch

set -u

job=shards
# shellcheck source=/dev/null
. "$(dirname "$0")/_elasticsearch.sh"

first
need '/_cat/shards?format=json&bytes=b&h=index,shard,prirep,state,unassigned.reason,unassigned.at,node,store,docs'
cp "$work/body" "$work/shards"
jq -r --argjson now "$now" "$jqlib"'
    map(.store |= n | .docs |= n) |
    "metric shards \(length)",
    "metric primaries \([.[] | select(.prirep == "p")] | length)",
    "metric replicas \([.[] | select(.prirep == "r")] | length)",
    "metric started \([.[] | select(.state == "STARTED")] | length)",
    "metric relocating \([.[] | select(.state == "RELOCATING")] | length)",
    "metric initializing \([.[] | select(.state == "INITIALIZING")] | length)",
    "metric unassigned \([.[] | select(.state == "UNASSIGNED")] | length)",
    "metric unassigned_primaries \([.[] | select(.state == "UNASSIGNED" and .prirep == "p")] | length)",
    "metric unassigned_replicas \([.[] | select(.state == "UNASSIGNED" and .prirep == "r")] | length)",
    "metric largest_shard_bytes \([.[].store] | max // 0)",
    "metric largest_shard_docs \([.[].docs] | max // 0)",
    "metric shards_over_50gb \([.[] | select(.store > 53687091200)] | length)",
    "metric shards_over_200m_docs \([.[] | select(.docs > 200000000)] | length)",
    ([.[] | select(.node != null and .node != "")] | group_by(.node)[] | "metric node_shards \(length) node=\(.[0].node | tag)"),
    ([.[] | select(.state == "UNASSIGNED") | . + {at: (.["unassigned.at"] | epoch)}]
        | sort_by(.prirep != "p", .at, .index, (.shard | n)) |
        (.[0:100][] | "metric unassigned_seconds \(if .at then ($now - .at | floor | if . < 0 then 0 else . end) else 0 end) index=\(.index | tag) shard=\(.shard | tag) prirep=\(.prirep | tag) reason=\(.["unassigned.reason"] | tag)"),
        "metric unassigned_not_shown \([length - 100, 0] | max)")
' "$work/body" || exit 1
# The first unassigned shard, primaries first: Elasticsearch's own explanation.
jq -c '[.[] | select(.state == "UNASSIGNED")] | sort_by(.prirep != "p", .index, (.shard | tonumber)) | .[0] // empty | {index, shard: (.shard | tonumber), primary: (.prirep == "p")}' "$work/shards" > "$work/explain" || exit 1
if [ -s "$work/explain" ]; then
    get '/_cluster/allocation/explain?filter_path=index,shard,primary,can_allocate,allocate_explanation,node_allocation_decisions.node_decision,node_allocation_decisions.deciders' "$work/explain"
    rc=$?
    case $rc in
        0) jq -r "$jqlib"'
            ([.node_allocation_decisions[]?.deciders[]? | select(.decision == "NO" or .decision == "THROTTLE")][0]) as $d |
            "metric explained 1 index=\(.index | tag) shard=\(.shard | tag) prirep=\(if .primary then "p" else "r" end) can_allocate=\(.can_allocate | tag) decider=\($d.decider // "none" | tag) why=\(($d.explanation // .allocate_explanation // "") | tag)"
        ' "$work/body" || exit 1 ;;
        3) ;;
        *) why "$rc" '/_cluster/allocation/explain' ;;
    esac
fi
need '/_cat/recovery?format=json&active_only=true&bytes=b&time=ms&h=index,shard,type,stage,source_node,target_node,bytes_percent,time'
jq -r "$jqlib"'
    "metric recoveries \(length)",
    (sort_by(-(.time | n)) | .[0:50][] | "index=\(.index | tag) shard=\(.shard | tag) type=\(.type | tag) stage=\(.stage | tag)" as $t |
        "metric recovery_pct \(.bytes_percent | n) \($t)",
        "metric recovery_ms \(.time | n) \($t)"),
    "metric recoveries_not_shown \([length - 50, 0] | max)"
' "$work/body" || exit 1
exit 0
