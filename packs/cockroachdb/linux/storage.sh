#!/usr/bin/env bash
#
# storage.sh - a CockroachDB node's stores: disk, LSM health, write stalls
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
# Reports a node's stores, from its own metrics: their disks, how full, and
# how much of that is CockroachDB's; the health of the storage engine's LSM
# (its level 0: too many sub-levels and files, and reads slow down and
# admission control throttles writes); write stalls and a disk too slow to
# answer; and the write-ahead log's fsyncs, as running totals a backend
# turns into a mean latency. A node with more than one store reports them
# together: the fullest and worst, or the sum. Run it on every node. It
# needs no login.
#
# Reads CockroachDB at COCKROACH_URL (default https://localhost:8080), the
# node's HTTP port, with curl and jq: /_status/vars. Over https, the
# certificate is checked against COCKROACH_CACERT, the cluster's CA file
# (ca.crt), when it is set, else the system's CAs. What the scripts share is
# in _cockroachdb.sh, beside this one.
#
# Metrics:
#   up                        1 when the node answers, else 0
#   stores                    its stores
#   disk_bytes                their disks' size
#   disk_free_bytes           of those, free for CockroachDB
#   disk_used_pct             of those, used, by anything: a store stops
#                             taking writes when its disk is nearly full
#   used_bytes                CockroachDB's own data, every replica
#   live_bytes                of that, live keys and values
#   l0_sublevels              the most level-0 sub-levels a store has
#   l0_files                  level-0 files, every store
#   read_amp                  the largest read amplification
#   io_overload               the most overloaded store, 0 to 1 and past it:
#                             at 1 admission control throttles its writes
#   io_queue                  writes waiting for admission control, every
#                             store
#   io_tokens_exhausted_seconds  time writes had to wait, the store out of
#                             tokens (a running total)
#   write_stalls_count        writes stalled, the LSM too far behind (a
#                             running total)
#   write_stall_seconds       time they stalled (a running total)
#   disk_slow_count           times a disk took too long to answer (a running
#                             total)
#   wal_fsync_seconds         time the write-ahead log's fsyncs took (a
#                             running total)
#   wal_fsyncs_count          those fsyncs (a running total): divide the
#                             rates for the mean
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric stores 1
#   metric disk_bytes 117884059648
#   metric disk_used_pct 73.15
#   metric l0_sublevels 0
#   metric io_overload 0
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  disk_used_pct below 60; l0_sublevels below 10; io_overload below
#            0.5; write_stalls_count and disk_slow_count flat.
#   Watch    disk_used_pct past 70; l0_sublevels past 10 or read_amp past 20
#            for more than a few minutes: compactions are behind;
#            io_overload past 0.5; the mean fsync past 10 ms.
#   Act      disk_used_pct past 85; io_overload at 1 and above: writes are
#            throttled; write_stalls_count or disk_slow_count rising: the
#            disk cannot keep up, and a node with a stalled disk stops
#            itself.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, node up or down; 1 if curl or jq is missing, or
#   the node answers wrong
#
# Example (vigil.config):
#   [job.cockroachdb_storage]
#   file        = packs/cockroachdb/storage.sh
#   metric_name = cockroachdb.storage
#   run_every   = 1m
#   env         = COCKROACH_URL=https://localhost:8080
#   env         = COCKROACH_CACERT=/var/lib/cockroach/certs/ca.crt

set -u

job=storage
# shellcheck source=/dev/null
. "$(dirname "$0")/_cockroachdb.sh"

vars
awk '/^capacity\{/ && match($0, /store="[^"]*"/) { s[substr($0, RSTART, RLENGTH)] = 1 } END { n = 0; for (k in s) n++; printf "metric stores %d\n", n }' "$work/vars"
c=$(prom capacity)
a=$(prom capacity_available)
if [ -n "$c" ]; then
    echo "metric disk_bytes $c"
    if [ -n "$a" ]; then
        echo "metric disk_free_bytes $a"
        awk -v c="$c" -v a="$a" 'BEGIN { if (c > 0) printf "metric disk_used_pct %.2f\n", 100 * (c - a) / c }'
    fi
fi
say used_bytes capacity_used
say live_bytes livebytes
say l0_sublevels storage_l0_sublevels max
say l0_files storage_l0_num_files
say read_amp rocksdb_read_amplification max
say io_overload admission_io_overload max
say io_queue admission_wait_queue_length_kv_stores
say io_tokens_exhausted_seconds admission_granter_io_tokens_exhausted_duration_kv sum 1000000
say write_stalls_count storage_write_stalls
say write_stall_seconds storage_write_stall_nanos sum 1000000000
say disk_slow_count storage_disk_slow
say wal_fsync_seconds storage_wal_fsync_latency_sum sum 1000000000
say wal_fsyncs_count storage_wal_fsync_latency_count
exit 0
