#!/usr/bin/env bash
#
# features.sh - Elasticsearch's transforms, Watcher and enrich
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
# Reports the Elasticsearch features that run on their own: its transforms
# (how many, started and failed, and each failed one's reason, and each one's
# health), Watcher (on how many nodes it runs, its watches, and the watches
# waiting to run), and the enrich processor's coordinators (lookups queued and
# in flight) and the enrich policies being executed. A feature that is off, or
# that this user may not read, prints nothing. It only reads: it changes
# nothing in the cluster.
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
#   transforms            transforms
#   transforms_started    of those, started or indexing
#   transforms_failed     failed
#   transform_failed      always 1, for each failed transform, tagged
#                         transform=<its id> and reason=<why>
#   transform_health      a transform's health: 0 green, 1 yellow, 2 red, 3
#                         unknown; tagged transform
#   transforms_not_shown  transforms past the first 100, left out
#   watcher_nodes         nodes Watcher runs on
#   watcher_started       of those, nodes where it is started
#   watches               watches
#   watches_queued        watch runs waiting for a thread
#   enrich_queued         enrich lookups queued on the coordinators
#   enrich_in_flight      enrich lookups in flight
#   enrich_executing      enrich policies being executed
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric transforms 1
#   metric transforms_started 0
#   metric transforms_failed 0
#   metric watcher_nodes 3
#   metric watcher_started 3
#   metric enrich_queued 0
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  transforms_failed 0; watcher_started equal to watcher_nodes;
#            watches_queued near 0.
#   Watch    transform_health 1; enrich_queued rising: ingest waits for enrich
#            lookups.
#   Act      transforms_failed above 0: the transform stopped (the reason says
#            why); watcher_started 0: no watch runs, and no alert of Watcher's
#            fires.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Elasticsearch up or down; 1 if curl or jq is
#   missing, a setting is wrong, the login is refused, this user may not read
#   what the job needs, or the address is not Elasticsearch

set -u

job=features
# shellcheck source=/dev/null
. "$(dirname "$0")/_elasticsearch.sh"

first
get '/_transform/_stats?size=1000&filter_path=count,transforms.id,transforms.state,transforms.reason,transforms.health.status'
rc=$?
case $rc in
    0) jq -r "$jqlib"'
        [.transforms[]?] | sort_by(.id) |
        "metric transforms \(length)",
        "metric transforms_started \([.[] | select(.state == "started" or .state == "indexing")] | length)",
        "metric transforms_failed \([.[] | select(.state == "failed")] | length)",
        (.[0:100][] | "transform=\(.id | tag)" as $t |
            (if .state == "failed" then "metric transform_failed 1 \($t) reason=\(.reason // "" | tag)" else empty end),
            (if .health.status then "metric transform_health \(.health.status | code) \($t)" else empty end)),
        "metric transforms_not_shown \([length - 100, 0] | max)"
    ' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_transform/_stats' ;;
esac
get '/_watcher/stats?filter_path=stats.watcher_state,stats.watch_count,stats.execution_thread_pool'
rc=$?
case $rc in
    0) jq -r "$jqlib"'
        [.stats[]?] |
        "metric watcher_nodes \(length)",
        "metric watcher_started \([.[] | select(.watcher_state == "started")] | length)",
        "metric watches \([.[].watch_count | n] | add // 0)",
        "metric watches_queued \([.[].execution_thread_pool.queue_size | n] | add // 0)"
    ' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_watcher/stats' ;;
esac
get '/_enrich/_stats'
rc=$?
case $rc in
    0) jq -r "$jqlib"'
        "metric enrich_queued \([.coordinator_stats[]?.queue_size | n] | add // 0)",
        "metric enrich_in_flight \([.coordinator_stats[]?.remote_requests_current | n] | add // 0)",
        "metric enrich_executing \([.executing_policies[]?] | length)"
    ' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_enrich/_stats' ;;
esac
exit 0
