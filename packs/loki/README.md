# The loki pack

A Loki, from what it says about itself. The pack reads whether it is ready and its rings whole; the lines and bytes it received, and the entries it discarded with the reason for each; the streams and chunks its ingester holds, and whether its chunks reach storage; and its compactor: when it last ran, whether retention is applied, and the delete requests waiting.

Loki answers a push with success and then discards entries by policy: too old, too long, over a limit. The sender sees nothing wrong. The only place that says so is Loki's own counters, one reason at a time.

**Read-only: every request is a GET.** The pack reads Loki's own pages and changes nothing, whatever its login would allow. It needs `curl` and `awk` on Linux and macOS, and nothing but PowerShell on Windows.

1. Nothing to turn on: Loki serves `/metrics` and `/ready` already.
2. `vigil pack enable loki`, then in `vigil.config` set what differs from the defaults: `LOKI_URL` (`http://localhost:3100`). In microservices mode each job reads one component: point `loki_ingestion` at a distributor or an ingester and `loki_compaction` at the compactor, or install the pack beside each. A component reports the readings it has, and zeros for the rest.
3. Where a proxy in front of it asks for a login: `LOKI_USER` with `secret = LOKI_PASSWORD=secret:LOKI_PASSWORD`, or a bearer token as `LOKI_TOKEN`.

**Loki that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (a login refused on a page every job needs, or something that is not HTTP), and says why.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `awk` | `curl`, `awk` (built in) | Nothing: PowerShell 5.1 or later, and .NET |
| Loki | Loki 2.9 and later, and 3.x (tested: 3.7.9, one binary); in microservices mode, each component reports those of these metrics it has | | |
| Its address | reachable from the Vigil machine: `LOKI_URL` (default `http://localhost:3100`) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `loki_status` | Up and ready; version; ingesters active and unhealthy; members of any ring unhealthy or not active; requests, 4xx and 5xx; queries in progress and queued; live tails; panics and errors logged | minute |
| `loki_ingestion` | Lines and bytes received; entries discarded, for each reason; streams and chunks in memory; chunks flushed, flushes failed and waiting; WAL failures; writes ingesters refused | minute |
| `loki_compaction` | Compactor active; compactions done and failed, and how long since one succeeded; the same for retention; delete requests waiting, and the oldest | 5 minutes |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `loki.up`.

```text
+--------------------------------------------------------------------------------------------------+
| loki_status   loki.<metric>   every 1m                                                           |
+---------------------+----------------------------------------------------------------------------+
| up                  | 1 when Loki answered its metrics page, else 0 (and nothing more is read)   |
| ready               | 1 when Loki says it is ready (/ready answers 200), else 0: it is starting, |
|                     | or an ingester is not in its ring                                          |
| version             | always 1, tagged version=<its version>                                     |
| uptime_seconds      | seconds since it started                                                   |
| ingesters_active    | ingesters active in the ring                                               |
| ingesters_unhealthy | ingesters in the ring that stopped sending heartbeats                      |
| ring_unhealthy      | members of any ring (ingester, distributor, compactor, scheduler) that     |
|                     | stopped                                                                    |
| ring_not_active     | members of any ring joining, leaving or pending                            |
| requests_count      | requests answered (a running total)                                        |
| requests_4xx_count  | of those, answered 4xx: a query that does not parse, a push refused, a     |
|                     | limit reached (a running total)                                            |
| requests_5xx_count  | answered 5xx: Loki failed (a running total)                                |
| queries_in_progress | queries the query frontend has in hand                                     |
| queue_length        | queries waiting for a querier                                              |
| tails_active        | live tails open now                                                        |
| panics_count        | panics recovered from (a running total)                                    |
| errors_logged_count | errors it logged (a running total)                                         |
+---------------------+----------------------------------------------------------------------------+
| GOOD  up 1; ready 1; ingesters_unhealthy and ring_unhealthy 0; requests_5xx_count not moving.    |
| WATCH requests_4xx_count climbing (a query in a dashboard that no longer parses, or pushes being |
|       limited: the ingestion job says which); queue_length staying above 0 (too few queriers);   |
|       ring_not_active above 0 outside a rollout.                                                 |
| BAD   up 0 or ready 0; ingesters_unhealthy above 0: writes may fail and queries miss recent      |
|       logs; requests_5xx_count moving; panics_count moving.                                      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| loki_ingestion   loki.ingestion.<metric>   every 1m                                              |
+--------------------------+-----------------------------------------------------------------------+
| up                       | 1 when Loki answered its metrics page, else 0 (and nothing more is    |
|                          | read)                                                                 |
| lines_received_count     | log lines received (a running total)                                  |
| bytes_received_count     | bytes received (a running total)                                      |
| discarded_count          | entries discarded (a running total)                                   |
| discarded                | the same, for each reason, tagged                                     |
|                          | reason=<greater_than_max_sample_age, line_too_long, rate_limited,     |
|                          | per_stream_rate_limit, stream_limit, too_far_behind ...>              |
| discarded_bytes_count    | bytes discarded (a running total)                                     |
| streams                  | streams the ingester holds in memory                                  |
| chunks                   | chunks it holds in memory                                             |
| streams_created_count    | streams created (a running total): its rate is churn                  |
| chunks_flushed_count     | chunks flushed to storage (a running total)                           |
| flush_failures_count     | flushes that failed (a running total)                                 |
| flush_queue              | chunks waiting to be flushed                                          |
| wal_disk_full_count      | WAL writes refused: the WAL's disk is full (a running total)          |
| wal_corruptions_count    | corruptions found replaying the WAL (a running total)                 |
| checkpoints_failed_count | WAL checkpoints that failed (a running total)                         |
| append_failures_count    | writes an ingester refused or did not answer (a running total)        |
| ..._not_shown            | past 100 of a list (discarded), how many were left out                |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  lines_received_count moving; discarded_count not moving; flush_failures_count and the WAL  |
|       counts at 0.                                                                               |
| WATCH streams or streams_created_count climbing fast (a label with too many values); flush_queue |
|       growing (storage slower than ingestion).                                                   |
| BAD   discarded_count moving: discarded says why (rate_limited and stream_limit: raise the       |
|       tenant's limits or cut what is sent; greater_than_max_sample_age: a shipper replaying, or  |
|       a clock behind; line_too_long); flush_failures_count moving: chunks are not reaching       |
|       storage, and an ingester restart would lose them; wal_disk_full_count or                   |
|       append_failures_count moving; lines_received_count not moving: nothing arrives.            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| loki_compaction   loki.compaction.<metric>   every 5m                                            |
+-------------------------------+------------------------------------------------------------------+
| up                            | 1 when Loki answered its metrics page, else 0 (and nothing more  |
|                               | is read)                                                         |
| compactor_active              | compactors active in their ring                                  |
| compactions_count             | compactions that succeeded (a running total)                     |
| compactions_failed_count      | compactions that failed (a running total)                        |
| last_compaction_seconds       | seconds since a compaction last succeeded                        |
| retention_runs_count          | retention runs that succeeded (a running total)                  |
| retention_failed_count        | retention runs that failed (a running total)                     |
| last_retention_seconds        | seconds since retention was last applied                         |
| delete_requests_pending       | delete requests waiting to be processed                          |
| oldest_delete_request_seconds | the age of the oldest of them                                    |
| tables_skipped                | compactions skipped in a row because a table was locked          |
+-------------------------------+------------------------------------------------------------------+
| GOOD  last_compaction_seconds under a few compaction intervals (10 minutes by default); the      |
|       failed counts not moving.                                                                  |
| WATCH delete_requests_pending or oldest_delete_request_seconds growing; tables_skipped above 0.  |
| BAD   last_compaction_seconds growing, or compactions_failed_count moving: the index is not      |
|       compacted (queries slow down) and, with retention on, nothing is deleted (storage grows    |
|       without end); retention_failed_count moving; compactor_active 0 where one should run.      |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the stack in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `loki.up`, `ready` | 1 |  | 0: it takes no logs and answers no query | `up 0` where nothing listened |
| `loki.ingesters_unhealthy` | 0 |  | Above 0: writes may fail and queries miss recent logs | 0 |
| `loki.ingestion.discarded_count` | Flat |  | Rising: `discarded` says why, one reason a line | Rising: `greater_than_max_sample_age` and `line_too_long`, half each |
| `loki.ingestion.flush_failures_count` | 0, flat |  | Rising: chunks are not reaching storage | Not caused |
| `loki.ingestion.lines_received_count` | Rising |  | Flat: nothing is arriving | Rising |
| `loki.requests_5xx_count` | Flat |  | Rising: Loki is failing requests | Not caused |
| `loki.requests_4xx_count` | Flat | Rising: a query that no longer parses, or pushes being refused |  | Rising: the bad query and the refused pushes, sent on purpose |
| `loki.compaction.last_compaction_seconds` | Under a few compaction intervals |  | Rising without end: the index is not compacted and nothing is deleted | Under a minute, with a 1-minute interval |

## How it was tested

**Tested** on 2026-11-25 by `tests/integration/backends/scripts/run-obs.sh`, against `compose.obs.yaml`: one stack of all nine services wired together as they are in use, each in trouble on purpose. **Prometheus 3.15.1** (two targets down and one that answers without metrics, a rule group that cannot be evaluated, an Alertmanager that is not there, a remote write nothing answers and one that is refused), **Alertmanager 0.35.1** (two in a cluster; a receiver nothing listens to), **Grafana 13.2.5** (a data source nothing answers, an alert rule that reads it, a contact point nothing listens to), **Loki 3.7.9** (entries too old, lines too long), **Mimir 3.2.6** (a tenant held at 200 series), **Tempo 2.10.10** (traces larger than its limit), **the OpenTelemetry Collector 0.166.0** (an exporter nothing answers, whose queue fills; a receiver that must refuse), **VictoriaMetrics 1.157.0** (a scrape target down, queries that fail) and **VictoriaLogs 1.54.0** (entries older than its retention), in Docker, with traces, metrics and logs flowing through all of it.

- **On Fedora** (Fedora 44, bash 5.3): every job of every pack and what each must have read; a token Grafana refuses, a page that is not there, and nothing answering; then the stack broken further, live (Tempo stopped, and seen by its own pack and by Prometheus', the Collector's and Grafana's; an Alertmanager leaving its cluster; a configuration Prometheus refuses, then Alertmanager): **84 passed, 0 failed**. Then `service-packs.sh` through Vigil, for all nine packs (enable, and that CPU and memory are the base pack's; precheck; every job; a service that does not answer read as `up 0`; Grafana's token kept as a secret and written nowhere; the metrics reaching the backend): **95 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-25/fedora/pack-obs/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own awk), against the same stack through SSH tunnels: every job and the same checks, **69 passed, 0 failed**; through Vigil, **95 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-25/macos/pack-obs-macos/console.txt)).
- **On Windows**, as an account that is not an administrator, against the same stack through SSH tunnels: every job, each compared with what the Linux script printed a moment before (the same readings, by name and tag, for all 28 jobs), the faults read again, then `Service-Packs.ps1` through Vigil. On Windows 11 under Windows PowerShell 5.1 and under PowerShell 7, and on Windows Server 2025 under Windows PowerShell 5.1: **79 passed, 0 failed** and **76 passed, 0 failed** on each ([Windows 11](../../tests/integration/backends/reports/runs/2026-11-25/windows/pack-obs-windows/console.txt), [under PowerShell 7](../../tests/integration/backends/reports/runs/2026-11-25/windows/pack-obs-windows/console-powershell7.txt), [Server 2025](../../tests/integration/backends/reports/runs/2026-11-25/windows-server-2025/pack-obs-windows/console.txt)). Over SSH, Windows refuses its data protection to a logon with no password, so there the suite gives Grafana's token by an `env:` reference; at a console, `vigil secret set` keeps it.
- **The two engines**, bash with awk and PowerShell, were compared line for line over all nine services' pages with a table that uses every operation on every metric: 12,873 readings, none differing, between gawk, mawk, macOS' awk, busybox's, Windows PowerShell 5.1 and PowerShell 7 (`tools/obs/DESIGN.md`).

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
