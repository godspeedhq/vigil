# Compatibility matrix

How each backend works with Vigil, and what a real test showed. **Only Grafana LGTM has been run so far;** every other result is Not tested. A result changes only with evidence from a run: the software version, the date, the configuration, and what the backend's own query returned, saved by `scripts/verify.sh` in `reports/evidence/`. A test that didn't run is never marked Passed.

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
| Grafana LGTM (`grafana/otel-lgtm:0.38.1`) | Docker, default | Protocol-compatible (OTLP/HTTP) | **Failed** (see Runs) | **Passed** | Not applicable | **Failed** |
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

**Reading the matrix:**
- **Not supported** means no route for that signal exists today. For example, Prometheus and Mimir store metrics, not logs; Loki and VictoriaLogs store logs, not metrics.
- **Not applicable** under Traces means Vigil sends no traces at all.

## Runs

Each run adds a row here: date, target, the image versions it ran, the run tag, the result, and the evidence file.

| Date | Target | Vigil on | Images | Run tag | Metrics | Logs | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-11-03 | `lgtm` | Fedora 44, bash 5.3 (same host as Docker 29.9.2) | `grafana/otel-lgtm:0.38.1` | `bk2026110312015842111` | Failed | Passed | `reports/evidence/lgtm-bk2026110312015842111.txt` on the Fedora test host |

### LGTM metrics: why they failed

Found on the first run, and narrowed down by sending LGTM hand-made OTLP requests:

- **Logs arrived.** This run's tagged lines were found in Loki.
- **No metric was stored**, though LGTM answered every request with `HTTP 200`. Prometheus knew the metric names, with no samples behind them.
- **Not the request's content.** Vigil's request was byte for byte identical to a hand-made one that *was* stored.
- **The cause is delta sums.** Vigil sends counts (`runs`, `succeeded` and the like) as OTLP **delta** sums (spec 15.3), and Prometheus does not accept delta temporality by default. The collector inside LGTM batches requests together, and a batch holding a delta sum is dropped whole, gauges included. A gauge sent alone was stored; the same gauge sent with a count was not.
- **The loss is silent.** The collector answers `200` before Prometheus refuses, so Vigil records the batch as delivered.
- **Separately, the `job` label is lost.** Prometheus replaces the `job` attribute Vigil sends with `job="vigil"`, from the resource's `service.name`. A metric's name still identifies its job, since names start with the job's `metric_name`, but the label does not.

This affects every Prometheus-based backend reached over OTLP: LGTM, standalone Prometheus and Mimir. Whether to send counts as cumulative sums, or to rely on delta-to-cumulative conversion at the backend, is a decision for the project; it is recorded in backlog task 18.
