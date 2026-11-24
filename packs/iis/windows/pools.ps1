#Requires -Version 5.1

<#
.SYNOPSIS
    pools.ps1 - IIS's application pools and their request queues, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each application pool: its state (running, stopped, and the states
    between), its worker processes against the most it may run, its uptime, its
    recycles, its worker processes' failures (all, recent, failed pings, failed
    starts and stops) and the time since the last; then its request queue in
    HTTP.sys: requests waiting for a worker, how long the oldest has waited,
    requests turned away, and the rates. The pools not running first. It only
    reads: it changes nothing.

    The account Vigil runs as needs no administrator: it reads IIS's performance
    counters as a member of Performance Monitor Users (LocalSystem, the Vigil
    service's account, already may). It reads the counter sets APP_POOL_WAS and
    HTTP Service Request Queues.
    What the scripts share is in _iis.ps1, beside this one.

    Metrics:
      up                       1 when IIS's process activation service (WAS)
                               answers with its counters, else 0
      pools                    application pools
      pools_not_running        of those, not running (stopped, or starting, or
                               stopping)
      state                    its state: 1 uninitialized, 2 initialized, 3
                               running, 4 disabling, 5 stopped, 6 shutting_down,
                               7 deleting; tagged pool=<its name> and
                               status=<the word>
      worker_processes         worker processes now, tagged pool
      worker_processes_max     the most it may run (its web garden), tagged pool
      uptime_seconds           since it last started, tagged pool
      recycles_count           times it recycled (a running total), tagged pool
      worker_failures_count    its worker processes that failed (a running
                               total), tagged pool
      recent_failures          of those, recently (rapid-fail protection counts
                               these), tagged pool
      ping_failures_count      worker processes that did not answer a ping,
                               tagged pool
      startup_failures_count   worker processes that failed to start, tagged
                               pool
      shutdown_failures_count  worker processes that failed to stop, tagged pool
      since_failure_seconds    since its last worker process failed, tagged pool
      queue                    requests waiting in HTTP.sys for a worker, tagged
                               pool
      queue_oldest_ms          how long the oldest of those has waited, tagged
                               pool
      rejected_count           requests HTTP.sys turned away (a running total),
                               tagged pool
      arrival_rate             requests arriving a second, tagged pool
      rejection_rate           requests turned away a second, tagged pool
      cache_hit_rate           answers from HTTP.sys's own cache a second,
                               tagged pool
      pools_not_shown          pools past the first 200, left out

    Example output (the rest are in the same form):
      metric up 1
      metric pools 7
      metric pools_not_running 2
      metric state 5 pool=vigil-crash status=stopped
      metric worker_processes 0 pool=vigil-crash
      metric worker_processes_max 1 pool=vigil-crash
      metric uptime_seconds 183.77 pool=vigil-crash
      metric recycles_count 0 pool=vigil-crash
      metric worker_failures_count 6 pool=vigil-crash
      metric recent_failures 0 pool=vigil-crash
      metric ping_failures_count 0 pool=vigil-crash
      metric startup_failures_count 0 pool=vigil-crash
      metric shutdown_failures_count 0 pool=vigil-crash
      metric since_failure_seconds 0 pool=vigil-crash
      metric queue 0 pool=vigil-crash
      metric queue_oldest_ms 0 pool=vigil-crash

    Reading the results (starting points: tune them to the server):
      Healthy  every state 3 (running); queue 0; recent_failures 0;
               rejected_count flat.
      Watch    recycles_count rising faster than scheduled; queue above 0;
               worker_processes 0 for a pool that should be warm (idle
               time-out).
      Act      state 5 (stopped): the pool answers 503, by hand or by rapid-fail
               protection (iis_events says which); recent_failures rising:
               workers crash; rejected_count rising: requests turned away (queue
               full, or the pool stopped).

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, IIS up or down
#>

$Job = 'pools'
. (Join-Path $PSScriptRoot '_iis.ps1')

$wp = Get-Set 'APP_POOL_WAS'
if ($null -eq $wp) { M 'up' 0; exit 0 }
M 'up' 1
$q = Get-Set 'HTTP Service Request Queues'
if ($null -eq $q) { $q = @{} }
$names = Get-Instances $wp
$words = @{ 1 = 'uninitialized'; 2 = 'initialized'; 3 = 'running'; 4 = 'disabling'; 5 = 'stopped'; 6 = 'shutting_down'; 7 = 'deleting' }
M 'pools' $names.Count
M 'pools_not_running' (@($names | Where-Object { (N $wp[$_]['current application pool state']) -ne 3 })).Count
$order = @($names | Sort-Object @{ Expression = { if ((N $wp[$_]['current application pool state']) -eq 3) { 1 } else { 0 } } }, @{ Expression = { $_ } })
foreach ($p in @($order | Select-Object -First 200)) {
    $c = $wp[$p]; $t = "pool=$(Safe $p)"
    $st = [int](N $c['current application pool state'])
    $w = if ($words.ContainsKey($st)) { $words[$st] } else { 'unknown' }
    M 'state' $st "$t status=$w"
    M 'worker_processes' $c['current worker processes'] $t
    M 'worker_processes_max' $c['maximum worker processes'] $t
    M 'uptime_seconds' $c['current application pool uptime'] $t
    M 'recycles_count' $c['total application pool recycles'] $t
    M 'worker_failures_count' $c['total worker process failures'] $t
    M 'recent_failures' $c['recent worker process failures'] $t
    M 'ping_failures_count' $c['total worker process ping failures'] $t
    M 'startup_failures_count' $c['total worker process startup failures'] $t
    M 'shutdown_failures_count' $c['total worker process shutdown failures'] $t
    M 'since_failure_seconds' $c['time since last worker process failure'] $t
    if ($q.ContainsKey($p)) {
        $r = $q[$p]
        M 'queue' $r['currentqueuesize'] $t
        M 'queue_oldest_ms' $r['maxqueueitemage'] $t
        M 'rejected_count' $r['rejectedrequests'] $t
        M 'arrival_rate' $r['arrivalrate'] $t
        M 'rejection_rate' $r['rejectionrate'] $t
        M 'cache_hit_rate' $r['cachehitrate'] $t
    }
}
M 'pools_not_shown' ([Math]::Max($names.Count - 200, 0))
exit 0
