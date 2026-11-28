# The bash sender's OTLP running totals

Found by the fleet test (`tests/integration/fleet`, bugs B5 and B2 in `tests/integration/backends/reports/runs/2026-11-26/fleet-run2/BUGS.md`) on 2026-11-26: Alpine containers running bash Vigil with the base pack, capped at half a CPU, stopped delivering metrics. Every sender run passed its 5-minute `max_runtime` and was stopped before its first request, so the queue only grew: 1,585 files on `fedora-c1` an hour and a half later.

## What was wrong

An OTLP batch's counts are summed per series and merged with the backend's running totals (spec 15.3). The bash twin kept both as one string of lines and found a series in them with patterns: `case $s in *"$nl$series$tab"*`, `${s%%"$nl$series$tab"*}`, `${s#*"$nl$series$tab"}`. A pattern starting or ending with `*` takes time that grows with the square of the string's length in bash, and the strings were tens of kilobytes:

- the batch's counts, about 480 bytes per series (its OTLP attributes), 27 KB for the 57 series of one 160 KB batch;
- the totals, one line per series ever counted on the backend, 30 KB for 196 series.

So every batch paid about 12 seconds of CPU to merge the totals alone, even a small one (bug B2: the sender was the largest share of an instance's CPU). A backlog's full batches paid 40–50 seconds, which half a CPU on a busy host stretched past five minutes (bug B5). The gauges were never slow: 964 of them took 1.6 seconds.

The PowerShell twin keeps both in an `OrderedDictionary` and was never affected.

## The fix

The counts and the totals are kept in plain indexed arrays (bash 3.2 has no associative arrays) and a series is found by comparing with `=`. The order is the same, first seen, so the body and the totals are byte for byte the same.

One 160 KB batch from `fedora-c1`'s queue (1,167 events, 203 of them counts), with its real totals file:

| | Before | After |
| --- | --- | --- |
| Fedora 44, bash 5.3 | 52 s | 2.3 s |
| macOS 12, bash 3.2 (a 2015 MacBook) | 115 s | 11 s |

Four consecutive batches on bash 5.3 and two on bash 3.2, totals carried from each to the next, gave the same body and the same totals, checked by checksum. The conformance suite passed on both (144 and 129 cases), and `tests/integration/backends.sh` passed (42).

## On the stalled container

The fixed file went into `fedora-c1` at 22:40, its queue at 1,585 files and growing, no sender run having finished since 20:28. The first run with it started at 22:45. In the container a batch now costs 5 seconds of CPU, but takes a minute or two: the container's half a CPU is shared with the supervisor and the base pack. So runs still reached the 5-minute limit, but each sent two batches first, and what was sent stayed sent. The queue drained in 34 minutes, with new events arriving all the while, and at 23:19 a sender run finished on its own (198 s) for the first time in three hours. Its newest metrics were a minute old again.

Evidence: `tests/integration/backends/reports/runs/2026-11-26/sender-totals/` (`00-measurements.txt`, and the queue minute by minute in `02-fedora-c1-draining.txt`).

## What the backend kept

Prometheus stored the readings from 22:30 on, but not those from 20:35 to 22:25. With no `out_of_order_time_window`, it refuses a sample more than about an hour older than the newest it holds, and other hosts kept that current: 66,580 samples were refused as too old (`03-what-prometheus-kept.txt`). The OpenTelemetry Collector in front of it had already answered 2xx, so Vigil could not know, and counted nothing as dropped. Delivery after an outage is at least once as far as the backend's answer goes; a Prometheus that is to keep a long backlog needs `out_of_order_time_window` set at least as long as the outages it should survive. That belongs in the docs on backends.

## Closed

2026-11-26.
