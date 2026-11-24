#!/usr/bin/env bash
#
# backpressure.sh - OpenSearch's backpressure and admission control
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
# Reports what OpenSearch does on each node to protect itself under load:
# search backpressure (its mode, and the searches and shard searches it
# cancelled for CPU, time or heap), shard indexing pressure (whether it is on
# and enforced, and the writes it refused), and admission control (the
# requests it refused for the node's CPU, I/O or memory), each tagged by node.
# It only reads: it changes nothing in the cluster.
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
#   search_mode                search backpressure: 0 disabled, 1 monitor
#                              only, 2 enforced; tagged node=<its name> and
#                              mode=<it>
#   search_cancellations       searches it cancelled, every kind (a counter),
#                              tagged node
#   search_limit_reached       times it would have cancelled but reached its
#                              limit (a counter), tagged node
#   search_cancelled_for       shard searches cancelled for one reason (a
#                              counter), tagged node and reason=<cpu_usage,
#                              elapsed_time or heap_usage>
#   shard_indexing_enabled     1 when shard indexing pressure is on, tagged
#                              node
#   shard_indexing_enforced    1 when it is enforced, not only counted, tagged
#                              node
#   shard_indexing_rejections  writes it refused (or, not enforced, would
#                              have), tagged node and limit=<which>
#   admission_rejections       requests admission control refused (a counter),
#                              tagged node, controller=<cpu, io or native
#                              memory> and action=<indexing or search>
#   nodes_not_shown            nodes past the first 100, by name, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric search_mode 1 node=os310a mode=monitor_only
#   metric search_cancellations 0 node=os310a
#   metric search_cancelled_for 0 node=os310a reason=cpu_usage
#   metric search_cancelled_for 0 node=os310a reason=heap_usage
#   metric shard_indexing_enabled 0 node=os310a
#   metric shard_indexing_enforced 0 node=os310a
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  search_cancellations and admission_rejections flat.
#   Watch    search_cancellations rising in monitor-only mode: enforced, those
#            searches would fail; shard_indexing_rejections rising while not
#            enforced.
#   Act      search_cancellations rising in enforced mode: searches fail;
#            admission_rejections rising: the node refuses requests for its
#            CPU or I/O.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, OpenSearch up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, this user may not read what the
#   job needs, or the address is not OpenSearch

set -u

job=backpressure
# shellcheck source=/dev/null
. "$(dirname "$0")/_opensearch.sh"

first
need '/_nodes/stats/search_backpressure,shard_indexing_pressure,admission_control?filter_path=nodes.*.name,nodes.*.search_backpressure.mode,nodes.*.search_backpressure.search_task.cancellation_stats,nodes.*.search_backpressure.search_shard_task.cancellation_stats,nodes.*.search_backpressure.search_shard_task.resource_tracker_stats.*.cancellation_count,nodes.*.shard_indexing_pressure.enabled,nodes.*.shard_indexing_pressure.enforced,nodes.*.shard_indexing_pressure.total_rejections_breakup,nodes.*.shard_indexing_pressure.total_rejections_breakup_shadow_mode,nodes.*.admission_control'
jq -r "$jqlib"'
    [.nodes[]] | sort_by(.name) |
    (.[0:100][] | "node=\(.name | tag)" as $t |
        (.search_backpressure // empty |
            "metric search_mode \({"disabled": 0, "monitor_only": 1, "enforced": 2}[.mode] // 0) \($t) mode=\(.mode | tag)",
            "metric search_cancellations \((.search_task.cancellation_stats.cancellation_count | n) + (.search_shard_task.cancellation_stats.cancellation_count | n)) \($t)",
            "metric search_limit_reached \((.search_task.cancellation_stats.cancellation_limit_reached_count | n) + (.search_shard_task.cancellation_stats.cancellation_limit_reached_count | n)) \($t)",
            (.search_shard_task.resource_tracker_stats // {} | to_entries | sort_by(.key)[] | select(.value.cancellation_count != null) |
                "metric search_cancelled_for \(.value.cancellation_count | n) \($t) reason=\(.key | sub("_tracker$"; "") | tag)")),
        (.shard_indexing_pressure // empty |
            "metric shard_indexing_enabled \(.enabled | n) \($t)",
            "metric shard_indexing_enforced \(.enforced | n) \($t)",
            ((if .enforced then .total_rejections_breakup else .total_rejections_breakup_shadow_mode end) // {} | to_entries | sort_by(.key)[] |
                "metric shard_indexing_rejections \(.value | n) \($t) limit=\(.key | tag)")),
        (.admission_control // {} | to_entries | sort_by(.key)[] | .key as $c |
            (.value.transport.rejection_count // {}) | to_entries | sort_by(.key)[] |
            "metric admission_rejections \(.value | n) \($t) controller=\($c | sub("^global_"; "") | sub("_usage$"; "") | tag) action=\(.key | tag)")),
    "metric nodes_not_shown \([length - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
