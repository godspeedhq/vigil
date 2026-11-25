# The grafana pack

A Grafana, from what it says about itself and, for its data sources, from its API with a read-only token. The pack reads whether it is healthy (its database too); the requests it answered and those that failed; its database connections; whether each data source answers; and its own alerting: rules evaluated and failed, alerts in each state, and the notifications that got through and did not.

A dashboard that shows nothing looks the same whether the system is quiet or the data source is gone. And Grafana's alert rules stop evaluating, without a sound, when the data source they read stops answering.

**Read-only: every request is a GET.** The pack reads Grafana's own pages and changes nothing, whatever its login would allow. It needs `curl` and `awk` (and `jq` for the data sources) on Linux and macOS, and nothing but PowerShell on Windows.

1. Nothing to turn on for two of its three jobs: Grafana serves `/metrics` (unless `[metrics] enabled = false`) and `/api/health` already.
2. **For the datasources job, a token that may only view.** In Grafana: Administration, Users and access, Service accounts; add one with the role **Viewer**, and a token for it. Then `vigil secret set GRAFANA_TOKEN` and paste it. A Viewer may list the data sources and ask each for its health; it can change nothing. With no token to give, turn that one job off: `vigil pack disable grafana_datasources`.
3. `vigil pack enable grafana`, then in `vigil.config` set what differs from the defaults: `GRAFANA_URL` (`http://localhost:3000`; with `serve_from_sub_path`, that path too). Where `/metrics` asks for a login (`[metrics] basic_auth_username`): `GRAFANA_USER` with `secret = GRAFANA_PASSWORD=secret:GRAFANA_PASSWORD` on the status and alerting jobs.

**Grafana that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (a login refused on a page every job needs, or something that is not HTTP), and says why.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `awk`, `jq` | `curl`, `awk` (built in), `jq` (Homebrew; macOS 15 has it) | Nothing: PowerShell 5.1 or later, and .NET |
| Grafana | Grafana 10 and later (tested: 13.2.5) | | |
| Its address | reachable from the Vigil machine: `GRAFANA_URL` (default `http://localhost:3000`) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `grafana_status` | Up and healthy (its database too); version; dashboards, users, alert rules, data sources by kind; requests, 4xx and 5xx; database connections and waits; plugin requests that failed, for each plugin | minute |
| `grafana_alerting` | Rules scheduled; evaluations, and those that failed; alerts in each state (alerting, pending, no data, error); how far the scheduler is behind; notifications sent and failed, for each integration; silences | minute |
| `grafana_datasources` | Each data source (the first 20 by name): whether it answered Grafana's own check; how many are failing | 5 minutes |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `grafana.up`.

```text
+--------------------------------------------------------------------------------------------------+
| grafana_status   grafana.<metric>   every 1m                                                     |
+-----------------------+--------------------------------------------------------------------------+
| up                    | 1 when Grafana answered its metrics page, else 0 (and nothing more is    |
|                       | read)                                                                    |
| healthy               | 1 when /api/health answers 200 (Grafana and its database are up), else 0 |
| version               | always 1, tagged version=<its version> and edition=<oss or enterprise>   |
| uptime_seconds        | seconds since it started                                                 |
| dashboards            | dashboards it holds                                                      |
| users                 | users it has                                                             |
| active_users          | of those, seen in the last 30 days                                       |
| alert_rules           | alert rules it holds                                                     |
| datasources           | data sources configured                                                  |
| datasources_by_type   | the same, for each kind, tagged type=<prometheus, loki, ...>             |
| http_requests_count   | requests answered (a running total)                                      |
| http_4xx_count        | of those, answered 4xx: not logged in, not allowed, not found (a running |
|                       | total)                                                                   |
| http_5xx_count        | answered 5xx: Grafana failed (a running total)                           |
| requests_in_flight    | requests in hand now                                                     |
| db_connections        | connections to its database open                                         |
| db_connections_in_use | of those, in use                                                         |
| db_connections_max    | the most it may open (0: no limit)                                       |
| db_waits_count        | times a request had to wait for a connection (a running total)           |
| plugin_requests_count | requests to its plugins, data sources above all (a running total)        |
| plugin_errors_count   | of those, the ones that failed (a running total)                         |
| plugin_errors         | the same, for each plugin, tagged plugin=<its id>                        |
| live_clients          | browsers connected to Grafana Live                                       |
| ..._not_shown         | past 100 of a list (datasources_by_type, plugin_errors), how many were   |
|                       | left out                                                                 |
+-----------------------+--------------------------------------------------------------------------+
| GOOD  up 1; healthy 1; http_5xx_count and plugin_errors_count not moving.                        |
| WATCH db_waits_count moving (requests queue for the database: raise max_open_conn, or the        |
|       database is slow); http_4xx_count climbing (logins failing, or a dashboard asking for what |
|       is gone).                                                                                  |
| BAD   up 0 or healthy 0: nobody can open a dashboard, and its alert rules are not evaluated;     |
|       http_5xx_count moving; plugin_errors_count moving: a data source is failing, plugin_errors |
|       says which kind, and the datasources job which one.                                        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| grafana_alerting   grafana.alerting.<metric>   every 1m                                          |
+----------------------------+---------------------------------------------------------------------+
| up                         | 1 when Grafana answered its metrics page, else 0 (and nothing more  |
|                            | is read)                                                            |
| rules                      | alert rules it evaluates                                            |
| rule_groups                | rule groups they are in                                             |
| evaluations_count          | rule evaluations (a running total)                                  |
| evaluation_failures_count  | evaluations that failed: the query could not be run (a running      |
|                            | total)                                                              |
| evaluation_failures_pct    | of all since it started, the percentage that failed                 |
| alerts                     | alert instances in each state, tagged state=<alerting, pending,     |
|                            | nodata, error, normal, recovering>                                  |
| alerts_alerting            | alert instances firing                                              |
| alerts_error               | alert instances whose rule cannot be evaluated                      |
| alerts_nodata              | alert instances whose query brings nothing back                     |
| scheduler_behind_seconds   | how far its scheduler is behind where it should be                  |
| last_tick_seconds          | seconds since its scheduler last ticked                             |
| notifications_count        | notifications attempted (a running total)                           |
| notifications_failed_count | notifications that failed (a running total)                         |
| notifications_failed       | the same, for each integration, tagged integration=<webhook, email, |
|                            | slack ...>                                                          |
| silences_active            | silences in force                                                   |
| alerts_received_count      | alerts its rules sent to its Alertmanager (a running total)         |
| alerts_invalid_count       | of those, refused as invalid (a running total)                      |
| ..._not_shown              | past 100 of a list (alerts, notifications_failed), how many were    |
|                            | left out                                                            |
+----------------------------+---------------------------------------------------------------------+
| GOOD  evaluation_failures_count and notifications_failed_count not moving; alerts_error and      |
|       alerts_nodata 0; last_tick_seconds under a minute.                                         |
| WATCH alerts_nodata above 0 (a query that stopped bringing data back: a renamed metric, a target |
|       gone); scheduler_behind_seconds above 0.                                                   |
| BAD   evaluation_failures_count moving, or alerts_error above 0: a rule cannot be evaluated, so  |
|       it cannot fire (its data source is down: the datasources job says which);                  |
|       notifications_failed_count moving: alerts fire and reach nobody, and notifications_failed  |
|       says through which integration; last_tick_seconds growing: alerting has stopped;           |
|       alerts_alerting, which is what the rules are for.                                          |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| grafana_datasources   grafana.datasources.<metric>   every 5m                                    |
+---------------------+----------------------------------------------------------------------------+
| up                  | 1 when Grafana answered, else 0                                            |
| login_ok            | 1 when the token (or the user) may list the data sources; 0 when there is  |
|                     | none, or it is refused (and nothing more is read)                          |
| datasource_ok       | 1 when the data source answered Grafana's check, else 0; tagged name=<its  |
|                     | name> and type=<its kind>                                                  |
| datasources         | data sources configured                                                    |
| datasources_failing | of those checked, the ones that did not answer                             |
| ..._not_shown       | past 100 of a list (datasources), how many were left out                   |
+---------------------+----------------------------------------------------------------------------+
| GOOD  login_ok 1; datasources_failing 0.                                                         |
| WATCH datasources_not_shown above 0: only the first 20 by name are checked.                      |
| BAD   datasources_failing above 0: datasource_ok 0 names it. Its dashboards are empty and the    |
|       alert rules that read it error (the alerting job) until it answers again; login_ok 0: the  |
|       token is missing, expired or revoked, and this job sees nothing.                           |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the stack in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `grafana.up`, `healthy` | 1 |  | 0: nobody can open a dashboard, and its alert rules are not evaluated | `up 0` where nothing listened |
| `grafana.datasources.datasources_failing` | 0 |  | Above 0: `datasource_ok 0` names it. Its dashboards are empty and its alert rules error | 1: `name=Dead`; 2 with Tempo stopped (`name=Tempo`) |
| `grafana.datasources.login_ok` | 1 |  | 0: the token is missing, expired or revoked: the job sees nothing | 0 with a token it refused, and with none |
| `grafana.alerting.evaluation_failures_count`, `alerts_error` | Flat; 0 |  | Rising; above 0: a rule cannot be evaluated, so it cannot fire | Rising, a third of all evaluations; `alerts_error 1`: the rule reading the dead data source |
| `grafana.alerting.notifications_failed_count` | Flat |  | Rising: alerts fire and reach nobody; `notifications_failed` says through which integration | Rising: every notification, through `integration=webhook` |
| `grafana.alerting.alerts_nodata` | 0 | Above 0: a query that brings nothing back |  | Not caused |
| `grafana.alerting.last_tick_seconds` | Under a minute |  | Rising: alerting has stopped | 0 to 10 |
| `grafana.http_5xx_count` | Flat |  | Rising: Grafana is failing requests | Not caused |
| `grafana.db_waits_count` | Flat | Rising: requests queue for the database |  | Not caused |

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
