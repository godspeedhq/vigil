#!/usr/bin/env bash
#
# cluster.sh - a CockroachDB cluster's nodes: live, dead, leaving, upgraded
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
# Reports the cluster's nodes, as the node at COCKROACH_URL sees them: live,
# dead (its liveness expired for longer than server.time_until_store_dead),
# unavailable (expired, not yet dead), draining, decommissioning and
# decommissioned; each node's status and version, worst first; the versions
# they run; and whether an upgrade is left unfinished: the cluster's version
# behind its nodes' (cluster.preserve_downgrade_option holds it back, or the
# upgrade is still running). Run it on one node, or on each: the answer is
# the cluster's either way. It only reads.
#
# Reads CockroachDB at COCKROACH_URL (default https://localhost:8080), the
# node's HTTP port, as COCKROACH_USER with the password in
# COCKROACH_PASSWORD (a secret), with curl and jq: /api/v2/nodes/ and SHOW
# CLUSTER SETTING through /api/v2/sql/. The user needs the system privileges
# VIEWCLUSTERMETADATA and VIEWCLUSTERSETTING; an insecure cluster needs no
# login. Over https, the certificate is checked against COCKROACH_CACERT,
# the cluster's CA file (ca.crt), when it is set, else the system's CAs.
# What the scripts share is in _cockroachdb.sh, beside this one.
#
# Metrics:
#   up                    1 when the node answers, else 0
#   nodes                 nodes, decommissioned ones left out
#   live                  of those, live
#   dead                  dead
#   unavailable           not live, not yet dead
#   draining              draining (a restart, or decommissioning)
#   decommissioning       being decommissioned
#   decommissioned        decommissioned
#   versions              versions the nodes run
#   version_info          always 1, for each version, tagged version=<v26.4.1>
#   cluster_version       always 1, tagged version=<26.4>: the cluster's
#   upgrade_pending       1 when the cluster's version is behind its oldest
#                         node's, else 0
#   downgrade_preserved   1 when cluster.preserve_downgrade_option is set, else
#                         0: an upgrade waits for it to be reset
#   node_status           each node's: 3 live, 6 draining, 4 decommissioning,
#                         2 unavailable, 1 dead, 0 unknown; tagged node=<id>,
#                         status=<live, dead...>, version=<v26.4.1> and
#                         address=<host:port>
#   node_uptime_seconds   since each node started, tagged node=<id>
#   nodes_not_shown       nodes past the first 100, worst first, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric nodes 3
#   metric live 2
#   metric dead 1
#   metric versions 1
#   metric node_status 1 node=2 status=dead version=v26.4.1 address=crdb2:26257
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  live equal to nodes; dead and unavailable 0; versions 1;
#            upgrade_pending 0.
#   Watch    unavailable above 0 (a node restarting, or failing); draining
#            above 0 for long; decommissioning stuck; versions 2 for longer
#            than a rolling upgrade takes.
#   Act      dead above 0: its replicas are being moved, and another loss may
#            take ranges with it; live below a majority of nodes;
#            upgrade_pending 1 with downgrade_preserved 0 for long: the
#            upgrade did not finish.
#
# Requires: bash, curl and jq; a user with VIEWCLUSTERMETADATA and
#   VIEWCLUSTERSETTING
# Exit code: 0 on success, node up or down; 1 if curl or jq is missing, the
#   login is refused, or the user lacks a privilege
#
# Example (vigil.config):
#   [job.cockroachdb_cluster]
#   file        = packs/cockroachdb/cluster.sh
#   metric_name = cockroachdb.cluster
#   run_every   = 1m
#   env         = COCKROACH_URL=https://localhost:8080
#   env         = COCKROACH_CACERT=/var/lib/cockroach/certs/ca.crt
#   env         = COCKROACH_USER=vigil
#   secret      = COCKROACH_PASSWORD=secret:COCKROACH_PASSWORD

set -u

job=cluster
# shellcheck source=/dev/null
. "$(dirname "$0")/_cockroachdb.sh"

login
get '/api/v2/nodes/?limit=10000'
case $? in
    0) ;;
    2) echo "metric up 0"; exit 0 ;;
    3) echo "metric up 0"; echo "$job: /api/v2/nodes/ answered HTTP 503: the cluster is not available" >&2; exit 1 ;;
    4) echo "metric up 0"; echo "$job: this user may not read the nodes: GRANT SYSTEM VIEWCLUSTERMETADATA TO it (packs/cockroachdb/README.md)" >&2; exit 1 ;;
    *) echo "metric up 0"; exit 1 ;;
esac
echo "metric up 1"
cp "$work/body" "$work/nodes"
sql 'SHOW CLUSTER SETTING version'
cp "$work/rows" "$work/version"
sql 'SHOW CLUSTER SETTING cluster.preserve_downgrade_option'
jq -r --argjson now "$now" --slurpfile v "$work/version" --slurpfile p "$work/rows" "$jqlib"'
    def word: {"1": "dead", "2": "unavailable", "3": "live", "4": "decommissioning", "5": "decommissioned", "6": "draining"}[tostring] // "unknown";
    # Worst first: dead, unavailable, unknown, decommissioning, draining, live.
    def rank: {"1": 0, "2": 1, "0": 2, "4": 3, "6": 4, "3": 5}[tostring] // 2;
    def mm: tostring | ltrimstr("v") | split(".") | .[0:2] | map(tonumber? // 0);
    [.nodes[]? | .s = (.liveness_status // 0)] as $all |
    [$all[] | select(.s != 5)] as $n |
    ($v[0][0].version // "") as $cv |
    ([$n[].build_tag | mm] | min) as $oldest |
    "metric nodes \($n | length)",
    "metric live \([$n[] | select(.s == 3)] | length)",
    "metric dead \([$n[] | select(.s == 1)] | length)",
    "metric unavailable \([$n[] | select(.s == 2)] | length)",
    "metric draining \([$n[] | select(.s == 6)] | length)",
    "metric decommissioning \([$n[] | select(.s == 4)] | length)",
    "metric decommissioned \([$all[] | select(.s == 5)] | length)",
    "metric versions \([$n[].build_tag] | unique | length)",
    ([$n[].build_tag] | unique[] | "metric version_info 1 version=\(tag)"),
    (if $cv != "" then
        "metric cluster_version 1 version=\($cv | tag)",
        "metric upgrade_pending \(if $oldest != null and ($cv | mm) < $oldest then 1 else 0 end)"
     else empty end),
    "metric downgrade_preserved \(if (($p[0][0] // {}) | to_entries[0].value // "") != "" then 1 else 0 end)",
    ($n | sort_by([(.s | rank), .node_id]) | .[0:100][] |
        "node=\(.node_id | tag)" as $t |
        "metric node_status \(.s) \($t) status=\(.s | word) version=\(.build_tag | tag) address=\(.address.address_field | tag)",
        (if (.started_at | n) > 0 then "metric node_uptime_seconds \([($now - (.started_at / 1000000000) | floor), 0] | max) \($t)" else empty end)),
    "metric nodes_not_shown \([($n | length) - 100, 0] | max)"
' "$work/nodes"
exit 0
