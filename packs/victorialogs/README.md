# The victorialogs pack

A VictoriaLogs server, from what it says about itself. The pack reads whether it answers and whether its storage has gone read-only for lack of disk; the disk space left; the log entries and bytes it ingests for each protocol; the entries it dropped and why; and its queries against the limit on running at once.

A log store drops what it cannot place: an entry stamped older than its retention, or too far ahead, is counted and gone. A shipper replaying a backlog after an outage can lose exactly the hours you wanted.

**Read-only: every request is a GET.** The pack reads VictoriaLogs's own pages and changes nothing, whatever its login would allow. It needs `curl` and `awk` on Linux and macOS, and nothing but PowerShell on Windows.

1. Nothing to turn on: VictoriaLogs serves `/metrics` and `/health` already.
2. `vigil pack enable victorialogs`, then in `vigil.config` set what differs from the defaults: `VICTORIALOGS_URL` (`http://localhost:9428`).
3. Where it asks for a login (`-httpAuth.username`): `VICTORIALOGS_USER` with `secret = VICTORIALOGS_PASSWORD=secret:VICTORIALOGS_PASSWORD`, or a bearer token as `VICTORIALOGS_TOKEN`.

**VictoriaLogs that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (a login refused on a page every job needs, or something that is not HTTP), and says why.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `awk` | `curl`, `awk` (built in) | Nothing: PowerShell 5.1 or later, and .NET |
| VictoriaLogs | VictoriaLogs single-node 1.0 and later (tested: 1.54.0) | | |
| Its address | reachable from the Vigil machine: `VICTORIALOGS_URL` (default `http://localhost:9428`) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `victorialogs_status` | Up and healthy; version; read-only; free disk and what its data takes; requests, and those that failed for each path; queries against the most at once, those that waited and those turned away; live tails; errors logged | minute |
| `victorialogs_ingestion` | Entries ingested, for each protocol, and bytes; entries dropped, for each reason; lines too long; streams created; entries held and pending; partitions; merges; compression ratio | minute |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `victorialogs.up`.

```text
+--------------------------------------------------------------------------------------------------+
| victorialogs_status   victorialogs.<metric>   every 1m                                           |
+-----------------------------+--------------------------------------------------------------------+
| up                          | 1 when VictoriaLogs answered its metrics page, else 0 (and nothing |
|                             | more is read)                                                      |
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
| selects                     | queries running now                                                |
| selects_capacity            | the most it runs at once (-search.maxConcurrentRequests)           |
| selects_pct                 | queries running, as a percentage of that                           |
| selects_limit_reached_count | times a query had to wait for a place (a running total)            |
| selects_limit_timeout_count | queries turned away after waiting -search.maxQueueDuration (a      |
|                             | running total)                                                     |
| live_tails                  | live tails open now                                                |
| errors_logged_count         | errors it logged (a running total)                                 |
| panics_logged_count         | panics it logged (a running total)                                 |
| ..._not_shown               | past 100 of a list (http_errors), how many were left out           |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  up 1; healthy 1; read_only 0; http_errors_count and errors_logged_count not moving.        |
| WATCH free_disk_bytes falling towards its limit; selects_pct near 100 or                         |
|       selects_limit_reached_count moving; http_errors_count moving on a query path (a query that |
|       does not parse).                                                                           |
| BAD   up 0 or healthy 0; read_only 1: it accepts no more logs until space is freed;              |
|       selects_limit_timeout_count moving; http_errors_count moving on an insert path             |
|       (http_errors says which): a shipper is being refused.                                      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| victorialogs_ingestion   victorialogs.ingestion.<metric>   every 1m                              |
+-----------------------+--------------------------------------------------------------------------+
| up                    | 1 when VictoriaLogs answered its metrics page, else 0 (and nothing more  |
|                       | is read)                                                                 |
| rows_ingested_count   | log entries ingested (a running total)                                   |
| rows_ingested         | the same, for each protocol, tagged type=<jsonline,                      |
|                       | opentelemetry_protobuf, loki, ...>                                       |
| bytes_ingested_count  | bytes ingested (a running total)                                         |
| rows_dropped_count    | entries dropped (a running total)                                        |
| rows_dropped          | the same, for each reason, tagged reason=<too_small_timestamp: older     |
|                       | than the retention; too_big_timestamp: too far ahead; too_many_fields;   |
|                       | debug>                                                                   |
| too_long_lines_count  | lines skipped: longer than -insert.maxLineSizeBytes (a running total)    |
| ingest_errors_count   | errors reading what a listener was sent, syslog among them (a running    |
|                       | total)                                                                   |
| streams_created_count | log streams created (a running total): its rate is churn                 |
| rows                  | entries it holds                                                         |
| pending_rows          | entries received and not yet written to a part                           |
| partitions            | daily partitions on disk                                                 |
| active_merges         | merges of parts running now                                              |
| compression_ratio     | what its data would take uncompressed, over what it takes                |
| ..._not_shown         | past 100 of a list (rows_ingested, rows_dropped), how many were left out |
+-----------------------+--------------------------------------------------------------------------+
| GOOD  rows_ingested_count moving; rows_dropped_count and too_long_lines_count not moving.        |
| WATCH streams_created_count climbing fast (a stream field with too many values: memory and disk  |
|       follow); pending_rows growing.                                                             |
| BAD   rows_ingested_count not moving: nothing is arriving; rows_dropped_count moving:            |
|       rows_dropped says why (too_small_timestamp: a shipper replaying old logs, or a clock far   |
|       behind; too_big_timestamp: a clock ahead); too_long_lines_count moving: lines are being    |
|       thrown away whole.                                                                         |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the stack in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `victorialogs.up`, `healthy` | 1 |  | 0: it takes no logs and answers no query | `up 0` where nothing listened |
| `victorialogs.read_only` | 0 |  | 1: it accepts no more logs until disk is freed | 0 |
| `victorialogs.free_disk_bytes` | Steady | Falling towards `-storage.minFreeDiskSpaceBytes` | Near it: it is about to go read-only | 80 GB |
| `victorialogs.ingestion.rows_dropped_count` | Flat |  | Rising: `rows_dropped` says why | Rising: `too_small_timestamp`, the entries ten days old against a retention of one |
| `victorialogs.ingestion.rows_ingested_count` | Rising |  | Flat: nothing is arriving | Rising: JSON lines and OTLP |
| `victorialogs.ingestion.too_long_lines_count` | Flat |  | Rising: lines are thrown away whole | Not caused |
| `victorialogs.selects_limit_timeout_count` | Flat | `selects_limit_reached_count` rising: queries queue | Rising: queries are turned away | Not caused |

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
