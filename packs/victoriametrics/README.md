# The victoriametrics pack

A VictoriaMetrics server, from what it says about itself. The pack reads whether it answers and whether its storage has gone read-only for lack of disk; the disk space left; what it ingests for each protocol, and what it refuses or ignores and why; its queries against the limit on running at once, the slow ones and those that failed; and the targets it scrapes itself.

VictoriaMetrics protects itself by going read-only when the disk runs low, and by queueing, then refusing, inserts and queries past their limits. Each is a counter that moves long before a dashboard goes blank.

**Read-only: every request is a GET.** The pack reads VictoriaMetrics's own pages and changes nothing, whatever its login would allow. It needs `curl` and `awk` on Linux and macOS, and nothing but PowerShell on Windows.

1. Nothing to turn on: VictoriaMetrics serves `/metrics` and `/health` already.
2. `vigil pack enable victoriametrics`, then in `vigil.config` set what differs from the defaults: `VICTORIAMETRICS_URL` (`http://localhost:8428`). For a cluster, or vmagent, point each job at the component that has its metrics (ingestion: vminsert or vmstorage; status: vmselect or vmstorage; targets: vmagent, on 8429), or install the pack beside each.
3. Where it asks for a login (`-httpAuth.username`): `VICTORIAMETRICS_USER` with `secret = VICTORIAMETRICS_PASSWORD=secret:VICTORIAMETRICS_PASSWORD`, or a bearer token as `VICTORIAMETRICS_TOKEN`.

**VictoriaMetrics that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (a login refused on a page every job needs, or something that is not HTTP), and says why.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `awk` | `curl`, `awk` (built in) | Nothing: PowerShell 5.1 or later, and .NET |
| VictoriaMetrics | VictoriaMetrics single-node 1.90 and later (tested: 1.157.0); each component of a cluster (vminsert, vmselect, vmstorage) and vmagent report those of these metrics they have | | |
| Its address | reachable from the Vigil machine: `VICTORIAMETRICS_URL` (default `http://localhost:8428`) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `victoriametrics_status` | Up and healthy; version; read-only; free disk and what its data takes; requests, and those that failed for each path; slow queries; queries against the most at once, those that waited and those turned away; errors logged | minute |
| `victoriametrics_ingestion` | Rows ingested, for each protocol; rows invalid and ignored, for each reason; new series; slow inserts; inserts against the most at once; rows dropped by a series limit; rows held and pending; merges | minute |
| `victoriametrics_targets` | Targets up and down, the down ones for each job; scrapes made and failed; whether the scrape configuration reloaded | minute |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `victoriametrics.up`.

```text
+--------------------------------------------------------------------------------------------------+
| victoriametrics_status   victoriametrics.<metric>   every 1m                                     |
+-----------------------------+--------------------------------------------------------------------+
| up                          | 1 when VictoriaMetrics answered its metrics page, else 0 (and      |
|                             | nothing more is read)                                              |
| healthy                     | 1 when /health answers 200, else 0                                 |
| version                     | always 1, tagged version=<its version>                             |
| uptime_seconds              | seconds since it started                                           |
| read_only                   | 1 when the storage refuses writes: the disk has less free than     |
|                             | -storage.minFreeDiskSpaceBytes; else 0                             |
| free_disk_bytes             | free space on the disk its data is on                              |
| data_bytes                  | what its data and index take on disk                               |
| http_requests_count         | requests answered (a running total)                                |
| http_errors_count           | requests that failed (a running total)                             |
| http_errors                 | the same, for each path, tagged path=<it>                          |
| slow_queries_count          | queries slower than -search.logSlowQueryDuration (a running total) |
| selects                     | queries running now                                                |
| selects_capacity            | the most it runs at once (-search.maxConcurrentRequests)           |
| selects_pct                 | queries running, as a percentage of that                           |
| selects_limit_reached_count | times a query had to wait for a place (a running total)            |
| selects_limit_timeout_count | queries turned away after waiting -search.maxQueueDuration (a      |
|                             | running total)                                                     |
| errors_logged_count         | errors it logged (a running total)                                 |
| panics_logged_count         | panics it logged (a running total)                                 |
| ..._not_shown               | past 100 of a list (http_errors), how many were left out           |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  up 1; healthy 1; read_only 0; http_errors_count and errors_logged_count not moving.        |
| WATCH free_disk_bytes falling towards its limit; selects_pct near 100 or                         |
|       selects_limit_reached_count moving (queries queue); slow_queries_count climbing.           |
| BAD   up 0 or healthy 0; read_only 1: it accepts no more samples until space is freed, and       |
|       everything sent is lost or queued at the sender; selects_limit_timeout_count moving:       |
|       dashboards and rules get errors; http_errors_count moving on a write path (http_errors     |
|       says which).                                                                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| victoriametrics_ingestion   victoriametrics.ingestion.<metric>   every 1m                        |
+-----------------------------+--------------------------------------------------------------------+
| up                          | 1 when VictoriaMetrics answered its metrics page, else 0 (and      |
|                             | nothing more is read)                                              |
| rows_inserted_count         | rows (samples) ingested (a running total)                          |
| rows_inserted               | the same, for each protocol, tagged type=<promremotewrite,         |
|                             | promscrape, influx, ...>                                           |
| rows_invalid_count          | rows that could not be parsed (a running total)                    |
| rows_ignored_count          | rows ignored: a timestamp outside the retention, a value that is   |
|                             | not a number, a label too long (a running total)                   |
| rows_ignored                | the same, for each reason, tagged reason                           |
| new_series_count            | series created (a running total): its rate is churn                |
| slow_row_inserts_count      | rows inserted the slow way, their series not in the cache (a       |
|                             | running total): a rising share means too little memory for the     |
|                             | active series                                                      |
| slow_inserts_pct            | slow inserts, as a percentage of all rows since it started         |
| inserts                     | inserts running now                                                |
| inserts_capacity            | the most it runs at once (-maxConcurrentInserts)                   |
| inserts_limit_reached_count | times an insert had to wait (a running total)                      |
| inserts_limit_timeout_count | inserts turned away after waiting -insert.maxQueueDuration (a      |
|                             | running total)                                                     |
| series_limit_dropped_count  | rows dropped by -storage.maxHourlySeries (a running total)         |
| daily_limit_dropped_count   | rows dropped by -storage.maxDailySeries (a running total)          |
| rows                        | rows it holds                                                      |
| pending_rows                | rows received and not yet written to a part                        |
| active_merges               | merges of parts running now                                        |
| ..._not_shown               | past 100 of a list (rows_inserted, rows_ignored), how many were    |
|                             | left out                                                           |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  rows_inserted_count moving; rows_invalid_count, rows_ignored_count and the limit counts    |
|       not moving.                                                                                |
| WATCH slow_inserts_pct above a few percent (more active series than the memory holds: raise      |
|       memory or cut churn); new_series_count climbing fast; inserts_limit_reached_count moving.  |
| BAD   rows_inserted_count not moving: nothing is arriving; rows_ignored_count or                 |
|       rows_invalid_count moving (rows_ignored says why); series_limit_dropped_count or           |
|       daily_limit_dropped_count moving: a cardinality limit is discarding data;                  |
|       inserts_limit_timeout_count moving: senders are being turned away.                         |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| victoriametrics_targets   victoriametrics.targets.<metric>   every 1m                            |
+----------------------------+---------------------------------------------------------------------+
| up                         | 1 when VictoriaMetrics answered its metrics page, else 0 (and       |
|                            | nothing more is read)                                               |
| targets_up                 | targets whose last scrape worked                                    |
| targets_down               | targets whose last scrape failed                                    |
| scrapes_count              | scrapes made (a running total)                                      |
| scrapes_failed_count       | scrapes that failed (a running total)                               |
| config_reload_ok           | 1 when the last reload of the scrape configuration worked, else 0   |
| config_reload_errors_count | reloads of it that failed (a running total)                         |
| down                       | the targets down in each job, tagged job=<it>                       |
| ..._not_shown              | past 100 of a list (down), how many were left out                   |
+----------------------------+---------------------------------------------------------------------+
| GOOD  targets_down 0; scrapes_failed_count not moving; config_reload_ok 1.                       |
| WATCH scrapes_failed_count moving now and then (a target that restarts, or answers slowly).      |
| BAD   targets_down above 0 for more than a few scrapes: down says which job; config_reload_ok 0: |
|       an edit it refused, and it scrapes what it scraped before.                                 |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the stack in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `victoriametrics.up`, `healthy` | 1 |  | 0: it takes no samples and answers no query | `up 0` where nothing listened |
| `victoriametrics.read_only` | 0 |  | 1: it accepts no more samples until disk is freed | 0 |
| `victoriametrics.free_disk_bytes` | Steady | Falling towards `-storage.minFreeDiskSpaceBytes` | Near it: it is about to go read-only | 80 GB |
| `victoriametrics.http_errors_count` | Flat | Rising on a query path: a query that does not parse | Rising on a write path: senders are being refused | Rising for `path=/api/v1/query`: the bad query sent on purpose |
| `victoriametrics.selects_limit_timeout_count` | Flat | `selects_limit_reached_count` rising: queries queue | Rising: queries are turned away | Not caused |
| `victoriametrics.ingestion.rows_inserted_count` | Rising |  | Flat: nothing is arriving | Rising: remote write and its own scraping |
| `victoriametrics.ingestion.slow_inserts_pct` | Under 1 | Above 5: more active series than its memory holds |  | Under 1 |
| `victoriametrics.ingestion.series_limit_dropped_count` | Flat |  | Rising: a cardinality limit is discarding data | Not caused |
| `victoriametrics.targets.targets_down` | 0 | Above 0 for a few scrapes | Staying above 0: `down` says which job | 1: `job=dead` |

## How it was tested

(to be written from the runs)

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
