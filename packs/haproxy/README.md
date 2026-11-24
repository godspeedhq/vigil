# The haproxy pack

An HAProxy process, from its runtime API. The pack reads HAProxy itself (its version and uptime, its connections against `maxconn` and how often it reached it, its connection, session, request and TLS rates and their peaks, TLS session reuse, how busy its threads are, its run queue, its memory pools and their failures, dropped logs, failed DNS resolutions, its warnings and its stick-table peers), every frontend (open or not, sessions against its limit, rates, answers by status class, what it denied, requests it could not read, failed TLS handshakes), every backend (up or not, its servers up, its queue, how long requests wait, connect, and take, errors, retries and redispatches, how long it has been down), and every server with its health check (its state, its last check's result and code, how long since it changed, how often it failed and went down). The worst first. Linux and macOS: HAProxy does not run on Windows.

**A socket at `level user`, and bash.** The jobs send HAProxy's runtime API `show info` and `show stat`, and nothing else: a socket at `level user` answers those and refuses anything that would change HAProxy. Over TCP, bash reads it itself (`/dev/tcp`); a socket file is read with `socat` or `nc`.

1. **A socket for Vigil**, in `haproxy.cfg`'s `global` section, then reload HAProxy. Either a TCP address, from this machine only:

   ```haproxy
   stats socket ipv4@127.0.0.1:9999 level user
   ```

   or a socket file the account Vigil runs as may use (its group):

   ```haproxy
   stats socket /run/haproxy/vigil.sock mode 660 group vigil level user
   ```

   A socket HAProxy already has (Debian's `/run/haproxy/admin.sock`, Fedora's `/var/lib/haproxy/stats`) works too, when the account may use it: the pack only ever sends `show info` and `show stat`, but such a socket is often at `level admin`, and one at `level user` is the safer one to hand a monitor.
2. `vigil pack enable haproxy`, then in `vigil.config` set the jobs' `HAPROXY_SOCKET`: `127.0.0.1:9999`, or the socket file's path. Left empty, the jobs use the first of `/run/haproxy/admin.sock`, `/var/lib/haproxy/stats` and `/var/run/haproxy.sock` that is there.

**HAProxy that does not answer is a reading**, `up 0`, and the run succeeds. A socket this account may not use, or one that refuses `show info` or `show stat`, fails the run, saying so.

## What it needs

| | Linux | macOS |
| --- | --- | --- |
| On the Vigil machine | `bash`; for a socket file, `socat` or `nc` | `bash`; for a socket file, `nc` (built in) or `socat` |
| HAProxy | 2.4 and later | |
| A socket | `stats socket ... level user` (step 1) | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `haproxy_info` | HAProxy itself: version, uptime, threads, connections against `maxconn` and times it reached it, connection, session, request and TLS rates and peaks, TLS connections, full handshakes and session reuse, how busy its threads are, run queue, tasks, streams, stopping, open files, memory pools and failures, dropped logs, failed DNS resolutions, warnings, stick-table peers | minute |
| `haproxy_frontends` | Each frontend: open, sessions against its limit, session and request rates, requests, answers 1xx to 5xx, requests and answers denied, requests it could not read, bytes in and out, failed TLS handshakes | minute |
| `haproxy_backends` | Each backend, the down ones first: up, its servers (up, active, backup), sessions, queue and its peak, time in the queue, to connect, to the first byte and in all, connection and response errors, retries, redispatches, answers 4xx and 5xx, aborts by clients and servers, time down and since it changed | minute |
| `haproxy_servers` | Each server, the worst first: its state (up, draining, maintenance, down, not checked), its last check (L4OK, L4CON, L4TOUT, L7STS...) and code and how long it took, time since it changed and time down, checks failed and times it went down, sessions against its `maxconn`, queue, time to answer, 5xx, errors, weight | minute |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `haproxy.up`.

```text
+--------------------------------------------------------------------------------------------------+
| haproxy_info   haproxy.<metric>   every 1m                                                       |
+--------------------------+-----------------------------------------------------------------------+
| up                       | 1 when HAProxy answers, else 0                                        |
| info                     | always 1, tagged version=<its version>                                |
| uptime_seconds           | since HAProxy started                                                 |
| threads                  | threads                                                               |
| connections              | connections now                                                       |
| maxconn                  | the most it accepts (maxconn)                                         |
| connections_pct          | connections as a percentage of maxconn                                |
| maxconn_reached_count    | times it reached maxconn (a running total)                            |
| conn_rate                | connections a second, now                                             |
| conn_rate_max            | the most a second since it started                                    |
| sess_rate                | sessions a second                                                     |
| requests_count           | requests (a running total)                                            |
| ssl_rate                 | TLS sessions a second                                                 |
| ssl_connections          | TLS connections now                                                   |
| ssl_key_rate             | full TLS handshakes a second (those that are not resumed)             |
| ssl_reuse_pct            | TLS sessions resumed, as a percentage                                 |
| ssl_cache_misses_count   | TLS session cache misses (a running total)                            |
| busy_pct                 | how busy its threads are (100 less their idle time)                   |
| run_queue                | tasks waiting to run                                                  |
| tasks                    | tasks                                                                 |
| streams                  | streams now                                                           |
| stopping                 | 1 while HAProxy is stopping (an old process after a reload), else 0   |
| fd_limit                 | open files it may hold                                                |
| pool_used_bytes          | memory its pools use                                                  |
| pool_failed_count        | memory it asked for and did not get (a running total)                 |
| dropped_logs_count       | log lines it dropped (a running total)                                |
| failed_resolutions_count | DNS resolutions that failed (a running total)                         |
| warnings                 | warnings since it started (its configuration, its limits)             |
| bytes_out_rate           | bytes sent a second                                                   |
| peers_active             | stick-table peers known                                               |
| peers_connected          | of those, connected                                                   |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  up 1; connections_pct below 70; busy_pct below 70; pool_failed_count, dropped_logs_count   |
|       flat.                                                                                      |
| WATCH maxconn_reached_count rising; ssl_reuse_pct falling (each full handshake costs CPU);       |
|       run_queue above 0 for long; peers_connected below peers_active.                            |
| BAD   up 0; connections_pct near 100: new connections wait in the kernel; busy_pct near 100:     |
|       HAProxy is out of CPU; pool_failed_count rising: out of memory.                            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| haproxy_frontends   haproxy.frontends.<metric>   every 1m                                        |
+-----------------------------+--------------------------------------------------------------------+
| up                          | 1 when HAProxy answers, else 0                                     |
| frontends                   | frontends                                                          |
| frontends_closed            | of those, not open (stopped or full)                               |
| open                        | 1 when it is open, else 0, tagged frontend=<its name>              |
| sessions                    | sessions now, tagged frontend                                      |
| sessions_limit              | the most it accepts, tagged frontend                               |
| sessions_pct                | sessions as a percentage of the limit, tagged frontend             |
| session_rate                | sessions a second, tagged frontend                                 |
| session_rate_max            | the most a second, tagged frontend                                 |
| request_rate                | HTTP requests a second, tagged frontend                            |
| requests_count              | HTTP requests (a running total), tagged frontend                   |
| status_1xx_count            | answers 1xx (a running total), tagged frontend                     |
| status_2xx_count            | answers 2xx, tagged frontend                                       |
| status_3xx_count            | answers 3xx, tagged frontend                                       |
| status_4xx_count            | answers 4xx, tagged frontend                                       |
| status_5xx_count            | answers 5xx, tagged frontend                                       |
| denied_requests_count       | requests denied by its rules, tagged frontend                      |
| denied_responses_count      | answers denied, tagged frontend                                    |
| request_errors_count        | requests it could not read (bad, cut, timed out), tagged frontend  |
| bytes_in_count              | bytes received, tagged frontend                                    |
| bytes_out_count             | bytes sent, tagged frontend                                        |
| ssl_failed_handshakes_count | TLS handshakes that failed, tagged frontend                        |
| ..._not_shown               | past 100 of a list (frontends), how many were left out             |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  every open 1; sessions_pct below 70; status_5xx_count flat (graph the _count totals as     |
|       rates).                                                                                    |
| WATCH request_errors_count or ssl_failed_handshakes_count rising: clients, or scanners, failing; |
|       denied_requests_count rising: a rule blocking more than before.                            |
| BAD   open 0: that frontend accepts nothing; sessions_pct near 100: new clients wait;            |
|       status_5xx_count rising: the backends fail (the backends job says which).                  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| haproxy_backends   haproxy.backends.<metric>   every 1m                                          |
+-------------------------+------------------------------------------------------------------------+
| up                      | 1 when HAProxy answers, else 0                                         |
| backends                | backends                                                               |
| backends_down           | of those, down: no server to send to                                   |
| backend_up              | 1 when it is up, else 0, tagged backend=<its name>                     |
| servers                 | its servers, tagged backend                                            |
| servers_up              | of those, up, tagged backend                                           |
| servers_active          | active servers up (its weight goes to them), tagged backend            |
| servers_backup          | backup servers up, tagged backend                                      |
| sessions                | sessions now, tagged backend                                           |
| queue                   | requests waiting for a server, tagged backend                          |
| queue_max               | the most that waited, tagged backend                                   |
| queue_ms                | time waiting in the queue, on average, tagged backend                  |
| connect_ms              | time to connect to a server, on average, tagged backend                |
| response_ms             | time to the first byte of the answer, on average, tagged backend       |
| total_ms                | time for the whole request, on average, tagged backend                 |
| connection_errors_count | connections to a server that failed (a running total), tagged backend  |
| response_errors_count   | answers that failed, tagged backend                                    |
| retries_count           | connections retried, tagged backend                                    |
| redispatches_count      | requests sent to another server after a failure, tagged backend        |
| status_4xx_count        | answers 4xx, tagged backend                                            |
| status_5xx_count        | answers 5xx, tagged backend                                            |
| client_aborts_count     | transfers the client cut, tagged backend                               |
| server_aborts_count     | transfers the server cut, tagged backend                               |
| down_seconds            | down in all since HAProxy started, tagged backend                      |
| since_change_seconds    | since it last went up or down, tagged backend                          |
| ..._not_shown           | past 100 of a list (backends), how many were left out                  |
+-------------------------+------------------------------------------------------------------------+
| GOOD  backends_down 0; queue 0; response_ms steady; connection_errors_count flat.                |
| WATCH servers_up below servers; queue above 0 (every server at its maxconn); response_ms         |
|       climbing; retries_count or redispatches_count rising.                                      |
| BAD   backends_down above 0, or backend_up 0: its requests get 503; status_5xx_count or          |
|       response_errors_count rising: the servers fail.                                            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| haproxy_servers   haproxy.servers.<metric>   every 1m                                            |
+-------------------------+------------------------------------------------------------------------+
| up                      | 1 when HAProxy answers, else 0                                         |
| servers                 | servers, all backends together                                         |
| servers_up              | of those, up                                                           |
| servers_down            | down                                                                   |
| servers_maint           | in maintenance                                                         |
| servers_drain           | draining (taking no new sessions)                                      |
| state                   | 0 up, 1 draining or going down, 2 in maintenance, 3 down, 4 not        |
|                         | checked; tagged backend=<its name>, server=<its name> and              |
|                         | status=<HAProxy's word>                                                |
| check                   | always 1, tagged backend, server and check=<its last check: L4OK,      |
|                         | L7OK, L4TOUT, L4CON, L7STS...> and code=<the HTTP code, when there is  |
|                         | one>                                                                   |
| check_ms                | how long its last check took, tagged backend and server                |
| since_change_seconds    | since it last went up or down, tagged backend and server               |
| down_seconds            | down in all since HAProxy started, tagged backend and server           |
| check_failures_count    | checks that failed (a running total), tagged backend and server        |
| went_down_count         | times it went down, tagged backend and server                          |
| sessions                | sessions now, tagged backend and server                                |
| sessions_limit          | the most it takes (maxconn), tagged backend and server                 |
| queue                   | requests waiting for it, tagged backend and server                     |
| response_ms             | time to the first byte of its answer, on average, tagged backend and   |
|                         | server                                                                 |
| status_5xx_count        | its answers 5xx, tagged backend and server                             |
| response_errors_count   | its answers that failed, tagged backend and server                     |
| connection_errors_count | connections to it that failed, tagged backend and server               |
| weight                  | its weight, tagged backend and server                                  |
| ..._not_shown           | past 100 of a list (servers), how many were left out                   |
+-------------------------+------------------------------------------------------------------------+
| GOOD  servers_down 0; every state 0.                                                             |
| WATCH servers_drain or servers_maint above 0 after a deploy; check_failures_count rising on a    |
|       server that stays up: it flaps; queue above 0.                                             |
| BAD   servers_down above 0: state 3 says which, check what it failed (L4CON refused, L4TOUT no   |
|       answer, L7STS a bad status); every server of a backend down: its requests get 503.         |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the servers in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `haproxy.up` | 1 |  | 0: HAProxy, or its socket, does not answer | 0 where nothing listened, and for a socket file that is not there |
| `haproxy.connections_pct`, `maxconn_reached_count` | Below 70; flat | Above 70; rising | Near 100: new connections wait | 2; 0 |
| `haproxy.busy_pct` | Below 70 | Above 70 | Near 100: out of CPU | 0 |
| `haproxy.backends.backends_down` | 0 |  | Above 0: its requests get 503 | 2: `be_dead` (no server answers) and `be_badcheck` (its check gets a 404) |
| `haproxy.backends.queue` | 0 | Above 0: every server at its `maxconn` |  | 2 in `be_queue` (one at a time) with four slow requests |
| `haproxy.servers.state`, `check` | 0; `L4OK`, `L7OK` | 1 or 2 after a deploy (draining, maintenance) | 3: down; `check` says how | 3 with `L4TOUT`, `L4CON` and `L7STS code=404`; 2 for one in maintenance; 4 for one not checked |
| `haproxy.frontends.status_5xx_count`, `denied_requests_count` | Flat | Denials rising: a rule blocks more | 5xx rising | 4 503s from the dead backend; 4 requests denied |

## How it was tested

**Tested** on 2026-11-24 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-web.sh`, against `compose.web.yaml`: **nginx 1.30.8 and 1.31.10**, **Apache httpd 2.4.71** (event and prefork), **Caddy 2.11.9**, **HAProxy 3.4.8 and 3.2.27**, and **PHP-FPM 8.6.0 and 8.3.37**, in Docker, with certificates the run makes (a CA; one it signed that expires in five days; one that expired; one no CA signed), each server in trouble on purpose. In one minute the run sends answers of every kind (200, 404, 403, 500, 502, 503, 504) and slow PHP requests that fill PHP-FPM's workers and HAProxy's queue, then runs every job of every pack on the next minute and checks what it read; then the trouble one at a time: a configuration edited and not reloaded, then reloaded (nginx, httpd); a log the account may not read; a log that grows faster than the job reads; a configuration Caddy refuses; HAProxy's socket file through `socat` and `nc`; servers that do not answer. Then every job again in a Debian 13 container, with Debian's own awk (mawk 1.3.4), as on Debian and Ubuntu.

- **On Fedora**: every job directly, **131 passed, 0 failed**; then `service-packs.sh` through Vigil, for all five packs (enable, and that CPU and memory are the base pack's; precheck; every job; a server that does not answer read as `up 0`; the metrics reaching the backend): **52 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/fedora/pack-web/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own `openssl`, LibreSSL), against the same servers through SSH tunnels, with the logs, configuration folders and process trees the jobs read made on the Mac: every job, **52 passed, 0 failed**; through Vigil, **52 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/macos/pack-web-macos/console.txt)).

HAProxy does not run on Windows: the pack has no Windows scripts.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
