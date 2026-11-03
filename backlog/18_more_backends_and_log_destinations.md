# More backends, and a test environment of real ones

Two pieces of work that belong together:

1. **More backends.** Metrics backends beyond `file`, `datadog`, `otel` and `splunk` (spec 15.3). The native `splunk` and `datadog` log destinations (spec 13.4.5) are done.
2. **A test environment of real backends.** Vigil's integrations are tested today against mocks (`tests/integration/mock-backend.py`). This environment tests them against the real products, in Docker on the host, with Vigil itself running on the host as it would in production.

The environment comes first. It shows what works against real services, and each new backend in (1) is then tested in it.

## What Vigil sends today

This decides what each component below can be tested with. Nothing is added to Vigil to make a test pass.

| What | How |
| --- | --- |
| Metrics | `file` (Prometheus text file), `datadog` (Series API v2), `otel` (OTLP/HTTP JSON), `splunk` (HEC) |
| Logs (`[log_forward]`) | `otel` (OTLP/HTTP JSON logs), `splunk` (HEC), `datadog` (Logs API) |
| Traces | None. Vigil emits no traces. |
| Profiles | None. |

So a component is reached directly (Splunk HEC; anything with an OTLP/HTTP receiver), through the OpenTelemetry Collector, by scraping the `file` backend's output, or not at all. Each is classified below from what is actually tested, not from what its documentation suggests.

## Objective

A reproducible environment for testing Vigil's existing telemetry against real backends, without changing Vigil's production architecture.

- **Docker first.** Cloud only where there's no real self-hosted equivalent.
- **Eight Compose groups,** one command interface.
- **Lightweight by default:** Grafana LGTM only.
- **Location:** `tests/integration/backends/`.

## 1. Docker groups

### Group 1: Grafana ecosystem (`compose.grafana.yaml`)

Components:

1. Grafana (`grafana/grafana`)
2. Prometheus (`prom/prometheus`)
3. Grafana Loki (`grafana/loki`)
4. Grafana Tempo (`grafana/tempo`)
5. Grafana Mimir (`grafana/mimir`)
6. Grafana Pyroscope (`grafana/pyroscope`)
7. OpenTelemetry Collector (`otel/opentelemetry-collector-contrib`)
8. Grafana Alloy (`grafana/alloy`)

Plus the all-in-one `grafana/otel-lgtm` image.

Requirements:
- LGTM is the default, lightweight development profile.
- Each standalone component is an optional profile.
- Never start LGTM and the standalone components it duplicates together, unless explicitly asked.
- Configure OTLP/HTTP, metrics scraping, log ingestion and query interfaces as applicable.
- Persistent storage where needed.
- Dashboards and data sources provisioned automatically where practical.
- Existing Vigil protocols only.

### Group 2: Splunk (`compose.splunk.yaml`)

9. Splunk Enterprise (`splunk/splunk`)

Requirements:
- HTTP Event Collector enabled.
- Separate test indexes for metrics and logs where appropriate.
- A dedicated HEC token.
- Web interface and HEC API on localhost.
- Ingestion verified with Splunk searches.
- Tests for authentication failure, retries and recovery.
- Memory requirements and licence limits documented.

### Group 3: Victoria ecosystem (`compose.victoria.yaml`)

10. VictoriaMetrics (`victoriametrics/victoria-metrics`)
11. VictoriaLogs (`victoriametrics/victoria-logs`)
12. VictoriaTraces (`victoriametrics/victoria-traces`)

Requirements:
- Metrics, logs and traces ingestion where supported.
- The OpenTelemetry Collector as an intermediary where required.
- Ingestion verified with queries.
- Each component independently selectable.
- No claim of direct Vigil integration unless it exists.

### Group 4: Elastic ecosystem (`compose.elastic.yaml`)

13. Elasticsearch (official image)
14. Kibana (official image)

Requirements:
- Single-node development setup.
- Authentication enabled where practical.
- Kibana connected to Elasticsearch.
- Existing protocols, or an intermediary collector.
- Indexed documents verified.
- Resource requirements and licence conditions documented.

### Group 5: OpenSearch ecosystem (`compose.opensearch.yaml`)

15. OpenSearch (`opensearchproject/opensearch`)
16. OpenSearch Dashboards (`opensearchproject/opensearch-dashboards`)

Requirements:
- Single-node development setup.
- Secure local authentication.
- Dashboards configured automatically where possible.
- Indexed telemetry verified with queries.
- Ingestion mechanisms and limitations documented.

### Group 6: Additional metrics (`compose.metrics.yaml`)

17. InfluxDB (`influxdb`)

Requirements:
- Local time-series storage.
- An explicitly chosen, pinned version.
- Differences between InfluxDB versions and their APIs documented.
- Ingestion through supported protocols, or an intermediary.
- Stored metrics verified with queries.

### Group 7: Distributed tracing (`compose.tracing.yaml`)

18. Jaeger (`jaegertracing/jaeger`)
19. Zipkin (`openzipkin/zipkin`)

Requirements:
- OTLP and Zipkin-compatible endpoints configured.
- Traces verified through each backend's API.
- Tested only if Vigil, or an existing supported integration, emits compatible traces. Today Vigil emits none, so these are expected to be "available, not applicable".
- Tracing is not added to Vigil to make these tests pass.

### Group 8: Full observability platforms (`compose.platforms.yaml`)

20. SigNoz (official Docker deployment)
21. Uptrace (official Docker deployment)
22. Graylog (official Docker deployment)
23. ClickHouse (`clickhouse/clickhouse-server`)

Requirements:
- Required supporting services and databases kept.
- Officially supported deployment configurations.
- SigNoz, Uptrace and Graylog each selectable on its own.
- Incompatible products never forced to share a database.
- ClickHouse testable on its own.
- Ingestion through existing Vigil capabilities.
- Data verified through supported query APIs.
- Hardware requirements and licensing documented.

## 2. Compose layout

```
tests/integration/backends/
  compose.yaml
  compose.grafana.yaml
  compose.splunk.yaml
  compose.victoria.yaml
  compose.elastic.yaml
  compose.opensearch.yaml
  compose.metrics.yaml
  compose.tracing.yaml
  compose.platforms.yaml
  .env.example
  README.md
  configs/
    grafana/ prometheus/ loki/ tempo/ mimir/ pyroscope/ otel/ alloy/
    splunk/ victoria/ elastic/ opensearch/ influxdb/ jaeger/ zipkin/
    signoz/ uptrace/ graylog/ clickhouse/
  scripts/
    start.sh  stop.sh  reset.sh  verify.sh
  saas/
    datadog.md
    splunk-observability-cloud.md
  reports/
    compatibility.md
```

Compose requirements:
1. Eight logical backend groups.
2. One consistent startup interface.
3. Optional profiles or explicit service selection.
4. Grafana LGTM only by default.
5. Never start every backend automatically.
6. Image versions or digests pinned.
7. Named volumes for persistent data.
8. Health checks and readiness probes.
9. Published ports bound to 127.0.0.1 by default.
10. No port collisions between stacks.
11. No secrets in source control.
12. A `.env.example`.
13. CPU, memory and disk requirements documented.
14. Works with Docker Engine and Docker Desktop.
15. Local and CI configurations reproducible.
16. Official configurations rather than custom reimplementations.
17. No unnecessary duplicate collectors.
18. Each group can be started, stopped and reset on its own.

The top-level interface can use Compose's `include`, multiple `-f` files, profiles or the wrapper scripts. Its behaviour must be predictable, and it must work with documented Docker Compose versions.

## 3. Cloud-only backends

Documented separately. Accounts are never created, legal terms never accepted, payment details never entered and paid services never enabled automatically. Cloud credentials are supplied by the user, by hand.

### Datadog

- Free trial: https://www.datadoghq.com/free-datadog-trial/
- Pricing and free tier: https://www.datadoghq.com/pricing/

Tasks:
- Document registering by hand.
- Explain the free tier's and the trial's restrictions.
- Explain how to create a dedicated API key.
- Document site and region configuration.
- Prepare metrics and logs integration tests.
- Verify actual ingestion in Datadog.
- Test authentication failure and delivery recovery.
- Note every feature that needs payment.

### Splunk Observability Cloud

- Free Edition: https://help.splunk.com/en/splunk-observability-cloud/get-started/free-edition/splunk-observability-cloud-free-edition
- Splunk: https://www.splunk.com/

Tasks:
- Document registering for the Free Edition.
- Check current eligibility and limitations.
- Identify which telemetry protocols it accepts.
- Explain configuring the endpoint and access token.
- Prepare compatible integration tests.
- Distinguish Splunk Observability Cloud from Splunk Enterprise and Splunk Cloud Platform.
- Use local Splunk Enterprise for HEC metrics and logs validation.
- Never claim the Free Edition supports something it doesn't.

## 4. Test workloads

Through the existing runner configuration. Vigil runs any program, not only scripts.

- A successful short-running script.
- A script with a nonzero exit code.
- A long-running script.
- A script that passes its `max_runtime`.
- A missing runner or executable.
- Standard output and standard error.
- Application metrics.
- Several jobs scheduled at once.
- A native executable.
- A backend outage, and recovery.

## 5. What each test verifies

For each applicable backend:
1. Metrics ingestion.
2. Log ingestion.
3. Trace ingestion, only where supported.
4. Job identifiers and labels.
5. Host and environment metadata.
6. Timestamps preserved.
7. Authentication rejected.
8. Backend unavailable.
9. Retry and backoff.
10. Recovery from the persistent spool.
11. Backend restart.
12. Duplicate delivery behaviour.
13. Dropped telemetry reported.
14. Delivery to several destinations.
15. A healthy destination unaffected by an unhealthy one.
16. Supervisor restart, and delivery carrying on.

An HTTP success is not enough: telemetry is verified through the backend's own query interface. Vigil reports execution facts and doesn't interpret application health; that's for the backend and its users.

## 6. Compatibility classification

Each service is classified as one of:
- Direct Vigil integration
- Protocol-compatible integration
- Integration through an intermediary
- Supporting component only
- Unsupported
- Not applicable

The compatibility matrix:

| Backend | Deployment | Integration method | Metrics | Logs | Traces | Result |
| --- | --- | --- | --- | --- | --- | --- |

Results: Passed, Failed, Not supported, Not applicable, Not tested, Blocked by licensing or account restrictions. Each row records exact software versions, test date, configuration and evidence. A test that didn't run is never marked Passed.

## 7. Order of work

1. **Core:** Grafana LGTM, standalone Prometheus, Splunk Enterprise.
2. **The other Docker groups,** with their official dependencies.
3. **SaaS guides** for Datadog and Splunk Observability Cloud. No accounts registered.
4. **Verification:** the local backend tests, then cloud tests only once the user has supplied credentials.
5. **Reporting:** the full compatibility report, with evidence, failures, limitations and outstanding work.

## 8. Constraints

- Docker first, cloud only where necessary.
- Eight Compose groups, one command interface.
- Lightweight by default.
- No unnecessary production changes to Vigil, and no new production runtimes or dependencies.
- No invented integrations.
- No automatic SaaS registration, and no paid service enabled.
- No committed credentials.
- No misleading compatibility claims, and no hidden test failures.
- A ready container is not proof of ingestion, and an HTTP 2xx is not proof of storage.
- Incompatible platforms never forced to share dependencies.

## Notes for running it

- **CI:** GitHub's Ubuntu runners have Docker; its macOS and Windows runners don't run Linux containers out of the box. The real-backend tests can run on Ubuntu in CI, and against Vigil's other twins on a machine with Docker Desktop. Each test says which.
- **Size:** Splunk Enterprise, Elasticsearch, OpenSearch, SigNoz and Graylog each want several GB of memory. They're optional groups, never part of the default, and a CI job starts one group at a time.

## Done when

1. Eight grouped Compose configurations, with one start and manage interface.
2. All 23 components above available through it, with Grafana LGTM as the default.
3. Reproducible backend configuration and verification scripts.
4. The Datadog and Splunk Observability Cloud guides.
5. The compatibility matrix, with real test evidence.
6. A full README.
7. For each new backend type in (1): the conformance suite and an integration test, both twins, and a row in the matrix.

## Progress

- **Written, not run** (per the user's request, nothing is started on the development machine): all eight Compose groups, the configuration for each, `start`/`stop`/`reset`/`verify`/`run-vigil` scripts, the workloads, both SaaS guides and the compatibility matrix, all under `tests/integration/backends/`. Checked without running: `docker compose config` for every profile, `bash -n` on every script, and Vigil's own `precheck` on the configuration `run-vigil.sh` writes for each target.
- **Next:** Phase 4, the first real run of each group, then the matrix from its evidence. The 13 checks of section 5 beyond the first three are not written yet.

## Decision needed: counts over OTLP

The first real run (LGTM, 2026-11-03) found that Prometheus-based backends silently drop Vigil's metrics: Vigil sends counts as OTLP delta sums, Prometheus refuses delta temporality, and the collector in front answers `200` regardless. Details in `tests/integration/backends/reports/compatibility.md`. Two ways forward:

- **A. Vigil sends counts as cumulative sums,** keeping running totals per series in the sender's state, as the `file` backend already does. Works with Prometheus out of the box. A change to spec 15.3 and both twins.
- **B. Keep delta sums,** and document delta-to-cumulative conversion at the backend (Prometheus's `otlp-deltatocumulative` feature, or the collector's `deltatocumulative` processor). No change to Vigil, but every Prometheus user must know to turn it on.

Recommended: A.
