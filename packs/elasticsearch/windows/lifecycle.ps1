#Requires -Version 5.1

<#
.SYNOPSIS
    lifecycle.ps1 - Elasticsearch's lifecycles: ILM, SLM and data streams', on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports Elasticsearch's index lifecycle management (ILM): whether it runs,
    the indices it manages and in which phase, those whose step failed (with the
    step and Elasticsearch's reason) and those on one step for more than a day.
    Then snapshot lifecycle management (SLM): whether it runs, and each policy's
    last success and failure, whether it is failing now and why, its snapshots
    taken and failed, and its next run. Then the data stream lifecycle: the data
    streams it manages, and their backing indices in error. It only reads: it
    changes nothing in the cluster.

    Reads Elasticsearch at ELASTICSEARCH_URL (default https://localhost:9200),
    as ELASTICSEARCH_USER with the password in ELASTICSEARCH_PASSWORD (a
    secret), or with an API key in ELASTICSEARCH_API_KEY (a secret: the encoded
    form Elasticsearch gives). The login goes in a header made here, never on a
    command line.
    It speaks HTTP itself, with .NET: nothing to install. Over https, the
    certificate is checked against Windows' trusted CAs, or
    ELASTICSEARCH_CACERT, a CA file, and against the server's name. What the
    scripts share is in _elasticsearch.ps1, beside this one.

    Metrics:
      up                            1 when Elasticsearch answers, else 0
      ilm_running                   1 when ILM runs, tagged mode=<RUNNING,
                                    STOPPING or STOPPED>
      ilm_managed                   indices ILM manages
      ilm_errors                    of those, with a failed step
      ilm_stuck                     on one step (not the wait for a rollover)
                                    for more than a day
      ilm_in_phase                  indices in a phase, tagged phase=<hot, warm,
                                    cold, frozen or delete>
      ilm_error                     always 1, for each index whose step failed,
                                    tagged index, policy, step=<the step that
                                    failed> and reason=<Elasticsearch's reason>
                                    (the first 100)
      ilm_error_retries             times its step was retried, tagged index
      ilm_step_age_seconds          how long a stuck index has been on its step,
                                    tagged index and step (the 20 longest)
      slm_running                   1 when SLM runs, tagged mode=<it>
      slm_policies                  SLM policies
      slm_failing                   1 when a policy's last run failed, tagged
                                    policy=<its name> and reason=<why>
      slm_last_success_age_seconds  since its last snapshot that succeeded,
                                    tagged policy
      slm_last_failure_age_seconds  since its last failure, tagged policy
      slm_taken                     snapshots it has taken (a counter), tagged
                                    policy
      slm_failed                    snapshots it failed to take (a counter),
                                    tagged policy
      slm_next_seconds              until its next run, tagged policy
      dlm_data_streams              data streams the data stream lifecycle
                                    manages (8.11 and later)
      dlm_backing_indices           their backing indices
      dlm_errors                    of those, in error
      dlm_error                     a data stream's backing indices in error,
                                    tagged data_stream=<its name>

    Example output (the rest are in the same form):
      metric up 1
      metric ilm_running 1 mode=RUNNING
      metric ilm_errors 1
      metric ilm_error 1 index=ilm-broken policy=rollover-broken step=check-rollover-ready reason=setting__index.lifecycle.rollover_alias__for_index__ilm-broken__is_empty_or_not_defined
      metric ilm_error_retries 5 index=ilm-broken
      metric slm_failing 0 policy=nightly-ok reason=none
      metric slm_last_success_age_seconds 45 policy=nightly-ok

    Reading the results (starting points: tune them to the cluster):
      Healthy  ilm_running and slm_running 1; ilm_errors 0; slm_failing 0
               everywhere; dlm_errors 0.
      Watch    ilm_stuck above 0: an index waits on a step (a shrink with no
               node to go to, a replica that will not allocate);
               slm_last_success_age_seconds past the policy's schedule.
      Act      ilm_errors above 0: indices not rolled over, not deleted (disks
               fill); slm_failing 1: no new snapshots (the reason says why);
               ilm_running 0 left after maintenance.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, Elasticsearch up or down; 1 if a setting is wrong,
      the login is refused, this user may not read what the job needs, or the
      address is not Elasticsearch
#>

$Job = 'lifecycle'
. (Join-Path $PSScriptRoot '_elasticsearch.ps1')

Read-First
$p = Get-Page '/_ilm/status'
if ($p.State -eq 'ok') { M 'ilm_running' $(if ($p.Data.operation_mode -eq 'RUNNING') { 1 } else { 0 }) "mode=$(Safe $p.Data.operation_mode)" }
elseif ($p.State -ne 'unsupported') { Stop-Why $p.State '/_ilm/status' }
$p = Get-Page '/*,.*/_ilm/explain?only_managed=true&filter_path=indices.*.index,indices.*.policy,indices.*.phase,indices.*.action,indices.*.step,indices.*.failed_step,indices.*.step_info.reason,indices.*.step_info.type,indices.*.failed_step_retry_count,indices.*.step_time_millis'
if ($p.State -eq 'ok') {
    $all = @(Values $p.Data.indices)
    M 'ilm_managed' $all.Count
    $err = @($all | Where-Object { $_.step -eq 'ERROR' } | Sort-Object { [string]$_.index })
    M 'ilm_errors' $err.Count
    $stuck = @($all | Where-Object { $_.step -notin 'ERROR', 'complete', 'check-rollover-ready' -and $null -ne $_.step_time_millis } |
        ForEach-Object { [pscustomobject]@{ index = [string]$_.index; step = $_.step; age = [Math]::Floor($script:Now - (N $_.step_time_millis) / 1000) } } |
        Where-Object { $_.age -gt 86400 } | Sort-Object @{ Expression = { $_.age }; Descending = $true }, @{ Expression = { $_.index } })
    M 'ilm_stuck' $stuck.Count
    foreach ($x in @($stuck | Select-Object -First 20)) { M 'ilm_step_age_seconds' $x.age "index=$(Safe $x.index) step=$(Safe $x.step)" }
    foreach ($g in @($all | Group-Object { if ($_.phase) { [string]$_.phase } else { 'none' } } | Sort-Object Name)) { M 'ilm_in_phase' $g.Count "phase=$(Safe $g.Name)" }
    foreach ($x in @($err | Select-Object -First 100)) {
        $t = "index=$(Safe $x.index)"
        $why = if ($x.step_info.reason) { $x.step_info.reason } elseif ($x.step_info.type) { $x.step_info.type } else { '' }
        Write-Output "metric ilm_error 1 $t policy=$(Safe $x.policy) step=$(Safe $x.failed_step) reason=$(Safe $why)"
        M 'ilm_error_retries' $x.failed_step_retry_count $t
    }
} elseif ($p.State -ne 'unsupported') { Stop-Why $p.State '/_ilm/explain' }
$p = Get-Page '/_slm/status'
if ($p.State -eq 'ok') { M 'slm_running' $(if ($p.Data.operation_mode -eq 'RUNNING') { 1 } else { 0 }) "mode=$(Safe $p.Data.operation_mode)" }
elseif ($p.State -notin 'unsupported', 'forbidden') { Stop-Why $p.State '/_slm/status' }
$p = Get-Page '/_slm/policy'
if ($p.State -eq 'ok') {
    $pol = @(Props $p.Data | Sort-Object Name)
    M 'slm_policies' $pol.Count
    foreach ($e in $pol) {
        $t = "policy=$(Safe $e.Name)"
        $v = $e.Value
        $ok = if ($v.last_success.time) { N $v.last_success.time } elseif ($v.last_success.start_time) { N $v.last_success.start_time } else { $null }
        $bad = if ($v.last_failure.time) { N $v.last_failure.time } else { $null }
        $failing = ($null -ne $bad -and ($null -eq $ok -or $bad -gt $ok))
        $reason = 'none'
        if ($failing) {
            $d = [string]$v.last_failure.details
            try { $r = ($d | ConvertFrom-Json).reason; if ($r) { $d = $r } } catch { }
            $reason = Safe $d
        }
        M 'slm_failing' $(if ($failing) { 1 } else { 0 }) "$t reason=$reason"
        if ($null -ne $ok) { M 'slm_last_success_age_seconds' ([Math]::Max([Math]::Floor($script:Now - $ok / 1000), 0)) $t }
        if ($null -ne $bad) { M 'slm_last_failure_age_seconds' ([Math]::Max([Math]::Floor($script:Now - $bad / 1000), 0)) $t }
        M 'slm_taken' $v.stats.snapshots_taken $t
        M 'slm_failed' $v.stats.snapshots_failed $t
        if ($v.next_execution_millis) { M 'slm_next_seconds' ([Math]::Max([Math]::Floor((N $v.next_execution_millis) / 1000 - $script:Now), 0)) $t }
    }
} elseif ($p.State -notin 'unsupported', 'forbidden') { Stop-Why $p.State '/_slm/policy' }
$p = Get-Page '/_lifecycle/stats'
if ($p.State -eq 'ok') {
    $ds = @(@($p.Data.data_streams) | Where-Object { $_ })
    M 'dlm_data_streams' $p.Data.data_stream_count
    M 'dlm_backing_indices' (($ds | ForEach-Object { N $_.backing_indices_in_total } | Measure-Object -Sum).Sum)
    M 'dlm_errors' (($ds | ForEach-Object { N $_.backing_indices_in_error } | Measure-Object -Sum).Sum)
    foreach ($x in @($ds | Where-Object { (N $_.backing_indices_in_error) -gt 0 } | Sort-Object { [string]$_.name })) { M 'dlm_error' $x.backing_indices_in_error "data_stream=$(Safe $x.name)" }
} elseif ($p.State -notin 'unsupported', 'forbidden') { Stop-Why $p.State '/_lifecycle/stats' }
exit 0
