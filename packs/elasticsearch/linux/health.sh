#!/usr/bin/env bash
#
# health.sh - Elasticsearch's own health report
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
# Reports Elasticsearch's own health report (8.7 and later): its overall
# status, and each indicator's (the master, shard availability, disk, shard
# capacity, repositories, ILM, SLM, data stream lifecycle and more) with what
# Elasticsearch says is wrong, in its words. It asks for the short form
# (verbose=false), as Elasticsearch advises for polling. It only reads: it
# changes nothing in the cluster.
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
#   up                 1 when Elasticsearch answers, else 0
#   served             1 when this Elasticsearch has a health report (8.7 and
#                      later), else 0
#   status             the overall status: 0 green, 1 yellow, 2 red, 3
#                      unknown; tagged status=<it>
#   indicators_red     indicators red
#   indicators_yellow  indicators yellow
#   indicator          each indicator's status, the same codes, tagged
#                      indicator=<its name> and symptom=<what Elasticsearch
#                      says>
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric served 1
#   metric status 2 status=red
#   metric indicators_red 2
#   metric indicators_yellow 1
#   metric indicator 2 indicator=shards_availability symptom=This_cluster_has_2_unavailable_primary_shards__2_unavailable_replica_shards.
#   metric indicator 2 indicator=shards_capacity symptom=Cluster_is_close_to_reaching_the_configured_maximum_number_of_shards_for_data_nodes.
#   metric indicator 0 indicator=master_is_stable symptom=The_cluster_has_a_stable_master_node
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  status 0; every indicator 0.
#   Watch    An indicator at 1: its symptom says what (disk filling, shards
#            near the limit, a lifecycle stalled).
#   Act      status 2: an indicator red; its symptom says what, and
#            Elasticsearch's own health report (GET
#            _health_report/<indicator>) says what to do.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Elasticsearch up or down; 1 if curl or jq is
#   missing, a setting is wrong, the login is refused, this user may not read
#   what the job needs, or the address is not Elasticsearch

set -u

job=health
# shellcheck source=/dev/null
. "$(dirname "$0")/_elasticsearch.sh"

first
get '/_health_report?verbose=false'
rc=$?
case $rc in
    0) ;;
    3) echo "metric served 0"; exit 0 ;;
    *) why "$rc" '/_health_report' ;;
esac
jq -r "$jqlib"'
    "metric served 1",
    "metric status \(.status | code) status=\(.status | tag)",
    "metric indicators_red \([.indicators[] | select(.status == "red")] | length)",
    "metric indicators_yellow \([.indicators[] | select(.status == "yellow")] | length)",
    (.indicators | to_entries | sort_by(.key)[] | "metric indicator \(.value.status | code) indicator=\(.key | tag) symptom=\(.value.symptom | tag)")
' "$work/body" || exit 1
exit 0
