# After a long outage, current metrics waited behind hours of history

Found by the fleet test on 2026-11-27 (bug B7 in `tests/integration/backends/reports/runs/2026-11-26/fleet-run2/BUGS.md`). The Mac, HP and Lenovo containers had been stuck for about ten hours (bug B5, fixed in #281). Once patched, each had some 10,000 queued files to send, oldest first, at about 50 files a minute net on half a CPU. That is three to four hours before its current metrics would arrive. Prometheus refused most of them anyway as too old, about 1,000 samples a minute.

## What was wrong

The spool was bounded only by size (`[spool] max_mb`, 100 MB by default), not by age. A small instance's ten hours fit well inside 100 MB, so all of it waited to be sent, oldest first, ahead of the present.

## The fix

- **`[spool] max_age`:** a duration, default `6h`; `0s` means no limit. Before delivery, the sender drops every queued file older than that and counts its events in `vigil.spool.dropped` with `reason=too_old`, tagged by backend, as Datadog's too-old points already were.
  - The age is the epoch each queue file's name starts with, so no file is opened to decide.
  - The check comes before the size cap, so a long outage loses its oldest hours to age rather than to size.
- **Why 6 hours:** most backends refuse samples older than that anyway. Prometheus refuses a sample about an hour older than its newest, unless its out-of-order window is larger (the README suggests 6 hours), and Datadog refuses anything older than an hour. It also matches the out-of-order window the README suggests for Prometheus (#281).
- **Order:** delivery stays oldest first. Sending the newest first after a backlog was considered and left out: Loki refuses a stream's lines more than an hour behind its newest (bug B8, #286), and spec §4.5 stays as it was.
- **Where:** spec §4.5 and §15.5 and the README; both twins and their validators (`dur0`).

## Tests

`tests/integration/backends.sh` and `Backends.ps1`, with the HTTP backends down and `max_age = 1h`:
- a file two hours old is dropped from every queue and counted `too_old`;
- one half an hour old stays;
- with `max_age = 0s`, a file two hours old stays, and the setting is valid.

## Closed

2026-11-28.
