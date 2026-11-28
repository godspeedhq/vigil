# A whole fleet's forwarded logs were one stream in Loki

Found by the fleet test's 2-hour backend outage on 2026-11-27 (bug B8 in `tests/integration/backends/reports/runs/2026-11-26/fleet-run2/BUGS.md`, report in `tests/integration/backends/reports/runs/2026-11-27/outage/`). The backend was down from 17:35 to 19:35 UTC. Afterwards, Loki held all of Fedora's base_cpu lines from the outage, and none of the other four instances' lines from 17:35 to about 18:45. It had refused 10,692 lines as `too_far_behind`. Every metric arrived.

## What was wrong

Two things, of which Vigil can fix one.

- **One stream for a whole fleet.** Of a forwarded record's resource attributes, Loki indexes only `service.name` (`vigil`). Host, tags and the rest become structured metadata. So every instance writing to one Loki was one stream, `{service_name="vigil"}`, with one stream's rate limit (3 MB/s by default) for the whole fleet. After an outage, whichever instance delivered first set the stream's newest line for everyone.
- **Loki's window.** Loki refuses a line more than `max_chunk_age / 2` (an hour, by default) behind its stream's newest line. The forwarder sends each log file to its end before the next (§13.4.4), so even within one instance, the first file brings the stream up to date. After an outage of more than an hour, the next file's older lines are refused. Fedora showed it: its base_cpu lines, sent first, all arrived, while base_load kept 32 of the 120 lines it wrote from 18:00 to 19:00. This is the backend's setting, like Prometheus's out-of-order window. Vigil cannot see it either, since the collector answers 2xx.

## The fix

- **`service.instance.id`** = `<host>/<instance>` on the resource of every OTLP request: the OpenTelemetry attribute for one instance of a service, which Loki indexes by default (checked against Loki 3.7: the stream label `service_instance_id`). Each instance is a stream of its own. Logs only: the metrics already carry `host` and `instance`, and a new resource attribute would start new series in Prometheus.
- **Documentation:** the README's "Forwarding Vigil's logs" says Loki needs `max_chunk_age` of twice the outages whose logs it should keep, with an example.
- Spec §13.4.2; both twins.

Sending the oldest pending lines across all files first would keep the whole backlog inside Loki's default window. It was considered and left out, to keep the forwarder simple.

## Tests

`tests/integration/logs.sh` and `Logs.ps1`: the request's resource carries `service.instance.id` = `<host>/lg`.

## Closed

2026-11-27.
