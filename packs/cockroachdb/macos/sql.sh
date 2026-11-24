#!/usr/bin/env bash
#
# sql.sh - a CockroachDB node's SQL: connections, statements, transactions
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
# Reports the SQL a node serves as a gateway, from its own metrics: its
# client connections, the statements and transactions open now, and running
# totals of statements by kind, those that failed, full scans, transactions
# committed, aborted and restarted (contention or clock uncertainty made
# CockroachDB retry them), and the time statements and transactions took,
# for a backend to turn into rates and mean latencies. Only clients' SQL:
# CockroachDB's own internal queries are not counted. Run it on every node.
# It needs no login.
#
# Reads CockroachDB at COCKROACH_URL (default https://localhost:8080), the
# node's HTTP port, with curl and jq: /_status/vars. Over https, the
# certificate is checked against COCKROACH_CACERT, the cluster's CA file
# (ca.crt), when it is set, else the system's CAs. What the scripts share is
# in _cockroachdb.sh, beside this one.
#
# Metrics:
#   up                      1 when the node answers, else 0
#   connections             client connections open
#   statements_active       statements running now
#   transactions_open       transactions open now
#   memory_bytes            memory SQL statements hold now
#   connections_count       connections made (a running total)
#   selects_count           SELECTs run (a running total)
#   inserts_count           INSERTs run (a running total)
#   updates_count           UPDATEs run (a running total)
#   deletes_count           DELETEs run (a running total)
#   ddl_count               schema changes run (a running total)
#   failures_count          statements that failed (a running total)
#   full_scans_count        full table or index scans (a running total)
#   commits_count           transactions committed (a running total)
#   aborts_count            transactions aborted (a running total)
#   restarts_count          transactions CockroachDB restarted, every reason
#                           (a running total)
#   statement_seconds       time statements took (a running total)
#   statements_count        statements timed (a running total): divide the
#                           rates for the mean
#   transaction_seconds     time transactions took (a running total)
#   transactions_count      transactions timed (a running total)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric connections 4
#   metric selects_count 1200
#   metric failures_count 3
#   metric restarts_count 0
#
# Reading the results (starting points: tune them to the workload):
#   Healthy  failures_count and restarts_count rising slowly, if at all, against
#            the statements; the mean statement latency steady.
#   Watch    restarts_count rising with the load: contention, transactions
#            that touch the same rows; full_scans_count rising: a query
#            lacks an index; connections growing without end.
#   Act      failures_count rising fast; aborts_count rising with
#            restarts_count; the mean statement latency several times its
#            usual.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, node up or down; 1 if curl or jq is missing, or
#   the node answers wrong
#
# Example (vigil.config):
#   [job.cockroachdb_sql]
#   file        = packs/cockroachdb/sql.sh
#   metric_name = cockroachdb.sql
#   run_every   = 1m
#   env         = COCKROACH_URL=https://localhost:8080
#   env         = COCKROACH_CACERT=/var/lib/cockroach/certs/ca.crt

set -u

job=sql
# shellcheck source=/dev/null
. "$(dirname "$0")/_cockroachdb.sh"

vars
say connections sql_conns
say statements_active sql_statements_active
say transactions_open sql_txns_open
say memory_bytes sql_mem_root_current
say connections_count sql_new_conns
say selects_count sql_select_count
say inserts_count sql_insert_count
say updates_count sql_update_count
say deletes_count sql_delete_count
say ddl_count sql_ddl_count
say failures_count sql_failure_count
say full_scans_count sql_full_scan_count
say commits_count sql_txn_commit_count
say aborts_count sql_txn_abort_count
# Every reason a transaction was restarted: txn_restarts_<reason>.
awk '/^txn_restarts_[a-z_]+[{ ]/ && $0 !~ /^txn_restarts_(bucket|sum|count)/ { s += $NF; seen = 1 } END { if (seen) printf "metric restarts_count %.0f\n", s }' "$work/vars"
say statement_seconds sql_service_latency_sum sum 1000000000
say statements_count sql_service_latency_count
say transaction_seconds sql_txn_latency_sum sum 1000000000
say transactions_count sql_txn_latency_count
exit 0
