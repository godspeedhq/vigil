#!/usr/bin/env bash
#
# storage.sh - Tempo's blocks, compaction and retention
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
# Reports Tempo's storage: the blocks in each tenant's blocklist, the
# compactions run and those that failed, the blocks retention deleted and its
# failures, the polls of the blocklist that failed, and the requests to the
# backend (the bucket, or the disk) that failed. It only reads: every request
# is a GET, and it changes nothing.
#
# Reads TEMPO_URL (default http://localhost:3200): /metrics, Tempo's page
# about itself.
# What the scripts share is in _tempo.sh, beside this one.
#
# Metrics:
#   up                           1 when Tempo answered its metrics page, else
#                                0 (and nothing more is read)
#   blocks                       blocks in the blocklist, every tenant
#   compactions_count            blocks compacted (a running total)
#   compaction_errors_count      compactions that failed (a running total)
#   retention_deleted_count      blocks retention deleted (a running total)
#   retention_errors_count       retention runs that failed (a running total)
#   blocklist_poll_errors_count  polls of the blocklist that failed (a running
#                                total)
#   backend_requests_count       requests to the backend (a running total)
#   backend_errors_count         of those, the ones the backend failed (a
#                                running total)
#   work_queue                   jobs waiting in its read queue
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  compaction_errors_count, retention_errors_count and
#            blocklist_poll_errors_count not moving.
#   Watch    blocks growing without end (compaction or retention not keeping
#            up); work_queue staying above 0.
#   Act      compaction_errors_count moving: blocks pile up and searches slow;
#            retention_errors_count moving: nothing is deleted and storage
#            grows; blocklist_poll_errors_count or backend_errors_count
#            moving: Tempo cannot read its storage, and queries miss traces.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Tempo does not answer (up 0 is the
#   reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or awk is missing

set -u

job=storage
# shellcheck source=/dev/null
. "$(dirname "$0")/_tempo.sh"
needs curl awk

page '/metrics'
readings <<'T'
blocks|sum|tempodb_blocklist_length
compactions_count|sum|tempodb_compaction_blocks_total
compaction_errors_count|sum|tempodb_compaction_errors_total
retention_deleted_count|sum|tempodb_retention_deleted_total
retention_errors_count|sum|tempodb_retention_errors_total
blocklist_poll_errors_count|sum|tempodb_blocklist_poll_errors_total
backend_requests_count|sum|tempodb_backend_request_duration_seconds_count
backend_errors_count|sum|tempodb_backend_request_duration_seconds_count|status_code~^5
work_queue|sum|tempodb_work_queue_length
T
exit 0
