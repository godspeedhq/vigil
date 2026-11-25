#Requires -Version 5.1

<#
.SYNOPSIS
    rules.ps1 - Prometheus' rules and alerts, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports Prometheus' recording and alerting rules: the groups and rules
    loaded, evaluations and those that failed (for each group), iterations a
    group missed because the one before was still running, the slowest group,
    how stale the stalest one is, and the alerts firing and pending. It only
    reads: every request is a GET, and it changes nothing.

    Reads PROMETHEUS_URL (default http://localhost:9090): /metrics, Prometheus'
    page about itself, and /federate for the ALERTS series (one line an alert).
    What the scripts share is in _prometheus.ps1, beside this one.

    Metrics:
      up                             1 when Prometheus answered its metrics
                                     page, else 0 (and nothing more is read)
      groups                         rule groups loaded
      rules                          rules in them
      evaluations_count              rule evaluations (a running total)
      evaluation_failures_count      evaluations that failed (a running total)
      evaluation_failures            the same, for each group, tagged
                                     group=<file;name>
      evaluation_failures_not_shown  how many more there were than the 20 shown
      iterations_missed_count        times a group was skipped: its last run had
                                     not ended (a running total)
      slowest_group_seconds          how long the slowest group took, last time
      stalest_group_seconds          seconds since the group evaluated longest
                                     ago was evaluated
      alerts_firing                  alerts firing now
      alerts_pending                 alerts whose condition holds, waiting out
                                     their "for"
      firing                         the alerts firing, for each alert rule,
                                     tagged alert=<its name>
      firing_not_shown               how many more there were than the 20 shown

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your own):
      Healthy  evaluation_failures_count and iterations_missed_count not moving;
               stalest_group_seconds under twice the longest group interval.
      Watch    slowest_group_seconds near its group interval (it will start
               missing iterations); alerts_pending staying high.
      Act      evaluation_failures_count moving: evaluation_failures says which
               group (its alerts cannot fire, and its recorded series go stale);
               iterations_missed_count moving; stalest_group_seconds growing:
               rules have stopped being evaluated; alerts_firing, which is what
               the rules are for.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when Prometheus does not answer (up 0
      is the reading); 1 when it answers wrong (a login refused, not HTTP), said
      on stderr
#>

$Job = 'rules'
. (Join-Path $PSScriptRoot '_prometheus.ps1')

Read-Page '/metrics'
Get-Readings @'
groups|count|prometheus_rule_group_rules
rules|sum|prometheus_rule_group_rules
evaluations_count|sum|prometheus_rule_evaluations_total
evaluation_failures_count|sum|prometheus_rule_evaluation_failures_total
evaluation_failures|by|prometheus_rule_evaluation_failures_total||rule_group:group
iterations_missed_count|sum|prometheus_rule_group_iterations_missed_total
slowest_group_seconds|max|prometheus_rule_group_last_duration_seconds
stalest_group_seconds|oldest|prometheus_rule_group_last_evaluation_timestamp_seconds
'@
$extra1 = Get-Extra '/federate?match[]=ALERTS'
if ($null -ne $extra1) {
    Get-Readings @'
alerts_firing|count|ALERTS|alertstate=firing
alerts_pending|count|ALERTS|alertstate=pending
firing|countby|ALERTS|alertstate=firing|alertname:alert
'@ $extra1
}
exit 0
