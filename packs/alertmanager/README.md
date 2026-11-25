# The alertmanager pack

An Alertmanager, from what it says about itself. The pack reads whether it is ready and its configuration loaded; the alerts and silences it holds; the notifications it sent and those that failed, for each integration and each reason; and its view of its cluster: the members it sees and the peers it has lost.

Alertmanager is the last step before a person. If its webhook has a stale token or its cluster has split, every alert upstream still fires, and nobody is told. This is the pack whose alerts must not go through the Alertmanager it watches: Vigil sends its metrics to your backend by a path of its own.

**Read-only: every request is a GET.** The pack reads Alertmanager's own pages and changes nothing, whatever its login would allow. It needs `curl` and `awk` on Linux and macOS, and nothing but PowerShell on Windows.

1. Nothing to turn on: Alertmanager serves `/metrics` and `/-/ready` already.
2. `vigil pack enable alertmanager`, then in `vigil.config` set what differs from the defaults: `ALERTMANAGER_URL` (`http://localhost:9093`). For a cluster, install the pack on each member's machine: each reports its own view, and a split shows as members that disagree.
3. Where it asks for a login: `ALERTMANAGER_USER` with `secret = ALERTMANAGER_PASSWORD=secret:ALERTMANAGER_PASSWORD`, or a bearer token as `ALERTMANAGER_TOKEN`.

**Alertmanager that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (a login refused on a page every job needs, or something that is not HTTP), and says why.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `awk` | `curl`, `awk` (built in) | Nothing: PowerShell 5.1 or later, and .NET |
| Alertmanager | Alertmanager 0.25 and later (tested: 0.35.1, alone and as a cluster of two) | | |
| Its address | reachable from the Vigil machine: `ALERTMANAGER_URL` (default `http://localhost:9093`) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `alertmanager_status` | Up and ready; version; the last configuration reload, and how long ago; alerts active, suppressed and unprocessed; alerts received and refused as invalid; silences; receivers, integrations, inhibition rules; aggregation groups | minute |
| `alertmanager_notifications` | Notifications attempted and failed, for each integration and each reason; requests to the services notified, and those that failed; how long a notification takes | minute |
| `alertmanager_cluster` | Clustering on; members seen and peers lost; health score; position among the members; gossip waiting and dropped; reconnections that failed; peers joined and left | minute |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `alertmanager.up`.

```text
+--------------------------------------------------------------------------------------------------+
| alertmanager_status   alertmanager.<metric>   every 1m                                           |
+--------------------------------+-----------------------------------------------------------------+
| up                             | 1 when Alertmanager answered its metrics page, else 0 (and      |
|                                | nothing more is read)                                           |
| ready                          | 1 when Alertmanager says it is ready (/-/ready answers 200),    |
|                                | else 0: it is starting, or its cluster has not settled          |
| version                        | always 1, tagged version=<its version>                          |
| uptime_seconds                 | seconds since it started                                        |
| config_reload_ok               | 1 when the last configuration reload worked, else 0: it is      |
|                                | still running the one before                                    |
| config_age_seconds             | seconds since the configuration it runs was loaded              |
| alerts_active                  | alerts firing and not silenced or inhibited                     |
| alerts_suppressed              | alerts silenced or inhibited                                    |
| alerts_unprocessed             | alerts received and not yet looked at                           |
| alerts_received_count          | alerts received (a running total)                               |
| alerts_invalid_count           | alerts refused as invalid (a running total)                     |
| silences_active                | silences in force                                               |
| silences_pending               | silences not yet started                                        |
| silences_expired               | silences ended and still kept                                   |
| receivers                      | receivers configured                                            |
| integrations                   | integrations in them (a webhook, an email, a pager)             |
| inhibition_rules               | inhibition rules configured                                     |
| aggregation_groups             | groups of alerts being held for notification                    |
| aggregation_limit_reached_coun | alerts that could not be grouped: the limit on groups was       |
| t                              | reached (a running total)                                       |
| fds_pct                        | open files, as a percentage of its limit                        |
+--------------------------------+-----------------------------------------------------------------+
| GOOD  up 1; ready 1; config_reload_ok 1; alerts_invalid_count not moving.                        |
| WATCH alerts_active when you expect none; silences_active that nobody remembers setting;         |
|       alerts_suppressed far above alerts_active (a silence or an inhibition hiding a lot).       |
| BAD   up 0 or ready 0: no alert reaches anyone through it; config_reload_ok 0 (an edit it        |
|       refused: routes and receivers are the old ones); alerts_received_count not moving while    |
|       Prometheus has alerts firing: they are not arriving; aggregation_limit_reached_count       |
|       moving.                                                                                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| alertmanager_notifications   alertmanager.notifications.<metric>   every 1m                      |
+----------------------------+---------------------------------------------------------------------+
| up                         | 1 when Alertmanager answered its metrics page, else 0 (and nothing  |
|                            | more is read)                                                       |
| notifications_count        | notifications attempted (a running total)                           |
| notifications_failed_count | notifications that failed (a running total)                         |
| failed_pct                 | of all attempted since it started, the percentage that failed       |
| sent                       | notifications attempted by each integration, tagged                 |
|                            | integration=<its kind>                                              |
| failed                     | those that failed, for each integration, tagged integration         |
| failed_reason              | those that failed, for each reason Alertmanager gives, tagged       |
|                            | reason=<clientError, serverError, contextDeadlineExceeded, other    |
|                            | ...>                                                                |
| requests_count             | requests made to the services notified (a running total)            |
| requests_failed_count      | requests that failed (a running total)                              |
| latency_avg_seconds        | how long a notification took, on average since it started           |
| ..._not_shown              | past 100 of a list (sent, failed, failed_reason), how many were     |
|                            | left out                                                            |
+----------------------------+---------------------------------------------------------------------+
| GOOD  notifications_failed_count not moving while notifications_count does.                      |
| WATCH failed_pct above a few percent; latency_avg_seconds climbing (a slow webhook holds up the  |
|       group behind it).                                                                          |
| BAD   notifications_failed_count moving: failed says which integration and failed_reason why     |
|       (clientError: a bad URL, token or payload; serverError: the service is failing;            |
|       contextDeadlineExceeded: it does not answer in time). An alert that is not delivered is an |
|       outage nobody hears about.                                                                 |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| alertmanager_cluster   alertmanager.cluster.<metric>   every 1m                                  |
+----------------------------+---------------------------------------------------------------------+
| up                         | 1 when Alertmanager answered its metrics page, else 0 (and nothing  |
|                            | more is read)                                                       |
| cluster_enabled            | 1 when clustering is on, else 0                                     |
| members                    | members this one sees, itself included                              |
| failed_peers               | peers it has lost and is trying to reach                            |
| health_score               | 0 when its gossip is healthy; higher, the worse                     |
| peer_position              | its position among the members (0 is first to notify)               |
| messages_queued            | gossip messages waiting to be sent                                  |
| messages_pruned_count      | messages dropped from a full queue (a running total)                |
| reconnections_count        | reconnections to peers attempted (a running total)                  |
| reconnections_failed_count | reconnections that failed (a running total)                         |
| peers_joined_count         | peers that joined (a running total)                                 |
| peers_left_count           | peers that left (a running total)                                   |
+----------------------------+---------------------------------------------------------------------+
| GOOD  members the number you run, on every member; failed_peers 0; health_score 0.               |
| WATCH peers_left_count or reconnections_failed_count moving (a member restarting, or a network   |
|       that drops); messages_queued growing.                                                      |
| BAD   members below the number you run, or failed_peers above 0: the cluster is split, and each  |
|       side notifies on its own: expect duplicate notifications, and silences set on one side     |
|       missing on the other; health_score staying above 0.                                        |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the stack in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `alertmanager.up`, `ready` | 1 |  | 0: no alert reaches anyone through it | `up 0` where nothing listened |
| `alertmanager.config_reload_ok` | 1 |  | 0: an edit it refused. Routes and receivers are the old ones | 0 after a file with a broken line and a reload; 1 again once mended |
| `alertmanager.notifications.notifications_failed_count` | Flat |  | Rising: `failed` says which integration, `failed_reason` why | Rising: every notification to the webhook nothing listened to |
| `alertmanager.notifications.failed_pct` | 0 | A few percent | Most of them: a receiver is broken | 100 on the member second in line, which sends only what the first could not; lower on the first |
| `alertmanager.cluster.members` | The number you run |  | Fewer: the cluster is split. Expect duplicate notifications | 2; then 1 when the other member stopped |
| `alertmanager.cluster.failed_peers` | 0 |  | Above 0: a peer is lost and being retried | 1 when the other member stopped; 0 again when it came back |
| `alertmanager.alerts_invalid_count` | Flat | Rising: a sender posts alerts it cannot read |  | Not caused |

## How it was tested

**Tested** on 2026-11-25 by `tests/integration/backends/scripts/run-obs.sh`, against `compose.obs.yaml`: one stack of all nine services wired together as they are in use, each in trouble on purpose. **Prometheus 3.15.1** (two targets down and one that answers without metrics, a rule group that cannot be evaluated, an Alertmanager that is not there, a remote write nothing answers and one that is refused), **Alertmanager 0.35.1** (two in a cluster; a receiver nothing listens to), **Grafana 13.2.5** (a data source nothing answers, an alert rule that reads it, a contact point nothing listens to), **Loki 3.7.9** (entries too old, lines too long), **Mimir 3.2.6** (a tenant held at 200 series), **Tempo 2.10.10** (traces larger than its limit), **the OpenTelemetry Collector 0.166.0** (an exporter nothing answers, whose queue fills; a receiver that must refuse), **VictoriaMetrics 1.157.0** (a scrape target down, queries that fail) and **VictoriaLogs 1.54.0** (entries older than its retention), in Docker, with traces, metrics and logs flowing through all of it.

- **On Fedora** (Fedora 44, bash 5.3): every job of every pack and what each must have read; a token Grafana refuses, a page that is not there, and nothing answering; then the stack broken further, live (Tempo stopped, and seen by its own pack and by Prometheus', the Collector's and Grafana's; an Alertmanager leaving its cluster; a configuration Prometheus refuses, then Alertmanager): **84 passed, 0 failed**. Then `service-packs.sh` through Vigil, for all nine packs (enable, and that CPU and memory are the base pack's; precheck; every job; a service that does not answer read as `up 0`; Grafana's token kept as a secret and written nowhere; the metrics reaching the backend): **95 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-25/fedora/pack-obs/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own awk), against the same stack through SSH tunnels: every job and the same checks, **69 passed, 0 failed**; through Vigil, **95 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-25/macos/pack-obs-macos/console.txt)).
- **On Windows**, as an account that is not an administrator, against the same stack through SSH tunnels: every job, each compared with what the Linux script printed a moment before (the same readings, by name and tag, for all 28 jobs), the faults read again, then `Service-Packs.ps1` through Vigil. On Windows 11 under Windows PowerShell 5.1 and under PowerShell 7, and on Windows Server 2025 under Windows PowerShell 5.1: **79 passed, 0 failed** and **76 passed, 0 failed** on each ([Windows 11](../../tests/integration/backends/reports/runs/2026-11-25/windows/pack-obs-windows/console.txt), [under PowerShell 7](../../tests/integration/backends/reports/runs/2026-11-25/windows/pack-obs-windows/console-powershell7.txt), [Server 2025](../../tests/integration/backends/reports/runs/2026-11-25/windows-server-2025/pack-obs-windows/console.txt)). Over SSH, Windows refuses its data protection to a logon with no password, so there the suite gives Grafana's token by an `env:` reference; at a console, `vigil secret set` keeps it.
- **The two engines**, bash with awk and PowerShell, were compared line for line over all nine services' pages with a table that uses every operation on every metric: 12,873 readings, none differing, between gawk, mawk, macOS' awk, busybox's, Windows PowerShell 5.1 and PowerShell 7 (`tools/obs/DESIGN.md`).

**What the tests found.** In a cluster, one member sends each notification and tells the others, who then do not. So a notification that gets through is counted on one member only, and the member second in line may show every attempt of its own as failed: read `notifications_count` and `notifications_failed_count` summed over the members.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
