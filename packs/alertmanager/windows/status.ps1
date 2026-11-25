#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - is Alertmanager ready, and what it holds, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports whether Alertmanager is ready, whether its last configuration reload
    worked and when, the alerts it holds (active, suppressed), those it received
    and those it refused as invalid, its silences, and what its configuration
    gives it to work with (receivers, integrations, inhibition rules). It only
    reads: every request is a GET, and it changes nothing.

    Reads ALERTMANAGER_URL (default http://localhost:9093): /metrics,
    Alertmanager's page about itself, and /-/ready.
    What the scripts share is in _alertmanager.ps1, beside this one.

    Metrics:
      up                               1 when Alertmanager answered its metrics
                                       page, else 0 (and nothing more is read)
      ready                            1 when Alertmanager says it is ready
                                       (/-/ready answers 200), else 0: it is
                                       starting, or its cluster has not settled
      version                          always 1, tagged version=<its version>
      uptime_seconds                   seconds since it started
      config_reload_ok                 1 when the last configuration reload
                                       worked, else 0: it is still running the
                                       one before
      config_age_seconds               seconds since the configuration it runs
                                       was loaded
      alerts_active                    alerts firing and not silenced or
                                       inhibited
      alerts_suppressed                alerts silenced or inhibited
      alerts_unprocessed               alerts received and not yet looked at
      alerts_received_count            alerts received (a running total)
      alerts_invalid_count             alerts refused as invalid (a running
                                       total)
      silences_active                  silences in force
      silences_pending                 silences not yet started
      silences_expired                 silences ended and still kept
      receivers                        receivers configured
      integrations                     integrations in them (a webhook, an
                                       email, a pager)
      inhibition_rules                 inhibition rules configured
      aggregation_groups               groups of alerts being held for
                                       notification
      aggregation_limit_reached_count  alerts that could not be grouped: the
                                       limit on groups was reached (a running
                                       total)
      fds_pct                          open files, as a percentage of its limit

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your own):
      Healthy  up 1; ready 1; config_reload_ok 1; alerts_invalid_count not
               moving.
      Watch    alerts_active when you expect none; silences_active that nobody
               remembers setting; alerts_suppressed far above alerts_active (a
               silence or an inhibition hiding a lot).
      Act      up 0 or ready 0: no alert reaches anyone through it;
               config_reload_ok 0 (an edit it refused: routes and receivers are
               the old ones); alerts_received_count not moving while Prometheus
               has alerts firing: they are not arriving;
               aggregation_limit_reached_count moving.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when Alertmanager does not answer (up 0
      is the reading); 1 when it answers wrong (a login refused, not HTTP), said
      on stderr
#>

$Job = 'status'
. (Join-Path $PSScriptRoot '_alertmanager.ps1')

Read-Page '/metrics'
Test-Answers 'ready' '/-/ready'
Get-Readings @'
version|info|alertmanager_build_info||version:version
uptime_seconds|age|process_start_time_seconds
config_reload_ok|min|alertmanager_config_last_reload_successful
config_age_seconds|age|alertmanager_config_last_reload_success_timestamp_seconds
alerts_active|sum|alertmanager_alerts|state=active
alerts_suppressed|sum|alertmanager_alerts|state=suppressed
alerts_unprocessed|sum|alertmanager_alerts|state=unprocessed
alerts_received_count|sum|alertmanager_alerts_received_total
alerts_invalid_count|sum|alertmanager_alerts_invalid_total
silences_active|sum|alertmanager_silences|state=active
silences_pending|sum|alertmanager_silences|state=pending
silences_expired|sum|alertmanager_silences|state=expired
receivers|sum|alertmanager_receivers
integrations|sum|alertmanager_integrations
inhibition_rules|sum|alertmanager_inhibition_rules
aggregation_groups|sum|alertmanager_dispatcher_aggregation_groups
aggregation_limit_reached_count|sum|alertmanager_dispatcher_aggregation_group_limit_reached_total
_fds|sum|process_open_fds
_maxfds|sum|process_max_fds
fds_pct|pct|_fds|_maxfds
'@
exit 0
