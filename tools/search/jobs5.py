# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""OpenSearch's lifecycle job: Index State Management (ISM) and snapshot
management (tools/search/jobs.py says how the jobs are written)."""
from jobs import job, M

ISM_EXPLAIN = ('/_plugins/_ism/explain?size=1000&filter_path=total_managed_indices,*.index,*.policy_id,*.enabled,'
               '*.state.name,*.action.name,*.action.failed,*.action.consumed_retries,*.step.name,'
               '*.step.step_status,*.retry_info.failed,*.info.message')
SM_EXPLAIN = '/_plugins/_sm/policies/*/_explain'
job(job='lifecycle', metric='lifecycle', when='cron        = 2/5 * * * *', runtime='4m', only='os',
    title="OpenSearch's Index State Management and snapshot management",
    what="Reports OpenSearch's Index State Management (ISM): the indices it manages and in which state, "
         "those whose action failed (with the action and OpenSearch's message) and those it no longer "
         "runs. Then snapshot management: each policy, whether it is on, its last snapshot's state and "
         "age, whether it is failing and why, and its next run. Snapshot management skips every run while "
         "the cluster is red, so a red cluster soon shows here too.",
    metrics=M(('up', '1 when OpenSearch answers, else 0'),
              ('ism_managed', 'indices ISM manages'),
              ('ism_failed', 'of those, whose action failed'),
              ('ism_disabled', 'whose policy ISM no longer runs (it stops after an action fails for good)'),
              ('ism_in_state', 'indices in a state of their policy, tagged state=<its name>'),
              ('ism_failure', 'always 1, for each index whose action failed, tagged index, policy, action=<it> '
                              "and reason=<OpenSearch's message> (the first 100)"),
              ('ism_retries', 'times its action was retried, tagged index'),
              ('ism_not_shown', 'indices past the first 1000, left out'),
              ('sm_policies', 'snapshot management policies'),
              ('sm_enabled', 'of those, on'),
              ('sm_last_status', "a policy's last snapshot: 0 SUCCESS, 1 IN_PROGRESS or RETRYING, 2 "
                                 'TIME_LIMIT_EXCEEDED, 3 FAILED, 4 none yet; tagged policy=<its name> and status=<it>'),
              ('sm_failing', '1 when its last snapshot failed, tagged policy and reason=<why, or not_given when OpenSearch does not say>'),
              ('sm_last_age_seconds', 'since its last snapshot ended (or began), tagged policy'),
              ('sm_next_seconds', 'until its next snapshot, tagged policy'),
              ('sm_deletion_failing', '1 when its last deletion of old snapshots failed, tagged policy')),
    healthy="ism_failed 0; every sm_last_status 0, sm_failing 0.",
    watch="ism_disabled above 0: ISM gave up on those indices; sm_last_age_seconds past the policy's "
          "schedule.",
    act="ism_failed above 0: indices not rolled over or deleted, disks fill (the reason says why); "
        "sm_failing 1: no new snapshots (the reason says why); sm_last_status 4 for long on a red cluster: "
        "snapshot management skips every run until it is green or yellow.",
    sh=r'''first
get '@ISM_EXPLAIN@'
rc=$?
case $rc in
    0) jq -r "$jqlib"'
        (.total_managed_indices | n) as $total |
        [to_entries[] | select(.key != "total_managed_indices") | .value + {index: (.value.index // .key)}] | sort_by(.index) |
        "metric ism_managed \($total)",
        "metric ism_failed \([.[] | select(.action.failed == true or .step.step_status == "failed")] | length)",
        "metric ism_disabled \([.[] | select(.enabled == false)] | length)",
        (group_by(.state.name // "none")[] | "metric ism_in_state \(length) state=\(.[0].state.name // "none" | tag)"),
        ([.[] | select(.action.failed == true or .step.step_status == "failed")] | .[0:100][] | "index=\(.index | tag)" as $t |
            "metric ism_failure 1 \($t) policy=\(.policy_id | tag) action=\(.action.name // .step.name // "" | tag) reason=\(.info.message // "" | tag)",
            "metric ism_retries \(.action.consumed_retries | n) \($t)"),
        "metric ism_not_shown \([$total - length, 0] | max)"
    ' "$work/body" || exit 1 ;;
    3) ;;
    *) why "$rc" '/_plugins/_ism/explain' ;;
esac
get '@SM_EXPLAIN@'
rc=$?
case $rc in
    0) jq -r --argjson now "$now" "$jqlib"'
        def scode: {"SUCCESS": 0, "IN_PROGRESS": 1, "RETRYING": 1, "TIME_LIMIT_EXCEEDED": 2, "FAILED": 3}[. // ""] // 4;
        [.policies[]?] | sort_by(.name) |
        "metric sm_policies \(length)",
        "metric sm_enabled \([.[] | select(.enabled == true)] | length)",
        (.[] | "policy=\(.name | tag)" as $t | .creation.latest_execution as $l |
            "metric sm_last_status \($l.status | scode) \($t) status=\($l.status // "none" | tag)",
            "metric sm_failing \(if $l.status == "FAILED" then 1 else 0 end) \($t) reason=\(if $l.status == "FAILED" then ($l.info.cause // $l.info.message // "not_given" | tag) else "none" end)",
            (if $l.end_time or $l.start_time then "metric sm_last_age_seconds \([$now - (($l.end_time // $l.start_time) / 1000) | floor, 0] | max) \($t)" else empty end),
            (if .creation.trigger.time then "metric sm_next_seconds \([(.creation.trigger.time / 1000) - $now | floor, 0] | max) \($t)" else empty end),
            (if .deletion then "metric sm_deletion_failing \(if .deletion.latest_execution.status == "FAILED" then 1 else 0 end) \($t)" else empty end))
    ' "$work/body" || exit 1 ;;
    3) ;;
    *) why "$rc" '/_plugins/_sm/policies' ;;
esac
exit 0
''',
    ps=r'''Read-First
$p = Get-Page '@ISM_EXPLAIN@'
if ($p.State -eq 'ok') {
    $total = N $p.Data.total_managed_indices
    $all = @(Props $p.Data | Where-Object { $_.Name -ne 'total_managed_indices' } | ForEach-Object {
        $v = $_.Value; if (-not $v.index) { $v | Add-Member -NotePropertyName index -NotePropertyValue $_.Name -Force }; $v } | Sort-Object { [string]$_.index })
    $failed = @($all | Where-Object { $_.action.failed -eq $true -or $_.step.step_status -eq 'failed' })
    M 'ism_managed' $total
    M 'ism_failed' $failed.Count
    M 'ism_disabled' (@($all | Where-Object { $_.enabled -eq $false }).Count)
    foreach ($g in @($all | Group-Object { if ($_.state.name) { [string]$_.state.name } else { 'none' } } | Sort-Object Name)) { M 'ism_in_state' $g.Count "state=$(Safe $g.Name)" }
    foreach ($x in @($failed | Select-Object -First 100)) {
        $t = "index=$(Safe $x.index)"
        $act = if ($x.action.name) { $x.action.name } elseif ($x.step.name) { $x.step.name } else { '' }
        Write-Output "metric ism_failure 1 $t policy=$(Safe $x.policy_id) action=$(Safe $act) reason=$(Safe $x.info.message)"
        M 'ism_retries' $x.action.consumed_retries $t
    }
    M 'ism_not_shown' ([Math]::Max($total - $all.Count, 0))
} elseif ($p.State -ne 'unsupported') { Stop-Why $p.State '/_plugins/_ism/explain' }
$p = Get-Page '@SM_EXPLAIN@'
if ($p.State -eq 'ok') {
    $codes = @{ 'SUCCESS' = 0; 'IN_PROGRESS' = 1; 'RETRYING' = 1; 'TIME_LIMIT_EXCEEDED' = 2; 'FAILED' = 3 }
    $pol = @(@($p.Data.policies) | Where-Object { $_ } | Sort-Object { [string]$_.name })
    M 'sm_policies' $pol.Count
    M 'sm_enabled' (@($pol | Where-Object { $_.enabled -eq $true }).Count)
    foreach ($x in $pol) {
        $t = "policy=$(Safe $x.name)"
        $l = $x.creation.latest_execution
        $st = if ($l -and $l.status) { [string]$l.status } else { 'none' }
        $c = if ($codes.ContainsKey($st)) { $codes[$st] } else { 4 }
        M 'sm_last_status' $c "$t status=$(Safe $st)"
        $why = 'none'
        if ($st -eq 'FAILED') { $why = if ($l.info.cause) { Safe $l.info.cause } elseif ($l.info.message) { Safe $l.info.message } else { 'not_given' } }
        M 'sm_failing' $(if ($st -eq 'FAILED') { 1 } else { 0 }) "$t reason=$why"
        $at = if ($l.end_time) { N $l.end_time } elseif ($l.start_time) { N $l.start_time } else { $null }
        if ($null -ne $at) { M 'sm_last_age_seconds' ([Math]::Max([Math]::Floor($script:Now - $at / 1000), 0)) $t }
        if ($x.creation.trigger.time) { M 'sm_next_seconds' ([Math]::Max([Math]::Floor((N $x.creation.trigger.time) / 1000 - $script:Now), 0)) $t }
        if ($x.deletion) { M 'sm_deletion_failing' $(if ($x.deletion.latest_execution.status -eq 'FAILED') { 1 } else { 0 }) $t }
    }
} elseif ($p.State -ne 'unsupported') { Stop-Why $p.State '/_plugins/_sm/policies' }
exit 0
'''.replace('@ISM_EXPLAIN@', ISM_EXPLAIN).replace('@SM_EXPLAIN@', SM_EXPLAIN))
from jobs import JOBS
JOBS[-1]['sh'] = JOBS[-1]['sh'].replace('@ISM_EXPLAIN@', ISM_EXPLAIN).replace('@SM_EXPLAIN@', SM_EXPLAIN)
