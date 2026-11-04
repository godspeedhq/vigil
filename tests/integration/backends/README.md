# Real-backend test environment

Vigil's telemetry is tested everywhere else against mocks. Here it's tested against the real products: the backends run in Docker, Vigil runs on the host exactly as it would in production, and each test asks the backend, through its own query interface, whether the data arrived. This is backlog task 18.

> **Status: first runs done.** Grafana LGTM, OpenBao and HashiCorp Vault have been run, with Vigil on Linux, macOS and Windows; every other target is still **Not tested**. See [`reports/compatibility.md`](reports/compatibility.md) and [`reports/secrets-compatibility.md`](reports/secrets-compatibility.md).

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

**Needs:** Docker Engine or Docker Desktop with Compose 2.20 or later (for `include`), plus bash, curl and git, on the machine running the backends. Vigil can run there or on another machine (see below): `run-vigil.sh` and `run-store.sh` on Linux and macOS, `run-vigil.ps1` and `run-store.ps1` on Windows (PowerShell 5.1 or 7; Git Bash for `verify.sh`).

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
| 9 Secrets | `compose.secrets.yaml` | `openbao`, `vault` | — | Vigil's `hashicorp_vault` secret store reads from them (below) | 8200, 8210 (https) |

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

Then run `scripts/run-vigil.sh lgtm` as usual. For Splunk, forward 8088 (HEC) and 8089 (the management API `verify.sh` uses) the same way; for other targets, forward the ports in the table above. For LGTM, `verify.sh` also needs Grafana's 3000.

**The clocks must agree.** Vigil stamps telemetry with its own machine's time. A clock minutes ahead of the backend's makes Loki hide the lines until that time comes, and Prometheus refuses samples too far ahead. `run-vigil` compares the two, from the `Date` on the backend's HTTP answer, and warns past a minute. Keep the time set automatically on every test machine.

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

**SigNoz, Uptrace and Graylog** each come with their own multi-service deployment. They aren't copied here, which would mean keeping a private version of each. Instead `scripts/start.sh` fetches the official one at the pin in [`configs/platforms/upstream.txt`](configs/platforms/upstream.txt) into `configs/platforms/<name>/upstream`, and runs it as its own Compose project (`vigil-uptrace`, `vigil-graylog`), so no two platforms share a database.

**SigNoz** deprecated its Compose files in v0.130.0 and now installs through its own tool, Foundry, which generates the Compose file. Install `foundryctl` yourself, following https://signoz.io/docs/install/docker/; nothing here installs it. `scripts/start.sh signoz` then runs it with [`configs/platforms/signoz/casting.yaml`](configs/platforms/signoz/casting.yaml).

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
   - **metrics:** the probe value, 42, with the run's tag. Its name, `bk_metrics.vigil_backend_probe`, says which job sent it; Prometheus-based backends replace the `job` label with `vigil`, from the service name.
   - **logs:** a line with the run's tag

   It retries for two minutes, since backends index in the background, and saves the backend's answers in `reports/evidence/`. That folder isn't committed; copy what matters into the report.

On Windows, `run-vigil.ps1 <target>` does the same, with `.ps1` workloads and `hostname.exe` as the native program. `-Keep` leaves its temporary folder, with Vigil's logs and state, in place afterwards. Either way, the run's [evidence](#evidence) is kept.

### Delivery checks

`scripts/run-checks.sh <target>` checks the rest of section 5 of the backlog, on the Docker host, since it stops and starts the target's containers. It needs `jq`, and takes about seven minutes.

One Vigil sends to the target and to a local `file` backend. Its job runs every 5 seconds, writes its run in a ledger outside Vigil, reports the second it ran as a metric (`bk_check.seq`) and prints it as a log line. Then, in turn:

1. the target is stopped for 70 seconds, and started again
2. the target is restarted
3. Vigil's supervisor is stopped for 10 seconds, and started again
4. the target is stopped, the spool cut to 1 MB, and a job floods it

The backend's own query interface is then asked for every run in the ledger:

| Check | Passes when |
| --- | --- |
| 4 job identifiers | the job is in a label, or in the metric's name where the backend replaces the label |
| 5 host metadata | `host`, `os` and `instance` are stored as Vigil sent them |
| 6 timestamps | every sample and line is stamped within 10 seconds of its run, those delivered late after the outage too |
| 7 authentication | a wrong credential is refused; not applicable where the target takes none |
| 8 unavailable | failures are counted, the events held in the target's queue, and jobs run on |
| 9 retry and backoff | the sender's failed runs are 5, 10, 20... seconds apart, from its own log |
| 10, 11, 16 recovery | every run of the outage, the restart and the supervisor restart arrives |
| 12 duplicates | no run is stored twice |
| 13 dropped telemetry | drops are counted, and the count reaches the target once it is back |
| 14 several destinations | the same runs reach the file backend |
| 15 a healthy destination | the file backend stays current all through the outage |

Prometheus-style and Loki-style query APIs are supported so far: `prometheus`, `loki`, `mimir`, `otel-collector` and `alloy`. A target without one has those checks NOT RUN, and says so.

## Secret stores

Group 9, `compose.secrets.yaml`, tests Vigil's existing secret stores (backlog task 24). Each store has its own profile and starts only when asked for:

| Target | Product | Port (127.0.0.1) | Vigil's store type | Memory |
| --- | --- | --- | --- | --- |
| `openbao` | OpenBao 2.7.1, the open-source fork of Vault | 8200 (https) | `hashicorp_vault` | about 25 MB |
| `vault` | HashiCorp Vault 2.2.0 | 8210 (https) | `hashicorp_vault` | about 70 MB |
| `aws` | Floci 2.3.0, an AWS emulator, behind an nginx TLS front | 4566 (https) | `aws_secrets_manager` | about 60 MB |
| `azure` | Floci Azure 0.15.0, Key Vault and an emulated Entra ID, behind an nginx TLS front | 4577 (https); 4578 (http, managed identity only) | `azure_keyvault` | about 40 MB |
| `gcp` | Floci GCP 0.11.0, Secret Manager and an OAuth2 token endpoint, behind an nginx TLS front | 4588 (https) | `gcp_secret_manager` | about 20 MB |
| `azure-alt` | Lowkey Vault 7.3.127, a community Key Vault emulator, with its own TLS | 8443 (https); 8081 (http, managed identity only) | `azure_keyvault` | about 270 MB (Java) |
| `gcp-alt` | Blackwell's Secret Manager emulator 1.9.0, behind an nginx TLS front; it has no sign-in, so start `gcp` too, for Floci's token endpoint | 4598 (https) | `gcp_secret_manager` | about 5 MB |

LocalStack is not included: since 2026.03.0 it needs a LocalStack account's auth token, which is not made for you. An emulator proves Vigil's requests and how it reads the answers, never the real cloud's sign-in: Floci, for one, accepts any key, and `run-store` reports that as an EMULATOR LIMITATION, not a pass.

```sh
scripts/start.sh openbao        # the test CA if new, start, unseal, fixtures
scripts/run-store.sh openbao    # the tests (run-store.ps1 on Windows)
scripts/stop.sh openbao         # keeps its data
scripts/reset.sh openbao        # removes it; the next start initialises again
```

Both are real servers, not dev mode, so they survive a restart, which the tests use:

- **Storage:** integrated (raft, one node), on a named volume.
- **TLS:** from a test CA. [`configs/secrets/tls.sh`](configs/secrets/tls.sh) makes it once, before the first start, with a certificate for `localhost` and `127.0.0.1`. Vigil's stores are https only.
- **Setup:** [`configs/secrets/provision.sh`](configs/secrets/provision.sh) runs after every start. It initialises the server the first time, unseals it every time, and sets up the same fixtures in both:
  - KV v2 at `secret/` and KV v1 at `kv1/`
  - a read policy, AppRole, a token, a token that expires after 5 seconds, and a token that may only rotate one secret
  - secrets with new random values

Everything generated goes in `.secrets/`, which is git-ignored: the CA, the unseal key, the credentials and the fixtures' values. To test from another machine, copy `.secrets/<target>.env` and `.secrets/tls/ca.pem` to the same paths there, and forward the store's port.

`run-store` checks retrieval with AppRole and a token, a missing secret, permission denied, an untrusted certificate, an invalid and an expired token, an invalid AppRole secret id, KV v1 (not supported by Vigil), rotation, and that no secret or credential is ever written down. On the Docker host, it also stops, restarts and unseals the store, and checks that Vigil recovers; elsewhere that is reported NOT RUN. Results are in [`reports/secrets-compatibility.md`](reports/secrets-compatibility.md).

## Sources

Group 10, `compose.sources.yaml`, tests the servers Vigil fetches its configuration and scripts from (backlog task 25). Each has its own profile, and none starts with the observability environment:

| Target | Server | Ports (127.0.0.1) | Vigil's source type | Memory |
| --- | --- | --- | --- | --- |
| `git-gitea` | Gitea 28.2.0 | 3443 (https), 2222 (ssh) | `git` | about 110 MB |
| `https-nginx` | nginx 1.30.5 | 9443 (https), 9080 (http) | `https` | about 10 MB |
| `sftp-openssh` | OpenSSH (atmoz/sftp) | 2022 | `sftp` | about 10 MB |
| `local` | none: a directory | — | `local` | — |

GitLab CE, Caddy and SFTPGo follow in phase 2 of the task.

```sh
scripts/start.sh git-gitea          # the test CA and keys if new, start, fixtures
scripts/run-source.sh git-gitea     # the tests
scripts/run-source.sh local         # needs no server at all
```

- **Fixtures:** fixed files in [`fixtures/sources/`](fixtures/sources), byte-exact on every checkout, so their SHA-256 is known: scripts in both flavours, and the configurations Vigil fetches in remote mode.
- **Provisioning:** each server's `configs/sources/<server>/provision.sh` runs after it starts. Gitea gets a private repository with a fixed history (the same commits every time), a read-only collaborator and a read-only deploy key. nginx serves the fixtures, with endpoints that fail on purpose. The SFTP server has a key-only user and a fixed host key.
- **Generated files:** dummy keys, passwords and tokens go in `.sources/` (git-ignored). Copy it, and `.secrets/tls/ca.pem`, to test from another machine.
- **Trust:** a source has no `ca_file`, so the test CA is trusted as an operator trusts a private one: git's `http.sslCAInfo` and curl's `CURL_CA_BUNDLE`. sftp uses its key and `known_hosts` through Vigil's own test switch, `VIGIL_TEST_SSH_CONFIG`.

`run-source` drives Vigil with supervisor ticks, as `tests/integration/fetch.sh` does. No check passes on a connection or a download alone: each reads the fetcher's status and reason, the activation record, the cached file's SHA-256 and the job's run. It covers:
- retrieval, updates and remote mode
- every failure the server can give, with the last good configuration kept each time
- refused credentials and host keys
- the server down and back, on the Docker host
- that no credential is ever written down

Results are in [`reports/sources-compatibility.md`](reports/sources-compatibility.md).

## Updates

`run-update` needs no Docker and no server but GitHub. A published release is installed by its own installer from GitHub, into a throwaway folder, and real jobs run on it, one of them across the update. Then its own `vigil self update` moves it to the latest release, with no test overrides: the real release server and the real release key. The supervisor must carry on as the same process, with its configuration, jobs, state and metrics intact.

```sh
scripts/run-update.sh          # from 0.2.0 (run-update.ps1 -From 0.2.0 on Windows)
scripts/run-update.sh 0.2.1    # from the first signed release
```

A release from 0.2.1 on carries the release key, and its update refuses what that key did not sign; it says nothing when the signature is good, so the run verifies the same signature with the same key itself. 0.2.0 predates signing, and checks the SHA-256 only. A Vigil already installed on the machine is not touched. Results are in [`reports/updates.md`](reports/updates.md).

## Evidence

Every `run-vigil`, `run-store`, `run-source` and `run-update` run, in bash and PowerShell, keeps its evidence in `reports/runs/<date>/<host>/<name>/` before its temporary folder goes:

- **`console.txt`:** a header (the date, host, OS, the Vigil commit, and the versions of the shell, git, curl, OpenSSL and ssh, with the images the Compose file pins), then everything the run printed. On Windows it is a PowerShell transcript.
- **`*.out`:** what Vigil itself printed.
- **`root/`:** Vigil's configuration, logs, state and metrics, as the run left them.

`VIGIL_EVIDENCE_HOST` names the host folder (by default, the hostname). On a copy that isn't a Git checkout, `VIGIL_EVIDENCE_COMMIT` names the commit it was copied from.

The run's secrets and credentials are test values. Even so, a file holding one is left out and said so, and so is a `console.txt` that holds one: the run has failed its leak check already. The runs behind the compatibility reports are committed, and published on the site.

## Not done yet

- **Delivery checks beyond group 1:** `run-checks.sh` needs a query helper for each other backend's API (Splunk, VictoriaMetrics and VictoriaLogs, Elasticsearch, OpenSearch, InfluxDB, ClickHouse), and an authentication case where the target takes a credential.
- **Uptrace and Graylog,** and an API check for SigNoz instead of its UI.

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
| `openbao`, `vault` | about 25 MB and 70 MB measured | under 100 MB each |

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
| OpenBao | MPL 2.0 |
| HashiCorp Vault | BUSL 1.1, which allows this local testing |
| Elasticsearch and Kibana | Elastic License 2.0 / AGPLv3, free Basic features |
| SigNoz | MIT, with enterprise features |
| Uptrace | AGPLv3 |
| Graylog Open | SSPL |
| Splunk Enterprise | Proprietary: a trial, then Splunk Free at 500 MB a day |

`scripts/start.sh splunk` refuses to start Splunk until you set `SPLUNK_START_ARGS` and `SPLUNK_GENERAL_TERMS` in `.env` yourself, after reading its terms, and the Splunk container refuses without them too. Nothing here accepts a licence for you.

## Cloud backends

Datadog and Splunk Observability Cloud have no self-hosted equivalent. Their manual setup guides are in [`saas/`](saas). No account is ever created and no paid feature is enabled for you, and their tests run only with credentials you supply.

## Versions

Every image is pinned in the Compose files. The tags were checked against Docker Hub when they were written; the versions actually run go in the report's evidence.
