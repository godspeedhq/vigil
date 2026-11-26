#Requires -Version 5.1

<#
.SYNOPSIS
    queries.ps1 - ClickHouse's queries running now, the longest and the largest, and the errors it has counted since it started, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the queries running now: how many, those running longer than a
    minute, the longest and the most memory one holds; the five longest, each
    by its user, kind and query ID (never its text, which may hold data or a
    password). And the errors the server has counted since it started, by
    name, the most frequent first: a name rising is a kind of failure
    happening again and again (TOO_MANY_PARTS, MEMORY_LIMIT_EXCEEDED,
    TIMEOUT_EXCEEDED, KEEPER_EXCEPTION...).

    Reads ClickHouse at CLICKHOUSE_URL with PowerShell alone: system.processes and
    system.errors. At most 20 errors are named. What the scripts share is in
    _clickhouse.ps1, beside this one.

    Metrics:
      up                    1 when the server answers, else 0
      running               queries running now, but this job's own
      slow                  of those, how many have run longer than a minute
      longest_seconds       the longest-running one's time
      memory_max_bytes      the most memory one holds
      query_seconds         one of the five longest, tagged user=<user>,
                            kind=<Select, Insert...> and id=<query_id>
      errors_count          an error's count since the server started (a
                            running total), tagged name=<its name>
      errors_not_shown      kinds of error past 20, not named

    Example output (the rest are in the same form):
      metric running 3
      metric slow 1
      metric longest_seconds 312.5
      metric query_seconds 312.5 user=etl kind=Insert id=5a1e...
      metric errors_count 14 name=TOO_MANY_PARTS

    Reading the results (starting points: tune them to the workload):
      Healthy  slow 0 for an interactive server; errors_count flat, but the
               usual few (UNKNOWN_TABLE from a typo, and the like).
      Watch    slow above 0 on two runs in a row; longest_seconds past what
               the workload allows; memory_max_bytes a large share of the
               server's limit.
      Act      errors_count rising for TOO_MANY_PARTS, MEMORY_LIMIT_EXCEEDED
               or KEEPER_EXCEPTION (inserts refused, queries killed, Keeper
               lost); a query running for hours that nobody expects (KILL
               QUERY WHERE query_id = '...').

    Requires: PowerShell 5.1 or later
    Exit code: 0 on success, server up or down; 1 if the login is refused, or the
      server answers wrong

    Example (vigil.config):
      [job.clickhouse_queries]
      file        = packs/clickhouse/queries.ps1
      metric_name = clickhouse.queries
      run_every   = 1m
      env         = CLICKHOUSE_URL=http://localhost:8123
      env         = CLICKHOUSE_USER=vigil
      secret      = CLICKHOUSE_PASSWORD=secret:CLICKHOUSE_PASSWORD
#>

$Job = 'queries'
. (Join-Path $PSScriptRoot '_clickhouse.ps1')

Up
# This job's own SELECT is a query like any: it is left out.
$p = @(Get-Rows @"
SELECT user, query_kind AS kind, query_id AS id, elapsed, memory_usage AS memory
FROM system.processes WHERE query_id != queryID() ORDER BY elapsed DESC
"@)
$slow = 0; $longest = 0; $mem = 0
foreach ($q in $p) {
    if ((N $q.elapsed) -gt 60) { $slow++ }
    if ((N $q.elapsed) -gt $longest) { $longest = N $q.elapsed }
    if ((N $q.memory) -gt $mem) { $mem = N $q.memory }
}
M 'running' $p.Count
M 'slow' $slow
M 'longest_seconds' $longest
M 'memory_max_bytes' $mem
foreach ($q in @($p | Select-Object -First 5)) { M 'query_seconds' $q.elapsed "user=$(Safe $q.user) kind=$(Safe $q.kind) id=$(Safe $q.id)" }
$e = @(Get-Rows 'SELECT name, value FROM system.errors WHERE value > 0 AND remote = 0 ORDER BY value DESC, name')
foreach ($r in @($e | Select-Object -First 20)) { M 'errors_count' $r.value "name=$(Safe $r.name)" }
if ($e.Count -gt 20) { M 'errors_not_shown' ($e.Count - 20) }
exit 0
