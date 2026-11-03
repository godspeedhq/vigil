# Compatibility matrix

How each backend works with Vigil, and what a real test showed. **Grafana LGTM has been run so far,** with Vigil on Linux, macOS and Windows; every other result is Not tested. Secret stores are in [`secrets-compatibility.md`](secrets-compatibility.md). A result changes only with evidence from a run: the software version, the date, the configuration, and what the backend's own query returned, saved by `scripts/verify.sh` in `reports/evidence/`. A test that didn't run is never marked Passed.

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
| Prometheus (`v3.15.1`) | Docker | Protocol-compatible (OTLP receiver) | Not tested | Not supported | Not applicable | Not tested |
| Grafana (`13.2.5`) | Docker | Supporting component only | Not applicable | Not applicable | Not applicable | Not applicable |
| Loki (`3.7.9`) | Docker | Protocol-compatible (OTLP) | Not supported | Not tested | Not applicable | Not tested |
| Tempo (`2.10.10`) | Docker | Not applicable | Not applicable | Not applicable | Not applicable | Not applicable |
| Mimir (`3.2.4`) | Docker | Protocol-compatible (OTLP) | Not tested | Not supported | Not applicable | Not tested |
| Pyroscope (`2.4.2`) | Docker | Not applicable | Not applicable | Not applicable | Not applicable | Not applicable |
| OpenTelemetry Collector (`0.163.2`) | Docker | Through an intermediary (to Mimir and Loki) | Not tested | Not tested | Not applicable | Not tested |
| Grafana Alloy (`v1.21.3`) | Docker | Through an intermediary (to Prometheus and Loki) | Not tested | Not tested | Not applicable | Not tested |
| Splunk Enterprise (`10.6.1`) | Docker | Direct Vigil integration (HEC) | Not tested | Not tested | Not applicable | Not tested |
| VictoriaMetrics (`v1.155.0`) | Docker | Protocol-compatible (OTLP) | Not tested | Not supported | Not applicable | Not tested |
| VictoriaLogs (`v1.53.0`) | Docker | Protocol-compatible (OTLP) | Not supported | Not tested | Not applicable | Not tested |
| VictoriaTraces (`v0.12.1`) | Docker | Not applicable | Not applicable | Not applicable | Not applicable | Not applicable |
| Elasticsearch and Kibana (`9.5.5`) | Docker | Through an intermediary (collector) | Not tested | Not tested | Not applicable | Not tested |
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
