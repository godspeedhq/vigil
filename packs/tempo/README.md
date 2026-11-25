# The tempo pack

A Grafana Tempo, from what it says about itself. The pack reads whether it is ready and its ingester ring whole; the spans it received, those its receivers refused and those it discarded, with the reason for each; the traces it holds live and the blocks it flushes; and its storage: compaction, retention and the list of blocks.

A trace that is too large, or a tenant over its rate, is dropped by Tempo with a success to the sender's batch as a whole. The trace you go looking for during an incident is the one most likely to have been the large one.

**Read-only: every request is a GET.** The pack reads Tempo's own pages and changes nothing, whatever its login would allow. It needs `curl` and `awk` on Linux and macOS, and nothing but PowerShell on Windows.

1. Nothing to turn on: Tempo serves `/metrics` and `/ready` already.
2. `vigil pack enable tempo`, then in `vigil.config` set what differs from the defaults: `TEMPO_URL` (`http://localhost:3200`). In microservices mode each job reads one component: point `tempo_ingestion` at a distributor or an ingester and `tempo_storage` at the compactor, or install the pack beside each.
3. Where a proxy in front of it asks for a login: `TEMPO_USER` with `secret = TEMPO_PASSWORD=secret:TEMPO_PASSWORD`, or a bearer token as `TEMPO_TOKEN`.

**Tempo that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (a login refused on a page every job needs, or something that is not HTTP), and says why.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `awk` | `curl`, `awk` (built in) | Nothing: PowerShell 5.1 or later, and .NET |
| Tempo | Grafana Tempo 2.x (tested: 2.10.10, one binary); in microservices mode, each component reports those of these metrics it has | | |
| Its address | reachable from the Vigil machine: `TEMPO_URL` (default `http://localhost:3200`) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `tempo_status` | Up and ready; version; ingesters active and unhealthy; members of any ring unhealthy or not active; requests, 4xx and 5xx; requests in flight | minute |
| `tempo_ingestion` | Spans and bytes received; spans its receivers took and refused; spans discarded, for each reason; live traces and traces created; blocks flushed, flushes failed and waiting; writes ingesters refused | minute |
| `tempo_storage` | Blocks in the blocklist; compactions and those that failed; blocks retention deleted, and its failures; polls of the blocklist that failed; requests to the backend that failed | 5 minutes |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `tempo.up`.

```text
+--------------------------------------------------------------------------------------------------+
| tempo_status   tempo.<metric>   every 1m                                                         |
+---------------------+----------------------------------------------------------------------------+
| up                  | 1 when Tempo answered its metrics page, else 0 (and nothing more is read)  |
| ready               | 1 when Tempo says it is ready (/ready answers 200), else 0: it is          |
|                     | starting, or an ingester is not in its ring                                |
| version             | always 1, tagged version=<its version>                                     |
| uptime_seconds      | seconds since it started                                                   |
| ingesters_active    | ingesters active in the ring                                               |
| ingesters_unhealthy | ingesters in the ring that stopped sending heartbeats                      |
| ring_unhealthy      | members of any ring that stopped sending heartbeats                        |
| ring_not_active     | members of any ring joining, leaving or pending                            |
| requests_count      | requests answered (a running total)                                        |
| requests_4xx_count  | of those, answered 4xx: a search that does not parse, a trace that is not  |
|                     | there, a limit reached (a running total)                                   |
| requests_5xx_count  | answered 5xx: Tempo failed (a running total)                               |
| inflight_requests   | requests in flight now                                                     |
+---------------------+----------------------------------------------------------------------------+
| GOOD  up 1; ready 1; ingesters_unhealthy and ring_unhealthy 0; requests_5xx_count not moving.    |
| WATCH requests_4xx_count climbing; ring_not_active above 0 outside a rollout.                    |
| BAD   up 0 or ready 0; ingesters_unhealthy above 0: spans may be refused and recent traces       |
|       missing; requests_5xx_count moving.                                                        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| tempo_ingestion   tempo.ingestion.<metric>   every 1m                                            |
+-------------------------+------------------------------------------------------------------------+
| up                      | 1 when Tempo answered its metrics page, else 0 (and nothing more is    |
|                         | read)                                                                  |
| spans_received_count    | spans received (a running total)                                       |
| bytes_received_count    | bytes received (a running total)                                       |
| receiver_accepted_count | spans its receivers (OTLP, Jaeger, Zipkin) took (a running total)      |
| receiver_refused_count  | spans its receivers refused (a running total)                          |
| discarded_count         | spans discarded (a running total)                                      |
| discarded               | the same, for each reason, tagged reason=<trace_too_large,             |
|                         | rate_limited, live_traces_exceeded, internal_error ...>                |
| live_traces             | traces the ingester holds in memory, not yet cut to a block            |
| traces_created_count    | traces it started (a running total)                                    |
| blocks_flushed_count    | blocks flushed to storage (a running total)                            |
| flush_failures_count    | flushes that failed (a running total)                                  |
| flush_queue             | blocks waiting to be flushed                                           |
| append_failures_count   | writes an ingester refused or did not answer (a running total)         |
| warnings_count          | traces it had to change or cut short (a running total)                 |
| ..._not_shown           | past 100 of a list (discarded), how many were left out                 |
+-------------------------+------------------------------------------------------------------------+
| GOOD  spans_received_count moving; discarded_count and receiver_refused_count not moving;        |
|       flush_failures_count at 0.                                                                 |
| WATCH live_traces climbing towards the tenant's limit; flush_queue growing (storage slower than  |
|       ingestion).                                                                                |
| BAD   discarded_count moving: discarded says why (trace_too_large: a trace over                  |
|       max_bytes_per_trace, usually a loop; rate_limited: raise the tenant's limits or sample     |
|       more; live_traces_exceeded); receiver_refused_count moving: senders are being turned away; |
|       flush_failures_count moving: blocks are not reaching storage; spans_received_count not     |
|       moving: nothing arrives.                                                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| tempo_storage   tempo.storage.<metric>   every 5m                                                |
+-----------------------------+--------------------------------------------------------------------+
| up                          | 1 when Tempo answered its metrics page, else 0 (and nothing more   |
|                             | is read)                                                           |
| blocks                      | blocks in the blocklist, every tenant                              |
| compactions_count           | blocks compacted (a running total)                                 |
| compaction_errors_count     | compactions that failed (a running total)                          |
| retention_deleted_count     | blocks retention deleted (a running total)                         |
| retention_errors_count      | retention runs that failed (a running total)                       |
| blocklist_poll_errors_count | polls of the blocklist that failed (a running total)               |
| backend_requests_count      | requests to the backend (a running total)                          |
| backend_errors_count        | of those, the ones the backend failed (a running total)            |
| work_queue                  | jobs waiting in its read queue                                     |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  compaction_errors_count, retention_errors_count and blocklist_poll_errors_count not        |
|       moving.                                                                                    |
| WATCH blocks growing without end (compaction or retention not keeping up); work_queue staying    |
|       above 0.                                                                                   |
| BAD   compaction_errors_count moving: blocks pile up and searches slow; retention_errors_count   |
|       moving: nothing is deleted and storage grows; blocklist_poll_errors_count or               |
|       backend_errors_count moving: Tempo cannot read its storage, and queries miss traces.       |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the stack in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `tempo.up`, `ready` | 1 |  | 0: it takes no spans and answers no query | `up 0` when it was stopped; then three other packs saw it too |
| `tempo.ingesters_unhealthy` | 0 |  | Above 0: spans may be refused and recent traces missing | 0 |
| `tempo.ingestion.discarded_count` | Flat |  | Rising: `discarded` says why | Rising: `trace_too_large`, the traces of 40 spans against a limit of 2 KB |
| `tempo.ingestion.receiver_refused_count` | Flat |  | Rising: senders are being turned away | Not caused |
| `tempo.ingestion.flush_failures_count` | 0, flat |  | Rising: blocks are not reaching storage | Not caused |
| `tempo.ingestion.spans_received_count` | Rising |  | Flat: nothing is arriving | Rising |
| `tempo.storage.compaction_errors_count`, `retention_errors_count` | Flat |  | Rising: blocks pile up, or nothing is deleted | Not caused |

## How it was tested

(to be written from the runs)

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
