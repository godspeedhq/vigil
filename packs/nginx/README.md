# The nginx pack

An nginx server on this machine. The pack reads its `stub_status` page (connections reading, writing and waiting, and the connections and requests since it started); its processes and configuration (the master and its workers, old workers still finishing after a reload, when it last reloaded, a configuration edited and not reloaded yet, `worker_connections` and how full the workers are, the open files a worker may hold); its access log, minute by minute (requests by status and method, the 4xx and 5xx share, bytes, clients, and, when the log records them, response and upstream times with percentiles); and the certificates it serves (days left, within their dates, trusted, the TLS version). Linux, macOS and Windows (on Windows: `status`, `log` and `tls`).

**A status page, the log's group, and `curl` and `openssl`.** Every job only reads: a page from this machine, the process list, the configuration's files and the log, and, for certificates, a TLS handshake.

1. **The status page**, from this machine only, in a `server` block, then reload nginx:

   ```nginx
   location = /nginx_status { stub_status; allow 127.0.0.1; deny all; }
   ```

2. **For the log job, response times in the log** (optional, and worth it): end the `log_format` with them, and use it.

   ```nginx
   log_format vigil '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent" rt=$request_time urt=$upstream_response_time';
   access_log /var/log/nginx/access.log vigil;
   ```

   Without them, the log job reads the same counts from the standard `combined` format, with no times.
3. **For the log job, read access to the log.** On Debian and Ubuntu the logs belong to the `adm` group: `sudo usermod -aG adm vigil`, then restart Vigil. On Fedora and RHEL, `/var/log/nginx` is root's alone: `sudo setfacl -m u:vigil:rx /var/log/nginx` and `sudo setfacl -m u:vigil:r /var/log/nginx/access.log`, and the same in logrotate's `postrotate` (or `create 0640 nginx vigil`). Until then the job reports `log_readable 0` and nothing more, and the run succeeds.
4. `vigil pack enable nginx`, then in `vigil.config` set what differs from the defaults, in the jobs' `env` lines: `NGINX_STATUS_URL` (`http://127.0.0.1/nginx_status`), `NGINX_PID_FILE` (`/run/nginx.pid`), `NGINX_CONF` (`/etc/nginx/nginx.conf`), `NGINX_ACCESS_LOG` (`/var/log/nginx/access.log`), `NGINX_TLS` (the https endpoints, `localhost:443`, or `127.0.0.1:443/www.example.com` to ask for a name) and, for a private CA, `NGINX_CACERT`.

**nginx that does not answer is a reading**, `up 0` (or `running 0`), and the run succeeds. A page that answers but is not `stub_status` fails the run.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `ps`, `openssl` | `curl`, `ps`, `openssl` (built in) | Nothing: `Invoke-WebRequest` and .NET |
| nginx | 1.18 and later; NGINX Plus too (its `stub_status`) | | nginx for Windows |
| A page | `stub_status`, from this machine only (step 1) | | |
| The log | read access (step 3) | | |

## Its jobs

| Job | Reports | Every | Windows |
| --- | --- | --- | --- |
| `nginx_status` | Up, connections (active, reading, writing, waiting), accepted, handled and dropped connections, requests | minute | Yes |
| `nginx_server` | The master running and its uptime, workers, old workers still finishing after a reload, cache processes, seconds since the last reload, files changed since (an edit not reloaded), `worker_processes`, `worker_connections` and how full the workers are, open files a worker may hold | minute | No |
| `nginx_log` | The access log's last whole minute: requests, by status class and by status, the 4xx and 5xx share, by method, bytes, clients; with `rt=` and `urt=`, response and upstream times (average, p50, p90, p99, the slowest); whether the whole minute was read | minute | Yes |
| `nginx_tls` | Each https endpoint: answering TLS, days until its certificate expires, within its dates, trusted (and why not), its issuer and the TLS version | 15 minutes | Yes |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `nginx.up`.

```text
+--------------------------------------------------------------------------------------------------+
| nginx_status   nginx.<metric>   every 1m                                                         |
+--------------------+-----------------------------------------------------------------------------+
| up                 | 1 when the page answers, else 0                                             |
| active_connections | client connections now, waiting ones included                               |
| reading            | connections reading a request                                               |
| writing            | connections writing a response                                              |
| waiting            | idle keep-alive connections                                                 |
| accepts_count      | connections accepted (a running total)                                      |
| handled_count      | connections handled (a running total)                                       |
| requests_count     | requests served (a running total)                                           |
| dropped_count      | connections accepted but not handled (a running total)                      |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  up 1; dropped_count not rising; requests_count rising at your usual rate (graph the _count |
|       totals as a rate).                                                                         |
| WATCH active_connections near worker_connections times the workers (the server job says how      |
|       near).                                                                                     |
| BAD   up 0; dropped_count rising, which means nginx is turning connections away, usually at a    |
|       resource limit.                                                                            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| nginx_server   nginx.server.<metric>   every 1m                                                  |
+--------------------------+-----------------------------------------------------------------------+
| running                  | 1 when the master named in the pid file runs, else 0                  |
| master_uptime_seconds    | since the master started                                              |
| workers                  | worker processes                                                      |
| workers_shutting_down    | old workers still finishing their connections after a reload          |
| cache_processes          | cache manager and loader processes                                    |
| last_reload_seconds      | since the youngest worker started: the last reload (or a worker       |
|                          | restarted after a crash)                                              |
| config_changed           | files under the configuration folder changed since then: an edit not  |
|                          | reloaded yet (0 when none)                                            |
| worker_processes_setting | worker_processes in the configuration (0 for auto)                    |
| worker_connections       | worker_connections in the configuration (512 when not set, as nginx)  |
| connections_capacity_pct | the stub_status page's active connections, as a percentage of workers |
|                          | times worker_connections                                              |
| worker_open_files_limit  | open files a worker may hold (Linux)                                  |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  running 1; workers steady; workers_shutting_down 0 soon after a reload; config_changed 0.  |
| WATCH config_changed above 0 for long: someone edited the configuration and did not reload (or   |
|       the edit has an error); connections_capacity_pct above 70; workers_shutting_down above 0   |
|       for long: long connections (websockets, downloads) keep old workers alive.                 |
| BAD   running 0; connections_capacity_pct near 100: new connections wait or fail; workers below  |
|       worker_processes_setting: workers dying.                                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| nginx_log   nginx.log.<metric>   every 1m                                                        |
+-----------------+--------------------------------------------------------------------------------+
| log_found       | 1 when the access log is there, else 0                                         |
| log_readable    | 1 when this account may read it, else 0 (and nothing more is read)             |
| log_bytes       | the log's size                                                                 |
| window_complete | 1 when the whole minute was read; 0 when the log grew faster than              |
|                 | NGINX_LOG_MAX_MB a minute, and the counts are of its end only                  |
| requests        | requests logged in the last whole minute                                       |
| status_1xx      | of those, answered 1xx                                                         |
| status_2xx      | answered 2xx                                                                   |
| status_3xx      | answered 3xx                                                                   |
| status_4xx      | answered 4xx: the client asked wrong (not found, refused, too many)            |
| status_5xx      | answered 5xx: the server failed                                                |
| errors_4xx_pct  | 4xx, as a percentage of the requests                                           |
| errors_5xx_pct  | 5xx, as a percentage of the requests                                           |
| bytes_sent      | bytes sent in answers                                                          |
| clients         | client addresses seen                                                          |
| status          | requests answered with one status, tagged code=<it> (each one seen)            |
| method          | requests by method, tagged method=<GET, POST, HEAD, PUT, DELETE, PATCH,        |
|                 | OPTIONS or other>                                                              |
| response_avg_ms | time to answer, on average, when the log records it (rt=$request_time at the   |
|                 | end of the log_format)                                                         |
| response_p50_ms | half the requests were answered within this                                    |
| response_p90_ms | 90% were answered within this                                                  |
| response_p99_ms | 99% were answered within this                                                  |
| response_max_ms | the slowest                                                                    |
| upstream_avg_ms | the upstream's time to answer, on average, when the log records it             |
|                 | (urt=$upstream_response_time)                                                  |
| upstream_p50_ms | half the upstream's answers came within this                                   |
| upstream_p90_ms | 90% came within this                                                           |
| upstream_p99_ms | 99% came within this                                                           |
| upstream_max_ms | the slowest                                                                    |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  window_complete 1; errors_5xx_pct below 1; response_p99_ms steady.                         |
| WATCH errors_4xx_pct climbing (a broken link, a client retrying, a scan); response_p99_ms rising |
|       while requests do not; window_complete 0 (raise NGINX_LOG_MAX_MB).                         |
| BAD   errors_5xx_pct above a few percent: the server or its upstream is failing (status says     |
|       which: 500, 502 bad gateway, 503 unavailable, 504 timed out); requests 0 on a busy site:   |
|       nothing reaches it, or it stopped logging.                                                 |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| nginx_tls   nginx.tls.<metric>   every 15m                                                       |
+-------------------+------------------------------------------------------------------------------+
| tls_up            | 1 when the endpoint finished a TLS handshake, else 0; tagged                 |
|                   | endpoint=<host:port, or host:port/name>                                      |
| cert_expires_days | days until the certificate it served expires (below 0: expired), tagged      |
|                   | endpoint                                                                     |
| cert_valid        | 1 when today is within its dates, else 0, tagged endpoint                    |
| cert_verified     | 1 when it checks against the trusted CAs (or NGINX_CACERT) and the name,     |
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
| `nginx.up` | 1 |  | 0: nginx does not answer | 0 where nothing listened |
| `nginx.dropped_count` (a rate) | 0 | Any | Rising: nginx turns connections away, at a limit | 0: not caused |
| `nginx.server.connections_capacity_pct` | Below 70 | Above 70 | Near 100: new connections wait or fail | 4.69 with two workers of 64 connections and the slow requests in flight |
| `nginx.server.config_changed` | 0 | Above 0 for long: an edit not reloaded (or one that would fail) |  | 1 after an edit; 0 after `nginx -s reload` |
| `nginx.server.workers_shutting_down` | 0, soon after a reload | Above 0 for long: long connections keep old workers alive |  | 2 just after a reload, with a 20-second request running |
| `nginx.log.errors_5xx_pct` | Below 1 |  | Above a few percent: the server or its upstream fails | 5.33: PHP's 500s, 502 where nothing listened, 504 where nothing answered |
| `nginx.log.status` `code=502`, `code=504` | 0 |  | Rising: the upstream refuses (502) or does not answer in time (504) | 4 and 3 |
| `nginx.log.response_p99_ms`, `upstream_p99_ms` | Steady | Rising while `requests` does not |  | 1000 and 1001: the one-second timeouts |
| `nginx.log.window_complete` | 1 | 0: raise `NGINX_LOG_MAX_MB` |  | 0 for a 4 MB log read 1 MB at a time |
| `nginx.log.log_readable` | 1 | 0: give the account access (step 3) |  | 0 for a log it may not read; the run still succeeded |
| `nginx.tls.cert_expires_days` | Above 30 | Below 30 | Below 7; below 0: expired | 4 for the certificate made to expire in 5 days; -661 for the expired one |
| `nginx.tls.cert_verified` | 1 |  | 0: clients refuse it (`reason` says why) | 1 with the test CA; 0 `reason=certificate_has_expired` |

## How it was tested

**Tested** on 2026-11-24 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-web.sh`, against `compose.web.yaml`: **nginx 1.30.8 and 1.31.10**, **Apache httpd 2.4.71** (event and prefork), **Caddy 2.11.9**, **HAProxy 3.4.8 and 3.2.27**, and **PHP-FPM 8.6.0 and 8.3.37**, in Docker, with certificates the run makes (a CA; one it signed that expires in five days; one that expired; one no CA signed), each server in trouble on purpose. In one minute the run sends answers of every kind (200, 404, 403, 500, 502, 503, 504) and slow PHP requests that fill PHP-FPM's workers and HAProxy's queue, then runs every job of every pack on the next minute and checks what it read; then the trouble one at a time: a configuration edited and not reloaded, then reloaded (nginx, httpd); a log the account may not read; a log that grows faster than the job reads; a configuration Caddy refuses; HAProxy's socket file through `socat` and `nc`; servers that do not answer. Then every job again in a Debian 13 container, with Debian's own awk (mawk 1.3.4), as on Debian and Ubuntu.

- **On Fedora**: every job directly, **131 passed, 0 failed**; then `service-packs.sh` through Vigil, for all five packs (enable, and that CPU and memory are the base pack's; precheck; every job; a server that does not answer read as `up 0`; the metrics reaching the backend): **52 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/fedora/pack-web/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own `openssl`, LibreSSL), against the same servers through SSH tunnels, with the logs, configuration folders and process trees the jobs read made on the Mac: every job, **52 passed, 0 failed**; through Vigil, **52 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/macos/pack-web-macos/console.txt)).
- **On Windows**, as an account that is not an administrator, against the same servers through SSH tunnels, with the access logs written on Windows: every Windows job (nginx, httpd, caddy) directly, then `Service-Packs.ps1` through Vigil, on Windows 11 under Windows PowerShell 5.1 and PowerShell 7, **76 passed, 0 failed** and **26 passed, 0 failed** on each ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/windows/pack-web-windows/console.txt)), and on Windows Server 2025 under Windows PowerShell 5.1, **38 passed, 0 failed** and **26 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/windows-server-2025/pack-web-windows/console.txt)).

On macOS the `server` job read a process tree named as nginx's (a master and two workers), through macOS's `ps`; on Linux, the real nginx's, from the host.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
