# Compatibility matrix

How each backend works with Vigil, and what a real test showed. **Grafana LGTM has been run with Vigil on Linux, macOS and Windows; the rest of group 1 (the Grafana ecosystem), group 3 (Victoria) and group 4 (Elastic) with Vigil on Linux, including the delivery checks of section 5** (below). Every other result is Not tested. Secret stores are in [`secrets-compatibility.md`](secrets-compatibility.md). A result changes only with evidence from a run: the software version, the date, the configuration, and what the backend's own query returned, saved by `scripts/verify.sh` in `reports/evidence/`. A test that didn't run is never marked Passed.

**Integration methods:**
- **Direct Vigil integration:** a Vigil backend or log destination made for this product.
- **Protocol-compatible:** the product takes a protocol Vigil sends, OTLP/HTTP here.
- **Through an intermediary:** a collector or agent in between.
- **Supporting component only:** stores nothing Vigil sends.
- **Unsupported:** no route works.
- **Not applicable:** a signal Vigil doesn't send.

**Results:** Passed, Failed, Not supported, Not applicable, Not tested, or Blocked by licensing or account restrictions.

| Backend | Deployment | Integration method | Metrics | Logs | Traces | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Grafana LGTM (`grafana/otel-lgtm:0.38.1`) | Docker, default | Protocol-compatible (OTLP/HTTP) | **Passed** (counts as cumulative sums; see Runs) | **Passed** | Not applicable | **Passed** |
| Prometheus (`v3.15.1`) | Docker | Protocol-compatible (OTLP receiver) | **Passed** | Not supported | Not applicable | **Passed** |
| Grafana (`13.2.5`) | Docker | Supporting component only (starts and is healthy) | Not applicable | Not applicable | Not applicable | Not applicable |
| Loki (`3.7.9`) | Docker | Protocol-compatible (OTLP) | Not supported | **Passed** | Not applicable | **Passed** |
| Tempo (`2.10.10`) | Docker | Not applicable (starts and is ready) | Not applicable | Not applicable | Not applicable | Not applicable |
| Mimir (`3.2.4`) | Docker | Protocol-compatible (OTLP) | **Passed** | Not supported | Not applicable | **Passed** |
| Pyroscope (`2.4.2`) | Docker | Not applicable (starts and is ready) | Not applicable | Not applicable | Not applicable | Not applicable |
| OpenTelemetry Collector (`0.163.2`) | Docker | Through an intermediary (to Mimir and Loki) | **Passed** | **Passed** | Not applicable | **Passed** |
| Grafana Alloy (`v1.21.3`) | Docker | Through an intermediary (to Prometheus and Loki) | **Passed** | **Passed** | Not applicable | **Passed** |
| Splunk Enterprise (`10.6.1`) | Docker | Direct Vigil integration (HEC) | Not tested | Not tested | Not applicable | Not tested |
| VictoriaMetrics (`v1.155.0`) | Docker | Through an intermediary (collector): its OTLP takes protobuf only | **Passed** | Not supported | Not applicable | **Passed** |
| VictoriaLogs (`v1.53.0`) | Docker | Through an intermediary (collector): its OTLP takes protobuf only | Not supported | **Passed** | Not applicable | **Passed** |
| VictoriaTraces (`v0.12.1`) | Docker | Not applicable (starts and is ready) | Not applicable | Not applicable | Not applicable | Not applicable |
| Elasticsearch and Kibana (`9.5.5`) | Docker | Through an intermediary (collector, `elasticsearch` exporter) | **Passed** | **Passed** | Not applicable | **Passed**; a line the collector held was lost when it restarted (Delivery checks) |
| OpenSearch and Dashboards (`3.9.0`) | Docker | Through an intermediary (collector) | Not supported | Not tested | Not applicable | Not tested |
| InfluxDB (`2.9.1`) | Docker | Through an intermediary (collector) | Not tested | Not supported | Not applicable | Not tested |
| Jaeger (`2.22.0`) | Docker | Not applicable | Not applicable | Not applicable | Not applicable | Not applicable |
| Zipkin (`3.6.1`) | Docker | Not applicable | Not applicable | Not applicable | Not applicable | Not applicable |
| ClickHouse (`26.10.3.7`) | Docker | Through an intermediary (collector) | Not tested | Not tested | Not applicable | Not tested |
| SigNoz | Docker, official (Foundry) | Protocol-compatible (OTLP) | Not tested | Not tested | Not applicable | Not tested |
| Uptrace | Docker, official (`v2.0.3` example) | To be worked out: needs an `uptrace-dsn` header | Not tested | Not tested | Not applicable | Not tested |
| Graylog | Docker, official (open-core) | Through an intermediary, to be worked out: OTLP over gRPC only | Not tested | Not tested | Not applicable | Not tested |
| Datadog | SaaS, credentials supplied by you | Direct Vigil integration | Not tested | Not tested | Not applicable | Not tested |
| Splunk Observability Cloud | SaaS, credentials supplied by you | Protocol-compatible or through an intermediary, to be confirmed | Not tested | Not supported | Not applicable | Not tested |

### Secret stores

The secret stores have their own report: [`secrets-compatibility.md`](secrets-compatibility.md). OpenBao and HashiCorp Vault pass on Linux, macOS and Windows; the cloud emulators are not tested yet.

**Reading the matrix:**
- **Not supported** means no route for that signal exists today. For example, Prometheus and Mimir store metrics, not logs; Loki and VictoriaLogs store logs, not metrics.
- **Not applicable** under Traces means Vigil sends no traces at all.

## Runs

Each run adds a row here: date, target, the image versions it ran, the run tag, the result, and the evidence file.

| Date | Target | Vigil on | Images | Run tag | Metrics | Logs | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-11-03 | `lgtm` | Fedora 44, bash 5.3 (same host as Docker 29.9.2) | `grafana/otel-lgtm:0.38.1` | `bk2026110312015842111` | Failed | Passed | `reports/evidence/lgtm-bk2026110312015842111.txt` on the Fedora test host |
| 2026-11-03 | `lgtm` | Windows 11 Pro, PowerShell 5.1, over SSH as a standard user; tunnels to Fedora | `grafana/otel-lgtm:0.38.1` | `bk2026110313472112660` and the next three | Failed | Failed | on the Windows test host: see below |
| 2026-11-03 | `lgtm` | Fedora 44, with counts as cumulative sums (#64) | `grafana/otel-lgtm:0.38.1` | `bk2026110314401288246` | **Passed** | **Passed** | on the Fedora test host |
| 2026-11-03 | `lgtm` | macOS 12.7, bash 3.2, tunnels to Fedora, cumulative sums | `grafana/otel-lgtm:0.38.1` | `bk2026110314495011786` | **Passed** | **Passed** | on the Mac test host |
| 2026-11-03 | `lgtm` | Windows 11 Pro, PowerShell 5.1, tunnels to Fedora, cumulative sums and #63 | `grafana/otel-lgtm:0.38.1` | `bk2026110314495310700` | **Passed** | **Passed** | on the Windows test host |
| 2026-11-03 | `lgtm` | Fedora 44, bash 5.3, at `4040737`, evidence kept | `grafana/otel-lgtm:0.38.1` | `bk202611032008051138583` | **Passed** | **Passed** | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#backend-lgtm), [files](runs/2026-11-03/fedora/backend-lgtm) |
| 2026-11-03 | `lgtm` | macOS 12.7.6, bash 3.2, tunnels to Fedora, at `4040737`, evidence kept | `grafana/otel-lgtm:0.38.1` | `bk2026110320160960421` | **Passed** | **Passed** | [macOS](https://godspeedhq.github.io/vigil/real/macos/#backend-lgtm), [files](runs/2026-11-03/macos/backend-lgtm) |
| 2026-11-03 | `lgtm` | Windows 11 Pro, PowerShell 5.1, tunnels to Fedora, at `c278240`, evidence kept | `grafana/otel-lgtm:0.38.1` | `bk202611032135249088` | **Passed** | **Passed** | [Windows](https://godspeedhq.github.io/vigil/real/windows/#backend-lgtm), [files](runs/2026-11-03/windows/backend-lgtm) |
| 2026-11-04 | `prometheus` | Fedora 44, bash 5.3, at `8a09525` | `prom/prometheus:v3.15.1` | `bk20261104074757644378` | **Passed** | Not supported | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#backend-prometheus), [files](runs/2026-11-04/fedora/backend-prometheus) |
| 2026-11-04 | `loki` | Fedora 44, bash 5.3, at `8a09525` | `grafana/loki:3.7.9` | `bk20261104075553692852` | Not supported | **Passed** | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#backend-loki), [files](runs/2026-11-04/fedora/backend-loki) |
| 2026-11-04 | `mimir` | Fedora 44, bash 5.3, at `8a09525` | `grafana/mimir:3.2.4` | `bk20261104080348745658` | **Passed** | Not supported | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#backend-mimir), [files](runs/2026-11-04/fedora/backend-mimir) |
| 2026-11-04 | `otel-collector` | Fedora 44, bash 5.3, at `8a09525` | `otel/opentelemetry-collector-contrib:0.163.2`, to Mimir and Loki | `bk20261104080648766671` | **Passed** | **Passed** | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#backend-otel-collector), [files](runs/2026-11-04/fedora/backend-otel-collector) |
| 2026-11-04 | `alloy` | Fedora 44, bash 5.3, at `8a09525` | `grafana/alloy:v1.21.3`, to Prometheus and Loki | `bk20261104080955790261` | **Passed** | **Passed** | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#backend-alloy), [files](runs/2026-11-04/fedora/backend-alloy) |
| 2026-11-04 | `victoriametrics` | Fedora 44, bash 5.3, direct | `victoriametrics/victoria-metrics:v1.155.0` | `bk202611041114291955993` | Failed: HTTP 400, protobuf only | Not supported | not kept: the run through the collector replaced its folder; the answer is below |
| 2026-11-04 | `victoriametrics` | Fedora 44, bash 5.3, at `aa1c9e4`, through the collector | `victoriametrics/victoria-metrics:v1.155.0`, `otel/opentelemetry-collector-contrib:0.163.2` | `bk202611041221482057946` | **Passed** | Not supported | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#backend-victoriametrics), [files](runs/2026-11-04/fedora/backend-victoriametrics) |
| 2026-11-04 | `victorialogs` | Fedora 44, bash 5.3, at `aa1c9e4`, through the collector | `victoriametrics/victoria-logs:v1.53.0`, `otel/opentelemetry-collector-contrib:0.163.2` | `bk202611041224462068400` | Not supported | **Passed** | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#backend-victorialogs), [files](runs/2026-11-04/fedora/backend-victorialogs) |
| 2026-11-04 | `elastic` | Fedora 44, bash 5.3, at `f0310b7`, through the collector | `elasticsearch:9.5.5`, `kibana:9.5.5`, `otel/opentelemetry-collector-contrib:0.163.2` | `bk202611041312432475480` | **Passed** | **Passed** | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#backend-elastic), [files](runs/2026-11-04/fedora/backend-elastic) |

### Victoria: why through a collector

VictoriaMetrics' and VictoriaLogs' OTLP endpoints take protobuf only. Vigil sends OTLP/HTTP as JSON, the only encoding a shell can write, and both answer `HTTP 400` ("json encoding isn't supported for opentelemetry format. Use protobuf encoding"). Vigil counts a refused batch as dropped (`vigil.spool.dropped`, `reason=rejected`) and moves on, as the spec says: the first run stored nothing. Through `victoria-collector`, an OpenTelemetry Collector that takes JSON and forwards protobuf, both pass. VictoriaMetrics' other ways in (its Prometheus import, InfluxDB line protocol) are not backends Vigil has.

## Delivery checks

`scripts/run-checks.sh`, section 5's checks beyond what `run-vigil` shows: the target stopped for 70 seconds, restarted, Vigil's supervisor stopped for 10 seconds, and the spool cut to 1 MB with the target down. Every run of the test's job is then looked for in the backend's own query interface, from a ledger the job keeps outside Vigil. See the [README](../README.md#delivery-checks) for what each check needs to pass.

Group 1, the Grafana ecosystem, with Vigil on Fedora 44, bash 5.3, at `6d133fa`, 2026-11-04:

| Check | Prometheus | Loki | Mimir | Collector (to Mimir, Loki) | Alloy (to Prometheus, Loki) |
| --- | --- | --- | --- | --- | --- |
| 4 job identifiers | **Passed** (in the name) | **Passed** | **Passed** (in the name) | **Passed** | **Passed** |
| 5 host metadata | **Passed** | **Passed** | **Passed** | **Passed** | **Passed** |
| 6 timestamps | **Passed**, late ones too | **Passed** | **Passed**, late ones too | **Passed** | **Passed** |
| 7 authentication | Not applicable | Not applicable | Not applicable | Not applicable | Not applicable |
| 8 unavailable | **Passed** | **Passed** | **Passed** | **Passed** | **Passed** |
| 9 retry and backoff | **Passed** | **Passed** | **Passed** | **Passed** | **Passed** |
| 10 recovery from the spool | **Passed**, 14 of 14 | **Passed** | **Passed**, 14 of 14 | **Passed** | **Passed** |
| 11 a backend restart | **Passed** | **Passed** | **Passed** | **Passed** | **Passed** |
| 12 duplicates | **Passed**, none | **Passed**, none | **Passed**, none | **Passed**, none | **Passed**, none |
| 13 dropped telemetry | **Passed** | Not applicable | **Passed** | **Passed** | **Passed** |
| 14 several destinations | **Passed** | Not applicable | **Passed** | **Passed** | **Passed** |
| 15 a healthy destination | **Passed** | Not applicable | **Passed** | **Passed** | **Passed** |
| 16 a supervisor restart | **Passed** | **Passed** | **Passed** | **Passed** | **Passed** |
| Evidence | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#checks-prometheus), [files](runs/2026-11-04/fedora/checks-prometheus) | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#checks-loki), [files](runs/2026-11-04/fedora/checks-loki) | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#checks-mimir), [files](runs/2026-11-04/fedora/checks-mimir) | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#checks-otel-collector), [files](runs/2026-11-04/fedora/checks-otel-collector) | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#checks-alloy), [files](runs/2026-11-04/fedora/checks-alloy) |

Group 3, Victoria, through `victoria-collector`, with Vigil on Fedora 44, bash 5.3, at `aa1c9e4`, 2026-11-04:

| Check | VictoriaMetrics | VictoriaLogs |
| --- | --- | --- |
| 4 job identifiers | **Passed**, `job="bk_check"` kept | **Passed** |
| 5 host metadata | **Passed** | **Passed** |
| 6 timestamps | **Passed**, late ones too | **Passed** |
| 7 authentication | Not applicable | Not applicable |
| 8 unavailable | **Passed** | **Passed** |
| 9 retry and backoff | **Passed** | **Passed** |
| 10 recovery from the spool | **Passed**, 14 of 14 | **Passed** |
| 11 a backend restart | **Passed** | **Passed** |
| 12 duplicates | **Passed**, none | **Passed**, none |
| 13 dropped telemetry | **Passed** | Not applicable |
| 14 several destinations | **Passed** | Not applicable |
| 15 a healthy destination | **Passed** | Not applicable |
| 16 a supervisor restart | **Passed** | **Passed** |
| Evidence | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#checks-victoriametrics), [files](runs/2026-11-04/fedora/checks-victoriametrics) | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#checks-victorialogs), [files](runs/2026-11-04/fedora/checks-victorialogs) |

Stopping or restarting the target stops or restarts the collector in front of it too.

Group 4, Elastic, through `elastic-collector`, with Vigil on Fedora 44, bash 5.3, at `f0310b7`, 2026-11-04:

| Check | Elasticsearch metrics | Elasticsearch logs |
| --- | --- | --- |
| 4 job identifiers | **Passed**, `job="bk_check"` kept | **Passed** |
| 5 host metadata | **Passed** | **Passed** |
| 6 timestamps | **Passed**, late ones too | **Passed** |
| 7 authentication | Not applicable | Not applicable |
| 8 unavailable | **Passed** | **Passed** |
| 9 retry and backoff | **Passed** | **Passed** |
| 10 recovery from the spool | **Passed**, 15 of 15 | **Passed** |
| 11 a backend restart | **Passed** | **Failed**: 1 of 85 lines, held by the collector when it restarted |
| 12 duplicates | **Passed**, none | **Passed**, none |
| 13 dropped telemetry | **Passed** | Not applicable |
| 14 several destinations | **Passed** | Not applicable |
| 15 a healthy destination | **Passed** | Not applicable |
| 16 a supervisor restart | **Passed** | **Passed** |
| Evidence | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#checks-elastic), [files](runs/2026-11-04/fedora/checks-elastic) | the same run |

**Through a collector, Vigil's delivery ends at the collector.** Once the collector answers 2xx, Vigil has done its part and moves its checkpoint on; finishing the delivery is the collector's. The Elastic runs showed this twice:

- **Elasticsearch restarting.** The collector's `elasticsearch` exporter, by default, retries twice within a second and then drops (`Exporting failed. Dropping data.`). The first run lost 50 seconds of metrics and logs while Elasticsearch came back. With `retry` set to try for minutes (`max_retries: 60`, up to 10 seconds apart), nothing was lost. The collector's `otlphttp` exporter, in groups 1 and 3, retries for 5 minutes by default, and lost nothing.
- **The collector restarting.** A collector keeps what it has accepted in memory, in its batch and its retry queue. One log line, accepted 8 seconds before the collector itself was restarted, was gone. Groups 1 and 3 restarted their collectors too, with nothing in flight at the time. Only a persistent queue (the collector's `sending_queue` with `file_storage`) survives a collector restart.

So with an intermediary, configure it to retry for as long as its store may be away, and give it a persistent queue if a restart must lose nothing.

**Why not applicable:**
- **7:** Vigil sends to each target without a credential here: groups 1 and 3 take none, and Elasticsearch's password is the collector's, not Vigil's. Splunk, which takes Vigil's own token, tests it.
- **13 for Loki and VictoriaLogs:** only metrics go through the spool, and it is the spool that drops. The log forwarder reads Vigil's own log files from a checkpoint, so an outage delays lines, never drops them.
- **14 and 15 for Loki and VictoriaLogs:** they are about metrics backends; Vigil has one log destination at a time.

**What the checks showed:**
- **A delayed sample keeps its time.** The 14 runs made during the outage reached Prometheus and Mimir a minute late, each stamped within a second of when it ran, not when it arrived.
- **Backoff is as the spec says:** the sender's failed runs started 6, 10 and 20 seconds apart (5, 10, 20, and the time a run takes), and the log forwarder backed off on its own.
- **Prometheus-based backends replace the `job` label** with `job="vigil"`, from the service name, as the first LGTM run found. The job stays in the metric's name, `bk_check_seq`, so it can still be told apart. Loki, VictoriaMetrics and VictoriaLogs keep `job` as a label.
- **VictoriaMetrics keeps OTLP names as they are,** dots and all (`bk_check.seq`), and every attribute (`service.name`, `scope.name`), where Prometheus-based backends turn dots into underscores.
- **Mimir names a counter without `_total`** (`vigil_spool_dropped`), where Prometheus adds it (`vigil_spool_dropped_total`): Mimir's OTLP translation leaves suffixes off by default. A query for one name misses the other.
- **A full spool's drops are counted, and the count arrives** once the backend is back: `vigil_spool_dropped` with `reason="spool_full"`.

**What they found in Vigil, and fixed in #75.** With Prometheus stopped and a full batch queued, the sender never finished a run again. The bash twin's escaping of a request body for curl took time growing with the square of its size (over 10 minutes for 385 KB, longer than the 5 minutes a sender may run), and so did building the bodies. Any outage long enough to fill one request would have left that backend's queue stuck, and every other backend waiting behind it. Now linear; what is left (the file backend's own merge speed, and a slow backend holding up the rest) is backlog 29.

**And in the tests, fixed in #76.** Every test script started Vigil's supervisor through a shell function in the background, so the process it stopped afterwards was a subshell: each run left its supervisor running, 15 of them on the Fedora host and 5 on the Mac. Each now starts the supervisor directly, and ends its own workers.

### Windows: what the first runs found

- **Over SSH, as a standard user, WMI refuses every query.** Vigil read process facts and the boot time through WMI alone, so finished runs stayed RUNNING, timeouts couldn't be proven and were held as uncertain, and every tick took tens of seconds. Fixed in #63 (backlog/fixed/23): the same facts now come from the kernel when WMI refuses.
- **The machine's clock was 6.5 minutes fast.** Its log lines reached Loki stamped in the future, and Loki returned them only once that time came, minutes after `verify.sh` had given up. With the clock set right, logs passed. `run-vigil` now warns when the clocks disagree.

### LGTM metrics: why they failed at first

Found on the first run, and narrowed down by sending LGTM hand-made OTLP requests:

- **Logs arrived.** This run's tagged lines were found in Loki.
- **No metric was stored**, though LGTM answered every request with `HTTP 200`. Prometheus knew the metric names, with no samples behind them.
- **Not the request's content.** Vigil's request was byte for byte identical to a hand-made one that *was* stored.
- **The cause is delta sums.** Vigil sends counts (`runs`, `succeeded` and the like) as OTLP **delta** sums (spec 15.3), and Prometheus does not accept delta temporality by default. The collector inside LGTM batches requests together, and a batch holding a delta sum is dropped whole, gauges included. A gauge sent alone was stored; the same gauge sent with a count was not.
- **The loss is silent.** The collector answers `200` before Prometheus refuses, so Vigil records the batch as delivered.
- **Separately, the `job` label is lost.** Prometheus replaces the `job` attribute Vigil sends with `job="vigil"`, from the resource's `service.name`. A metric's name still identifies its job, since names start with the job's `metric_name`, but the label does not.

This affects every Prometheus-based backend reached over OTLP: LGTM, standalone Prometheus and Mimir. **Fixed in #64:** counts are now sent as cumulative sums (spec 15.3). The rerun stored every metric on all three systems, counters as `<name>_total`, with the probe at 42.
