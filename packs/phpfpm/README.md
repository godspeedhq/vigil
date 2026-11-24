# The phpfpm pack

PHP-FPM's pools, from their status pages. When a PHP site slows down or answers 502 while nginx or httpd look fine, the cause is usually here: every worker busy, requests waiting in the pool's listen queue, `pm.max_children` reached. The pack reads, for each pool, its process manager and uptime, the requests it accepted, its listen queue against its length and its peak, its workers (idle, active, all, the most active at once), how often it hit `pm.max_children`, its slow requests and its memory peak; then its workers one by one, summed up: how many are in each state, the longest request running now, and the most memory, CPU, requests and age of any. It never prints a request's URI or script, only counts. Linux and macOS: PHP-FPM does not run on Windows.

**A status page for each pool, through the web server, and `curl`.** PHP-FPM serves its status page over FastCGI, so the web server in front of it passes the page on, from this machine only.

1. **Turn the page on** in each pool's configuration (`www.conf`), then reload PHP-FPM:

   ```ini
   pm.status_path = /fpm-status
   ```

2. **Pass it on, from this machine only.** With nginx:

   ```nginx
   location = /fpm-status {
       allow 127.0.0.1;
       deny all;
       include fastcgi_params;
       fastcgi_param SCRIPT_NAME /fpm-status;
       fastcgi_param SCRIPT_FILENAME /fpm-status;
       fastcgi_pass unix:/run/php-fpm/www.sock;
   }
   ```

   With httpd:

   ```apache
   <Location "/fpm-status">
       Require local
       SetHandler "proxy:unix:/run/php-fpm/www.sock|fcgi://localhost"
   </Location>
   ```

   A second pool has its own socket and its own path (`/fpm-status-api`, say).
3. `vigil pack enable phpfpm`, then in `vigil.config` set the job's `PHPFPM_STATUS_URLS`: one URL for each pool, separated by spaces (`http://127.0.0.1/fpm-status http://127.0.0.1/fpm-status-api`).

**A pool that does not answer is a reading**, `up 0` tagged with its URL, and the run succeeds. A URL that answers but is not a PHP-FPM status page fails the run.

## What it needs

| | Linux | macOS |
| --- | --- | --- |
| On the Vigil machine | `curl` | `curl` |
| PHP-FPM | 7.4 and later (`memory_peak_bytes`: 8.4 and later) | |
| A page | each pool's `pm.status_path`, passed on by the web server (steps 1 and 2) | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `phpfpm_pools` | Each pool: up, its process manager, uptime, requests accepted, listen queue against its length and its peak, workers idle, active, all and the most active at once, times `pm.max_children` was reached, slow requests, memory peak; its workers by state, the longest request running, and the most memory, CPU, requests and age of any worker | minute |

The job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `phpfpm.up`.

```text
+--------------------------------------------------------------------------------------------------+
| phpfpm_pools   phpfpm.<metric>   every 1m                                                        |
+-------------------------------+------------------------------------------------------------------+
| up                            | 1 when the page answers, else 0, tagged url=<it>                 |
| timed_out                     | 1 when the page was reached but did not answer in 10 seconds,    |
|                               | tagged url: the status page waits for a free worker like any     |
|                               | request, so this is every worker busy (or the web server stuck); |
|                               | 0 when it answered or nothing listened                           |
| info                          | always 1, tagged pool=<its name> and pm=<static, dynamic or      |
|                               | ondemand>                                                        |
| uptime_seconds                | since the pool started, tagged pool                              |
| accepted_count                | requests accepted (a running total), tagged pool                 |
| listen_queue                  | requests waiting for a free worker, tagged pool                  |
| listen_queue_max              | the most that waited at once since it started, tagged pool       |
| listen_queue_len              | the most that may wait, tagged pool                              |
| listen_queue_pct              | listen_queue as a percentage of listen_queue_len, tagged pool    |
| idle_processes                | workers waiting for a request, tagged pool                       |
| active_processes              | workers serving one, tagged pool                                 |
| total_processes               | all its workers, tagged pool                                     |
| active_max                    | the most active at once since it started, tagged pool            |
| max_children_reached_count    | times it wanted another worker and pm.max_children said no (a    |
|                               | running total), tagged pool                                      |
| slow_requests_count           | requests slower than request_slowlog_timeout (a running total),  |
|                               | tagged pool                                                      |
| memory_peak_bytes             | the most memory the pool used (PHP 8.4 and later), tagged pool   |
| processes_in_state            | workers in one state, tagged pool and state=<Idle, Running,      |
|                               | Reading_headers, Finishing, Ending...>                           |
| longest_request_ms            | the longest request running now, tagged pool                     |
| last_request_memory_max_bytes | the most memory any worker's last request used, tagged pool      |
| last_request_cpu_max_pct      | the most CPU any worker's last request used, tagged pool         |
| process_requests_max          | the most requests one worker has served (pm.max_requests         |
|                               | restarts it), tagged pool                                        |
| process_age_max_seconds       | the oldest worker, tagged pool                                   |
+-------------------------------+------------------------------------------------------------------+
| GOOD  up 1; listen_queue 0; max_children_reached_count flat; idle_processes above 0.             |
| WATCH slow_requests_count rising (the slow log says which scripts); active_max near              |
|       total_processes; longest_request_ms in seconds.                                            |
| BAD   up 0; timed_out 1: no worker free even for the status page; listen_queue above 0, or       |
|       max_children_reached_count rising: every worker is busy and requests wait, or time out as  |
|       502 or 504 at the web server: raise pm.max_children, or find what holds the workers        |
|       (longest_request_ms).                                                                      |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the servers in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `phpfpm.up`, `timed_out` | 1; 0 |  | `timed_out 1`: no worker free, even for the status page; `up 0` with `timed_out 0`: nothing there | `timed_out 1` for the pool of two with three slow requests; 0 where nothing listened |
| `phpfpm.listen_queue`, `listen_queue_max` | 0 |  | Above 0: requests wait for a worker | A peak of 7 in the full pool |
| `phpfpm.max_children_reached_count` | Flat |  | Rising: raise `pm.max_children`, or find what holds the workers | 1 |
| `phpfpm.slow_requests_count` | Flat | Rising: the slow log says which scripts |  | 12 |
| `phpfpm.longest_request_ms` | Well below your timeouts | In seconds |  | 16,483 ms while 40-second requests ran |
| `phpfpm.idle_processes` | Above 0 | 0 |  | 0 in the www pool of PHP 8.3 while slow requests ran |

## How it was tested

**Tested** on 2026-11-24 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-web.sh`, against `compose.web.yaml`: **nginx 1.30.8 and 1.31.10**, **Apache httpd 2.4.71** (event and prefork), **Caddy 2.11.9**, **HAProxy 3.4.8 and 3.2.27**, and **PHP-FPM 8.6.0 and 8.3.37**, in Docker, with certificates the run makes (a CA; one it signed that expires in five days; one that expired; one no CA signed), each server in trouble on purpose. In one minute the run sends answers of every kind (200, 404, 403, 500, 502, 503, 504) and slow PHP requests that fill PHP-FPM's workers and HAProxy's queue, then runs every job of every pack on the next minute and checks what it read; then the trouble one at a time: a configuration edited and not reloaded, then reloaded (nginx, httpd); a log the account may not read; a log that grows faster than the job reads; a configuration Caddy refuses; HAProxy's socket file through `socat` and `nc`; servers that do not answer. Then every job again in a Debian 13 container, with Debian's own awk (mawk 1.3.4), as on Debian and Ubuntu.

- **On Fedora**: every job directly, **131 passed, 0 failed**; then `service-packs.sh` through Vigil, for all five packs (enable, and that CPU and memory are the base pack's; precheck; every job; a server that does not answer read as `up 0`; the metrics reaching the backend): **52 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/fedora/pack-web/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own `openssl`, LibreSSL), against the same servers through SSH tunnels, with the logs, configuration folders and process trees the jobs read made on the Mac: every job, **52 passed, 0 failed**; through Vigil, **52 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-24/macos/pack-web-macos/console.txt)).

**What the tests found.** PHP-FPM serves its status page with a worker of the pool: with every worker busy, the page waits with the requests, and the job reads `timed_out 1`. Its slow-request count needs ptrace (in Docker, `cap_add: SYS_PTRACE`). PHP-FPM does not run on Windows: the pack has no Windows scripts.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
