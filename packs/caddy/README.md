# The caddy pack

A Caddy server, from its admin API. The pack reads what its configuration serves (HTTP servers, their addresses, routes, site names, reverse proxies, file servers, certificate policies), whether the last configuration change loaded and how long ago, its goroutines and its open files against its limit; the traffic each server handles (requests, those in flight, handler errors, answers by status class, the average time to answer); every upstream of its reverse proxies (the requests it handles now, its recent failures, and, where Caddy checks them, healthy or not); and the certificate of every site it serves, found in its configuration (days left, within their dates, trusted, the TLS version). Certificates Caddy's own local CA issued check against that CA. Linux, macOS and Windows.

**The admin API, GET only, and `curl`, `jq` and `openssl`.** Caddy's admin API could change its configuration: the pack only ever reads it. A certificate is read from a TLS handshake: nothing else is sent.

1. **The admin API**, which Caddy serves on `localhost:2019` unless told otherwise. Leave it there, reachable from this machine only; if you moved it, the jobs' `CADDY_ADMIN` says where.
2. **For the traffic job, Caddy's HTTP metrics**, in the Caddyfile's global options, then reload Caddy:

   ```caddyfile
   {
       metrics
   }
   ```

   Without them, `caddy_traffic` says `metrics_enabled 0` and nothing else, and no run fails.
3. `vigil pack enable caddy`, then in `vigil.config` set what differs from the defaults, in the jobs' `env` lines: `CADDY_ADMIN` (`http://localhost:2019`), `CADDY_TLS_ADDRESS` (where its sites answer https, `127.0.0.1:443`), or `CADDY_TLS` to name the endpoints yourself instead (`127.0.0.1:443/shop.example.com`), and for a CA of your own, `CADDY_CACERT`.

**Caddy that does not answer is a reading**, `up 0`, and the run succeeds. An address that answers but is not Caddy's admin API fails the run.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `jq`, `openssl` | `curl`, `jq` (Homebrew; macOS 15 has it), `openssl` (built in) | Nothing: `Invoke-WebRequest`, `ConvertFrom-Json` and .NET |
| Caddy | 2.6 and later | | |
| The admin API | on, from this machine (step 1) | | |
| For traffic | `metrics` in the global options (step 2) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `caddy_status` | Up; servers, listeners, routes, sites, reverse proxies, file servers, certificate policies; HTTP metrics on; the last configuration change loaded, and how long ago; goroutines; open files against the limit | minute |
| `caddy_traffic` | Each server: requests, in flight, handler errors, answers 2xx to 5xx, average time to answer | minute |
| `caddy_upstreams` | Each upstream, the failing first: requests it handles now, recent failures, healthy (where Caddy checks); upstreams failing and unhealthy | minute |
| `caddy_tls` | Every site name in its configuration (or `CADDY_TLS`): answering TLS, days until its certificate expires, within its dates, trusted (and why not), its issuer and the TLS version | 15 minutes |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `caddy.up`.

```text
+--------------------------------------------------------------------------------------------------+
| caddy_status   caddy.<metric>   every 1m                                                         |
+---------------------+----------------------------------------------------------------------------+
| up                  | 1 when the admin API answers, else 0                                       |
| servers             | HTTP servers in the configuration                                          |
| listeners           | addresses they listen on                                                   |
| routes              | routes, all servers together                                               |
| sites               | site names the routes match                                                |
| reverse_proxies     | reverse_proxy handlers                                                     |
| file_servers        | file_server handlers                                                       |
| tls_policies        | certificate automation policies                                            |
| metrics_enabled     | 1 when Caddy's HTTP metrics are on (the traffic job needs them), else 0    |
| reload_ok           | 1 when the last configuration change loaded, 0 when it failed (Caddy kept  |
|                     | the old one)                                                               |
| last_reload_seconds | since the configuration last loaded                                        |
| goroutines          | Caddy's goroutines                                                         |
| open_fds            | files and sockets Caddy holds open                                         |
| max_fds             | the most it may                                                            |
| fds_pct             | open_fds as a percentage of max_fds                                        |
+---------------------+----------------------------------------------------------------------------+
| GOOD  up 1; reload_ok 1; fds_pct well below 100.                                                 |
| WATCH goroutines climbing for hours: a leak, or connections held open; fds_pct above 70.         |
| BAD   up 0; reload_ok 0: a configuration change was refused and Caddy still runs the old one     |
|       (its log says why); fds_pct near 100: new connections fail.                                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| caddy_traffic   caddy.traffic.<metric>   every 1m                                                |
+----------------------+---------------------------------------------------------------------------+
| up                   | 1 when the admin API answers, else 0                                      |
| metrics_enabled      | 1 when Caddy's HTTP metrics are on, else 0 (and nothing more is reported) |
| requests_count       | requests handled (a running total), tagged server=<its name>              |
| in_flight            | requests being handled now, tagged server                                 |
| handler_errors_count | requests a handler failed (a running total), tagged server                |
| status_2xx_count     | answers 2xx (a running total), tagged server                              |
| status_3xx_count     | answers 3xx, tagged server                                                |
| status_4xx_count     | answers 4xx, tagged server                                                |
| status_5xx_count     | answers 5xx, tagged server                                                |
| duration_avg_ms      | time to answer, on average since Caddy started, tagged server             |
| servers_reporting    | servers with HTTP metrics to report (0 with metrics_enabled 1 while Caddy |
|                      | serves traffic: in our tests, Caddy 2.11.9 stopped reporting them after   |
|                      | any configuration reload through its admin API, until it restarted)       |
| ..._not_shown        | past 100 of a list (servers), how many were left out                      |
+----------------------+---------------------------------------------------------------------------+
| GOOD  status_5xx_count and handler_errors_count flat (graph the _count totals as rates).         |
| WATCH status_4xx_count rising faster than requests_count; in_flight climbing; servers_reporting  |
|       0 with metrics_enabled 1 on a Caddy that serves traffic: its metrics stopped after a       |
|       reload (restart Caddy to have them back).                                                  |
| BAD   status_5xx_count or handler_errors_count rising: requests failing (the upstreams job says  |
|       whether an upstream is down).                                                              |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| caddy_upstreams   caddy.upstreams.<metric>   every 1m                                            |
+---------------------+----------------------------------------------------------------------------+
| up                  | 1 when the admin API answers, else 0                                       |
| upstreams           | upstreams, all reverse proxies together                                    |
| upstreams_failing   | of those, with recent failures                                             |
| upstreams_unhealthy | of those Caddy checks, unhealthy                                           |
| active_requests     | requests it is handling now, tagged upstream=<its address>                 |
| fails               | its failures counted now (they expire after fail_duration), tagged         |
|                     | upstream                                                                   |
| healthy             | 1 when Caddy's health checks find it healthy, else 0, tagged upstream      |
|                     | (only for upstreams Caddy checks)                                          |
| ..._not_shown       | past 100 of a list (upstreams), how many were left out                     |
+---------------------+----------------------------------------------------------------------------+
| GOOD  upstreams_failing 0; upstreams_unhealthy 0.                                                |
| WATCH fails above 0 on one upstream: it fails now and then.                                      |
| BAD   upstreams_unhealthy above 0: Caddy has stopped sending to it; every upstream of a proxy    |
|       failing: that site answers 502.                                                            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| caddy_tls   caddy.tls.<metric>   every 15m                                                       |
+-------------------+------------------------------------------------------------------------------+
| up                | 1 when Caddy's admin API answers, else 0 (only when CADDY_TLS is not set:    |
|                   | the job then asks it for the site names)                                     |
| sites_found       | site names found in Caddy's configuration (when CADDY_TLS is not set)        |
| tls_up            | 1 when the endpoint finished a TLS handshake, else 0; tagged                 |
|                   | endpoint=<host:port, or host:port/name>                                      |
| cert_expires_days | days until the certificate it served expires (below 0: expired), tagged      |
|                   | endpoint                                                                     |
| cert_valid        | 1 when today is within its dates, else 0, tagged endpoint                    |
| cert_verified     | 1 when it checks against the trusted CAs (or CADDY_CACERT) and the name,     |
|                   | else 0; tagged endpoint and reason=<openssl's, or Windows' word>             |
| cert_info         | always 1, tagged endpoint, issuer=<its CN> and protocol=<the TLS version     |
|                   | agreed>                                                                      |
| ..._not_shown     | past 100 of a list (certs), how many were left out                           |
+-------------------+------------------------------------------------------------------------------+
| GOOD  tls_up 1; cert_expires_days above 30; cert_valid 1; cert_verified 1.                       |
| WATCH cert_expires_days below 30: renewal should have happened by now.                           |
| BAD   cert_expires_days below 7, or cert_valid 0: clients will refuse it; cert_verified 0:       |
|       clients that check (all browsers) refuse it now (reason says why); tls_up 0: nothing       |
|       answers TLS there.                                                                         |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the servers in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `caddy.up` | 1 |  | 0: the admin API does not answer (Caddy down, or the API moved) | 0 where nothing listened |
| `caddy.reload_ok` | 1 |  | 0: a configuration change was refused, and Caddy runs the old one | 0 after a configuration it refused; `servers` still 2 |
| `caddy.fds_pct` | Well below 100 | Above 70 | Near 100: new connections fail | 0 |
| `caddy.traffic.status_5xx_count`, `handler_errors_count` | Flat |  | Rising: requests fail | 4 answers 5xx on the reverse proxy, 4 handler errors |
| `caddy.upstreams.upstreams_unhealthy` | 0 |  | Above 0: Caddy stopped sending to it; every upstream of a proxy down: 502 | 1: `gone:80`, a name that does not resolve |
| `caddy.tls.cert_expires_days` | Above 30 (a public CA); above 0 (Caddy's own: 12 hours) | Below 30 | Below 7: Caddy's renewal is failing | 0 for its own CA's 12-hour certificate, `cert_verified 1` against that CA |

## How it was tested

**Tested** on 2026-11-24 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-web.sh`, against `compose.web.yaml`: **nginx 1.30.8 and 1.31.10**, **Apache httpd 2.4.71** (event and prefork), **Caddy 2.11.9**, **HAProxy 3.4.8 and 3.2.27**, and **PHP-FPM 8.6.0 and 8.3.37**, in Docker, with certificates the run makes (a CA; one it signed that expires in five days; one that expired; one no CA signed), each server in trouble on purpose. In one minute the run sends answers of every kind (200, 404, 403, 500, 502, 503, 504) and slow PHP requests that fill PHP-FPM's workers and HAProxy's queue, then runs every job of every pack on the next minute and checks what it read; then the trouble one at a time: a configuration edited and not reloaded, then reloaded (nginx, httpd); a log the account may not read; a log that grows faster than the job reads; a configuration Caddy refuses; HAProxy's socket file through `socat` and `nc`; servers that do not answer. Then every job again in a Debian 13 container, with Debian's own awk (mawk 1.3.4), as on Debian and Ubuntu.

- **On Fedora**: every job directly, **131 passed, 0 failed**; then `service-packs.sh` through Vigil, for all five packs (enable, and that CPU and memory are the base pack's; precheck; every job; a server that does not answer read as `up 0`; the metrics reaching the backend): **52 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/fedora/pack-web/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own `openssl`, LibreSSL), against the same servers through SSH tunnels, with the logs, configuration folders and process trees the jobs read made on the Mac: every job, **52 passed, 0 failed**; through Vigil, **52 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/macos/pack-web-macos/console.txt)).
- **On Windows**, as an account that is not an administrator, against the same servers through SSH tunnels, with the access logs written on Windows: every Windows job (nginx, httpd, caddy) directly, then `Service-Packs.ps1` through Vigil, on Windows 11 under Windows PowerShell 5.1 and PowerShell 7, **76 passed, 0 failed** and **26 passed, 0 failed** on each ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/windows/pack-web-windows/console.txt)), and on Windows Server 2025 under Windows PowerShell 5.1, **38 passed, 0 failed** and **26 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/windows-server-2025/pack-web-windows/console.txt)).

**What the tests found.** Caddy 2.11.9 stopped reporting its HTTP metrics and its upstreams' health after a configuration reload through its admin API, refused or accepted, until it restarted: `caddy_traffic` then says `metrics_enabled 1` and `servers_reporting 0` while Caddy serves traffic.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
