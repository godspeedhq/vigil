#!/usr/bin/env bash
#
# cluster.sh - Alertmanager's cluster
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
# Reports this Alertmanager's view of its cluster: whether clustering is on,
# the members it sees and the peers it has lost, its health score, its
# position among the members, the gossip messages waiting, and reconnections
# that failed. A single Alertmanager reports members 1. It only reads: every
# request is a GET, and it changes nothing.
#
# Reads ALERTMANAGER_URL (default http://localhost:9093): /metrics,
# Alertmanager's page about itself.
# What the scripts share is in _alertmanager.sh, beside this one.
#
# Metrics:
#   up                          1 when Alertmanager answered its metrics page,
#                               else 0 (and nothing more is read)
#   cluster_enabled             1 when clustering is on, else 0
#   members                     members this one sees, itself included
#   failed_peers                peers it has lost and is trying to reach
#   health_score                0 when its gossip is healthy; higher, the
#                               worse
#   peer_position               its position among the members (0 is first to
#                               notify)
#   messages_queued             gossip messages waiting to be sent
#   messages_pruned_count       messages dropped from a full queue (a running
#                               total)
#   reconnections_count         reconnections to peers attempted (a running
#                               total)
#   reconnections_failed_count  reconnections that failed (a running total)
#   peers_joined_count          peers that joined (a running total)
#   peers_left_count            peers that left (a running total)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric cluster_enabled 1
#   metric members 2
#   metric failed_peers 0
#   metric health_score 0
#   metric peer_position 1
#   metric messages_queued 0
#   metric messages_pruned_count 0
#   metric reconnections_count 0
#   metric reconnections_failed_count 0
#   metric peers_joined_count 2
#   metric peers_left_count 0
#
# Reading the results (starting points: tune them to your own):
#   Healthy  members the number you run, on every member; failed_peers 0;
#            health_score 0.
#   Watch    peers_left_count or reconnections_failed_count moving (a member
#            restarting, or a network that drops); messages_queued growing.
#   Act      members below the number you run, or failed_peers above 0: the
#            cluster is split, and each side notifies on its own: expect
#            duplicate notifications, and silences set on one side missing on
#            the other; health_score staying above 0.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Alertmanager does not answer (up 0
#   is the reading); 1 when it answers wrong (a login refused, not HTTP), said
#   on stderr, or curl or awk is missing

set -u

job=cluster
# shellcheck source=/dev/null
. "$(dirname "$0")/_alertmanager.sh"
needs curl awk

page '/metrics'
readings <<'T'
cluster_enabled|min|alertmanager_cluster_enabled
members|sum|alertmanager_cluster_members
failed_peers|sum|alertmanager_cluster_failed_peers
health_score|max|alertmanager_cluster_health_score
peer_position|max|alertmanager_peer_position
messages_queued|sum|alertmanager_cluster_messages_queued
messages_pruned_count|sum|alertmanager_cluster_messages_pruned_total
reconnections_count|sum|alertmanager_cluster_reconnections_total
reconnections_failed_count|sum|alertmanager_cluster_reconnections_failed_total
peers_joined_count|sum|alertmanager_cluster_peers_joined_total
peers_left_count|sum|alertmanager_cluster_peers_left_total
T
exit 0
