#!/usr/bin/env bash
#
# status.sh - a cluster's health
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
# Reports whether Elasticsearch answers, its version, the cluster's health
# (green, yellow or red), its nodes, its shards (active, relocating,
# initializing, unassigned, and unassigned primaries), the cluster tasks
# waiting and for how long, and which node is the elected master. It only
# reads: it changes nothing in the cluster.
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
#   up                         1 when Elasticsearch answers, else 0
#   version                    always 1, tagged version=<its version> and
#                              cluster=<its name>
#   status                     the cluster's health: 0 green, 1 yellow (a
#                              replica unassigned), 2 red (a primary
#                              unassigned: data missing), 3 when there is no
#                              elected master; tagged status=<it>
#   timed_out                  1 when the health check timed out
#   nodes                      nodes in the cluster
#   data_nodes                 of those, nodes that hold data
#   active_primary_shards      primary shards active
#   active_shards              shards active, primaries and replicas
#   active_shards_pct          shards active, as a percentage of all
#   relocating_shards          shards moving between nodes
#   initializing_shards        shards being created or recovered
#   unassigned_shards          shards on no node
#   unassigned_primary_shards  of those, primaries (when Elasticsearch says)
#   delayed_unassigned_shards  unassigned shards whose allocation waits, on
#                              purpose, for a node to come back
#   pending_tasks              cluster tasks waiting for the master
#   task_max_wait_ms           how long the oldest of those has waited
#   in_flight_fetch            shard information being fetched from the nodes
#   master                     1 when a node is the elected master, tagged
#                              node=<its name>; 0 when none is
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric version 1 version=9.5.5 cluster=vigil95
#   metric status 2 status=red
#   metric nodes 3
#   metric active_shards_pct 86.21
#   metric unassigned_shards 4
#   metric unassigned_primary_shards 2
#   metric master 1 node=es95b
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  up 1; status 0; unassigned_shards 0; pending_tasks 0.
#   Watch    status 1 for long: replicas unassigned, one node from losing
#            data; relocating_shards or initializing_shards for long;
#            task_max_wait_ms in seconds.
#   Act      up 0; status 2: primaries unassigned, data unreachable (the
#            shards job says which, and why); master 0 or status 3: no elected
#            master, the cluster changes nothing.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Elasticsearch up or down; 1 if curl or jq is
#   missing, a setting is wrong, the login is refused, this user may not read
#   what the job needs, or the address is not Elasticsearch

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_elasticsearch.sh"

first
jq -r "$jqlib"'"metric version 1 version=\(.version.number | tag) cluster=\(.cluster_name | tag)"' "$work/root" || exit 1
health='/_cluster/health?timeout=10s&master_timeout=10s'
get "$health"
rc=$?
case $rc in
    0) ;;
    5) echo "metric status 3 status=no_master"; echo "metric master 0"; exit 0 ;;
    *) why "$rc" "$health" ;;
esac
jq -r "$jqlib"'
    "metric status \(.status | code) status=\(.status | tag)",
    "metric timed_out \(.timed_out | n)",
    "metric nodes \(.number_of_nodes | n)",
    "metric data_nodes \(.number_of_data_nodes | n)",
    "metric active_primary_shards \(.active_primary_shards | n)",
    "metric active_shards \(.active_shards | n)",
    "metric active_shards_pct \(.active_shards_percent_as_number | n | r2)",
    "metric relocating_shards \(.relocating_shards | n)",
    "metric initializing_shards \(.initializing_shards | n)",
    "metric unassigned_shards \(.unassigned_shards | n)",
    (if .unassigned_primary_shards != null then "metric unassigned_primary_shards \(.unassigned_primary_shards)" else empty end),
    "metric delayed_unassigned_shards \(.delayed_unassigned_shards | n)",
    "metric pending_tasks \(.number_of_pending_tasks | n)",
    "metric task_max_wait_ms \(.task_max_waiting_in_queue_millis | n)",
    "metric in_flight_fetch \(.number_of_in_flight_fetch | n)"
' "$work/body" || exit 1
need '/_cat/master?format=json&h=id,node'
jq -r "$jqlib"'if length > 0 and .[0].node != null and .[0].node != "-" then "metric master 1 node=\(.[0].node | tag)" else "metric master 0" end' "$work/body" || exit 1
exit 0
