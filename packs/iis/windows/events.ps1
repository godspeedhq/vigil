#Requires -Version 5.1

<#
.SYNOPSIS
    events.ps1 - IIS's events: pools disabled, workers crashed or hung, recycles, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Counts IIS's events of the last hour (IIS_EVENT_HOURS) in the System and
    Application logs, from the process activation service (WAS) and the web
    service (W3SVC, its worker processes): application pools stopped by
    rapid-fail protection, worker processes that crashed, that did not answer a
    ping or failed to start, recycles and idle shutdowns; then each kind of
    event by pool. These say why a pool is stopped, or why its workers keep
    starting. It only reads: it changes nothing.

    Reads the System and Application event logs (Get-WinEvent), the providers
    Microsoft-Windows-WAS, Microsoft-Windows-IIS-W3SVC and
    Microsoft-Windows-IIS-W3SVC-WP. The account Vigil runs as needs Event Log
    Readers (LocalSystem may already).
    What the scripts share is in _iis.ps1, beside this one.

    Metrics:
      readable              1 when this account may read the event logs, else 0
      events                IIS's events in the last hour
      errors                of those, errors and critical ones
      warnings              warnings
      rapid_fail_count      application pools stopped by rapid-fail protection
                            (event 5002)
      crashes_count         worker processes that ended unexpectedly (5009,
                            5011)
      unresponsive_count    worker processes that did not answer a ping (5010)
      start_failures_count  worker processes or pools that failed to start
                            (5053, 5057, 5059, 5085)
      recycles_count        recycles: on schedule, on memory, on requests, on a
                            configuration change (5074 to 5081, 5117)
      idle_shutdowns_count  worker processes shut down for being idle (5186)
      event                 events of one kind, tagged id=<the event id>,
                            pool=<the pool it names, or none> and level=<error,
                            warning or information>
      events_not_shown      kinds past the first 50, left out

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to the server):
      Healthy  rapid_fail_count 0; crashes_count 0; unresponsive_count 0.
      Watch    recycles_count above what the schedule makes; crashes_count above
               0 once.
      Act      rapid_fail_count above 0: a pool was stopped after its workers
               kept failing, and stays stopped until someone starts it (event
               says which); crashes_count or unresponsive_count rising: the
               application crashes or hangs.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever the events (an event log this account may not read is
      a reading)
#>

$Job = 'events'
. (Join-Path $PSScriptRoot '_iis.ps1')

$hours = 1; if ($env:IIS_EVENT_HOURS) { $hours = [double]$env:IIS_EVENT_HOURS }
$filter = @{ LogName = 'System', 'Application'; ProviderName = 'Microsoft-Windows-WAS', 'Microsoft-Windows-IIS-W3SVC', 'Microsoft-Windows-IIS-W3SVC-WP'; StartTime = (Get-Date).AddHours(-$hours) }
$ev = @()
try { $ev = @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop) }
catch {
    # None at all is an exception too: only a refusal is not a reading.
    if ($_.Exception.Message -match 'denied|unauthori') { M 'readable' 0; [Console]::Error.WriteLine("${Job}: this account may not read the event logs: add it to Event Log Readers"); exit 0 }
}
M 'readable' 1
M 'events' $ev.Count
M 'errors' (@($ev | Where-Object { $_.Level -le 2 -and $_.Level -ge 1 })).Count
M 'warnings' (@($ev | Where-Object { $_.Level -eq 3 })).Count
function Count-Ids($ids) { return (@($ev | Where-Object { $ids -contains $_.Id -and $_.ProviderName -eq 'Microsoft-Windows-WAS' })).Count }
M 'rapid_fail_count' (Count-Ids @(5002))
M 'crashes_count' (Count-Ids @(5009, 5011))
M 'unresponsive_count' (Count-Ids @(5010))
M 'start_failures_count' (Count-Ids @(5053, 5057, 5059, 5085))
M 'recycles_count' (Count-Ids @(5074, 5075, 5076, 5077, 5078, 5079, 5080, 5081, 5117))
M 'idle_shutdowns_count' (Count-Ids @(5186))
$by = @{}
foreach ($e in $ev) {
    $pool = 'none'
    $m = [regex]::Match([string]$e.Message, "application pool '([^']+)'", 'IgnoreCase')
    if ($m.Success) { $pool = $m.Groups[1].Value }
    $lv = switch ($e.Level) { 1 { 'critical' } 2 { 'error' } 3 { 'warning' } default { 'information' } }
    $k = "id=$($e.Id) pool=$(Safe $pool) level=$lv"
    $by[$k] = 1 + [int]$by[$k]
}
foreach ($k in @($by.Keys | Sort-Object { -$by[$_] }, { $_ } | Select-Object -First 50)) { M 'event' $by[$k] $k }
M 'events_not_shown' ([Math]::Max($by.Count - 50, 0))
exit 0
