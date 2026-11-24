#!/usr/bin/env bash
#
# indices.sh - the indices of a cluster
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
# Reports the cluster's indices, hidden ones and data streams' backing indices
# too: how many, open and closed, green, yellow and red, their documents and
# size, and those with a block (written to no more, or read-only, as
# OpenSearch leaves them when a disk fills). Then each index, the worst first
# (red, yellow, blocked, closed, then the largest): its health, documents,
# deleted documents, size, shards, replicas, age and blocks. It only reads: it
# changes nothing in the cluster.
#
# Reads OpenSearch at OPENSEARCH_URL (default https://localhost:9200), as
# OPENSEARCH_USER with the password in OPENSEARCH_PASSWORD (a secret), with
# curl and jq. The login goes to curl on its standard input, never on a
# command line.
# Over https, the certificate is checked against OPENSEARCH_CACERT, a CA file,
# when it is set, else the system's CAs. What the scripts share is in
# _opensearch.sh, beside this one.
#
# Metrics:
#   up                         1 when OpenSearch answers, else 0
#   indices                    indices
#   open                       of those, open
#   closed                     closed
#   green                      green: every shard assigned
#   yellow                     yellow: a replica unassigned
#   red                        red: a primary unassigned
#   hidden                     indices whose names start with a dot (hidden,
#                              and data streams' backing indices)
#   docs                       documents in every index, primaries only
#   deleted_docs               documents deleted but not yet merged away
#   store_bytes                the size of every index, replicas too
#   primary_store_bytes        the size of the primaries alone
#   blocked                    indices with a block of any kind
#   write_blocked              indices that take no writes: a write, read_only
#                              or read_only_allow_delete block
#   health                     an index's health: 0 green, 1 yellow, 2 red;
#                              tagged index=<its name>
#   is_open                    1 when it is open, tagged the same
#   index_docs                 its documents, primaries only
#   deleted_pct                its deleted documents, as a percentage of all
#   index_store_bytes          its size, replicas too
#   index_primary_store_bytes  its primaries' size
#   primaries                  its primary shards
#   replicas                   its replicas of each
#   age_days                   days since it was created
#   block                      always 1, for each block it has, tagged
#                              index=<its name> and block=<the block>
#   indices_not_shown          indices past the first 100, the worst first,
#                              left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric indices 16
#   metric yellow 1
#   metric red 1
#   metric write_blocked 1
#   metric health 2 index=archive-red
#   metric block 1 index=blocked block=write
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  red 0; yellow 0 (on a cluster of more than one node);
#            write_blocked 0.
#   Watch    deleted_pct above 30 on a large index: space held by deleted
#            documents until merges; an index far larger than the rest.
#   Act      red above 0: data unreachable (the shards job says why);
#            write_blocked above 0: writes to it fail, often after a disk
#            passed the flood stage (free space, then clear the block).
#
# Requires: bash, curl and jq
# Exit code: 0 on success, OpenSearch up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, this user may not read what the
#   job needs, or the address is not OpenSearch

set -u

job=indices
# shellcheck source=/dev/null
. "$(dirname "$0")/_opensearch.sh"

first
need '/_cat/indices?format=json&bytes=b&expand_wildcards=all&h=health,status,index,pri,rep,docs.count,docs.deleted,store.size,pri.store.size,creation.date'
cp "$work/body" "$work/cat"
need '/_settings?filter_path=*.settings.index.blocks&expand_wildcards=all'
jq -r --slurpfile cat "$work/cat" --argjson now "$now" "$jqlib"'
    . as $b |
    [$cat[0][] | {name: .index, health: .health, status: .status, pri: (.pri | n), rep: (.rep | n),
        docs: (.["docs.count"] | n), del: (.["docs.deleted"] | n), size: (.["store.size"] | n),
        psize: (.["pri.store.size"] | n), created: (.["creation.date"] | n),
        blocks: [($b[.index].settings.index.blocks // {}) | to_entries[] | select(.value == "true" or .value == true) | .key]}] |
    "metric indices \(length)",
    "metric open \([.[] | select(.status == "open")] | length)",
    "metric closed \([.[] | select(.status == "close")] | length)",
    "metric green \([.[] | select(.health == "green")] | length)",
    "metric yellow \([.[] | select(.health == "yellow")] | length)",
    "metric red \([.[] | select(.health == "red")] | length)",
    "metric hidden \([.[] | select(.name | startswith("."))] | length)",
    "metric docs \([.[].docs] | add // 0)",
    "metric deleted_docs \([.[].del] | add // 0)",
    "metric store_bytes \([.[].size] | add // 0)",
    "metric primary_store_bytes \([.[].psize] | add // 0)",
    "metric blocked \([.[] | select(.blocks | length > 0)] | length)",
    "metric write_blocked \([.[] | select(.blocks | any(. == "write" or . == "read_only" or . == "read_only_allow_delete"))] | length)",
    (sort_by((if .health == "red" then 0 elif .health == "yellow" then 1 elif (.blocks | length) > 0 then 2 elif .status == "close" then 3 else 4 end), -.size, .name)
        | .[0:100][] | "index=\(.name | tag)" as $t |
        (if .health == "green" or .health == "yellow" or .health == "red" then "metric health \(.health | code) \($t)" else empty end),
        "metric is_open \(if .status == "open" then 1 else 0 end) \($t)",
        "metric index_docs \(.docs) \($t)",
        "metric deleted_pct \(pct(.del; .docs + .del)) \($t)",
        "metric index_store_bytes \(.size) \($t)",
        "metric index_primary_store_bytes \(.psize) \($t)",
        "metric primaries \(.pri) \($t)",
        "metric replicas \(.rep) \($t)",
        (if .created > 0 then "metric age_days \(($now * 1000 - .created) / 86400000 | floor) \($t)" else empty end),
        (.blocks | sort[] | "metric block 1 \($t) block=\(. | tag)")),
    "metric indices_not_shown \([length - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
