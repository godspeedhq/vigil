# The prometheus pack

A Prometheus server, from what it says about itself. The pack reads whether it is ready and its last configuration reload worked; its targets, up and down, for each job; its TSDB (the series in its head, its WAL, its blocks, and everything that failed); its rules (evaluations that failed, for each group, and the alerts firing); the alerts it sends to its Alertmanagers and those that do not get there; and its remote write queues, with how far the slowest remote is behind.

It is the usual blind spot: Prometheus watches everything, and nothing watches Prometheus. When it stops scraping, its alerts stop too, and silence looks like health. This pack runs beside it and reports to wherever Vigil reports, so a Prometheus in trouble is said by something that is not Prometheus.

**Read-only: every request is a GET.** The pack reads Prometheus's own pages and changes nothing, whatever its login would allow. It needs `curl` and `awk` on Linux and macOS, and nothing but PowerShell on Windows.

1. Nothing to turn on: Prometheus serves `/metrics`, `/-/ready` and `/federate` already.
2. `vigil pack enable prometheus`, then in `vigil.config` set what differs from the defaults, in the jobs' `env` lines: `PROMETHEUS_URL` (`http://localhost:9090`; with `--web.route-prefix`, that prefix too), and where it asks for a login, `PROMETHEUS_USER` with `secret = PROMETHEUS_PASSWORD=secret:PROMETHEUS_PASSWORD` (then `vigil secret set PROMETHEUS_PASSWORD`), or a bearer token as `PROMETHEUS_TOKEN` the same way.

**Prometheus that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (a login refused on a page every job needs, or something that is not HTTP), and says why.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `awk` | `curl`, `awk` (built in) | Nothing: PowerShell 5.1 or later, and .NET |
| Prometheus | Prometheus 2.40 and later, and 3.x (tested: 3.15.1) | | |
| Its address | reachable from the Vigil machine: `PROMETHEUS_URL` (default `http://localhost:9090`) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `prometheus_status` | Up and ready; version; the last configuration reload, and how long ago; queries against the most allowed; requests, 4xx and 5xx; Alertmanagers found, alerts sent, failed (for each Alertmanager) and dropped; open files against the limit | minute |
| `prometheus_targets` | Targets up and down, the down ones for each job; the slowest scrape; scrapes rejected whole (sample, body and target limits); samples rejected (out of order, duplicate, out of bounds) | minute |
| `prometheus_tsdb` | Series and chunks in the head, churn, samples appended; blocks, WAL and head on disk; retention, and how far back and how fresh its data is; compactions, WAL writes, truncations, checkpoints and reloads that failed; corruptions | minute |
| `prometheus_rules` | Rule groups and rules; evaluations, and those that failed for each group; iterations missed; the slowest and the stalest group; alerts firing (for each alert) and pending | minute |
| `prometheus_remote_write` | For all remotes and each: samples sent, failed, retried, dropped and waiting; shards against the most allowed; how far the slowest remote is behind; remotes that never took a sample | minute |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `prometheus.up`.

```text
+--------------------------------------------------------------------------------------------------+
| prometheus_status   prometheus.<metric>   every 1m                                               |
+-----------------------------+--------------------------------------------------------------------+
| up                          | 1 when Prometheus answered its metrics page, else 0 (and nothing   |
|                             | more is read)                                                      |
| ready                       | 1 when Prometheus says it is ready to serve (/-/ready answers      |
|                             | 200), else 0: it is starting, replaying its WAL, or shutting down  |
| version                     | always 1, tagged version=<its version>                             |
| uptime_seconds              | seconds since it started                                           |
| config_reload_ok            | 1 when the last configuration reload worked, else 0: it is still   |
|                             | running the one before                                             |
| config_age_seconds          | seconds since the configuration it runs was loaded                 |
| queries                     | queries running or waiting now                                     |
| queries_max                 | the most it runs at once (--query.max-concurrency)                 |
| queries_pct                 | queries, as a percentage of that                                   |
| http_requests_count         | requests answered (a running total)                                |
| http_4xx_count              | of those, answered 4xx: a query it could not parse, or refused (a  |
|                             | running total)                                                     |
| http_5xx_count              | answered 5xx: it failed, or a query timed out (a running total)    |
| alertmanagers               | Alertmanagers it found to send alerts to                           |
| notifications_sent_count    | alerts sent to them (a running total)                              |
| notifications_errors_count  | alerts an Alertmanager did not take (a running total)              |
| notifications_errors        | the same, for each Alertmanager, tagged alertmanager=<its address> |
| notifications_dropped_count | alerts dropped: the queue was full, or no Alertmanager took them   |
|                             | (a running total)                                                  |
| notification_queue          | alerts waiting to be sent                                          |
| notification_queue_capacity | how many may wait                                                  |
| fds_pct                     | open files, as a percentage of its limit                           |
| ..._not_shown               | past 100 of a list (notifications_errors), how many were left out  |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  up 1; ready 1; config_reload_ok 1; http_5xx_count and notifications_errors_count not       |
|       moving.                                                                                    |
| WATCH queries_pct near 100 (queries queue behind --query.max-concurrency); notification_queue    |
|       growing; http_4xx_count climbing (a dashboard or a rule with a query that no longer        |
|       parses).                                                                                   |
| BAD   up 0 or ready 0; config_reload_ok 0 (an edit it refused: it runs the old configuration     |
|       until the file is fixed); notifications_errors_count or notifications_dropped_count        |
|       climbing: alerts are not reaching anyone; fds_pct above 80.                                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| prometheus_targets   prometheus.targets.<metric>   every 1m                                      |
+-----------------------------+--------------------------------------------------------------------+
| up                          | 1 when Prometheus answered its metrics page, else 0 (and nothing   |
|                             | more is read)                                                      |
| scrape_pools                | scrape jobs configured                                             |
| targets                     | targets in them                                                    |
| discovered_targets          | targets service discovery found, before relabelling                |
| sd_failed_configs           | service discovery configurations that could not be loaded          |
| pool_reloads_failed_count   | scrape jobs that could not be reloaded (a running total)           |
| exceeded_sample_limit_count | scrapes rejected whole: more samples than sample_limit (a running  |
|                             | total)                                                             |
| exceeded_body_size_count    | scrapes rejected whole: a page larger than body_size_limit (a      |
|                             | running total)                                                     |
| exceeded_target_limit_count | times a scrape job had more targets than target_limit: none of     |
|                             | them is scraped (a running total)                                  |
| out_of_order_count          | samples rejected: out of order (a running total)                   |
| duplicate_timestamp_count   | samples rejected: the same series twice in one scrape (a running   |
|                             | total)                                                             |
| out_of_bounds_count         | samples rejected: too old or too far ahead (a running total)       |
| targets_up                  | targets whose last scrape worked                                   |
| targets_down                | targets whose last scrape failed: nothing answered, or not with    |
|                             | metrics                                                            |
| down                        | the targets down in each job, tagged job=<it> (0 for a job with    |
|                             | none down)                                                         |
| scrape_slowest_seconds      | the slowest target's last scrape                                   |
| samples_scraped             | samples the last scrape of every target brought                    |
| ..._not_shown               | past 100 of a list (down), how many were left out                  |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  targets_down 0; the rejected counts not moving; scrape_slowest_seconds well under the      |
|       scrape interval.                                                                           |
| WATCH scrape_slowest_seconds near the scrape timeout (a target about to fail);                   |
|       out_of_order_count or duplicate_timestamp_count climbing (an exporter printing a series    |
|       twice, or two Prometheus scraping into one).                                               |
| BAD   targets_down above 0 for more than a few scrapes: down says which job;                     |
|       exceeded_sample_limit_count or exceeded_target_limit_count moving: whole scrapes are being |
|       thrown away; sd_failed_configs above 0.                                                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| prometheus_tsdb   prometheus.tsdb.<metric>   every 1m                                            |
+-------------------------------+------------------------------------------------------------------+
| up                            | 1 when Prometheus answered its metrics page, else 0 (and nothing |
|                               | more is read)                                                    |
| head_series                   | series in memory: the cardinality it carries now                 |
| head_chunks                   | chunks in memory                                                 |
| series_created_count          | series created (a running total): its rate is churn              |
| samples_appended_count        | samples appended (a running total)                               |
| out_of_order_samples_count    | samples refused: out of order (a running total)                  |
| blocks                        | blocks on disk it has loaded                                     |
| blocks_bytes                  | what they take                                                   |
| wal_bytes                     | what the WAL takes                                               |
| head_chunks_bytes             | what the head's chunks on disk take                              |
| retention_seconds             | how long it keeps data (0: no limit by time)                     |
| oldest_sample_seconds         | how far back its data goes, in seconds                           |
| newest_sample_seconds         | seconds since the newest sample it holds: it is ingesting when   |
|                               | this stays small                                                 |
| compactions_count             | compactions run (a running total)                                |
| compactions_failed_count      | compactions that failed (a running total)                        |
| wal_corruptions_count         | corruptions found in the WAL (a running total)                   |
| wal_writes_failed_count       | WAL writes that failed (a running total)                         |
| wal_truncations_failed_count  | WAL truncations that failed (a running total)                    |
| checkpoints_failed_count      | checkpoints that failed (a running total)                        |
| head_truncations_failed_count | head truncations that failed (a running total)                   |
| reloads_failed_count          | reloads of its blocks from disk that failed (a running total)    |
| mmap_corruptions_count        | corruptions found in the head's chunks on disk (a running total) |
| clean_start                   | 1 when it started from a clean shutdown; 0 when it had to        |
|                               | recover; -1 when it cannot tell                                  |
+-------------------------------+------------------------------------------------------------------+
| GOOD  head_series steady or growing slowly; newest_sample_seconds under a minute; every failed   |
|       count at 0.                                                                                |
| WATCH head_series or series_created_count climbing fast (a label with too many values: memory    |
|       follows); wal_bytes growing without end (checkpoints or truncations failing); clean_start  |
|       0 after a restart.                                                                         |
| BAD   any of compactions_failed_count, wal_writes_failed_count, checkpoints_failed_count,        |
|       reloads_failed_count moving: the disk is full, read-only or failing; wal_corruptions_count |
|       or mmap_corruptions_count above 0; newest_sample_seconds growing: it has stopped           |
|       ingesting.                                                                                 |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| prometheus_rules   prometheus.rules.<metric>   every 1m                                          |
+---------------------------+----------------------------------------------------------------------+
| up                        | 1 when Prometheus answered its metrics page, else 0 (and nothing     |
|                           | more is read)                                                        |
| groups                    | rule groups loaded                                                   |
| rules                     | rules in them                                                        |
| evaluations_count         | rule evaluations (a running total)                                   |
| evaluation_failures_count | evaluations that failed (a running total)                            |
| evaluation_failures       | the same, for each group, tagged group=<file;name>                   |
| iterations_missed_count   | times a group was skipped: its last run had not ended (a running     |
|                           | total)                                                               |
| slowest_group_seconds     | how long the slowest group took, last time                           |
| stalest_group_seconds     | seconds since the group evaluated longest ago was evaluated          |
| alerts_firing             | alerts firing now                                                    |
| alerts_pending            | alerts whose condition holds, waiting out their "for"                |
| firing                    | the alerts firing, for each alert rule, tagged alert=<its name>      |
| ..._not_shown             | past 100 of a list (evaluation_failures, firing), how many were left |
|                           | out                                                                  |
+---------------------------+----------------------------------------------------------------------+
| GOOD  evaluation_failures_count and iterations_missed_count not moving; stalest_group_seconds    |
|       under twice the longest group interval.                                                    |
| WATCH slowest_group_seconds near its group interval (it will start missing iterations);          |
|       alerts_pending staying high.                                                               |
| BAD   evaluation_failures_count moving: evaluation_failures says which group (its alerts cannot  |
|       fire, and its recorded series go stale); iterations_missed_count moving;                   |
|       stalest_group_seconds growing: rules have stopped being evaluated; alerts_firing, which is |
|       what the rules are for.                                                                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| prometheus_remote_write   prometheus.remote_write.<metric>   every 1m                            |
+-----------------------+--------------------------------------------------------------------------+
| up                    | 1 when Prometheus answered its metrics page, else 0 (and nothing more is |
|                       | read)                                                                    |
| remotes               | remote write destinations configured                                     |
| samples_sent_count    | samples sent (a running total)                                           |
| samples_failed_count  | samples a remote refused for good: they are lost to it (a running total) |
| samples_failed        | the same, for each remote, tagged remote=<its name>                      |
| samples_retried_count | samples sent again after a failure that may pass: the remote was down or |
|                       | slow (a running total)                                                   |
| samples_dropped_count | samples dropped before sending: relabelled away, or too old (a running   |
|                       | total)                                                                   |
| samples_pending       | samples waiting in the queues                                            |
| pending               | the same, for each remote, tagged remote                                 |
| shards                | shards sending now                                                       |
| shards_max            | the most it may use                                                      |
| shards_desired        | how many it works out it needs: above shards_max, it cannot keep up      |
| behind_seconds        | how far the slowest remote that has sent anything is behind the newest   |
|                       | sample ingested, in seconds                                              |
| remotes_never_sent    | remotes that have not taken a single sample since Prometheus started     |
| ..._not_shown         | past 100 of a list (samples_failed, pending), how many were left out     |
+-----------------------+--------------------------------------------------------------------------+
| GOOD  samples_failed_count not moving; behind_seconds under a minute; samples_pending small and  |
|       steady.                                                                                    |
| WATCH samples_retried_count climbing (a remote that is slow or flapping); shards near            |
|       shards_max.                                                                                |
| BAD   behind_seconds growing: a remote is down or too slow, and pending says which;              |
|       remotes_never_sent above 0 once Prometheus has run a few minutes: a remote that was never  |
|       there; samples_failed_count moving: samples_failed says which remote refuses them (a limit |
|       reached there, or samples it rejects); shards_desired above shards_max.                    |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the stack in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `prometheus.up`, `ready` | 1 |  | 0: it is down, starting, or replaying its WAL. Its own alerts are silent meanwhile | `up 0` where nothing listened; `ready 1` otherwise |
| `prometheus.config_reload_ok` | 1 |  | 0: an edit it refused. It runs the old configuration until the file is fixed | 0 after a file with a broken line and a reload; 1 again once mended |
| `prometheus.targets.targets_down` | 0 | Above 0 for a few scrapes | Staying above 0: `down` says which job | 3: two in `job=dead`, one in `job=notmetrics`; 4 with Tempo stopped |
| `prometheus.rules.evaluation_failures_count` | Flat |  | Rising: `evaluation_failures` names the group. Its alerts cannot fire | Rising, all in the group `broken` |
| `prometheus.notifications_errors_count`, `notifications_dropped_count` | Flat |  | Rising: alerts fire and reach nobody | Rising for the Alertmanager that was not there, named in `notifications_errors` |
| `prometheus.remote_write.behind_seconds` | Under a minute | Rising | Minutes and rising: a remote is down or too slow; `pending` says which | Seconds, for the two remotes that answered |
| `prometheus.remote_write.samples_failed_count` | Flat |  | Rising: a remote refuses samples for good (`samples_failed` says which) | Rising for `remote=mimir`, which was at its series limit |
| `prometheus.remote_write.remotes_never_sent` | 0 |  | Above 0 a few minutes after a start: a remote that was never there | 1: the remote nothing listened to |
| `prometheus.tsdb.head_series` | Steady | Rising fast: a label with too many values |  | About 15,600 for the stack's twelve targets |
| `prometheus.tsdb.wal_corruptions_count`, `compactions_failed_count` | 0, flat |  | Above 0, or rising: the disk is full, read-only or failing | Not caused |

## How it was tested

(to be written from the runs)

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
