# The mimir pack

A Grafana Mimir, from what it says about itself. The pack reads whether it is ready and its rings whole; the samples it received, and those it discarded with the reason for each; the series its ingester holds; the requests it failed or refused to protect itself; and what happens to its data afterwards: blocks shipped to the bucket, the compactor, the store-gateway, and the bucket itself.

Mimir enforces limits by discarding. A tenant at its series limit gets an error its sender may only count, and the series it was about to create never exist: a new deployment's metrics are simply not there. The reason is in one counter, with a label saying which limit.

**Read-only: every request is a GET.** The pack reads Mimir's own pages and changes nothing, whatever its login would allow. It needs `curl` and `awk` on Linux and macOS, and nothing but PowerShell on Windows.

1. Nothing to turn on: Mimir serves `/metrics` and `/ready` already.
2. `vigil pack enable mimir`, then in `vigil.config` set what differs from the defaults: `MIMIR_URL` (`http://localhost:9009`; often 8080 in a deployment). In microservices mode each job reads one component: point `mimir_ingestion` at a distributor or an ingester and `mimir_storage` at an ingester, a compactor or a store-gateway, or install the pack beside each. A component reports the readings it has, and zeros for the rest.
3. Where a proxy in front of it asks for a login: `MIMIR_USER` with `secret = MIMIR_PASSWORD=secret:MIMIR_PASSWORD`, or a bearer token as `MIMIR_TOKEN`.

**Mimir that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (a login refused on a page every job needs, or something that is not HTTP), and says why.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `awk` | `curl`, `awk` (built in) | Nothing: PowerShell 5.1 or later, and .NET |
| Mimir | Grafana Mimir 2.10 and later, and 3.x (tested: 3.2.6, one binary); in microservices mode, each component reports those of these metrics it has | | |
| Its address | reachable from the Vigil machine: `MIMIR_URL` (default `http://localhost:9009`) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `mimir_status` | Up and ready; version; ingesters, store-gateways and compactors active; members of any ring unhealthy or not active; requests, 4xx and 5xx; requests in flight; requests refused by instance limits | minute |
| `mimir_ingestion` | Samples sent, accepted and discarded, for each reason; series and tenants in memory; active series; samples appended and failed; writes ingesters refused; pushes in flight | minute |
| `mimir_storage` | Blocks shipped and uploads failed; the oldest block not shipped; head compactions, truncations and WAL failures; compactor runs, failures, and how long since one succeeded; blocks loaded and not; bucket operations failed, for each operation | 5 minutes |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `mimir.up`.

```text
+--------------------------------------------------------------------------------------------------+
| mimir_status   mimir.<metric>   every 1m                                                         |
+----------------------------+---------------------------------------------------------------------+
| up                         | 1 when Mimir answered its metrics page, else 0 (and nothing more is |
|                            | read)                                                               |
| ready                      | 1 when Mimir says it is ready (/ready answers 200), else 0: it is   |
|                            | starting, or a ring it needs is not whole                           |
| version                    | always 1, tagged version=<its version>                              |
| uptime_seconds             | seconds since it started                                            |
| ingesters_active           | ingesters active in the ring                                        |
| ingesters_unhealthy        | ingesters in the ring that stopped sending heartbeats               |
| store_gateways_active      | store-gateways active in their ring                                 |
| compactors_active          | compactors active in their ring                                     |
| ring_unhealthy             | members of any ring that stopped sending heartbeats                 |
| ring_not_active            | members of any ring joining, leaving or pending                     |
| requests_count             | requests answered (a running total)                                 |
| requests_4xx_count         | of those, answered 4xx: a query that does not parse, samples        |
|                            | refused, a limit reached (a running total)                          |
| requests_5xx_count         | answered 5xx: Mimir failed (a running total)                        |
| inflight_requests          | requests in flight now                                              |
| distributor_rejected_count | requests a distributor refused: one of its instance limits was      |
|                            | reached (a running total)                                           |
| ingester_rejected_count    | requests an ingester refused: one of its instance limits was        |
|                            | reached (a running total)                                           |
| querier_rejected_count     | queries refused (a running total)                                   |
+----------------------------+---------------------------------------------------------------------+
| GOOD  up 1; ready 1; ingesters_unhealthy and ring_unhealthy 0; requests_5xx_count not moving.    |
| WATCH requests_4xx_count climbing (the ingestion job says whether samples are being discarded);  |
|       ring_not_active above 0 outside a rollout; inflight_requests climbing.                     |
| BAD   up 0 or ready 0; ingesters_unhealthy above 0: with a replication factor of 3, a second one |
|       lost stops writes; requests_5xx_count moving; distributor_rejected_count or                |
|       ingester_rejected_count moving: Mimir is turning work away to stay up.                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mimir_ingestion   mimir.ingestion.<metric>   every 1m                                            |
+-----------------------------+--------------------------------------------------------------------+
| up                          | 1 when Mimir answered its metrics page, else 0 (and nothing more   |
|                             | is read)                                                           |
| samples_in_count            | samples sent to the distributor, before any check (a running       |
|                             | total)                                                             |
| samples_received_count      | samples it accepted (a running total)                              |
| discarded_count             | samples discarded (a running total)                                |
| discarded                   | the same, for each reason, tagged reason=<per_user_series_limit,   |
|                             | per_metric_series_limit, rate_limited, sample-out-of-order,        |
|                             | sample-too-old, label_invalid, metric_name_invalid ...>            |
| series                      | series the ingester holds in memory                                |
| tenants                     | tenants it holds series for                                        |
| active_series               | series that received a sample lately                               |
| ingested_samples_count      | samples the ingester appended (a running total)                    |
| ingested_failures_count     | samples it could not append (a running total)                      |
| append_failures_count       | writes an ingester refused or did not answer (a running total)     |
| pushes_in_flight            | pushes the distributor is handling now                             |
| out_of_order_appended_count | out-of-order samples it took, where that is allowed (a running     |
|                             | total)                                                             |
| ..._not_shown               | past 100 of a list (discarded), how many were left out             |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  samples_received_count moving; discarded_count not moving; ingested_failures_count at 0.   |
| WATCH series climbing towards a tenant's limit; ingested_failures_count moving a little          |
|       (out-of-order or duplicate samples from a sender).                                         |
| BAD   discarded_count moving: discarded says why (per_user_series_limit: the tenant is at its    |
|       limit and new series are lost; rate_limited: it sends faster than it may; sample-too-old;  |
|       label_invalid); append_failures_count moving: ingesters are refusing or missing;           |
|       samples_received_count not moving: nothing arrives.                                        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mimir_storage   mimir.storage.<metric>   every 5m                                                |
+-------------------------------+------------------------------------------------------------------+
| up                            | 1 when Mimir answered its metrics page, else 0 (and nothing more |
|                               | is read)                                                         |
| shipper_uploads_count         | blocks shipped to the bucket (a running total)                   |
| shipper_failures_count        | uploads that failed (a running total)                            |
| oldest_unshipped_seconds      | the age of the oldest block not yet shipped (nothing when all    |
|                               | are)                                                             |
| head_compactions_failed_count | the ingester's head compactions that failed (a running total)    |
| head_truncations_failed_count | head truncations that failed (a running total)                   |
| wal_corruptions_count         | corruptions found in the WAL (a running total)                   |
| wal_writes_failed_count       | WAL writes that failed (a running total)                         |
| compactor_runs_count          | compactor runs completed (a running total)                       |
| compactor_runs_failed_count   | compactor runs that failed (a running total)                     |
| last_compaction_seconds       | seconds since a compactor run last succeeded                     |
| cleanup_failures_count        | cleanups of deleted blocks that failed (a running total)         |
| blocks_loaded                 | blocks the store-gateway has loaded                              |
| block_load_failures_count     | blocks it could not load (a running total)                       |
| consistency_failures_count    | queries that could not find every block they needed in a         |
|                               | store-gateway (a running total)                                  |
| bucket_operations_count       | operations on the bucket (a running total)                       |
| bucket_failures_count         | operations on the bucket that failed (a running total)           |
| bucket_failures               | the same, for each operation, tagged operation=<get, upload,     |
|                               | iter, exists, delete ...>                                        |
| ..._not_shown                 | past 100 of a list (bucket_failures), how many were left out     |
+-------------------------------+------------------------------------------------------------------+
| GOOD  every failed count at 0; last_compaction_seconds under a few compaction intervals;         |
|       oldest_unshipped_seconds, when printed, under a few hours.                                 |
| WATCH bucket_failures_count moving now and then (the object store throttling, or a network that  |
|       drops); cleanup_failures_count moving.                                                     |
| BAD   shipper_failures_count moving, or oldest_unshipped_seconds growing: blocks stay on the     |
|       ingester's disk, which fills, and they are lost if it is; compactor_runs_failed_count      |
|       moving or last_compaction_seconds growing: blocks pile up and queries slow;                |
|       block_load_failures_count or consistency_failures_count moving: queries are missing data;  |
|       any WAL count above 0.                                                                     |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the stack in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `mimir.up`, `ready` | 1 |  | 0: it takes no samples and answers no query | `up 0` where nothing listened |
| `mimir.ingesters_unhealthy` | 0 |  | Above 0: with a replication factor of 3, a second one lost stops writes | 0 |
| `mimir.ingestion.discarded_count` | Flat |  | Rising: `discarded` says why (which limit, or what is wrong with the samples) | Rising: `per_user_series_limit` above all, the tenant held at 200 series |
| `mimir.ingestion.series` | Below the tenant's limit | Nearing it | At it: new series are lost | 200, the limit set |
| `mimir.requests_5xx_count` | Flat |  | Rising: Mimir is failing requests | 1, at its start |
| `mimir.distributor_rejected_count`, `ingester_rejected_count` | Flat |  | Rising: it is turning work away to stay up | Not caused |
| `mimir.storage.shipper_failures_count` | 0, flat |  | Rising: blocks stay on the ingester's disk, which fills | Not caused |
| `mimir.storage.last_compaction_seconds` | Under a few compaction intervals |  | Rising without end: blocks pile up and queries slow | Under a minute, with a 1-minute interval |
| `mimir.storage.bucket_failures_count` | Flat | Rising now and then | Rising steadily: the object store is failing; `bucket_failures` says which operation | Not caused |

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
