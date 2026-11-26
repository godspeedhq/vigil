#Requires -Version 5.1

<#
.SYNOPSIS
    merges.ps1 - ClickHouse's background work: mutations not finished and failing, merges running, parts detached, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the work ClickHouse does in the background. Mutations (ALTER
    TABLE ... UPDATE or DELETE) not finished: how many, how old the oldest
    is, and those that fail, each by its table and ID, the failing and the
    oldest first. A mutation that fails is tried again and again, forever,
    and every one queued after it on the table waits behind it. Merges
    running: how many, the longest, and the memory they hold. And parts
    detached, by why: a part ClickHouse found broken is moved aside, not
    deleted, and the data in it is no longer read.

    Reads ClickHouse at CLICKHOUSE_URL with PowerShell alone: system.mutations,
    system.merges and system.detached_parts. At most 20 mutations are named;
    the rest are counted. What the scripts share is in _clickhouse.ps1, beside
    this one.

    Metrics:
      up                         1 when the server answers, else 0
      mutations                  mutations not finished
      mutations_failing          of those, how many fail
      mutations_oldest_seconds   the oldest one's age
      mutation_seconds           a mutation's age, tagged
                                 table=<database.table> and id=<mutation_id>
      mutation_parts_to_do       the parts it has still to change
      mutation_failing           1 when it fails, else 0
      mutations_not_shown        mutations past 20, counted and not named
      merges                     merges running now
      merges_mutating            of those, mutations at work
      merge_longest_seconds      the longest-running one
      merges_memory_bytes        memory they hold
      detached_parts             parts detached, tagged reason=<broken,
                                 unexpected, ignored, clone, manual...>

    Example output (the rest are in the same form):
      metric mutations 1
      metric mutations_failing 1
      metric mutation_seconds 3600 table=default.events id=mutation_12.txt
      metric mutation_failing 1 table=default.events id=mutation_12.txt
      metric merges 2
      metric detached_parts 0 reason=broken

    Reading the results (starting points: tune them to the server):
      Healthy  mutations 0, or each finishing within minutes;
               mutations_failing 0; detached_parts 0 but reason=manual.
      Watch    mutations_oldest_seconds past an hour on a small table;
               merge_longest_seconds past an hour; merges_memory_bytes a
               large share of the server's memory.
      Act      mutations_failing above 0: it will never finish, and those
               after it wait (system.mutations' latest_fail_reason says why;
               KILL MUTATION ends it); detached_parts reason=broken or
               unexpected above 0: data the table no longer reads.

    Requires: PowerShell 5.1 or later
    Exit code: 0 on success, server up or down; 1 if the login is refused, or the
      server answers wrong

    Example (vigil.config):
      [job.clickhouse_merges]
      file        = packs/clickhouse/merges.ps1
      metric_name = clickhouse.merges
      run_every   = 5m
      env         = CLICKHOUSE_URL=http://localhost:8123
      env         = CLICKHOUSE_USER=vigil
      secret      = CLICKHOUSE_PASSWORD=secret:CLICKHOUSE_PASSWORD
#>

$Job = 'merges'
. (Join-Path $PSScriptRoot '_clickhouse.ps1')

Up
$mut = @(Get-Rows @"
SELECT database, table, mutation_id, dateDiff('second', create_time, now()) AS age, parts_to_do,
       latest_fail_reason != '' AS failing
FROM system.mutations WHERE NOT is_done ORDER BY failing DESC, age DESC, database, table, mutation_id
"@)
$failing = 0; $oldest = 0
foreach ($m in $mut) { $failing += N $m.failing; if ((N $m.age) -gt $oldest) { $oldest = N $m.age } }
M 'mutations' $mut.Count
M 'mutations_failing' $failing
M 'mutations_oldest_seconds' $oldest
foreach ($m in @($mut | Select-Object -First 20)) {
    $t = "table=$(Safe ($m.database + '.' + $m.table)) id=$(Safe $m.mutation_id)"
    M 'mutation_seconds' $m.age $t
    M 'mutation_parts_to_do' $m.parts_to_do $t
    M 'mutation_failing' $m.failing $t
}
if ($mut.Count -gt 20) { M 'mutations_not_shown' ($mut.Count - 20) }
$g = @(Get-Rows @"
SELECT count() AS merges, countIf(is_mutation) AS mutating, max(elapsed) AS longest, sum(memory_usage) AS memory
FROM system.merges
"@)
$g = if ($g.Count -gt 0) { $g[0] } else { [pscustomobject]@{} }
M 'merges' $g.merges
M 'merges_mutating' $g.mutating
M 'merge_longest_seconds' $g.longest
M 'merges_memory_bytes' $g.memory
# A reason is empty for a part detached by hand (ALTER TABLE ... DETACH
# PART): manual. Broken and unexpected always print, at 0 too.
$d = @{ broken = 0; unexpected = 0 }
foreach ($r in @(Get-Rows "SELECT if(reason = '', 'manual', reason) AS why, count() AS parts FROM system.detached_parts GROUP BY why")) { $d[[string]$r.why] = N $r.parts }
foreach ($k in @($d.Keys | Sort-Object { [string]$_ } -CaseSensitive)) { M 'detached_parts' $d[$k] "reason=$(Safe $k)" }
exit 0
