# The otelcol pack

An OpenTelemetry Collector, from what it says about itself. The pack reads what its receivers accepted and refused, for spans, metric points and log records and for each receiver; what its exporters delivered and could not, for each exporter; what was dropped because a queue was full; and how full the fullest queue is.

The Collector sits in the middle of every pipeline and fails in the quietest way there is: a destination slows, a queue fills, and from then on everything new for that exporter is dropped at the door. Applications upstream keep sending, and get no error.

**Read-only: every request is a GET.** The pack reads the OpenTelemetry Collector's own pages and changes nothing, whatever its login would allow. It needs `curl` and `awk` on Linux and macOS, and nothing but PowerShell on Windows.

1. **Its own metrics, at the level `detailed`**, in the Collector's configuration, then restart it. It serves them on `localhost:8888` by default; in a container, name `0.0.0.0` so that the host can read them:

   ```yaml
   service:
     telemetry:
       metrics:
         level: detailed
         readers:
           - pull:
               exporter:
                 prometheus:
                   host: 0.0.0.0
                   port: 8888
   ```

   At the default level, `normal`, some versions leave the queue readings out; the rest of the pack works.
2. `vigil pack enable otelcol`, then in `vigil.config` set what differs from the defaults: `OTELCOL_URL` (`http://localhost:8888`). One Collector a pack: for a fleet of them, the pack on each machine.
3. Where a proxy in front of it asks for a login: `OTELCOL_USER` with `secret = OTELCOL_PASSWORD=secret:OTELCOL_PASSWORD`, or a bearer token as `OTELCOL_TOKEN`.

**The OpenTelemetry Collector that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (a login refused on a page every job needs, or something that is not HTTP), and says why.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `awk` | `curl`, `awk` (built in) | Nothing: PowerShell 5.1 or later, and .NET |
| The OpenTelemetry Collector | the OpenTelemetry Collector 0.100 and later, core and contrib (tested: contrib 0.166.0) | | |
| Its address | reachable from the Vigil machine: `OTELCOL_URL` (default `http://localhost:8888`) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `otelcol_status` | Up; its version and distribution; how long it has run; the memory it holds | minute |
| `otelcol_receivers` | Spans, metric points and log records accepted, refused and failed; the refusals for each receiver | minute |
| `otelcol_exporters` | Spans, metric points and log records delivered, not delivered (for each exporter) and dropped at a full queue; batches waiting, for each exporter; how full the fullest queue is | minute |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `otelcol.up`.

```text
+--------------------------------------------------------------------------------------------------+
| otelcol_status   otelcol.<metric>   every 1m                                                     |
+------------------+-------------------------------------------------------------------------------+
| up               | 1 when the OpenTelemetry Collector answered its metrics page, else 0 (and     |
|                  | nothing more is read)                                                         |
| version          | always 1, tagged version=<its version> and name=<the distribution: otelcol,   |
|                  | otelcol-contrib ...>                                                          |
| uptime_seconds   | seconds since it started                                                      |
| memory_rss_bytes | memory it holds (resident)                                                    |
| heap_bytes       | of that, its heap in use                                                      |
+------------------+-------------------------------------------------------------------------------+
| GOOD  up 1; uptime_seconds growing from one run to the next.                                     |
| WATCH memory_rss_bytes climbing towards the memory_limiter's limit (it will start refusing       |
|       data).                                                                                     |
| BAD   up 0: nothing it receives goes anywhere; uptime_seconds going back to a small number again |
|       and again: it is restarting (out of memory, or a configuration it cannot start with).      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| otelcol_receivers   otelcol.receivers.<metric>   every 1m                                        |
+------------------------------+-------------------------------------------------------------------+
| up                           | 1 when the OpenTelemetry Collector answered its metrics page,     |
|                              | else 0 (and nothing more is read)                                 |
| accepted_spans_count         | spans its receivers took (a running total)                        |
| refused_spans_count          | spans its receivers refused: the pipeline behind them would not   |
|                              | take them (a running total)                                       |
| failed_spans_count           | spans its receivers could not process: an error of its own (a     |
|                              | running total)                                                    |
| accepted_metric_points_count | metric points its receivers took (a running total)                |
| refused_metric_points_count  | metric points its receivers refused: the pipeline behind them     |
|                              | would not take them (a running total)                             |
| failed_metric_points_count   | metric points its receivers could not process: an error of its    |
|                              | own (a running total)                                             |
| accepted_log_records_count   | log records its receivers took (a running total)                  |
| refused_log_records_count    | log records its receivers refused: the pipeline behind them would |
|                              | not take them (a running total)                                   |
| failed_log_records_count     | log records its receivers could not process: an error of its own  |
|                              | (a running total)                                                 |
| refused_spans                | spans refused, for each receiver, tagged receiver=<its name>      |
| refused_metric_points        | metric points refused, for each receiver, tagged receiver=<its    |
|                              | name>                                                             |
| refused_log_records          | log records refused, for each receiver, tagged receiver=<its      |
|                              | name>                                                             |
| ..._not_shown                | past 100 of a list (refused_spans, refused_metric_points,         |
|                              | refused_log_records), how many were left out                      |
+------------------------------+-------------------------------------------------------------------+
| GOOD  the accepted counts moving; the refused and failed counts not moving.                      |
| WATCH an accepted count that stops moving while its senders run (they cannot reach the           |
|       Collector).                                                                                |
| BAD   a refused count moving: senders are told to retry, and lose data when they give up;        |
|       refused_spans, refused_metric_points or refused_log_records says which receiver, and the   |
|       exporters job why (a queue that is full, sends that fail), or the memory limiter is        |
|       refusing.                                                                                  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| otelcol_exporters   otelcol.exporters.<metric>   every 1m                                        |
+--------------------------------+-----------------------------------------------------------------+
| up                             | 1 when the OpenTelemetry Collector answered its metrics page,   |
|                                | else 0 (and nothing more is read)                               |
| sent_spans_count               | spans its exporters delivered (a running total)                 |
| send_failed_spans_count        | spans its exporters could not deliver: lost, once the retries   |
|                                | are spent (a running total)                                     |
| enqueue_failed_spans_count     | spans dropped at once: the exporter's queue was full (a running |
|                                | total)                                                          |
| sent_metric_points_count       | metric points its exporters delivered (a running total)         |
| send_failed_metric_points_coun | metric points its exporters could not deliver: lost, once the   |
| t                              | retries are spent (a running total)                             |
| enqueue_failed_metric_points_c | metric points dropped at once: the exporter's queue was full (a |
| ount                           | running total)                                                  |
| sent_log_records_count         | log records its exporters delivered (a running total)           |
| send_failed_log_records_count  | log records its exporters could not deliver: lost, once the     |
|                                | retries are spent (a running total)                             |
| enqueue_failed_log_records_cou | log records dropped at once: the exporter's queue was full (a   |
| nt                             | running total)                                                  |
| send_failed_spans              | spans that could not be delivered, for each exporter, tagged    |
|                                | exporter=<its name>                                             |
| send_failed_metric_points      | metric points that could not be delivered, for each exporter,   |
|                                | tagged exporter=<its name>                                      |
| send_failed_log_records        | log records that could not be delivered, for each exporter,     |
|                                | tagged exporter=<its name>                                      |
| queue_size                     | batches waiting in the exporters' queues                        |
| queue_capacity                 | how many may wait                                               |
| queue_fullest_pct              | how full the fullest queue is, as a percentage of its own       |
|                                | capacity                                                        |
| queue                          | batches waiting, for each exporter, tagged exporter             |
| in_flight                      | requests its exporters are waiting on now                       |
| ..._not_shown                  | past 100 of a list (send_failed_spans,                          |
|                                | send_failed_metric_points, send_failed_log_records, queue), how |
|                                | many were left out                                              |
+--------------------------------+-----------------------------------------------------------------+
| GOOD  the sent counts moving; the send_failed and enqueue_failed counts not moving;              |
|       queue_fullest_pct near 0.                                                                  |
| WATCH queue_fullest_pct climbing: a destination is slower than what arrives, and queue says      |
|       which exporter; when it reaches 100, everything new for that exporter is dropped.          |
| BAD   a send_failed count moving: data is being lost, and send_failed_spans,                     |
|       send_failed_metric_points or send_failed_log_records says which exporter (its destination  |
|       is down, refuses it, or answers too slowly); an enqueue_failed count moving: a queue is    |
|       full and everything new for it is dropped.                                                 |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the stack in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `otelcol.up` | 1 |  | 0: nothing it receives goes anywhere | `up 0` where nothing listened |
| `otelcol.uptime_seconds` | Growing | Small again and again: it is restarting |  | Growing |
| `otelcol.exporters.queue_fullest_pct` | Near 0 | Rising: a destination is slower than what arrives; `queue` says which exporter | 100: everything new for it is dropped | 100, for the exporter nothing listened to |
| `otelcol.exporters.enqueue_failed_*_count` | Flat |  | Rising: a queue is full, and data is dropped at the door | `enqueue_failed_spans_count` rising |
| `otelcol.exporters.send_failed_*_count` | Flat |  | Rising: data is lost; `send_failed_*` names the exporter | Rising for spans (two exporters named) and metric points (`prometheusremotewrite/mimir`, refused by Mimir's limit) |
| `otelcol.receivers.refused_*_count` | Flat |  | Rising: senders are told to retry, and lose data when they give up; `refused_*` names the receiver | `refused_spans` rising for `receiver=otlp/refused` |
| `otelcol.receivers.accepted_*_count` | Rising |  | Flat while senders run: they cannot reach it | Rising, all three |

## How it was tested

**Tested** on 2026-11-25 by `tests/integration/backends/scripts/run-obs.sh`, against `compose.obs.yaml`: one stack of all nine services wired together as they are in use, each in trouble on purpose. **Prometheus 3.15.1** (two targets down and one that answers without metrics, a rule group that cannot be evaluated, an Alertmanager that is not there, a remote write nothing answers and one that is refused), **Alertmanager 0.35.1** (two in a cluster; a receiver nothing listens to), **Grafana 13.2.5** (a data source nothing answers, an alert rule that reads it, a contact point nothing listens to), **Loki 3.7.9** (entries too old, lines too long), **Mimir 3.2.6** (a tenant held at 200 series), **Tempo 2.10.10** (traces larger than its limit), **the OpenTelemetry Collector 0.166.0** (an exporter nothing answers, whose queue fills; a receiver that must refuse), **VictoriaMetrics 1.157.0** (a scrape target down, queries that fail) and **VictoriaLogs 1.54.0** (entries older than its retention), in Docker, with traces, metrics and logs flowing through all of it.

- **On Fedora** (Fedora 44, bash 5.3): every job of every pack and what each must have read; a token Grafana refuses, a page that is not there, and nothing answering; then the stack broken further, live (Tempo stopped, and seen by its own pack and by Prometheus', the Collector's and Grafana's; an Alertmanager leaving its cluster; a configuration Prometheus refuses, then Alertmanager): **84 passed, 0 failed**. Then `service-packs.sh` through Vigil, for all nine packs (enable, and that CPU and memory are the base pack's; precheck; every job; a service that does not answer read as `up 0`; Grafana's token kept as a secret and written nowhere; the metrics reaching the backend): **95 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-25/fedora/pack-obs/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own awk), against the same stack through SSH tunnels: every job and the same checks, **69 passed, 0 failed**; through Vigil, **95 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-25/macos/pack-obs-macos/console.txt)).
- **On Windows**, as an account that is not an administrator, against the same stack through SSH tunnels: every job, each compared with what the Linux script printed a moment before (the same readings, by name and tag, for all 28 jobs), the faults read again, then `Service-Packs.ps1` through Vigil. On Windows 11 under Windows PowerShell 5.1 and under PowerShell 7, and on Windows Server 2025 under Windows PowerShell 5.1: **79 passed, 0 failed** and **76 passed, 0 failed** on each ([Windows 11](../../tests/integration/backends/reports/runs/2026-11-25/windows/pack-obs-windows/console.txt), [under PowerShell 7](../../tests/integration/backends/reports/runs/2026-11-25/windows/pack-obs-windows/console-powershell7.txt), [Server 2025](../../tests/integration/backends/reports/runs/2026-11-25/windows-server-2025/pack-obs-windows/console.txt)). Over SSH, Windows refuses its data protection to a logon with no password, so there the suite gives Grafana's token by an `env:` reference; at a console, `vigil secret set` keeps it.
- **The two engines**, bash with awk and PowerShell, were compared line for line over all nine services' pages with a table that uses every operation on every metric: 12,873 readings, none differing, between gawk, mawk, macOS' awk, busybox's, Windows PowerShell 5.1 and PowerShell 7 (`tools/obs/DESIGN.md`).

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
