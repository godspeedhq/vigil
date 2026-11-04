# The bash sender with large batches

Found by `tests/integration/backends/scripts/run-checks.sh` (backlog 18) on Fedora 44, 2026-11-04: with Prometheus stopped and the spool full of queued events, the sender never finished a run again.

## What was wrong

Three places in the bash twin took time that grew with the square of the batch. A full batch is what an outage leaves behind: up to 160 KB of events per request (spec 15.3), and 512 KB of log lines per forwarder request (`batch_kb`).

| Where | Old | Now |
| --- | --- | --- |
| Escaping a request body for curl (`_vigil_http_escape`, `stores.sh`) | over 10 minutes for 385 KB | 2.7 seconds on bash 5.3, 4 on bash 3.2 |
| Building an OTLP, Datadog or Splunk body (`vigil_backend_body`, `backends.sh`) | 4.5 seconds for 1000 events, 18 for 2000 | 0.6 and 1.3 |
| Building a log batch (`_vigil_logs_file`, `logs.sh`) | the same pattern | the same fix |

A sender may run for 5 minutes (spec 4.5), so after an outage long enough to fill one request, the batch could never be sent: each run started it again and was stopped. Every other backend waited behind it, since one sender runs at a time.

The escape went through its string once per `\` or `"`, copying what was left each time, and a JSON body is mostly quotes. The bodies were appended to one growing string per event. Now the escape works through 1 KB pieces, and the bodies and batches are built through a short buffer. The output is byte for byte the same (the conformance suite, and checksums of large bodies on bash 3.2 and 5.3). The PowerShell twin builds its bodies with a `StringBuilder` and sends them without escaping, and was never affected.

`tests/integration/backends.sh` now sends a 1000-series run to three HTTP backends and the file backend in one sender run.

## Still open

- **The `file` backend** (`app/lib/posix/prom.sh`, `vigil_prom_merge`) merges about 430 events a second: 3 seconds for an events file of 1000 series, 23 seconds for nine more. Its system time is as high as its user time, so most of it is starting processes.
- **A slow backend holds up the others.** Spec 4.5 promises that a slow or unreachable backend never blocks another. That holds for one that fails: it backs off and is passed over. It does not hold for one that is slow to accept, and the file backend is the one most often enabled beside another. A job printing 1000 metric lines every 2 seconds outran it.

## Done when

- The file backend's process starts per event or line are gone, and a 1000-series run merges in a stated time on both twins.
- A sender run's time per backend is bounded, so a slow one cannot hold up the rest, or the spec states the limit plainly.
