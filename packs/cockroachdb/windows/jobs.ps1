#Requires -Version 5.1

<#
.SYNOPSIS
    jobs.ps1 - a CockroachDB cluster's jobs: backups, schema changes, changefeeds, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the cluster's jobs (backups, restores, imports, schema changes,
    changefeeds...): how many run, are paused, or failed in the time SHOW JOBS
    keeps finished jobs (12 hours), by type; the failed and paused ones, worst
    first, by ID and type (never their description, which may hold a
    statement or a storage URL); the schedules (scheduled backups), and those
    paused or late to run; and the changefeeds, and how far the furthest
    behind is from now. Run it on one node: the answer is the cluster's. It
    only reads.

    Reads CockroachDB at COCKROACH_URL (default https://localhost:8080), the
    node's HTTP port, as COCKROACH_USER with the password in
    COCKROACH_PASSWORD (a secret), with .NET's own HTTP: SHOW JOBS, SHOW
    SCHEDULES and SHOW CHANGEFEED JOBS through /api/v2/sql/. The user needs the
    system privilege VIEWJOB (without it, it sees only its own jobs: none); an
    insecure cluster needs no login. Over https, the certificate is checked
    against COCKROACH_CACERT, the cluster's CA file (ca.crt), when it is set,
    else the system's CAs. What the scripts share is in _cockroachdb.ps1,
    beside this one.

    Metrics:
      up                          1 when the node answers, else 0
      running                     jobs running
      paused                      jobs paused
      failed                      jobs failed in the last 12 hours
      reverting                   jobs rolling back a failure, or a cancel
      jobs                        jobs, by type and status, tagged
                                  type=<BACKUP, SCHEMA CHANGE...> and
                                  status=<running, paused, failed...>
      job_failed                  always 1, for each failed job, tagged
                                  id=<job ID> and type=<its type>
      job_paused_seconds          how long each paused job has been paused,
                                  tagged id=<job ID> and type=<its type>
      jobs_not_shown              failed and paused jobs past the first 20, left
                                  out
      schedules                   schedules (scheduled backups, and
                                  CockroachDB's own)
      schedules_paused            of those, paused
      schedules_late              of those, active and more than an hour past
                                  their next run
      changefeeds                 changefeeds running
      changefeed_behind_seconds   how far the furthest behind of those is from
                                  now: its high-water mark's age, or, with
                                  none yet, its own

    Example output (the rest are in the same form):
      metric up 1
      metric running 2
      metric paused 1
      metric failed 1
      metric jobs 1 type=BACKUP status=failed
      metric job_failed 1 id=1230347512866324481 type=BACKUP
      metric schedules 3
      metric changefeeds 0

    Reading the results (starting points: tune them to the cluster):
      Healthy  failed 0; paused 0, or only jobs paused on purpose;
               schedules_late 0; changefeed_behind_seconds near its
               resolved interval.
      Watch    paused above 0 for long (a paused schema change blocks the next
               on its table); schedules_paused above 0; reverting above 0.
      Act      failed above 0 with type=BACKUP: the last backup did not run;
               schedules_late above 0; changefeed_behind_seconds rising: its
               sink is down or slow, and the cluster keeps the history it
               still has to send (protected timestamps), which grows.

    Requires: Windows PowerShell 5.1 or PowerShell 7; a user with VIEWJOB
    Exit code: 0 on success, node up or down; 1 if the
      login is refused, or the user lacks a privilege

    Example (vigil.config):
      [job.cockroachdb_jobs]
      file        = packs/cockroachdb/jobs.ps1
      metric_name = cockroachdb.jobs
      run_every   = 5m
      env         = COCKROACH_URL=https://localhost:8080
      env         = COCKROACH_CACERT=/var/lib/cockroach/certs/ca.crt
      env         = COCKROACH_USER=vigil
      secret      = COCKROACH_PASSWORD=secret:COCKROACH_PASSWORD
#>

$Job = 'jobs'
. (Join-Path $PSScriptRoot '_cockroachdb.ps1')

# Worst first: failed, then paused, each newest first.
function Rank($s) { switch ([string]$s) { 'failed' { 0 } 'paused' { 1 } default { 9 } } }

Connect-Cockroach
# Up: the node answers its health (no login needed for that).
$h = Get-Answer '/health'
switch ($h.State) {
    'ok' { }
    'unready' { }
    'down' { Write-Output 'metric up 0'; Disconnect-Cockroach; exit 0 }
    default { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($h.Why)"); Disconnect-Cockroach; exit 1 }
}
M 'up' 1
# IDs as strings: they are past what a JSON number holds exactly.
$j = @(Get-Rows "SELECT job_id::STRING AS id, job_type AS type, status, extract(epoch FROM modified)::INT8 AS modified FROM [SHOW JOBS]")
$s = @(Get-Rows "SELECT schedule_status AS status, extract(epoch FROM next_run)::INT8 AS next FROM [SHOW SCHEDULES]")
$c = @(Get-Rows "SELECT status, (extract(epoch FROM now())::DECIMAL - COALESCE(high_water_timestamp / 1e9, extract(epoch FROM created)::DECIMAL))::FLOAT8 AS behind FROM [SHOW CHANGEFEED JOBS] WHERE status = 'running'")
Disconnect-Cockroach
M 'running' @($j | Where-Object { $_.status -eq 'running' }).Count
M 'paused' @($j | Where-Object { $_.status -eq 'paused' }).Count
M 'failed' @($j | Where-Object { $_.status -eq 'failed' }).Count
M 'reverting' @($j | Where-Object { $_.status -in 'reverting', 'cancel-requested', 'pause-requested' }).Count
foreach ($g in @($j | Group-Object -Property type, status | Sort-Object Name)) {
    $f = $g.Group[0]
    M 'jobs' $g.Count "type=$(Safe $f.type) status=$(Safe $f.status)"
}
$w = @($j | Where-Object { $_.status -in 'failed', 'paused' } | Sort-Object @{ Expression = { Rank $_.status } }, @{ Expression = { N $_.modified }; Descending = $true })
foreach ($x in @($w | Select-Object -First 20)) {
    $t = "id=$(Safe $x.id) type=$(Safe $x.type)"
    if ($x.status -eq 'failed') { M 'job_failed' 1 $t }
    else { M 'job_paused_seconds' ([Math]::Max($script:Now - (N $x.modified), 0)) $t }
}
M 'jobs_not_shown' ([Math]::Max($w.Count - 20, 0))
M 'schedules' $s.Count
M 'schedules_paused' @($s | Where-Object { $_.status -eq 'PAUSED' }).Count
M 'schedules_late' @($s | Where-Object { $_.status -eq 'ACTIVE' -and $null -ne $_.next -and (N $_.next) -lt $script:Now - 3600 }).Count
M 'changefeeds' $c.Count
if ($c.Count) { M 'changefeed_behind_seconds' (($c | ForEach-Object { N $_.behind } | Measure-Object -Maximum).Maximum) }
exit 0
