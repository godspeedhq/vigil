# The httpd pack

An Apache httpd server on this machine. The pack reads its `server-status` page (its version and MPM, uptime since the last restart and how many graceful restarts, requests, bytes and time served, CPU, workers busy, idle and finishing against those running, every worker's state from the scoreboard, connections writing, kept alive and closing with the event MPM, and with `mod_ssl` its TLS session cache: entries, how full, hits, misses and sessions thrown out for lack of room), whether a file of its configuration changed since the last restart (an edit not loaded yet), its access log minute by minute (requests by status and method, the 4xx and 5xx share, bytes, clients, and, when the log records them, response times with percentiles), and the certificates it serves (days left, within their dates, trusted, the TLS version). Linux, macOS and Windows.

**A status page, the log's group, and `curl` and `openssl`.** Every job only reads: a page from this machine, the configuration's files and the log, and, for certificates, a TLS handshake.

1. **The status page**, from this machine only, with its totals, then reload httpd (`apachectl -k graceful`):

   ```apache
   ExtendedStatus On
   <Location "/server-status">
       SetHandler server-status
       Require local
   </Location>
   ```

   `mod_status` is loaded by default on most systems (`a2enmod status` on Debian and Ubuntu).
2. **For the log job, response times in the log** (optional, and worth it): end the `LogFormat` with `rtus=%D`, and use it.

   ```apache
   LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\" rtus=%D" vigil
   CustomLog "logs/access_log" vigil
   ```

   Without it, the log job reads the same counts from the standard `combined` format, with no times.
3. **For the log job, read access to the log.** On Debian and Ubuntu the logs belong to the `adm` group: `sudo usermod -aG adm vigil`, then restart Vigil. On Fedora and RHEL, `/var/log/httpd` is root's alone: `sudo setfacl -m u:vigil:rx /var/log/httpd` and `sudo setfacl -m u:vigil:r /var/log/httpd/access_log`. Until then the job reports `log_readable 0` and nothing more, and the run succeeds.
4. `vigil pack enable httpd`, then in `vigil.config` set what differs from the defaults, in the jobs' `env` lines: `HTTPD_STATUS_URL` (`http://127.0.0.1/server-status`), `HTTPD_CONF` (by default the first of `/etc/httpd/conf/httpd.conf`, `/etc/apache2/apache2.conf`, `/usr/local/apache2/conf/httpd.conf` and Homebrew's that is there; `C:\Apache24\conf\httpd.conf` on Windows), `HTTPD_ACCESS_LOG` (by default the first of `/var/log/httpd/access_log`, `/var/log/apache2/access.log` and the others that is there), `HTTPD_TLS` (the https endpoints, `localhost:443`) and, for a private CA, `HTTPD_CACERT`.

**httpd that does not answer is a reading**, `up 0`, and the run succeeds. A page that answers but is not `server-status` fails the run.

**What server-status cannot say.** It does not say `MaxRequestWorkers`: its scoreboard has a slot for every worker `ServerLimit` and `ThreadLimit` allow. So `busy_pct` is of the workers running, busy and idle: near 100 with `idle_workers` 0, every worker is busy and httpd may start no more.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `openssl` | `curl`, `openssl` (built in) | Nothing: `Invoke-WebRequest` and .NET |
| httpd | 2.4, any MPM | | Apache Lounge's build |
| A page | `server-status`, from this machine only (step 1) | | |
| The log | read access (step 3) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `httpd_status` | Up, version and MPM, ExtendedStatus, uptime since the last restart, graceful restarts, requests, bytes and time served, CPU, workers busy, idle and finishing, scoreboard slots, busy %, processes and those stopping, connections (writing, keep-alive, closing), every scoreboard state, the TLS session cache, a configuration changed since the last restart | minute |
| `httpd_log` | The access log's last whole minute: requests, by status class and by status, the 4xx and 5xx share, by method, bytes, clients; with `rtus=`, response times (average, p50, p90, p99, the slowest); whether the whole minute was read | minute |
| `httpd_tls` | Each https endpoint: answering TLS, days until its certificate expires, within its dates, trusted (and why not), its issuer and the TLS version | 15 minutes |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `httpd.up`.

```text
+--------------------------------------------------------------------------------------------------+
| httpd_status   httpd.<metric>   every 1m                                                         |
+--------------------------+-----------------------------------------------------------------------+
| up                       | 1 when the page answers, else 0                                       |
| info                     | always 1, tagged version=<httpd's> and mpm=<event, worker or prefork> |
| extended_status          | 1 when ExtendedStatus is on (the totals need it), else 0              |
| uptime_seconds           | since httpd started (a graceful restart does not reset it)            |
| restarts                 | graceful restarts since httpd started (its configuration generation)  |
| accesses_count           | requests served (a running total)                                     |
| bytes_count              | bytes served (a running total)                                        |
| duration_ms_count        | time spent serving them (a running total)                             |
| cpu_load_pct             | httpd's CPU, as a percentage of one CPU, since the restart            |
| busy_workers             | workers serving a request                                             |
| idle_workers             | workers waiting for one                                               |
| finishing_workers        | workers finishing after a graceful restart                            |
| scoreboard_slots         | slots in the scoreboard: ServerLimit times ThreadLimit, the ceiling   |
|                          | no setting can pass                                                   |
| busy_pct                 | busy workers, as a percentage of the workers running (busy and idle): |
|                          | near 100 once httpd may start no more (MaxRequestWorkers)             |
| processes                | child processes                                                       |
| stopping_processes       | child processes stopping                                              |
| connections              | connections open (event MPM)                                          |
| conns_writing            | of those, writing a reply without a worker (event MPM)                |
| conns_keepalive          | idle keep-alive connections, held without a worker (event MPM)        |
| conns_closing            | closing (event MPM)                                                   |
| workers_in_state         | workers in one scoreboard state, tagged state=<waiting, starting,     |
|                          | reading, sending, keepalive, dns, closing, logging, finishing,        |
|                          | cleanup, open>                                                        |
| ssl_cache_entries        | TLS sessions in the cache (mod_ssl, shmcb)                            |
| ssl_cache_usage_pct      | how full the cache is                                                 |
| ssl_cache_hits_count     | sessions resumed from it (a running total)                            |
| ssl_cache_misses_count   | sessions looked for and not found (a running total)                   |
| ssl_cache_discards_count | sessions thrown out for lack of room (a running total)                |
| config_changed           | files under the configuration folder changed after the youngest       |
|                          | worker process started: an edit not loaded yet (0 when none; Linux    |
|                          | and macOS)                                                            |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  up 1; busy_pct well below 100; config_changed 0.                                           |
| WATCH busy_pct above 70; workers_in_state state=reading high (slow clients, or a slow-request    |
|       attack); config_changed above 0 for long: an edit not reloaded (or one that would fail);   |
|       ssl_cache_discards_count rising: the session cache is too small.                           |
| BAD   up 0; busy_pct near 100 with idle_workers 0: every worker busy, new requests wait          |
|       (MaxRequestWorkers reached); stopping_processes or finishing_workers stuck above 0: a      |
|       graceful restart that does not finish.                                                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| httpd_log   httpd.log.<metric>   every 1m                                                        |
+-----------------+--------------------------------------------------------------------------------+
| log_found       | 1 when the access log is there, else 0                                         |
| log_readable    | 1 when this account may read it, else 0 (and nothing more is read)             |
| log_bytes       | the log's size                                                                 |
| window_complete | 1 when the whole minute was read; 0 when the log grew faster than              |
|                 | HTTPD_LOG_MAX_MB a minute, and the counts are of its end only                  |
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
| response_avg_ms | time to answer, on average, when the log records it (rtus=%D at the end of the |
|                 | LogFormat)                                                                     |
| response_p50_ms | half the requests were answered within this                                    |
| response_p90_ms | 90% were answered within this                                                  |
| response_p99_ms | 99% were answered within this                                                  |
| response_max_ms | the slowest                                                                    |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  window_complete 1; errors_5xx_pct below 1; response_p99_ms steady.                         |
| WATCH errors_4xx_pct climbing (a broken link, a client retrying, a scan); response_p99_ms rising |
|       while requests do not; window_complete 0 (raise HTTPD_LOG_MAX_MB).                         |
| BAD   errors_5xx_pct above a few percent: the server or its upstream is failing (status says     |
|       which: 500, 502 bad gateway, 503 unavailable, 504 timed out); requests 0 on a busy site:   |
|       nothing reaches it, or it stopped logging.                                                 |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| httpd_tls   httpd.tls.<metric>   every 15m                                                       |
+-------------------+------------------------------------------------------------------------------+
| tls_up            | 1 when the endpoint finished a TLS handshake, else 0; tagged                 |
|                   | endpoint=<host:port, or host:port/name>                                      |
| cert_expires_days | days until the certificate it served expires (below 0: expired), tagged      |
|                   | endpoint                                                                     |
| cert_valid        | 1 when today is within its dates, else 0, tagged endpoint                    |
| cert_verified     | 1 when it checks against the trusted CAs (or HTTPD_CACERT) and the name,     |
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
| `httpd.up` | 1 |  | 0: httpd does not answer | 0 where nothing listened |
| `httpd.busy_pct` with `idle_workers` | Well below 100 | Above 70 | Near 100 with `idle_workers` 0: every worker busy, requests wait | 20% with three 40-second PHP requests in flight |
| `httpd.workers_in_state` `state=reading` | Low | High: slow clients, or a slow-request attack |  | Not caused |
| `httpd.config_changed` | 0 | Above 0 for long: an edit not loaded (or one that would fail) |  | 1 after an edit; 0 after `httpd -k graceful` (and `restarts` 1) |
| `httpd.stopping_processes`, `finishing_workers` | 0 |  | Stuck above 0: a graceful restart that does not finish | 0 |
| `httpd.ssl_cache_discards_count` | Flat | Rising: the TLS session cache is too small |  | 0 |
| `httpd.log.errors_5xx_pct` | Below 1 |  | Above a few percent | 2.79: PHP's 500s |
| `httpd.log.response_p99_ms` | Steady | Rising |  | 1.3 |
| `httpd.tls.cert_verified` | 1 |  | 0: clients refuse it | 0 `reason=self-signed_certificate` for a certificate no CA signed |

## How it was tested

**Tested** on 2026-11-24 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-web.sh`, against `compose.web.yaml`: **nginx 1.30.8 and 1.31.10**, **Apache httpd 2.4.71** (event and prefork), **Caddy 2.11.9**, **HAProxy 3.4.8 and 3.2.27**, and **PHP-FPM 8.6.0 and 8.3.37**, in Docker, with certificates the run makes (a CA; one it signed that expires in five days; one that expired; one no CA signed), each server in trouble on purpose. In one minute the run sends answers of every kind (200, 404, 403, 500, 502, 503, 504) and slow PHP requests that fill PHP-FPM's workers and HAProxy's queue, then runs every job of every pack on the next minute and checks what it read; then the trouble one at a time: a configuration edited and not reloaded, then reloaded (nginx, httpd); a log the account may not read; a log that grows faster than the job reads; a configuration Caddy refuses; HAProxy's socket file through `socat` and `nc`; servers that do not answer. Then every job again in a Debian 13 container, with Debian's own awk (mawk 1.3.4), as on Debian and Ubuntu.

- **On Fedora**: every job directly, **131 passed, 0 failed**; then `service-packs.sh` through Vigil, for all five packs (enable, and that CPU and memory are the base pack's; precheck; every job; a server that does not answer read as `up 0`; the metrics reaching the backend): **52 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/fedora/pack-web/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own `openssl`, LibreSSL), against the same servers through SSH tunnels, with the logs, configuration folders and process trees the jobs read made on the Mac: every job, **52 passed, 0 failed**; through Vigil, **52 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/macos/pack-web-macos/console.txt)).
- **On Windows**, as an account that is not an administrator, against the same servers through SSH tunnels, with the access logs written on Windows: every Windows job (nginx, httpd, caddy) directly, then `Service-Packs.ps1` through Vigil, on Windows 11 under Windows PowerShell 5.1 and PowerShell 7, **76 passed, 0 failed** and **26 passed, 0 failed** on each ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/windows/pack-web-windows/console.txt)), and on Windows Server 2025 under Windows PowerShell 5.1, **38 passed, 0 failed** and **26 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/windows-server-2025/pack-web-windows/console.txt)).

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
