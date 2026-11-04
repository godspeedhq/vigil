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

## Then, the file backend

The bash `file` backend (`vigil_prom_merge`, `prom.sh`) sorted each event's labels with a subshell and a `sort` process: two processes for every event, so its system time was as high as its user time. They are sorted in bash now, in the same order (bytes, by key, then the whole tag), and the output is byte for byte the same: the conformance suite, and 400 generated events with every awkward label (mixed case, digits, underscores, repeated keys, quotes and backslashes in values) merged by both versions, on bash 5.3 and 3.2.

| Merge | Fedora, bash 5.3 | macOS, bash 3.2 | Windows, PowerShell 5.1 |
| --- | --- | --- | --- |
| 1000 series into an empty file | 2.9 s, now 1.1 s | 6.3 s, now 2.6 s | 0.9 s |
| nine more files of them | 22 s, now 5.3 s | 46 s, now 12.6 s | 6.2 s |

## A slow backend and the others

One sender delivers to every backend in turn, so a backend slow to accept (not failing) delays the others while it is served. Bounding each backend's share of a run would mean a different sender for a load ordinary jobs do not make. The spec now states the limit plainly instead (§4.5, Throughput): the order, the 5-minute sender limit, the file backend's merge rate, and that a job printing the most metric lines a run allows every few seconds can outrun it.

## Closed

2026-11-04. Both conditions met: the file backend's process starts per event are gone, with the merge times above on both twins, and the spec states the limit.
