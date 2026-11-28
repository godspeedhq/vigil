#!/usr/bin/env bash
#
# status.sh - is this etcd member healthy, with a leader and quorum
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
# Reports whether the member is healthy, whether its cluster has a leader
# (without one, it has lost quorum and takes no writes), whether this member
# is the leader or a learner, how often the leader has changed, the members it
# knows and the peers it can reach, the proposals committed, applied, waiting
# and failed, and applies and reads that were slow or failed. It only reads:
# every request is a GET, and it changes nothing.
#
# Reads ETCD_URL (default http://localhost:2381): /metrics, etcd's page about
# itself, and /health.
# What the scripts share is in _etcd.sh, beside this one.
#
# Metrics:
#   up                         1 when etcd answered its metrics page, else 0
#                              (and nothing more is read)
#   healthy                    1 when /health answers 200, else 0: no leader,
#                              or an alarm (NOSPACE when the database is at
#                              its quota; etcdctl alarm list says which)
#   version                    always 1, tagged version=<its version>
#   cluster_version            always 1, tagged version=<the cluster's
#                              version>
#   has_leader                 1 when the cluster has a leader, 0 when it has
#                              none: quorum is lost, and no write succeeds
#   is_leader                  1 when this member is the leader
#   is_learner                 1 when this member is a learner, not yet voting
#   leader_changes_count       leader changes this member has seen (a running
#                              total)
#   members                    members of its cluster, itself counted
#   peers_active               other members it is connected to
#   peers_unreachable          other members it is not connected to
#   heartbeat_failures_count   heartbeats the leader failed to send (a running
#                              total)
#   peer_send_failures_count   messages to peers that failed (a running total)
#   proposals_committed_count  proposals committed (a running total)
#   proposals_applied_count    proposals applied (a running total)
#   apply_backlog              committed and not yet applied
#   proposals_pending          proposals waiting to be committed
#   proposals_failed_count     proposals that failed: no leader, or a timeout
#                              (a running total)
#   slow_applies_count         applies that took over 100 ms (a running total)
#   read_indexes_failed_count  linearizable reads that failed (a running
#                              total)
#   slow_read_indexes_count    linearizable reads that were slow (a running
#                              total)
#   health_failures_count      health checks that failed (a running total)
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  up 1; healthy 1; has_leader 1; peers_unreachable 0;
#            proposals_failed_count and leader_changes_count not moving.
#   Watch    leader_changes_count moving: elections, from a slow disk or
#            network (the disk job), or members restarting; apply_backlog or
#            proposals_pending growing; slow_applies_count moving.
#   Act      has_leader 0: quorum is lost, nothing can be written; healthy 0
#            with has_leader 1: an alarm (NOSPACE: the database job, then
#            compact, defragment and etcdctl alarm disarm); peers_unreachable
#            above 0: a member is down or cut off, and one more lost may cost
#            quorum; proposals_failed_count moving.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when etcd does not answer (up 0 is the
#   reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or awk is missing

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_etcd.sh"
needs curl awk

page '/metrics'
answers healthy '/health'
readings <<'T'
version|info|etcd_server_version||server_version:version
cluster_version|info?|etcd_cluster_version||cluster_version:version
has_leader|max|etcd_server_has_leader
is_leader|max|etcd_server_is_leader
is_learner|max|etcd_server_is_learner
leader_changes_count|sum|etcd_server_leader_changes_seen_total
_peers|count|etcd_network_active_peers
members|add|_peers|1
peers_active|count|etcd_network_active_peers||=1
peers_unreachable|count|etcd_network_active_peers||=0
heartbeat_failures_count|sum|etcd_server_heartbeat_send_failures_total
peer_send_failures_count|sum|etcd_network_peer_sent_failures_total
proposals_committed_count|sum|etcd_server_proposals_committed_total
proposals_applied_count|sum|etcd_server_proposals_applied_total
apply_backlog|sub|proposals_committed_count|proposals_applied_count
proposals_pending|sum|etcd_server_proposals_pending
proposals_failed_count|sum|etcd_server_proposals_failed_total
slow_applies_count|sum|etcd_server_slow_apply_total
read_indexes_failed_count|sum|etcd_server_read_indexes_failed_total
slow_read_indexes_count|sum|etcd_server_slow_read_indexes_total
health_failures_count|sum|etcd_server_health_failures
T
exit 0
