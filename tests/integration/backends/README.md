# Real-backend test environment

Vigil's telemetry is tested everywhere else against mocks. Here it's tested against the real products: the backends run in Docker, Vigil runs on the host exactly as it would in production, and each test asks the backend, through its own query interface, whether the data arrived. This is backlog task 18.

> **Status: written, not yet run.** None of these stacks has been started yet, so every result in [`reports/compatibility.md`](reports/compatibility.md) is **Not tested**. Expect to adjust some configurations at the first run; that run's results replace the matrix rows.

## Quick start

```sh
cd tests/integration/backends
cp .env.example .env           # then fill it in
scripts/start.sh               # Grafana LGTM, the default
scripts/run-vigil.sh lgtm      # Vigil on this host, then checks the data arrived
scripts/stop.sh lgtm           # keeps the data
scripts/reset.sh lgtm          # removes it
```

`docker compose up -d` on its own starts LGTM and nothing else. Every other target has a profile and starts only when asked for, so nothing heavy ever starts by accident.

**Needs:** Docker Engine or Docker Desktop with Compose 2.20 or later (for `include`), plus bash, curl and git. Vigil's scripts run on Linux and macOS. The Windows twin of `run-vigil.sh` is outstanding.

## Targets

| Group | File | Target (profile) | Vigil sends | How | Ports (127.0.0.1) |
| --- | --- | --- | --- | --- | --- |
| 1 Grafana | `compose.grafana.yaml` | **`lgtm`** (default) | metrics, logs | OTLP/HTTP direct | 3000 Grafana, 4317, 4318 |
| | | `prometheus` | metrics | OTLP receiver, direct | 9090 |
| | | `grafana` | — | the interface to the others | 3001 |
| | | `loki` | logs | OTLP, direct | 3100 |
| | | `mimir` | metrics | OTLP, direct | 9009 |
| | | `tempo`, `pyroscope` | — | traces and profiles: not applicable | 3200, 4040 |
| | | `otel-collector` | metrics, logs | collector, then Mimir and Loki | 24317, 24318 |
| | | `alloy` | metrics, logs | Alloy, then Prometheus and Loki | 12345, 34318 |
| | | `grafana-stack` | | all of the standalone ones | |
| 2 Splunk | `compose.splunk.yaml` | `splunk` | metrics, logs | HEC, direct (Vigil's `splunk` backend and log destination) | 8000, 8088 HEC, 8089 |
| 3 Victoria | `compose.victoria.yaml` | `victoriametrics` | metrics | OTLP, direct | 8428 |
| | | `victorialogs` | logs | OTLP, direct | 9428 |
| | | `victoriatraces` | — | not applicable | 10428 |
| | | `victoria` | | all three | |
| 4 Elastic | `compose.elastic.yaml` | `elastic` | metrics, logs | collector, `elasticsearch` exporter | 9200, 5601 Kibana, 4418 |
| 5 OpenSearch | `compose.opensearch.yaml` | `opensearch` | logs | collector, `opensearch` exporter (logs only) | 9201, 5602 Dashboards, 4428 |
| 6 Metrics | `compose.metrics.yaml` | `influxdb` | metrics | collector, `influxdb` exporter | 8086, 4438 |
| 7 Tracing | `compose.tracing.yaml` | `jaeger`, `zipkin` (`tracing`) | — | not applicable | 16686, 4517, 4518, 9411 |
| 8 Platforms | `compose.platforms.yaml` | `clickhouse` | metrics, logs | collector, `clickhouse` exporter | 18123, 4448 |
| | official deployment | `signoz` | metrics, logs | OTLP, direct | 8080, 4317, 4318 |
| | official deployment | `uptrace` | to be worked out | see below | the upstream file's |
| | official deployment | `graylog` | to be worked out | see below | the upstream file's |

**Notes:**
- **LGTM and the standalone components** do the same job, so start one or the other, not both. Their ports don't collide, so running both does no harm beyond the memory.
- **SigNoz and LGTM** both take OTLP on 4317 and 4318, so stop LGTM before starting SigNoz.
- **Run the platforms one at a time, alone.** Each is heavy, and their official files publish some of the same ports.

## Plain HTTP, and backends on another machine

**Everything on one machine needs nothing extra.** Vigil sends `https` only, except to its own machine: `http://localhost`, `http://127.0.0.1` and `http://[::1]` are allowed, since the request never leaves the computer. Every port here is published on 127.0.0.1, so when Docker and Vigil run on the same machine, Vigil sends plain HTTP to the backend as-is. That holds for:
- Docker Engine on Linux.
- Docker Desktop on Windows or macOS.
- Vigil inside WSL with Docker Desktop's WSL integration.
- Vigil on Windows with Docker running inside WSL, through WSL's localhost forwarding.

**Backends on another machine need a tunnel.** Vigil rightly refuses `http://other-machine:4318`, since that traffic crosses a network. An SSH tunnel brings the port back to localhost, encrypted, without exposing anything on the other machine:

```sh
# On the machine running Vigil: the remote LGTM's OTLP port on local 4318.
ssh -N -L 4318:127.0.0.1:4318 user@docker-host
```

Then run `scripts/run-vigil.sh lgtm` as usual. For Splunk, forward 8088 (HEC) and 8089 (the management API `verify.sh` uses) the same way; for other targets, forward the ports in the table above.

## What Vigil can and can't reach

What Vigil sends today, and nothing is added to it to make a test pass:

- **Metrics:** `file`, `datadog`, `otel` (OTLP/HTTP JSON) and `splunk` (HEC).
- **Logs:** `otel`, `splunk` and `datadog`.
- **Traces and profiles:** none.

So:
- **Not applicable:** Tempo, Pyroscope, VictoriaTraces, Jaeger and Zipkin. They're available, and no test targets them.
- **OpenSearch:** logs only. The collector's `opensearch` exporter doesn't take metrics.
- **Uptrace:** wants its DSN in an `uptrace-dsn` header. Vigil's `otel` log destination can send any header, but its metrics backend only sends `Authorization: Bearer`. To be worked out at the first run.
- **Graylog:** takes OTLP over gRPC, while Vigil sends OTLP over HTTP, so it needs a collector in between. To be worked out at the first run.

## Official deployments

**SigNoz, Uptrace and Graylog** each come with their own multi-service deployment. They aren't copied here, which would mean keeping a private version of each. Instead `scripts/start.sh` fetches the official one at the pin in [`configs/upstream.txt`](configs/upstream.txt) into `configs/<name>/upstream`, and runs it as its own Compose project (`vigil-uptrace`, `vigil-graylog`), so no two platforms share a database.

**SigNoz** deprecated its Compose files in v0.130.0 and now installs through its own tool, Foundry, which generates the Compose file. Install `foundryctl` yourself, following https://signoz.io/docs/install/docker/; nothing here installs it. `scripts/start.sh signoz` then runs it with [`configs/signoz/casting.yaml`](configs/signoz/casting.yaml).

## What a test checks

`scripts/run-vigil.sh <target>` does four things:

1. Installs this checkout in a temporary folder.
2. Gives it the jobs in [`workloads/`](workloads):
   - a run that succeeds
   - a run that fails
   - a long run
   - a run stopped at `max_runtime`
   - a run whose file is missing
   - stdout and stderr
   - an application metric
   - a native program (`/bin/date`)

   They all run every minute, so several run at once.
3. Runs the supervisor for about two and a half minutes.
4. Runs `scripts/verify.sh`, which asks the backend for this run's data, found by a tag unique to the run:
   - **metrics:** the probe value, 42, with the run's tag and `job=bk_metrics`
   - **logs:** a line with the run's tag

   It retries for two minutes, since backends index in the background, and saves the backend's answers in `reports/evidence/`. That folder isn't committed; copy what matters into the report.

## Not done yet

Section 5 of the backlog lists 16 checks per backend. Today `verify.sh` covers the first three, plus job labels for metrics. These are outstanding:

- host metadata
- timestamps
- an authentication failure
- a backend that's down, then back
- retry and backoff
- recovery from the spool
- a backend restart
- duplicate delivery
- dropped telemetry
- several destinations at once
- a healthy destination unaffected by an unhealthy one
- a supervisor restart

Also outstanding: the Windows harness, Uptrace, Graylog, and an API check for SigNoz instead of its UI.

## Resources

Rough guides, to confirm at the first run:

| Target | Memory | Disk |
| --- | --- | --- |
| `lgtm` | 1 to 2 GB | 1 GB |
| `prometheus`, `victoria*`, `influxdb`, `loki`, `mimir` | under 1 GB each | under 1 GB each |
| `splunk` | 4 GB or more | 5 GB or more |
| `elastic`, `opensearch` | 2 to 3 GB each | 2 GB each |
| `clickhouse` | 1 to 2 GB | 1 GB |
| `signoz`, `uptrace`, `graylog` | 4 GB or more each | several GB each |

Every configuration file is mounted read-only with `:ro,z`. The `z` lets containers read it on a host with SELinux enforcing, such as Fedora; elsewhere it does nothing.

On Linux, Elasticsearch and OpenSearch need `vm.max_map_count` of at least 262144:

```sh
sudo sysctl -w vm.max_map_count=262144
```

## Licences

| Product | Licence |
| --- | --- |
| Grafana, Loki, Tempo, Mimir, Pyroscope, Alloy | AGPLv3 |
| Prometheus, the OpenTelemetry Collector, VictoriaMetrics, OpenSearch, Jaeger, Zipkin, ClickHouse | Apache 2.0 |
| InfluxDB 2 | MIT |
| Elasticsearch and Kibana | Elastic License 2.0 / AGPLv3, free Basic features |
| SigNoz | MIT, with enterprise features |
| Uptrace | AGPLv3 |
| Graylog Open | SSPL |
| Splunk Enterprise | Proprietary: a trial, then Splunk Free at 500 MB a day |

Splunk won't start until you set `SPLUNK_START_ARGS` and `SPLUNK_GENERAL_TERMS` in `.env` yourself, after reading its terms. Nothing here accepts a licence for you.

## Cloud backends

Datadog and Splunk Observability Cloud have no self-hosted equivalent. Their manual setup guides are in [`saas/`](saas). No account is ever created and no paid feature is enabled for you, and their tests run only with credentials you supply.

## Versions

Every image is pinned in the Compose files. The tags were checked against Docker Hub when they were written; the versions actually run go in the report's evidence.
