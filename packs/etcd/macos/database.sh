#!/usr/bin/env bash
#
# database.sh - how full an etcd member's database is, against its quota
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
# Reports the database's size against its quota (past it, etcd raises the
# NOSPACE alarm and takes no more writes), the space in use and the space a
# defragmentation would give back, the keys and revisions and how far the
# revision is past the last compaction, the requests that read and change
# keys, the watchers, and the leases. It only reads: every request is a GET,
# and it changes nothing.
#
# Reads ETCD_URL (default http://localhost:2381): /metrics, etcd's page about
# itself.
# What the scripts share is in _etcd.sh, beside this one.
#
# Metrics:
#   up                       1 when etcd answered its metrics page, else 0
#                            (and nothing more is read)
#   db_bytes                 the database file's size
#   quota_bytes              its quota (--quota-backend-bytes; 2 GiB by
#                            default)
#   db_used_pct              the file, as a percent of the quota: near 100,
#                            the NOSPACE alarm (raised when a write would pass
#                            the quota)
#   db_in_use_bytes          of the file, the space in use
#   fragmented_bytes         the space a defragmentation would give back
#   keys                     keys
#   revision                 the current revision
#   compacted_revision       the revision compacted to
#   revisions_kept           revisions kept since the last compaction: history
#                            that fills the database
#   last_compaction_seconds  seconds since the last compaction (none since
#                            this member started: nothing)
#   puts_count               puts (a running total)
#   deletes_count            deletes (a running total)
#   ranges_count             reads (a running total)
#   txns_count               transactions (a running total)
#   watchers                 watchers
#   watch_streams            watch streams
#   slow_watchers            watchers behind the events they watch
#   leases_granted_count     leases granted (a running total)
#   leases_expired_count     leases that expired (a running total)
#   defrag_running           1 while a defragmentation runs: the member
#                            answers nothing meanwhile
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric db_bytes 167936
#   metric quota_bytes 2147483648
#   metric db_used_pct 0.01
#   metric db_in_use_bytes 167936
#   metric fragmented_bytes 0
#   metric keys 500
#   metric revision 2005
#   metric compacted_revision -1
#   metric revisions_kept 2006
#   metric puts_count 2002
#   metric deletes_count 2
#   metric ranges_count 3
#   metric txns_count 0
#   metric watchers 1
#   metric watch_streams 1
#   metric slow_watchers 0
#   metric leases_granted_count 2
#   metric leases_expired_count 2
#   metric defrag_running 0
#
# Reading the results (starting points: tune them to your own):
#   Healthy  db_used_pct well below 80; revisions_kept steady (compaction
#            runs); slow_watchers 0.
#   Watch    db_used_pct above 80; fragmented_bytes a large share of db_bytes:
#            a defragmentation would give it back; revisions_kept growing:
#            nothing compacts (Kubernetes compacts every 5 minutes).
#   Act      db_used_pct near 100: at the quota, etcd raises NOSPACE and takes
#            no writes until it is compacted, defragmented and the alarm
#            disarmed; slow_watchers above 0 for long.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when etcd does not answer (up 0 is the
#   reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or awk is missing

set -u

job=database
# shellcheck source=/dev/null
. "$(dirname "$0")/_etcd.sh"
needs curl awk

page '/metrics'
readings <<'T'
db_bytes|sum|etcd_mvcc_db_total_size_in_bytes
quota_bytes|sum|etcd_server_quota_backend_bytes
db_used_pct|pct|db_bytes|quota_bytes
db_in_use_bytes|sum|etcd_mvcc_db_total_size_in_use_in_bytes
fragmented_bytes|sub|db_bytes|db_in_use_bytes
keys|sum|etcd_debugging_mvcc_keys_total
revision|sum|etcd_debugging_mvcc_current_revision
compacted_revision|sum|etcd_debugging_mvcc_compact_revision
revisions_kept|sub|revision|compacted_revision
last_compaction_seconds|age|etcd_debugging_mvcc_db_compaction_last
puts_count|sum|etcd_mvcc_put_total
deletes_count|sum|etcd_mvcc_delete_total
ranges_count|sum|etcd_mvcc_range_total
txns_count|sum|etcd_mvcc_txn_total
watchers|sum|etcd_debugging_mvcc_watcher_total
watch_streams|sum|etcd_debugging_mvcc_watch_stream_total
slow_watchers|sum|etcd_debugging_mvcc_slow_watcher_total
leases_granted_count|sum|etcd_debugging_lease_granted_total
leases_expired_count|sum|etcd_debugging_server_lease_expired_total
defrag_running|max|etcd_disk_defrag_inflight
T
exit 0
