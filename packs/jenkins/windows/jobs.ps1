#Requires -Version 5.1

<#
.SYNOPSIS
    jobs.ps1 - every Jenkins job, folders and multibranch pipelines too: failing, unstable or disabled, its health, its last ten builds, and how long since it last succeeded
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Every job (/api/json, four levels of folders deep): its last completed
    build's result, its health (Jenkins' weather), when it last succeeded and
    failed, its last ten builds. The worst first: failing, then unstable,
    then the longest without a success; past 100, the rest counted in the
    totals only.

    Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
    in JENKINS_API_TOKEN (a secret), with Invoke-WebRequest; the token goes in a header made
    here, never on a command line. Over https, the
    certificate must be one Windows trusts (JENKINS_CACERT is not read here).

    Metrics:
      up                        1 when Jenkins answers, else 0
      jobs                      the jobs (folders not counted)
      failing                   of those, whose last completed build failed
      unstable                  of those, whose last completed build was
                                unstable (tests failed)
      aborted                   of those, whose last completed build was
                                aborted
      disabled                  of those, disabled
      never_built               of those, never built
      building                  of those, building now
      in_queue                  of those, waiting in the queue
      builds_last_hour          builds started in the last hour (of each
                                job's last ten)
      failures_last_hour        of those, failed
      job_failing               1 when one job's last completed build
                                failed, else 0, tagged job=<its full name>
      job_unstable              1 when it was unstable, tagged the same
      health_score              Jenkins' health for it, 0 to 100 (its
                                weather: the share of recent builds that
                                passed), tagged the same
      success_rate_pct          of its last ten completed builds, the share
                                that succeeded
      builds_since_success      builds since its last success
      last_success_age_seconds  how long since its last successful build
      last_failure_age_seconds  how long since its last failed build
      last_build_age_seconds    how long since its last build started
      last_duration_seconds     how long its last build took
      jobs_not_shown            past the worst 100, how many were left out

    Example output:
      metric up 1

    Reading the results (starting points: tune them to the controller):
      Healthy  failing and unstable 0, or a known few; health_score high;
               last_success_age_seconds recent for the jobs you build often.
      Watch    unstable rising: tests failing; success_rate_pct falling: a
               flaky job; builds_since_success above 0 for a job you release
               from; a nightly job past a day and a half without a success.
      Act      failing rising, or a job_failing you depend on (a release, a
               deploy) 1; failures_last_hour climbing; last_duration_seconds
               climbing build after build.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, Jenkins up or down; 1 if a setting is wrong, the login is refused, or the address is not Jenkins
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$inv = [Globalization.CultureInfo]::InvariantCulture
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$url = if ($env:JENKINS_URL) { $env:JENKINS_URL.TrimEnd('/') } else { 'http://127.0.0.1:8080' }
# The login, as a header made here: never on a command line.
$headers = @{}
if ($env:JENKINS_USER) {
    $pair = [Text.Encoding]::UTF8.GetBytes("$($env:JENKINS_USER):$($env:JENKINS_API_TOKEN)")
    $headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String($pair)
}
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# Get-Json <path>: the page as objects; 'down' when Jenkins does not answer
# (a reading), 'forbidden' when this user may not read it; exits 1 when it
# answers wrong, saying why.
function Get-Json([string]$path) {
    try { $r = Invoke-WebRequest -Uri ($url + $path) -Headers $headers -UseBasicParsing -TimeoutSec 60 }
    catch {
        $resp = $_.Exception.Response
        if (-not $resp) { return 'down' }
        $code = [int]$resp.StatusCode
        if ($code -eq 401) { Write-Output 'metric up 0'; [Console]::Error.WriteLine('jobs: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong'); exit 1 }
        if ($code -eq 403) { return 'forbidden' }
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("jobs: $url$path answered HTTP $code"); exit 1
    }
    if (-not $r.Headers['X-Jenkins']) {
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("jobs: $url answers, but not as Jenkins (no X-Jenkins header)"); exit 1
    }
    $script:jenkinsVersion = [string]$r.Headers['X-Jenkins']
    return ($r.Content | ConvertFrom-Json)
}
# The page this job reads, and up.
function Read-Page([string]$path) {
    $j = Get-Json $path
    if ($j -is [string] -and $j -eq 'down') { Write-Output 'metric up 0'; exit 0 }
    if ($j -is [string] -and $j -eq 'forbidden') { Write-Output 'metric up 0'; [Console]::Error.WriteLine("jobs: this user may not read ${path}: give it Overall/Read, Job/Read and Agent/Read"); exit 1 }
    return $j
}
# A tag's value: no spaces, quotes or control characters, never empty.
function Safe($s) {
    $s = ([string]$s) -replace '[^A-Za-z0-9@._:/+-]', '_'
    if (-not $s) { return 'none' }
    if ($s.Length -gt 120) { return $s.Substring(0, 120) }
    return $s
}
# A job's full name, from its URL.
function Full-Name([string]$u) {
    $n = $u -replace '^.*?/job/', '' -replace '/job/', '/' -replace '/$', ''
    if (-not $n) { return 'none' }
    return $n
}
function Num([double]$v, [string]$f = '0') { return $v.ToString($f, $inv) }

$root = Read-Page '/api/json?tree=jobs[name,url,color,inQueue,healthReport[score],lastBuild[number,result,timestamp,duration],lastSuccessfulBuild[number,timestamp],lastFailedBuild[timestamp],lastCompletedBuild[result],builds[result,timestamp]{0,10},jobs[name,url,color,inQueue,healthReport[score],lastBuild[number,result,timestamp,duration],lastSuccessfulBuild[number,timestamp],lastFailedBuild[timestamp],lastCompletedBuild[result],builds[result,timestamp]{0,10},jobs[name,url,color,inQueue,healthReport[score],lastBuild[number,result,timestamp,duration],lastSuccessfulBuild[number,timestamp],lastFailedBuild[timestamp],lastCompletedBuild[result],builds[result,timestamp]{0,10},jobs[name,url,color,inQueue,healthReport[score],lastBuild[number,result,timestamp,duration],lastSuccessfulBuild[number,timestamp],lastFailedBuild[timestamp],lastCompletedBuild[result],builds[result,timestamp]{0,10}]]]]'
Write-Output 'metric up 1'
function Age($t) { if ($t) { return [Math]::Max(0, ($nowMs - [double]$t) / 1000) } else { return -1 } }
# Every job, folders walked: a job has a color; a folder has jobs.
$all = New-Object System.Collections.Generic.List[object]
function Walk($list) { foreach ($x in @($list)) { if (-not $x) { continue }; if ($x.PSObject.Properties['color']) { $all.Add($x) }; if ($x.PSObject.Properties['jobs']) { Walk $x.jobs } } }
Walk $root.jobs
$hour = New-Object System.Collections.Generic.List[object]
$jobs = @($all | ForEach-Object {
        $res = if ($_.lastCompletedBuild -and $_.lastCompletedBuild.result) { $_.lastCompletedBuild.result } else { 'NONE' }
        $recent = @($_.builds | Where-Object { $_ -and $_.result })
        foreach ($b in @($_.builds)) { if ($b -and $b.timestamp -and ($nowMs - [double]$b.timestamp) / 1000 -lt 3600) { $hour.Add($b) } }
        [pscustomobject]@{ Name = (Full-Name $_.url); Res = $res; Age = (Age $_.lastSuccessfulBuild.timestamp); Color = [string]$_.color; Built = [bool]$_.lastBuild
            InQueue = ($_.inQueue -eq $true)
            Health = $(if ($_.healthReport -and @($_.healthReport).Count) { @($_.healthReport)[0].score } else { $null })
            Rate = $(if ($recent.Count) { 100 * @($recent | Where-Object { $_.result -eq 'SUCCESS' }).Count / $recent.Count } else { -1 })
            Since = $(if ($_.lastBuild -and $_.lastBuild.number) { [int]$_.lastBuild.number - $(if ($_.lastSuccessfulBuild) { [int]$_.lastSuccessfulBuild.number } else { 0 }) } else { -1 })
            FailAge = (Age $_.lastFailedBuild.timestamp); BuildAge = (Age $_.lastBuild.timestamp)
            Dur = $(if ($_.lastBuild -and $_.lastBuild.duration -gt 0) { [double]$_.lastBuild.duration / 1000 } else { -1 })
            Rank = $(if ($res -eq 'FAILURE') { 0 } elseif ($res -eq 'UNSTABLE') { 1 } else { 2 }) }
    })
Write-Output "metric jobs $($jobs.Count)"
Write-Output "metric failing $(@($jobs | Where-Object { $_.Res -eq 'FAILURE' }).Count)"
Write-Output "metric unstable $(@($jobs | Where-Object { $_.Res -eq 'UNSTABLE' }).Count)"
Write-Output "metric aborted $(@($jobs | Where-Object { $_.Res -eq 'ABORTED' }).Count)"
Write-Output "metric disabled $(@($jobs | Where-Object { $_.Color -eq 'disabled' }).Count)"
Write-Output "metric never_built $(@($jobs | Where-Object { -not $_.Built }).Count)"
Write-Output "metric building $(@($jobs | Where-Object { $_.Color.EndsWith('_anime') }).Count)"
Write-Output "metric in_queue $(@($jobs | Where-Object { $_.InQueue }).Count)"
Write-Output "metric builds_last_hour $($hour.Count)"
Write-Output "metric failures_last_hour $(@($hour | Where-Object { $_.result -eq 'FAILURE' }).Count)"
foreach ($x in ($jobs | Sort-Object Rank, @{ Expression = 'Age'; Descending = $true } | Select-Object -First 100)) {
    $t = "job=$(Safe $x.Name)"
    Write-Output "metric job_failing $(if ($x.Res -eq 'FAILURE') { 1 } else { 0 }) $t"
    Write-Output "metric job_unstable $(if ($x.Res -eq 'UNSTABLE') { 1 } else { 0 }) $t"
    if ($null -ne $x.Health) { Write-Output "metric health_score $($x.Health) $t" }
    if ($x.Rate -ge 0) { Write-Output "metric success_rate_pct $(Num $x.Rate '0.##') $t" }
    if ($x.Since -ge 0) { Write-Output "metric builds_since_success $($x.Since) $t" }
    if ($x.Age -ge 0) { Write-Output "metric last_success_age_seconds $(Num ([Math]::Floor($x.Age))) $t" }
    if ($x.FailAge -ge 0) { Write-Output "metric last_failure_age_seconds $(Num ([Math]::Floor($x.FailAge))) $t" }
    if ($x.BuildAge -ge 0) { Write-Output "metric last_build_age_seconds $(Num ([Math]::Floor($x.BuildAge))) $t" }
    if ($x.Dur -gt 0) { Write-Output "metric last_duration_seconds $(Num ([Math]::Floor($x.Dur))) $t" }
}
Write-Output "metric jobs_not_shown $([Math]::Max(0, $jobs.Count - 100))"
exit 0
