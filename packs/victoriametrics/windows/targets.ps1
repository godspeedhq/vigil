#Requires -Version 5.1

<#
.SYNOPSIS
    targets.ps1 - the targets VictoriaMetrics scrapes, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the targets VictoriaMetrics (or vmagent) scrapes itself: how many
    are up and down, the down ones for each job, the scrapes made and failed,
    and whether its scrape configuration reloaded. It reports zeros where it
    scrapes nothing (-promscrape.config not set). It only reads: every request
    is a GET, and it changes nothing.

    Reads VICTORIAMETRICS_URL (default http://localhost:8428): /metrics,
    VictoriaMetrics' page about itself.
    What the scripts share is in _victoriametrics.ps1, beside this one.

    Metrics:
      up                          1 when VictoriaMetrics answered its metrics
                                  page, else 0 (and nothing more is read)
      targets_up                  targets whose last scrape worked
      targets_down                targets whose last scrape failed
      scrapes_count               scrapes made (a running total)
      scrapes_failed_count        scrapes that failed (a running total)
      config_reload_ok            1 when the last reload of the scrape
                                  configuration worked, else 0
      config_reload_errors_count  reloads of it that failed (a running total)
      down                        the targets down in each job, tagged job=<it>
      down_not_shown              how many more there were than the 20 shown

    Example output (the rest are in the same form):
      metric up 1
      metric targets_up 1
      metric targets_down 1
      metric scrapes_count 62
      metric scrapes_failed_count 62
      metric config_reload_ok 1
      metric config_reload_errors_count 0
      metric down 1 job=dead
      metric down 0 job=victoriametrics
      metric down_not_shown 0

    Reading the results (starting points: tune them to your own):
      Healthy  targets_down 0; scrapes_failed_count not moving; config_reload_ok
               1.
      Watch    scrapes_failed_count moving now and then (a target that restarts,
               or answers slowly).
      Act      targets_down above 0 for more than a few scrapes: down says which
               job; config_reload_ok 0: an edit it refused, and it scrapes what
               it scraped before.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when VictoriaMetrics does not answer
      (up 0 is the reading); 1 when it answers wrong (a login refused, not
      HTTP), said on stderr
#>

$Job = 'targets'
. (Join-Path $PSScriptRoot '_victoriametrics.ps1')

Read-Page '/metrics'
Get-Readings @'
targets_up|sum|vm_promscrape_targets|status=up
targets_down|sum|vm_promscrape_targets|status=down
scrapes_count|sum|vm_promscrape_scrapes_total
scrapes_failed_count|sum|vm_promscrape_scrapes_failed_total
config_reload_ok|min?|vm_promscrape_config_last_reload_successful
config_reload_errors_count|sum|vm_promscrape_config_reloads_errors_total
down|by|vm_promscrape_scrape_pool_targets|status=down|scrape_job:job
'@
exit 0
