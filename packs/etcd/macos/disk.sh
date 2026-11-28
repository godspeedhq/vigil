#!/usr/bin/env bash
#
# disk.sh - is an etcd member's disk fast enough
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
# Reports how fast the member's disk is where etcd needs it: the WAL's fsyncs
# and the backend's commits, each on average and those that were slow, the
# bytes written to the WAL, and the round trip to its peers. A slow disk shows
# first as missed heartbeats and leader changes. It only reads: every request
# is a GET, and it changes nothing.
#
# Reads ETCD_URL (default http://localhost:2381): /metrics, etcd's page about
# itself.
# What the scripts share is in _etcd.sh, beside this one.
#
# Metrics:
#   up                          1 when etcd answered its metrics page, else 0
#                               (and nothing more is read)
#   wal_fsyncs_count            WAL fsyncs (a running total)
#   wal_fsync_avg_ms            their average, in milliseconds, since the
#                               member started
#   wal_fsyncs_slow_count       of them, over 16 ms (a running total): etcd
#                               wants most under 10
#   backend_commits_count       backend commits (a running total)
#   backend_commit_avg_ms       their average, in milliseconds
#   backend_commits_slow_count  of them, over 32 ms (a running total): etcd
#                               wants most under 25
#   wal_written_bytes_count     bytes written to the WAL (a running total)
#   peer_rtt_avg_ms             the round trip to its peers, on average, in
#                               milliseconds (none alone)
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  wal_fsyncs_slow_count and backend_commits_slow_count rising
#            slowly, if at all, against their totals.
#   Watch    wal_fsync_avg_ms above 10 or backend_commit_avg_ms above 25; the
#            slow counts rising with the totals.
#   Act      the slow counts rising fast with leader changes (the status job):
#            the disk is too slow for etcd. Give it an SSD of its own;
#            peer_rtt_avg_ms above 50: the network between members.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when etcd does not answer (up 0 is the
#   reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or awk is missing

set -u

job=disk
# shellcheck source=/dev/null
. "$(dirname "$0")/_etcd.sh"
needs curl awk

page '/metrics'
readings <<'T'
wal_fsyncs_count|sum|etcd_disk_wal_fsync_duration_seconds_count
_wf_s|sum|etcd_disk_wal_fsync_duration_seconds_sum
_wf_avg|div|_wf_s|wal_fsyncs_count
wal_fsync_avg_ms|mul|_wf_avg|1000
_wf_all|sum|etcd_disk_wal_fsync_duration_seconds_bucket|le=+Inf
_wf_fast|sum|etcd_disk_wal_fsync_duration_seconds_bucket|le=0.016
wal_fsyncs_slow_count|sub|_wf_all|_wf_fast
backend_commits_count|sum|etcd_disk_backend_commit_duration_seconds_count
_bc_s|sum|etcd_disk_backend_commit_duration_seconds_sum
_bc_avg|div|_bc_s|backend_commits_count
backend_commit_avg_ms|mul|_bc_avg|1000
_bc_all|sum|etcd_disk_backend_commit_duration_seconds_bucket|le=+Inf
_bc_fast|sum|etcd_disk_backend_commit_duration_seconds_bucket|le=0.032
backend_commits_slow_count|sub|_bc_all|_bc_fast
wal_written_bytes_count|sum|etcd_disk_wal_write_bytes_total
_rtt_s|sum?|etcd_network_peer_round_trip_time_seconds_sum
_rtt_n|sum?|etcd_network_peer_round_trip_time_seconds_count
_rtt_avg|div|_rtt_s|_rtt_n
peer_rtt_avg_ms|mul|_rtt_avg|1000
T
exit 0
