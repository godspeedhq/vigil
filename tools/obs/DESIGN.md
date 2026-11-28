# The packs that watch a monitoring stack

Nine packs from one source: `prometheus`, `alertmanager`, `grafana`, `loki`, `mimir`, `tempo`, `otelcol`, `victoriametrics` and `victorialogs`. They watch the things that watch everything else, and each stands on its own (packs never depend on each other). They are written together because all nine say what is wrong with them the same way: a page of metrics in Prometheus' text format, at `/metrics`.

Other services that say what is wrong with them the same way are written here too, though they watch nothing: `etcd`, `openbao` (OpenBao and Vault; its status job reads their health pages with no token), `traefik` (its config job reads its API) and `nats` (NATS says what is wrong with it in JSON, so its jobs are all code). A pack's page may then carry its own "How it was tested" (`tested` in `pages.py`); the nine share one.

`py tools/obs/gen.py .` writes them all; `py tools/obs/gen.py . loki` writes one.

| File | What |
| --- | --- |
| `lib.sh`, `lib.ps1` | What every script shares, as `_<pack>.sh` (Linux, macOS) and `_<pack>.ps1` (Windows), beside the scripts: one request, with a login when one is set, and `readings` (`Get-Readings`), which takes a table of readings from a page of metrics in one pass. |
| `jobs.py` | How a job is written: a list of steps (`page`, `answers`, `table`, `extra`, `code`), the same on every platform. |
| `<pack>.py` | Each pack's words (its name, its settings' prefix, its version, what it needs) and its jobs: what each reports, its readings, and how to read them. |
| `gen.py` | The scripts' headers, the two bodies each job's steps become, and `pack.config`. |
| `examples-<pack>.txt` | Each job's example output, from the test run, for its script's header. |

## A job is a table

Almost every job is one request and a table. A line of the table is one reading:

```text
name|op|metric|filters|arg
```

`sum`, `max`, `min` and `count` of the series that pass the filters (`label=value`, `!=`, `~regex`, `!~regex`); `by` and `countby`, one line for each value of a label, the 20 largest, with `<name>_not_shown` for the rest; `age` and `oldest`, seconds since a time; `info`, labels as tags; `maxpct`, how full the fullest of several queues is; and `pct`, `div`, `sub`, `add`, `mul` of readings above. `lib.sh` and `lib.ps1` document each at `readings`.

The table is the same text in the bash script and the PowerShell one, and the two engines must print the same for it: awk on one side, .NET on the other. They were compared line for line over all nine services' pages, idle and under load, with a table generated to use every operation on every metric: about 12,900 readings, none differing, between gawk, mawk, macOS' awk and busybox's, Windows PowerShell 5.1 and PowerShell 7.

## Choices

- **Read-only.** Every request is a GET: the metrics page, a health or readiness page, Prometheus' and VictoriaMetrics' federation page, and, for Grafana's data sources, its API with a Viewer's token. No pack calls a reload, a snapshot, a delete or an admin endpoint, whatever the login would allow.
- **Their own words.** A pack reads what the service says about itself, not what a Prometheus scraping it says. So it works where there is no Prometheus, and it is how a Prometheus that has stopped scraping is noticed.
- **Running totals are passed on as they are.** A job keeps nothing between runs, so a counter is printed as the service has it, named `*_count`, and the backend works out the rate. "Moving" in a job's reading notes means its rate is above zero.
- **One name for a thing, across versions.** Where a service has renamed a counter (the Collector, with and without `_total`), the reading is the sum of both names, of which a version has one.
- **Bounded output.** A breakdown by label stops at 20 lines, the largest first, and says how many it left out. A breakdown never takes a label that grows with use (a tenant, a target, a stream): only the kind of thing (a reason, an integration, an exporter, a job).
- **Numbers as text that every backend reads.** Whole numbers whole; otherwise at most 15 significant digits and 6 decimals, never an exponent. That is all a double holds for certain, and what every awk and both PowerShells agree on.
- **No CPU or memory of the processes.** That is the base pack's `processes` job; the packs say so in their `needs` lines.
- **A service that does not answer is a reading.** `up 0`, and the run succeeds: the backend alerts on it. A run fails only when the answer is wrong (a login refused where one is needed for everything, something that is not HTTP), and says why.
- **One address a pack.** Each job reads `<PACK>_URL`. For a service run as several components (Loki, Mimir, Tempo in microservices mode; a VictoriaMetrics cluster), point each job at the component that has its metrics, or install the pack beside each: a component reports those of the readings it has, and zeros for the rest.

## Lessons from the test stack

- VictoriaMetrics and VictoriaLogs print no `# TYPE` lines: nothing here needs them.
- Prometheus' `/federate?match[]=up` gives one line a target, in the text format: the targets job needs no JSON, and no `jq`.
- A remote Prometheus has never sent to reads `queue_highest_sent_timestamp_seconds 0`: "behind" is counted from the remotes that have sent (`minpos`), and the others are counted apart (`remotes_never_sent`).
- The Collector serves its own metrics on localhost: in a container, `service::telemetry::metrics::readers` must name `0.0.0.0`. Its receiver and exporter counters appear only once data has flowed.
- A Collector queue's fullness is a share of its own capacity: summed over exporters, one full queue of ten disappears beside five empty ones of a thousand. Hence `maxpct`.
- A row's fields are separated by `|`, so a filter's regex cannot use one: `^[JLP]` for JOINING, LEAVING and PENDING.
- PowerShell: `continue` inside a `switch` leaves the switch, not the loop around it.
- VictoriaLogs' `/insert/jsonline` answers 200 to anything, and keeps only what is sent as `application/stream+json` (the test's own loader had that wrong first).
- A Grafana Viewer may list the data sources and ask each for its health. The health check answers 400, not 200, for one that does not answer.
