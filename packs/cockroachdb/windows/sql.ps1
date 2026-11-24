#Requires -Version 5.1

<#
.SYNOPSIS
    sql.ps1 - a CockroachDB node's SQL: connections, statements, transactions, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the SQL a node serves as a gateway, from its own metrics: its
    client connections, the statements and transactions open now, and running
    totals of statements by kind, those that failed, full scans, transactions
    committed, aborted and restarted (contention or clock uncertainty made
    CockroachDB retry them), and the time statements and transactions took,
    for a backend to turn into rates and mean latencies. Only clients' SQL:
    CockroachDB's own internal queries are not counted. Run it on every node.
    It needs no login.

    Reads CockroachDB at COCKROACH_URL (default https://localhost:8080), the
    node's HTTP port, with .NET's own HTTP: /_status/vars. Over https, the
    certificate is checked against COCKROACH_CACERT, the cluster's CA file
    (ca.crt), when it is set, else the system's CAs. What the scripts share is
    in _cockroachdb.ps1, beside this one.

    Metrics:
      up                      1 when the node answers, else 0
      connections             client connections open
      statements_active       statements running now
      transactions_open       transactions open now
      memory_bytes            memory SQL statements hold now
      connections_count       connections made (a running total)
      selects_count           SELECTs run (a running total)
      inserts_count           INSERTs run (a running total)
      updates_count           UPDATEs run (a running total)
      deletes_count           DELETEs run (a running total)
      ddl_count               schema changes run (a running total)
      failures_count          statements that failed (a running total)
      full_scans_count        full table or index scans (a running total)
      commits_count           transactions committed (a running total)
      aborts_count            transactions aborted (a running total)
      restarts_count          transactions CockroachDB restarted, every reason
                              (a running total)
      statement_seconds       time statements took (a running total)
      statements_count        statements timed (a running total): divide the
                              rates for the mean
      transaction_seconds     time transactions took (a running total)
      transactions_count      transactions timed (a running total)

    Example output (the rest are in the same form):
      metric up 1
      metric connections 4
      metric selects_count 1200
      metric failures_count 3
      metric restarts_count 0

    Reading the results (starting points: tune them to the workload):
      Healthy  failures_count and restarts_count rising slowly, if at all, against
               the statements; the mean statement latency steady.
      Watch    restarts_count rising with the load: contention, transactions
               that touch the same rows; full_scans_count rising: a query
               lacks an index; connections growing without end.
      Act      failures_count rising fast; aborts_count rising with
               restarts_count; the mean statement latency several times its
               usual.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, node up or down; 1 if
      the node answers wrong

    Example (vigil.config):
      [job.cockroachdb_sql]
      file        = packs/cockroachdb/sql.ps1
      metric_name = cockroachdb.sql
      run_every   = 1m
      env         = COCKROACH_URL=https://localhost:8080
      env         = COCKROACH_CACERT=/var/lib/cockroach/certs/ca.crt
#>

$Job = 'sql'
. (Join-Path $PSScriptRoot '_cockroachdb.ps1')

Read-Vars
Say 'connections' 'sql_conns'
Say 'statements_active' 'sql_statements_active'
Say 'transactions_open' 'sql_txns_open'
Say 'memory_bytes' 'sql_mem_root_current'
Say 'connections_count' 'sql_new_conns'
Say 'selects_count' 'sql_select_count'
Say 'inserts_count' 'sql_insert_count'
Say 'updates_count' 'sql_update_count'
Say 'deletes_count' 'sql_delete_count'
Say 'ddl_count' 'sql_ddl_count'
Say 'failures_count' 'sql_failure_count'
Say 'full_scans_count' 'sql_full_scan_count'
Say 'commits_count' 'sql_txn_commit_count'
Say 'aborts_count' 'sql_txn_abort_count'
# Every reason a transaction was restarted: txn_restarts_<reason>.
$sum = $null
foreach ($k in @($script:Vars.Keys)) {
    if ($k -match '^txn_restarts_[a-z_]+$' -and $k -notmatch '^txn_restarts_(bucket|sum|count)') {
        if ($null -eq $sum) { $sum = [double]0 }
        $sum += Prom $k
    }
}
if ($null -ne $sum) { M 'restarts_count' $sum }
Say 'statement_seconds' 'sql_service_latency_sum' 'sum' 1000000000
Say 'statements_count' 'sql_service_latency_count'
Say 'transaction_seconds' 'sql_txn_latency_sum' 'sum' 1000000000
Say 'transactions_count' 'sql_txn_latency_count'
exit 0
