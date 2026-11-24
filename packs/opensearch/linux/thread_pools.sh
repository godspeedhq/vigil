#!/usr/bin/env bash
#
# thread_pools.sh - the thread pools of a cluster's nodes
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
# Reports each node's thread pools, the queues of work OpenSearch keeps for
# writes, searches, gets and its own housekeeping: threads busy, work waiting
# against the queue's size, and work refused when the queue was full (a client
# sees HTTP 429). The write, search and get pools are always reported; the
# others when they have work busy, waiting or refused. It only reads: it
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
#   up               1 when OpenSearch answers, else 0
#   rejected_total   work refused by every pool of every node, since each
#                    started (a counter)
#   queued_total     work waiting in every pool now
#   active_total     threads busy in every pool now
#   active           a pool's threads busy, tagged node=<its name> and
#                    pool=<the pool>
#   queue            its work waiting, tagged the same
#   queue_pct        queue, as a percentage of the queue's size, when it has
#                    one
#   rejected         its work refused, since the node started (a counter)
#   completed        its work done (a counter)
#   threads          its threads
#   largest          the most threads it has had at once
#   pools_not_shown  pools past the first 200 (refusing first), left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric rejected_total 247
#   metric queued_total 0
#   metric rejected 177 node=os310b pool=write
#   metric completed 204 node=os310b pool=write
#   metric threads 1 node=os310b pool=write
#   metric rejected 70 node=os310c pool=write
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  rejected_total flat; queue near 0 most of the time.
#   Watch    queue_pct above 50 on the write or search pool: the node falls
#            behind.
#   Act      rejected rising on write: writes refused, clients see HTTP 429
#            (bulk requests partly fail); on search: searches refused.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, OpenSearch up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, this user may not read what the
#   job needs, or the address is not OpenSearch

set -u

job=thread_pools
# shellcheck source=/dev/null
. "$(dirname "$0")/_opensearch.sh"

first
need '/_cat/thread_pool?format=json&h=node_name,name,active,queue,queue_size,rejected,completed,largest,size'
jq -r "$jqlib"'
    map(.active |= n | .queue |= n | .rejected |= n | .completed |= n | .size |= n | .largest |= n) |
    "metric rejected_total \([.[].rejected] | add // 0)",
    "metric queued_total \([.[].queue] | add // 0)",
    "metric active_total \([.[].active] | add // 0)",
    ([.[] | select(.name == "write" or .name == "search" or .name == "get" or .active > 0 or .queue > 0 or .rejected > 0)]
        | sort_by(-.rejected, -.queue, .node_name, .name) |
        (.[0:200][] | "node=\(.node_name | tag) pool=\(.name | tag)" as $t |
            "metric active \(.active) \($t)",
            "metric queue \(.queue) \($t)",
            (if (.queue_size | n) > 0 then "metric queue_pct \(pct(.queue; .queue_size)) \($t)" else empty end),
            "metric rejected \(.rejected) \($t)",
            "metric completed \(.completed) \($t)",
            "metric threads \(.size) \($t)",
            "metric largest \(.largest) \($t)"),
        "metric pools_not_shown \([length - 200, 0] | max)")
' "$work/body" || exit 1
exit 0
