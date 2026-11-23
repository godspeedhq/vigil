#!/usr/bin/env bash
#
# nodes.sh - each node of a cluster
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
# Reports the cluster's nodes, by role and version, and each node as
# Elasticsearch sees it: its version and roles, whether it is the elected
# master, its CPU and load, memory, open files against the limit, its data
# disk, HTTP and transport connections and traffic, and indexing pressure: the
# memory held by writes in flight against the limit, and the writes refused
# for it. Never its JVM's heap or garbage collection: those are the jvm
# pack's. It only reads: it changes nothing in the cluster.
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
#   up                             1 when Elasticsearch answers, else 0
#   nodes                          nodes in the cluster
#   master_eligible                of those, nodes that may be elected master
#   data_nodes                     nodes that hold data
#   ingest_nodes                   nodes that run ingest pipelines
#   coordinating_only              nodes with no role: they only route
#                                  requests
#   versions                       Elasticsearch versions among the nodes:
#                                  more than 1 during an upgrade, or one left
#                                  behind
#   info                           always 1, tagged node=<its name>,
#                                  version=<its version> and roles=<its roles,
#                                  as _cat/nodes abbreviates them>
#   master                         1 when the node is the elected master,
#                                  tagged node=<its name>
#   cpu_pct                        the CPU in use on the node's machine (or
#                                  container), tagged the same
#   load_1m                        its load average over a minute, tagged the
#                                  same (not on Windows)
#   load_5m                        over 5 minutes
#   load_15m                       over 15 minutes
#   mem_used_pct                   the machine's (or container's) memory in
#                                  use
#   process_cpu_pct                the CPU Elasticsearch's process uses
#   open_fds                       files it has open
#   max_fds                        files it may have open
#   fds_pct                        open_fds, as a percentage of max_fds
#   disk_total_bytes               the size of the node's data disks
#   disk_free_bytes                of that, free for Elasticsearch
#   disk_used_pct                  the data disks in use
#   http_open                      HTTP connections open
#   http_opened                    HTTP connections opened since it started (a
#                                  counter)
#   transport_open                 connections open to the other nodes
#   transport_rx_bytes             bytes received from the other nodes (a
#                                  counter)
#   transport_tx_bytes             bytes sent to them (a counter)
#   indexing_pressure_bytes        memory held by writes in flight on the node
#   indexing_pressure_limit_bytes  the most it may hold
#   indexing_pressure_pct          indexing_pressure_bytes, as a percentage of
#                                  the limit
#   indexing_rejections            writes refused for it, since the node
#                                  started (a counter)
#   nodes_not_shown                nodes past the first 100, by name, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric nodes 3
#   metric versions 1
#   metric info 1 node=es95a version=9.5.5 roles=cdfhilmrstw
#   metric master 0 node=es95a
#   metric cpu_pct 90 node=es95a
#   metric load_1m 9.94 node=es95a
#   metric mem_used_pct 77 node=es95a
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  nodes as many as you run; versions 1; fds_pct and disk_used_pct
#            well below 80; indexing_rejections flat.
#   Watch    cpu_pct high on one node only: a hot shard; fds_pct above 80;
#            disk_used_pct nearing the disk watermarks (the allocation job);
#            indexing_pressure_pct above 50.
#   Act      nodes below what you run: a node left; versions above 1 when no
#            upgrade runs; indexing_rejections rising: writes refused, clients
#            see HTTP 429.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Elasticsearch up or down; 1 if curl or jq is
#   missing, a setting is wrong, the login is refused, this user may not read
#   what the job needs, or the address is not Elasticsearch

set -u

job=nodes
# shellcheck source=/dev/null
. "$(dirname "$0")/_elasticsearch.sh"

first
need '/_cat/nodes?format=json&full_id=true&h=id,name,version,node.role,master'
cp "$work/body" "$work/cat"
need '/_nodes/stats/os,process,fs,http,transport,indexing_pressure?filter_path=nodes.*.name,nodes.*.roles,nodes.*.os.cpu.percent,nodes.*.os.cpu.load_average,nodes.*.os.mem.used_percent,nodes.*.process.cpu.percent,nodes.*.process.open_file_descriptors,nodes.*.process.max_file_descriptors,nodes.*.fs.total,nodes.*.http.current_open,nodes.*.http.total_opened,nodes.*.transport.server_open,nodes.*.transport.rx_size_in_bytes,nodes.*.transport.tx_size_in_bytes,nodes.*.indexing_pressure.memory'
jq -r --slurpfile cat "$work/cat" "$jqlib"'
    ($cat[0] | map({key: .id, value: .}) | from_entries) as $c |
    [.nodes | to_entries[] | .value + {id: .key}] | sort_by(.name) |
    "metric nodes \(length)",
    "metric master_eligible \([.[] | select(.roles | index("master") or index("cluster_manager"))] | length)",
    "metric data_nodes \([.[] | select(any(.roles[]; startswith("data")))] | length)",
    "metric ingest_nodes \([.[] | select(.roles | index("ingest"))] | length)",
    "metric coordinating_only \([.[] | select((.roles | length) == 0)] | length)",
    "metric versions \([$c[].version] | unique | length)",
    (.[0:100][] | "node=\(.name | tag)" as $t | ($c[.id] // {}) as $k |
        "metric info 1 \($t) version=\($k.version | tag) roles=\($k["node.role"] | tag)",
        "metric master \(if $k.master == "*" then 1 else 0 end) \($t)",
        "metric cpu_pct \(.os.cpu.percent | n) \($t)",
        (.os.cpu.load_average // empty | "metric load_1m \(.["1m"] | n) \($t)", "metric load_5m \(.["5m"] | n) \($t)", "metric load_15m \(.["15m"] | n) \($t)"),
        "metric mem_used_pct \(.os.mem.used_percent | n) \($t)",
        "metric process_cpu_pct \(.process.cpu.percent | n) \($t)",
        "metric open_fds \(.process.open_file_descriptors | n) \($t)",
        "metric max_fds \(.process.max_file_descriptors | n) \($t)",
        "metric fds_pct \(pct(.process.open_file_descriptors; .process.max_file_descriptors)) \($t)",
        "metric disk_total_bytes \(.fs.total.total_in_bytes | n) \($t)",
        "metric disk_free_bytes \(.fs.total.available_in_bytes | n) \($t)",
        "metric disk_used_pct \(pct((.fs.total.total_in_bytes | n) - (.fs.total.available_in_bytes | n); .fs.total.total_in_bytes)) \($t)",
        "metric http_open \(.http.current_open | n) \($t)",
        "metric http_opened \(.http.total_opened | n) \($t)",
        "metric transport_open \(.transport.server_open | n) \($t)",
        "metric transport_rx_bytes \(.transport.rx_size_in_bytes | n) \($t)",
        "metric transport_tx_bytes \(.transport.tx_size_in_bytes | n) \($t)",
        (.indexing_pressure.memory // empty |
            ((.current.combined_coordinating_and_primary_in_bytes | n) + (.current.replica_in_bytes | n)) as $b |
            "metric indexing_pressure_bytes \($b) \($t)",
            "metric indexing_pressure_limit_bytes \(.limit_in_bytes | n) \($t)",
            "metric indexing_pressure_pct \(pct($b; .limit_in_bytes)) \($t)",
            "metric indexing_rejections \((.total.coordinating_rejections | n) + (.total.primary_rejections | n) + (.total.replica_rejections | n)) \($t)")),
    "metric nodes_not_shown \([length - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
