#!/usr/bin/env bash
#
# compaction.sh - Loki's compactor and retention
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
# Reports Loki's compactor: its compactions done and failed and how long ago
# the last one succeeded, the same for retention, and the delete requests
# waiting with the age of the oldest. It reports little where no compactor
# runs at LOKI_URL. It only reads: every request is a GET, and it changes
# nothing.
#
# Reads LOKI_URL (default http://localhost:3100): /metrics, Loki's page about
# itself.
# What the scripts share is in _loki.sh, beside this one.
#
# Metrics:
#   up                             1 when Loki answered its metrics page, else
#                                  0 (and nothing more is read)
#   compactor_active               compactors active in their ring
#   compactions_count              compactions that succeeded (a running
#                                  total)
#   compactions_failed_count       compactions that failed (a running total)
#   last_compaction_seconds        seconds since a compaction last succeeded
#   retention_runs_count           retention runs that succeeded (a running
#                                  total)
#   retention_failed_count         retention runs that failed (a running
#                                  total)
#   last_retention_seconds         seconds since retention was last applied
#   delete_requests_pending        delete requests waiting to be processed
#   oldest_delete_request_seconds  the age of the oldest of them
#   tables_skipped                 compactions skipped in a row because a
#                                  table was locked
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  last_compaction_seconds under a few compaction intervals (10
#            minutes by default); the failed counts not moving.
#   Watch    delete_requests_pending or oldest_delete_request_seconds growing;
#            tables_skipped above 0.
#   Act      last_compaction_seconds growing, or compactions_failed_count
#            moving: the index is not compacted (queries slow down) and, with
#            retention on, nothing is deleted (storage grows without end);
#            retention_failed_count moving; compactor_active 0 where one
#            should run.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Loki does not answer (up 0 is the
#   reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or awk is missing

set -u

job=compaction
# shellcheck source=/dev/null
. "$(dirname "$0")/_loki.sh"
needs curl awk

page '/metrics'
readings <<'T'
compactor_active|sum|loki_ring_members|name=compactor,state=ACTIVE
compactions_count|sum|loki_boltdb_shipper_compact_tables_operation_total|status=success
compactions_failed_count|sum|loki_boltdb_shipper_compact_tables_operation_total|status=failure
last_compaction_seconds|age|loki_boltdb_shipper_compact_tables_operation_last_successful_run_timestamp_seconds
retention_runs_count|sum|loki_compactor_apply_retention_operation_total|status=success
retention_failed_count|sum|loki_compactor_apply_retention_operation_total|status=failure
last_retention_seconds|age|loki_compactor_apply_retention_last_successful_run_timestamp_seconds
delete_requests_pending|sum|loki_compactor_pending_delete_requests_count
oldest_delete_request_seconds|max|loki_compactor_oldest_pending_delete_request_age_seconds
tables_skipped|sum|loki_compactor_locked_table_successive_compaction_skips
T
exit 0
