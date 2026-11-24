# The iis pack

IIS on this Windows machine, read by an account that is **not an administrator**. The pack reads its sites (connections, requests by method, 404s, bytes, uptime), its application pools (each pool's state, its worker processes, recycles, worker failures and the time since the last, and its request queue in HTTP.sys: requests waiting, how long the oldest has waited, requests turned away), its worker processes (requests running and served, threads, the share of 500, 404, 403 and 401 they sent, their caches), each site's log minute by minute (statuses with their sub-status, the 5xx share, time-taken from p50 to p99, Windows errors) **and HTTP.sys's own error log** (the requests it turned away before any site saw them, by reason and pool), its events (pools stopped by rapid-fail protection, worker processes that crashed or hung, recycles), and the certificates its https bindings serve. Windows only: there is no Linux or macOS script.

**No administrator, and nothing to install.** IIS's configuration (`applicationHost.config`, the WebAdministration module) is closed to an account that is not an administrator, so the pack never reads it: it reads what Windows opens to a monitoring account instead. The performance counters, the event logs, the logs it is given access to, and `netsh http show sslcert`, which any account may read. Every job only reads.

1. **The groups.** The account Vigil runs as must be in **Performance Monitor Users** (the counters) and **Event Log Readers** (the events). The Vigil service's own account, LocalSystem, already may; for another account, as an administrator:

   ```powershell
   Add-LocalGroupMember -Group 'Performance Monitor Users' -Member vigil
   Add-LocalGroupMember -Group 'Event Log Readers' -Member vigil
   ```

2. **For the log job, read access to the logs** (LocalSystem already may):

   ```powershell
   icacls C:\inetpub\logs\LogFiles /grant "vigil:(OI)(CI)RX"
   icacls C:\Windows\System32\LogFiles\HTTPERR /grant "vigil:(OI)(CI)RX"
   ```

   Until then the job reports `log_readable 0` (and `httperr_readable 0`) and nothing more, and the run succeeds.
3. `vigil pack enable iis`. Nothing to set for a default IIS: `IIS_LOG_DIR` and `IIS_HTTPERR_DIR` say where the logs are when you moved them, `IIS_TLS` names the https endpoints yourself instead of the bindings, and `IIS_CACERT` checks a private CA.

**IIS that does not run is a reading**, `up 0`, and the run succeeds.

**Sites in the log job are named by their folder** (`W3SVC2`): reading their names would need IIS's configuration. IIS Manager shows each site's ID.

**On a Windows that is not in English** the performance counters have other names: the counter jobs read the English ones, and report `up 0` there. The log, events and certificate jobs work in any language.

## What it needs

| | Windows |
| --- | --- |
| On the Vigil machine | Nothing: Windows PowerShell 5.1 or PowerShell 7, `Get-Counter`, `Get-WinEvent`, `netsh` |
| IIS | 10, on Windows Server 2016 and later (tested on Windows Server 2025) |
| The account | Performance Monitor Users and Event Log Readers (step 1); not an administrator |
| The logs | read access (step 2) |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `iis_sites` | Up and uptime; each site: uptime (0: stopped), connections now and the most, requests by method, 404s, locked errors, bytes sent and received, users, CGI and ISAPI requests running | minute |
| `iis_pools` | Each application pool, the ones not running first: its state, worker processes against its most, uptime, recycles, worker failures (all, recent, pings, starts, stops) and the time since the last; its HTTP.sys request queue: waiting, the oldest's age, turned away, arrival and rejection rates | minute |
| `iis_workers` | Each worker process (w3wp.exe), the busiest first: requests running and served, threads against the most, the share of 500, 404, 403 and 401 it sent, websockets, its caches and their memory | minute |
| `iis_log` | Each site's log, the minute before last: requests, by status class and by status with sub-status, by method, Windows errors, time-taken (average, p50, p90, p99, slowest); HTTP.sys's error log: requests turned away, by reason, status and pool | minute |
| `iis_events` | The last hour's events of WAS and W3SVC: pools stopped by rapid-fail protection, worker crashes, workers that did not answer a ping or failed to start, recycles, idle shutdowns; each kind by pool | 5 minutes |
| `iis_tls` | Every https binding in HTTP.sys: answering TLS, days until its certificate expires, within its dates, trusted (and why not), its issuer and the TLS version | 15 minutes |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `iis.up`.

```text
+--------------------------------------------------------------------------------------------------+
| iis_sites   iis.<metric>   every 1m                                                              |
+---------------------------+----------------------------------------------------------------------+
| up                        | 1 when IIS's web service (W3SVC) answers with its counters, else 0   |
| uptime_seconds            | since the web service started                                        |
| sites                     | sites                                                                |
| connections               | connections now, all sites together                                  |
| site_uptime_seconds       | since the site started, tagged site=<its name> (0: stopped)          |
| site_connections          | connections now, tagged site                                         |
| site_connections_max      | the most at once since it started, tagged site                       |
| site_requests_count       | requests (a running total), tagged site                              |
| site_method_count         | requests by method (a running total), tagged site and method=<get,   |
|                           | post, head, put, delete, options or other>                           |
| site_not_found_count      | answers 404 (a running total), tagged site                           |
| site_locked_count         | requests refused because the file was locked (423), tagged site      |
| site_bytes_sent_count     | bytes sent (a running total), tagged site                            |
| site_bytes_received_count | bytes received (a running total), tagged site                        |
| site_users                | users now, tagged site and kind=<anonymous or authenticated>         |
| site_cgi_running          | CGI and ISAPI requests running now, tagged site                      |
| ..._not_shown             | past 100 of a list (sites), how many were left out                   |
+---------------------------+----------------------------------------------------------------------+
| GOOD  up 1; every site_uptime_seconds above 0; site_not_found_count rising slowly (graph the     |
|       _count totals as rates).                                                                   |
| WATCH site_not_found_count rising fast (a broken link, a scan); site_connections near what the   |
|       site should see.                                                                           |
| BAD   up 0: IIS does not serve; site_uptime_seconds 0: that site is stopped.                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| iis_pools   iis.pools.<metric>   every 1m                                                        |
+-------------------------+------------------------------------------------------------------------+
| up                      | 1 when IIS's process activation service (WAS) answers with its         |
|                         | counters, else 0                                                       |
| pools                   | application pools                                                      |
| pools_not_running       | of those, not running (stopped, or starting, or stopping)              |
| state                   | its state: 1 uninitialized, 2 initialized, 3 running, 4 disabling, 5   |
|                         | stopped, 6 shutting_down, 7 deleting; tagged pool=<its name> and       |
|                         | status=<the word>                                                      |
| worker_processes        | worker processes now, tagged pool                                      |
| worker_processes_max    | the most it may run (its web garden), tagged pool                      |
| uptime_seconds          | since it last started, tagged pool                                     |
| recycles_count          | times it recycled (a running total), tagged pool                       |
| worker_failures_count   | its worker processes that failed (a running total), tagged pool        |
| recent_failures         | of those, recently (rapid-fail protection counts these), tagged pool   |
| ping_failures_count     | worker processes that did not answer a ping, tagged pool               |
| startup_failures_count  | worker processes that failed to start, tagged pool                     |
| shutdown_failures_count | worker processes that failed to stop, tagged pool                      |
| since_failure_seconds   | since its last worker process failed, tagged pool                      |
| queue                   | requests waiting in HTTP.sys for a worker, tagged pool                 |
| queue_oldest_ms         | how long the oldest of those has waited, tagged pool                   |
| rejected_count          | requests HTTP.sys turned away (a running total), tagged pool           |
| arrival_rate            | requests arriving a second, tagged pool                                |
| rejection_rate          | requests turned away a second, tagged pool                             |
| cache_hit_rate          | answers from HTTP.sys's own cache a second, tagged pool                |
| ..._not_shown           | past 100 of a list (pools), how many were left out                     |
+-------------------------+------------------------------------------------------------------------+
| GOOD  every state 3 (running); queue 0; recent_failures 0; rejected_count flat.                  |
| WATCH recycles_count rising faster than scheduled; queue above 0; worker_processes 0 for a pool  |
|       that should be warm (idle time-out).                                                       |
| BAD   state 5 (stopped): the pool answers 503, by hand or by rapid-fail protection (iis_events   |
|       says which); recent_failures rising: workers crash; rejected_count rising: requests turned |
|       away (queue full, or the pool stopped).                                                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| iis_workers   iis.workers.<metric>   every 1m                                                    |
+------------------------+-------------------------------------------------------------------------+
| workers                | worker processes, all pools together                                    |
| active_requests        | requests it is running now, tagged pool=<its pool> and pid=<its process |
|                        | id>                                                                     |
| requests_count         | requests it served (a running total), tagged pool and pid               |
| requests_rate          | requests a second, tagged pool and pid                                  |
| threads_active         | threads busy with a request, tagged pool and pid                        |
| threads                | threads it has, tagged pool and pid                                     |
| threads_max            | the most it may have, tagged pool and pid                               |
| sent_500_pct           | its answers that were 500, as a percentage, tagged pool and pid         |
| sent_404_pct           | its answers that were 404, tagged pool and pid                          |
| sent_403_pct           | its answers that were 403, tagged pool and pid                          |
| sent_401_pct           | its answers that were 401, tagged pool and pid                          |
| websockets             | websocket requests open, tagged pool and pid                            |
| file_cache_bytes       | memory of its file cache, tagged pool and pid                           |
| output_cache_bytes     | memory of its output cache, tagged pool and pid                         |
| uri_cache_hits_count   | URIs found in its cache (a running total), tagged pool and pid          |
| uri_cache_misses_count | URIs not found in it, tagged pool and pid                               |
| ..._not_shown          | past 100 of a list (workers), how many were left out                    |
+------------------------+-------------------------------------------------------------------------+
| GOOD  sent_500_pct near 0; active_requests low; threads_active below threads_max.                |
| WATCH active_requests climbing: requests run longer, or pile up; sent_404_pct rising.            |
| BAD   sent_500_pct above a few percent: the application fails; threads_active at threads_max:    |
|       the worker has no thread left for a new request.                                           |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| iis_log   iis.log.<metric>   every 1m                                                            |
+------------------+-------------------------------------------------------------------------------+
| log_readable     | 1 when this account may read the site logs, else 0 (and they are not read)    |
| sites_logging    | site log folders read                                                         |
| window_complete  | 1 when each log's whole minute was read; 0 when one grew faster than          |
|                  | IIS_LOG_MAX_MB                                                                |
| requests         | requests logged in the minute, tagged site=<W3SVC and its id>                 |
| status_2xx       | of those, answered 2xx, tagged site (and status_1xx, _3xx, _4xx, _5xx)        |
| status_1xx       | answered 1xx, tagged site                                                     |
| status_3xx       | answered 3xx, tagged site                                                     |
| status_4xx       | answered 4xx, tagged site                                                     |
| status_5xx       | answered 5xx, tagged site                                                     |
| errors_5xx_pct   | 5xx, as a percentage of its requests, tagged site                             |
| status           | requests answered with one status, tagged site and code=<status.sub-status,   |
|                  | 500.0>                                                                        |
| method           | requests by method, tagged site and method                                    |
| win32_errors     | requests Windows recorded an error for (sc-win32-status not 0: a client that  |
|                  | went away, a connection reset), tagged site                                   |
| time_avg_ms      | time-taken, on average, tagged site                                           |
| time_p50_ms      | half the requests took less, tagged site                                      |
| time_p90_ms      | 90% took less, tagged site                                                    |
| time_p99_ms      | 99% took less, tagged site                                                    |
| time_max_ms      | the slowest, tagged site                                                      |
| httperr_readable | 1 when this account may read HTTP.sys's error log, else 0                     |
| rejected_total   | requests HTTP.sys turned away in the minute                                   |
| rejected         | of those, by reason and pool, tagged reason=<HTTP.sys's word: AppOffline,     |
|                  | QueueFull, Disabled, Timer_ConnectionIdle, Connection_Dropped...>,            |
|                  | status=<what it answered> and queue=<the pool>                                |
| ..._not_shown    | past 100 of a list (sites), how many were left out                            |
+------------------+-------------------------------------------------------------------------------+
| GOOD  errors_5xx_pct below 1; rejected_total 0; time_p99_ms steady.                              |
| WATCH time_p99_ms rising; win32_errors rising (clients giving up); rejected with reason=Timer_*: |
|       connections that idled out.                                                                |
| BAD   errors_5xx_pct above a few percent (status says which: 500.0 the application, 503 the      |
|       pool); rejected with reason=AppOffline, Disabled or QueueFull: a pool stopped, crashed or  |
|       overwhelmed, and its requests turned away before IIS saw them.                             |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| iis_events   iis.events.<metric>   every 5m                                                      |
+----------------------+---------------------------------------------------------------------------+
| readable             | 1 when this account may read the event logs, else 0                       |
| events               | IIS's events in the last hour                                             |
| errors               | of those, errors and critical ones                                        |
| warnings             | warnings                                                                  |
| rapid_fail_count     | application pools stopped by rapid-fail protection (event 5002)           |
| crashes_count        | worker processes that ended unexpectedly (5009, 5011)                     |
| unresponsive_count   | worker processes that did not answer a ping (5010)                        |
| start_failures_count | worker processes or pools that failed to start (5053, 5057, 5059, 5085)   |
| recycles_count       | recycles: on schedule, on memory, on requests, on a configuration change  |
|                      | (5074 to 5081, 5117)                                                      |
| idle_shutdowns_count | worker processes shut down for being idle (5186)                          |
| event                | events of one kind, tagged id=<the event id>, pool=<the pool it names, or |
|                      | none> and level=<error, warning or information>                           |
| ..._not_shown        | past 100 of a list (events), how many were left out                       |
+----------------------+---------------------------------------------------------------------------+
| GOOD  rapid_fail_count 0; crashes_count 0; unresponsive_count 0.                                 |
| WATCH recycles_count above what the schedule makes; crashes_count above 0 once.                  |
| BAD   rapid_fail_count above 0: a pool was stopped after its workers kept failing, and stays     |
|       stopped until someone starts it (event says which); crashes_count or unresponsive_count    |
|       rising: the application crashes or hangs.                                                  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| iis_tls   iis.tls.<metric>   every 15m                                                           |
+-------------------+------------------------------------------------------------------------------+
| bindings_found    | https bindings found in HTTP.sys (when IIS_TLS is not set)                   |
| tls_up            | 1 when the endpoint finished a TLS handshake, else 0; tagged                 |
|                   | endpoint=<host:port, or host:port/name>                                      |
| cert_expires_days | days until the certificate it served expires (below 0: expired), tagged      |
|                   | endpoint                                                                     |
| cert_valid        | 1 when today is within its dates, else 0, tagged endpoint                    |
| cert_verified     | 1 when it checks against the trusted CAs (or IIS_CACERT) and the name, else  |
|                   | 0; tagged endpoint and reason=<openssl's, or Windows' word>                  |
| cert_info         | always 1, tagged endpoint, issuer=<its CN> and protocol=<the TLS version     |
|                   | agreed>                                                                      |
| ..._not_shown     | past 100 of a list (certs), how many were left out                           |
+-------------------+------------------------------------------------------------------------------+
| GOOD  tls_up 1; cert_expires_days above 30; cert_verified 1.                                     |
| WATCH cert_expires_days below 30: renewal should have happened by now.                           |
| BAD   cert_expires_days below 7, or cert_valid 0: clients will refuse it; cert_verified 0:       |
|       clients that check refuse it now (reason says why); tls_up 0: the binding does not answer. |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what IIS in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `iis.up` | 1 |  | 0: IIS does not serve (W3SVC stopped) | Not caused: stopping IIS takes an administrator |
| `iis.site_uptime_seconds` | Above 0 |  | 0: that site is stopped | Above 0 for every site |
| `iis.site_not_found_count` (a rate) | Low | Rising fast: a broken link, or a scan |  | 50 for vigil-ok, its total across the runs |
| `iis.pools.state` | 3 (running) |  | 5 (stopped): the pool answers 503, by hand or by rapid-fail protection | 5 for `vigil-stopped` (by hand) and `vigil-crash` (by rapid-fail protection), listed first |
| `iis.pools.rejected_count` (a rate) | Flat |  | Rising: requests turned away (a stopped pool, a full queue) | 36 for `vigil-stopped`, its total across the runs |
| `iis.pools.recent_failures`, `worker_failures_count` | 0 |  | Rising: worker processes crash | `worker_failures_count 3` for `vigil-crash` |
| `iis.pools.queue`, `queue_oldest_ms` | 0 | Above 0: requests wait for a worker |  | 0 |
| `iis.workers.active_requests` | Low | Climbing: requests run longer, or pile up |  | 4 in vigil-ok's worker, the four 10-second requests |
| `iis.workers.sent_500_pct` | Near 0 |  | Above a few percent: the application fails | Its cooked rate: 0 between our bursts |
| `iis.log.errors_5xx_pct` | Below 1 |  | Above a few percent; `status` says which (500.0, 503.x) | 100 for vigil-fail (W3SVC3): seven 500.0 |
| `iis.log.time_p99_ms` | Steady | Rising |  | 103 ms for vigil-ok, 89 ms for vigil-fail |
| `iis.log.rejected` | None | `reason=Timer_*`: connections that idled out | `reason=Disabled`, `AppOffline` or `QueueFull`: requests turned away before any site saw them | 7 `reason=Disabled status=503 queue=vigil-stopped`; after the crashes, 3 `reason=AppOffline status=503 queue=vigil-crash` |
| `iis.events.rapid_fail_count`, `crashes_count` | 0 | `crashes_count` above 0 once | `rapid_fail_count` above 0: a pool stopped, and stays stopped until started | 1 and 3: event 5002 and three 5011, all naming `vigil-crash` |
| `iis.tls.cert_expires_days`, `cert_verified` | Above 30; 1 | Below 30 | Below 7; 0 | 9 for the binding's certificate (made to expire in 10 days); 1 against its own public half |

## How it was tested

**Tested** on 2026-11-24 on Windows Server 2025 (build 26100), IIS 10, by `tests/windows-server/Run-Iis.ps1`, as `vigil-test`, an account that is not an administrator (in Performance Monitor Users and Event Log Readers, given read access to the logs), over SSH. `tests/windows-server/Enable-IIS.ps1` (its owner runs it once, elevated) turned IIS on and set up four sites in trouble on purpose: one that answers (with https, its certificate made to expire in 10 days, and a page that takes 10 seconds), one whose page answers 500, one whose pool is stopped, and one whose page crashes its worker process. The run sends a minute of traffic of every kind, runs every job on the minute IIS writes that minute out, with slow requests in flight, and checks what they read; then a log the account may not read; then the crash, three times, until rapid-fail protection stops the pool; then `Service-Packs.ps1` through Vigil (enable, and that CPU and memory are the base pack's; precheck; every Windows job; the metrics reaching the backend).

- **The run with the crash test**: every job directly, **36 passed, 0 failed**; through Vigil, **8 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/windows-server-2025/pack-iis-crash/console.txt)). Its own https test requests failed in the test runner (a PowerShell certificate check .NET called on a thread where a script block cannot run), not in the pack: fixed for the run below.
- **The run after it**, with https traffic: **30 passed, 0 failed**, and through Vigil **8 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/windows-server-2025/pack-iis/console.txt)). Its crash checks were left out: the run before had stopped that pool, and starting it again takes an administrator (`Enable-IIS.ps1 -Reset`).

The pack is the same in both runs.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
