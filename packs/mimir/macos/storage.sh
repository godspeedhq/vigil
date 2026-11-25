#!/usr/bin/env bash
#
# storage.sh - Mimir's blocks, compactor and bucket
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
# Reports what happens to Mimir's data after it is ingested: the blocks its
# ingester ships to the bucket and the uploads that failed, how old the oldest
# block not yet shipped is, the head compactions and truncations that failed,
# the compactor's runs and when one last succeeded, the blocks its
# store-gateway loaded and those it could not, and the bucket operations that
# failed. It only reads: every request is a GET, and it changes nothing.
#
# Reads MIMIR_URL (default http://localhost:9009): /metrics, Mimir's page
# about itself.
# What the scripts share is in _mimir.sh, beside this one.
#
# Metrics:
#   up                             1 when Mimir answered its metrics page,
#                                  else 0 (and nothing more is read)
#   shipper_uploads_count          blocks shipped to the bucket (a running
#                                  total)
#   shipper_failures_count         uploads that failed (a running total)
#   oldest_unshipped_seconds       the age of the oldest block not yet shipped
#                                  (nothing when all are)
#   head_compactions_failed_count  the ingester's head compactions that failed
#                                  (a running total)
#   head_truncations_failed_count  head truncations that failed (a running
#                                  total)
#   wal_corruptions_count          corruptions found in the WAL (a running
#                                  total)
#   wal_writes_failed_count        WAL writes that failed (a running total)
#   compactor_runs_count           compactor runs completed (a running total)
#   compactor_runs_failed_count    compactor runs that failed (a running
#                                  total)
#   last_compaction_seconds        seconds since a compactor run last
#                                  succeeded
#   cleanup_failures_count         cleanups of deleted blocks that failed (a
#                                  running total)
#   blocks_loaded                  blocks the store-gateway has loaded
#   block_load_failures_count      blocks it could not load (a running total)
#   consistency_failures_count     queries that could not find every block
#                                  they needed in a store-gateway (a running
#                                  total)
#   bucket_operations_count        operations on the bucket (a running total)
#   bucket_failures_count          operations on the bucket that failed (a
#                                  running total)
#   bucket_failures                the same, for each operation, tagged
#                                  operation=<get, upload, iter, exists,
#                                  delete ...>
#   bucket_failures_not_shown      how many more there were than the 20 shown
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  every failed count at 0; last_compaction_seconds under a few
#            compaction intervals; oldest_unshipped_seconds, when printed,
#            under a few hours.
#   Watch    bucket_failures_count moving now and then (the object store
#            throttling, or a network that drops); cleanup_failures_count
#            moving.
#   Act      shipper_failures_count moving, or oldest_unshipped_seconds
#            growing: blocks stay on the ingester's disk, which fills, and
#            they are lost if it is; compactor_runs_failed_count moving or
#            last_compaction_seconds growing: blocks pile up and queries slow;
#            block_load_failures_count or consistency_failures_count moving:
#            queries are missing data; any WAL count above 0.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Mimir does not answer (up 0 is the
#   reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or awk is missing

set -u

job=storage
# shellcheck source=/dev/null
. "$(dirname "$0")/_mimir.sh"
needs curl awk

page '/metrics'
readings <<'T'
shipper_uploads_count|sum|cortex_ingester_shipper_uploads_total
shipper_failures_count|sum|cortex_ingester_shipper_upload_failures_total
oldest_unshipped_seconds|age|cortex_ingester_oldest_unshipped_block_timestamp_seconds
head_compactions_failed_count|sum|cortex_ingester_tsdb_compactions_failed_total
head_truncations_failed_count|sum|cortex_ingester_tsdb_head_truncations_failed_total
wal_corruptions_count|sum|cortex_ingester_tsdb_wal_corruptions_total
wal_writes_failed_count|sum|cortex_ingester_tsdb_wal_writes_failed_total
compactor_runs_count|sum|cortex_compactor_runs_completed_total
compactor_runs_failed_count|sum|cortex_compactor_runs_failed_total
last_compaction_seconds|age|cortex_compactor_last_successful_run_timestamp_seconds
cleanup_failures_count|sum|cortex_compactor_block_cleanup_failures_total
blocks_loaded|sum|cortex_bucket_store_blocks_loaded
block_load_failures_count|sum|cortex_bucket_store_block_load_failures_total
consistency_failures_count|sum|cortex_querier_blocks_consistency_checks_failed_total
bucket_operations_count|sum|thanos_objstore_bucket_operations_total
bucket_failures_count|sum|thanos_objstore_bucket_operation_failures_total
bucket_failures|by|thanos_objstore_bucket_operation_failures_total||operation
T
exit 0
