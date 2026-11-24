#!/usr/bin/env bash
#
# allocation.sh - where a cluster may put its shards: disks, watermarks and settings
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
# Reports each data node's disk as OpenSearch weighs it for shards: its
# shards, the bytes its indices take, its disk used, free and total, and which
# disk watermark it is past (low: no new shards come to it; high: shards move
# off it; flood stage: its indices take no more writes), from the cluster's
# own watermarks and headroom. Then the settings that stop shards moving,
# which are often left behind after maintenance: allocation and rebalancing
# turned off, nodes excluded, the disk check off, and the cluster's shard
# limit against the shards it has. It only reads: it changes nothing in the
# cluster.
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
#   up                      1 when OpenSearch answers, else 0
#   shards                  a node's shards, tagged node=<its name>
#   undesired_shards        of those, shards the balancer wants elsewhere
#                           (Elasticsearch 8.6 and later)
#   disk_indices_bytes      the bytes its indices take
#   disk_used_bytes         its disk used, by anything
#   disk_free_bytes         its disk free
#   disk_total_bytes        its disk size
#   disk_used_pct           its disk used, as OpenSearch counts it
#   watermark               the disk watermark it is past: 0 none, 1 low, 2
#                           high, 3 flood stage; tagged the same
#   nodes_over_low          nodes past the low watermark: no new shards come
#                           to them
#   nodes_over_high         past the high watermark: shards move off them
#   nodes_over_flood        past the flood stage: their indices take no more
#                           writes
#   watermark_pct           a watermark set as a percentage of the disk used,
#                           tagged level=<low, high or flood_stage>
#   watermark_free_bytes    a watermark set as free space, tagged the same
#   disk_threshold_enabled  1 when OpenSearch weighs disks at all (the
#                           default)
#   allocation_enabled      1 when shards may be allocated
#                           (cluster.routing.allocation.enable all), tagged
#                           setting=<all, primaries, new_primaries or none>
#   rebalance_enabled       1 when shards may be rebalanced
#                           (cluster.routing.rebalance.enable all), tagged
#                           setting=<it>
#   exclusions              allocation filters excluding nodes
#                           (cluster.routing.allocation.exclude)
#   exclusion               always 1, for each, tagged attribute=<_name, _ip,
#                           _host or yours> and value=<what is excluded>
#   max_shards_per_node     the cluster's limit of open shards a data node
#   shards_capacity_pct     the cluster's shards, as a percentage of the limit
#                           for its data nodes: at 100, no index can be
#                           created
#   nodes_not_shown         nodes past the first 100, by name, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric disk_used_pct 65 node=os310a
#   metric watermark 2 node=os310a
#   metric nodes_over_high 3
#   metric allocation_enabled 0 setting=primaries
#   metric exclusion 1 attribute=_name value=decommissioned-1
#   metric shards_capacity_pct 100
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  watermark 0 on every node; allocation_enabled and
#            rebalance_enabled 1; exclusions 0; shards_capacity_pct below 80.
#   Watch    nodes_over_low above 0: that node takes no new shards; exclusions
#            above 0 after maintenance; undesired_shards staying above 0.
#   Act      nodes_over_high above 0: shards moving off a full disk;
#            nodes_over_flood above 0: writes to its indices fail;
#            allocation_enabled 0 left after a restart: replicas stay
#            unassigned; shards_capacity_pct near 100: new indices fail.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, OpenSearch up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, this user may not read what the
#   job needs, or the address is not OpenSearch

set -u

job=allocation
# shellcheck source=/dev/null
. "$(dirname "$0")/_opensearch.sh"

first
need '/_cat/allocation?format=json&bytes=b'
cp "$work/body" "$work/alloc"
need '/_cluster/settings?include_defaults=true&filter_path=*.cluster.routing.allocation.disk.watermark,*.cluster.routing.allocation.disk.threshold_enabled,*.cluster.routing.allocation.enable,*.cluster.routing.rebalance.enable,*.cluster.max_shards_per_node,*.cluster.routing.allocation.exclude'
jq -r --slurpfile al "$work/alloc" "$jqlib"'
    def bytes: ascii_downcase | capture("^(?<n>[0-9.]+)\\s*(?<u>[a-z]*)$") as $c |
        ($c.n | tonumber) * ({"": 1, "b": 1, "k": 1024, "kb": 1024, "m": 1048576, "mb": 1048576, "g": 1073741824, "gb": 1073741824,
            "t": 1099511627776, "tb": 1099511627776, "p": 1125899906842624, "pb": 1125899906842624}[$c.u] // 1);
    def wm: if . == null then null elif test("%$") then {pct: (rtrimstr("%") | tonumber)}
        elif test("^[0-9.]+$") then {pct: (tonumber * 100)} else {free: bytes} end;
    def at(p): (.transient | try getpath(p) catch null) // (.persistent | try getpath(p) catch null);
    def eff(p): at(p) // (.defaults | try getpath(p) catch null);
    def needfree(total): . as $x | if $x.w == null then null elif $x.w.pct != null then
        (total * (100 - $x.w.pct) / 100) as $f | (if $x.h != null and $x.h >= 0 then [$f, $x.h] | min else $f end) else $x.w.free end;
    ["cluster", "routing", "allocation", "disk", "watermark"] as $w |
    . as $s |
    # Each level: its watermark, and the headroom that caps it (set, or the
    # default when the watermark itself is not set).
    [["low", "high", "flood_stage"][] | . as $l | {level: $l, w: ($s | eff($w + [$l]) | wm),
        h: ((($s | at($w + [$l + ".max_headroom"])) // (if ($s | at($w + [$l])) == null then ($s.defaults | try getpath($w + [$l + ".max_headroom"]) catch null) else null end))
            | if . == null or . == "-1" then null else bytes end)}] as $lv |
    (($s | eff(["cluster", "routing", "allocation", "disk", "threshold_enabled"])) // "true" | tostring) as $on |
    [$al[0][] | select(.node != "UNASSIGNED" and .["disk.total"] != null)] | sort_by(.node) | . as $nodes |
    [$nodes[] | (.["disk.total"] | n) as $tot | (.["disk.avail"] | n) as $free |
        . + {level: (if $on != "true" then 0 else ([$lv[] | needfree($tot)] as $nf |
            if $nf[2] != null and $free < $nf[2] then 3 elif $nf[1] != null and $free < $nf[1] then 2 elif $nf[0] != null and $free < $nf[0] then 1 else 0 end) end)}] |
    (.[0:100][] | "node=\(.node | tag)" as $t |
        "metric shards \(.shards | n) \($t)",
        (if .["shards.undesired"] != null then "metric undesired_shards \(.["shards.undesired"] | n) \($t)" else empty end),
        "metric disk_indices_bytes \(.["disk.indices"] | n) \($t)",
        "metric disk_used_bytes \(.["disk.used"] | n) \($t)",
        "metric disk_free_bytes \(.["disk.avail"] | n) \($t)",
        "metric disk_total_bytes \(.["disk.total"] | n) \($t)",
        "metric disk_used_pct \(.["disk.percent"] | n) \($t)",
        "metric watermark \(.level) \($t)"),
    "metric nodes_over_low \([.[] | select(.level >= 1)] | length)",
    "metric nodes_over_high \([.[] | select(.level >= 2)] | length)",
    "metric nodes_over_flood \([.[] | select(.level >= 3)] | length)",
    ($lv[] | if .w.pct != null then "metric watermark_pct \(.w.pct | r2) level=\(.level)" elif .w.free != null then "metric watermark_free_bytes \(.w.free | floor) level=\(.level)" else empty end),
    "metric disk_threshold_enabled \(if $on == "true" then 1 else 0 end)",
    (($s | eff(["cluster", "routing", "allocation", "enable"])) // "all" | "metric allocation_enabled \(if . == "all" then 1 else 0 end) setting=\(tag)"),
    (($s | eff(["cluster", "routing", "rebalance", "enable"])) // "all" | "metric rebalance_enabled \(if . == "all" then 1 else 0 end) setting=\(tag)"),
    ([($s | at(["cluster", "routing", "allocation", "exclude"])) // {} | to_entries[] | select(.value != null and .value != "")] |
        "metric exclusions \(length)",
        (.[] | "metric exclusion 1 attribute=\(.key | tag) value=\(.value | tag)")),
    ((($s | eff(["cluster", "max_shards_per_node"])) // "1000" | n) as $max |
        "metric max_shards_per_node \($max)",
        "metric shards_capacity_pct \(pct([$al[0][].shards | n] | add // 0; $max * ($nodes | length)))"),
    "metric nodes_not_shown \([($nodes | length) - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
