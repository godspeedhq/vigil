#!/usr/bin/env bash
#
# replication.sh - a CockroachDB node's ranges: replicated, available, moving
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
# Reports the ranges a node holds, from its own metrics: the replicas and
# leases on its stores, and the ranges it leads that are unavailable (a
# quorum of their replicas lost: their data cannot be read or written),
# under-replicated (fewer replicas than their zone asks for) or
# over-replicated, and those with a replica on a node being decommissioned.
# A range is counted by the node that holds its lease, so each node reports
# its share: the cluster's are the sum over every node. And requests stuck
# for a long time (on raft, a lease, latches, or between nodes), and the
# replicate queue's backlog. Run it on every node. It needs no login.
#
# Reads CockroachDB at COCKROACH_URL (default https://localhost:8080), the
# node's HTTP port, with curl and jq: /_status/vars. Over https, the
# certificate is checked against COCKROACH_CACERT, the cluster's CA file
# (ca.crt), when it is set, else the system's CAs. What the scripts share is
# in _cockroachdb.sh, beside this one.
#
# Metrics:
#   up                          1 when the node answers, else 0
#   ranges                      ranges on its stores
#   replicas                    replicas on its stores
#   leaseholders                of those, holding their range's lease
#   raft_leaders                of those, raft leaders
#   leaders_not_leaseholders    raft leaders whose lease another store holds:
#                               more than a few, and requests take a detour
#   ranges_unavailable          ranges it leads that lost a quorum
#   ranges_underreplicated      ranges it leads with too few replicas
#   ranges_overreplicated       ranges it leads with too many
#   ranges_decommissioning      ranges it leads with a replica on a node being
#                               decommissioned
#   slow_raft                   requests stuck in raft for a long time
#   slow_lease                  requests stuck acquiring a lease
#   slow_latch                  requests stuck acquiring latches
#   slow_distsender             requests stuck on their way to another node
#   replicate_queue_pending     replicas waiting for the replicate queue
#   splits_count                ranges split (a running total)
#   merges_count                ranges merged (a running total)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric ranges 81
#   metric replicas 81
#   metric leaseholders 27
#   metric ranges_unavailable 0
#   metric ranges_underreplicated 0
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  ranges_unavailable 0, ranges_underreplicated 0, and every
#            slow_ count 0, on every node.
#   Watch    ranges_underreplicated above 0 for more than a few minutes after a
#            node left (the cluster replaces a dead node's replicas after 5
#            minutes, server.time_until_store_dead); ranges_decommissioning
#            not falling; replicate_queue_pending growing.
#   Act      ranges_unavailable above 0: some data cannot be read or written
#            until the lost nodes return; slow_raft, slow_lease or slow_latch
#            above 0 for more than a few minutes. A node cut off from a
#            quorum counts no range unavailable (no lease is left to count
#            them): there, the status job's ready 0 and live_nodes 0 say it.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, node up or down; 1 if curl or jq is missing, or
#   the node answers wrong
#
# Example (vigil.config):
#   [job.cockroachdb_replication]
#   file        = packs/cockroachdb/replication.sh
#   metric_name = cockroachdb.replication
#   run_every   = 1m
#   env         = COCKROACH_URL=https://localhost:8080
#   env         = COCKROACH_CACERT=/var/lib/cockroach/certs/ca.crt

set -u

job=replication
# shellcheck source=/dev/null
. "$(dirname "$0")/_cockroachdb.sh"

vars
say ranges ranges
say replicas replicas
say leaseholders replicas_leaseholders
say raft_leaders replicas_leaders
say leaders_not_leaseholders replicas_leaders_not_leaseholders
say ranges_unavailable ranges_unavailable
say ranges_underreplicated ranges_underreplicated
say ranges_overreplicated ranges_overreplicated
say ranges_decommissioning ranges_decommissioning
say slow_raft requests_slow_raft
say slow_lease requests_slow_lease
say slow_latch requests_slow_latch
say slow_distsender requests_slow_distsender
say replicate_queue_pending queue_replicate_pending
say splits_count range_splits
say merges_count range_merges
exit 0
