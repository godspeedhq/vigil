# The jetty pack

Eclipse Jetty 9.4 to 12, on this machine or any it can reach, over JMX with a password and TLS: the server and its web applications, whether it is low on resources, its requests and responses by class and their times, its thread pool, connections and their limits, the QoS handler (12), sessions and Jetty's own byte buffers. It reports Jetty's, never its JVM: heap, garbage collection, threads, CPU and open files are the [jvm pack](../jvm/README.md)'s. Linux, macOS and Windows.

**Only tables, and one jar**, as the [tomcat pack](../tomcat/README.md): the probe and `_probe.tables` (written by `tools/jetty/gen.py`), run with Java 11 or later, a JDK or a JRE, once the jar matches the SHA-256 each script carries. Jetty 9.4 to 11 and Jetty 12 name some of their MBeans differently, and time requests in milliseconds and nanoseconds: the pack reads both, and prints seconds.

1. **Jetty's modules**: `jmx`, which puts Jetty's MBeans on the JVM's own MBean server, and for `jetty_requests`, the statistics module (`stats` on 9.4 to 11, `statistics` on 12). The thread pool, connection limit, low resources and QoS modules are read when they are on.

   ```sh
   java -jar $JETTY_HOME/start.jar --add-modules=jmx,statistics   # 9.4 to 11: --add-to-start=jmx,stats
   ```
2. **Turn on the JVM's JMX**, with a password and TLS, in Jetty's JVM options: in `start.d/jvm.ini` (with `--exec`) or `JAVA_OPTIONS`, the same `com.sun.management.jmxremote` options as the [tomcat pack](../tomcat/README.md)'s step 1. Jetty's own `jmx-remote` module opens a connector without a password: leave it off.
3. `vigil pack enable jetty`, then in `vigil.config` set the jobs' `JETTY_JMX` (`web1: jmxs=jetty1.example.com:9010; ...`), `JETTY_JMX_USER`, `JETTY_CACERT`, and a secret line on each job with the password, as the [tomcat pack](../tomcat/README.md)'s step 4: `secret = JETTY_JMX_PASSWORD=secret:JETTY_JMX_PASSWORD`, then `vigil secret set JETTY_JMX_PASSWORD`.

**What Jetty calls a failed app.** By default Jetty keeps a web application whose start failed (a listener or a filter it cannot load) `STARTED`, and answers 503 for it: `app_up` says 1, and the 503s show in `jetty_requests`' `responses_5xx_count`. With `throwUnavailableOnStartupException` set, the app is `FAILED`, and `app_up` says 0. On 9.4 to 11 a request that ended in an exception is counted in `thrown_count`, not `responses_5xx_count`; on 12 it is a 5xx.

**Jetty's JVM: the jvm pack.** Install it beside this one and name each Jetty in `JVM_TARGETS` as here, so a Jetty's figures and its JVM's line up.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | Java 11 or later, a JDK or a JRE (`JAVA_HOME` or `java` on the PATH) | The same | The same |
| The server | Eclipse Jetty 9.4 to 12, with its `jmx` module and the JVM's JMX on (steps 1 and 2) | | |
| A secret | `JETTY_JMX_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 3) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `jetty_status` | Whether each Jetty answers, its version, the server and each app started, how long since it started (9.4 to 11), and whether it is low on resources, and since when | minute |
| `jetty_requests` | Requests, active now and at most, responses 1xx to 5xx, failures, those that threw (9.4 to 11), async requests, bytes, the slowest, mean and total time | minute |
| `jetty_threads` | The thread pool: threads, busy, idle, ready, used by apps, its most and fewest, jobs queued, how much is in use, low on threads, leased and reserved | minute |
| `jetty_connections` | Connections open, at most and opened, how long they last, bytes and messages in and out (every connector added up); the connection limit and those waiting for it; the QoS handler's limit and requests suspended (12), and its totals, suspended, refused and expired (12.1) | minute |
| `jetty_sessions` | Each app's sessions now, the most at once and every one cached; created, how long they live, their timeout | minute |
| `jetty_buffers` | The memory Jetty's own buffer pools hold, direct and heap, and how much is free (12) | 5 minutes |


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `jetty.version`.

```text
+--------------------------------------------------------------------------------------------------+
| jetty_status   jetty.<metric>   every 1m                                                         |
+-------------------+------------------------------------------------------------------------------+
| jmx_up            | 1 when JMX answers, else 0, tagged jetty=<its name> and jmx=<its address>    |
| version           | always 1, tagged version=<Jetty's version, 12.1.15>                          |
| up                | 1 when the server is started, else 0                                         |
| uptime_seconds    | since the server started (9.4 to 11: 12 gives it as a text)                  |
| app_up            | 1 when the web application is started, else 0 (FAILED, STOPPED), tagged      |
|                   | context=<its name>. Jetty keeps an app whose start failed STARTED and        |
|                   | answers 503, unless it throws (throwUnavailableOnStartupException): its 503s |
|                   | show in jetty_requests                                                       |
| low_on_resources  | 1 when the low resources monitor says so, else 0                             |
| low_since_seconds | how long it has been low on resources, when it is                            |
| ..._not_shown     | past 100 of a list (version, up, uptime_seconds, app_up, low_on_resources,   |
|                   | low_since_seconds), how many were left out                                   |
+-------------------+------------------------------------------------------------------------------+
| GOOD  jmx_up 1; up 1 and every app_up 1; low_on_resources 0.                                     |
| WATCH uptime_seconds falling back: Jetty restarted; version older than the newest of its line.   |
| BAD   jmx_up 0: Jetty or its JMX is down; app_up 0: that app answers 404 (and                    |
|       responses_5xx_count rising may be an app that failed to start, answering 503);             |
|       low_on_resources 1: Jetty is closing idle connections early and may stop accepting.        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jetty_requests   jetty.requests.<metric>   every 1m                                              |
+----------------------------+---------------------------------------------------------------------+
| jmx_up                     | 1 when JMX answers, else 0, tagged jetty=<its name> and jmx=<its    |
|                            | address>                                                            |
| requests_count             | requests                                                            |
| active                     | requests being handled now                                          |
| active_max                 | the most at once                                                    |
| responses_1xx_count        | responses with a 1xx status                                         |
| responses_2xx_count        | with a 2xx status                                                   |
| responses_3xx_count        | with a 3xx status                                                   |
| responses_4xx_count        | with a 4xx status                                                   |
| responses_5xx_count        | with a 5xx status (on 9.4 to 11, not those that threw:              |
|                            | thrown_count)                                                       |
| failures_count             | requests that failed (12)                                           |
| handling_failures_count    | failures while handling (12)                                        |
| thrown_count               | requests that ended in an exception (9.4 to 11)                     |
| dispatched_count           | dispatches to the application (9.4 to 11)                           |
| dispatched_active          | dispatches running now (9.4 to 11)                                  |
| handling_active            | requests being handled by the application now (12)                  |
| async_count                | asynchronous requests (9.4 to 11)                                   |
| async_waiting              | asynchronous requests waiting now (9.4 to 11)                       |
| expired_count              | asynchronous requests that timed out (9.4 to 11)                    |
| received_bytes             | bytes of requests read (12)                                         |
| sent_bytes                 | bytes of responses written                                          |
| slowest_seconds            | the slowest request                                                 |
| mean_seconds               | the mean time of a request                                          |
| total_seconds              | the time of every request, added up                                 |
| handling_slowest_seconds   | the slowest time in the application, apart from reading and writing |
|                            | (12)                                                                |
| handling_mean_seconds      | the mean time in the application (12)                               |
| handling_active_max        | the most in the application at once (12)                            |
| dispatched_slowest_seconds | the slowest dispatch to the application (9.4 to 11)                 |
| dispatched_mean_seconds    | the mean time of a dispatch (9.4 to 11)                             |
| dispatched_active_max      | the most dispatches at once (9.4 to 11)                             |
| async_waiting_max          | the most asynchronous requests waiting at once (9.4 to 11)          |
| stats_seconds              | since these statistics began (9.4 to 11): the totals count from     |
|                            | then                                                                |
| ..._not_shown              | past 100 of a list (requests_count, active, active_max,             |
|                            | responses_1xx_count, responses_2xx_count, responses_3xx_count,      |
|                            | responses_4xx_count, responses_5xx_count, failures_count,           |
|                            | handling_failures_count, thrown_count, dispatched_count,            |
|                            | dispatched_active, handling_active, async_count, async_waiting,     |
|                            | expired_count, received_bytes, sent_bytes, slowest_seconds,         |
|                            | mean_seconds, total_seconds, handling_slowest_seconds,              |
|                            | handling_mean_seconds, handling_active_max,                         |
|                            | dispatched_slowest_seconds, dispatched_mean_seconds,                |
|                            | dispatched_active_max, async_waiting_max, stats_seconds), how many  |
|                            | were left out                                                       |
+----------------------------+---------------------------------------------------------------------+
| GOOD  responses_5xx_count flat; active well below the thread pool's max; mean_seconds steady.    |
| WATCH responses_4xx_count rising faster than requests: clients asking for what is not there, or  |
|       refused.                                                                                   |
| BAD   responses_5xx_count rising: the server or the apps are failing; active near the pool's     |
|       max: requests are waiting for a thread.                                                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jetty_threads   jetty.threads.<metric>   every 1m                                                |
+-------------------+------------------------------------------------------------------------------+
| jmx_up            | 1 when JMX answers, else 0, tagged jetty=<its name> and jmx=<its address>    |
| threads           | threads it has, tagged id=<the pool>                                         |
| busy              | busy threads, tagged the same                                                |
| idle              | idle threads, tagged the same                                                |
| ready             | threads ready for a job now, tagged the same                                 |
| utilized          | threads running a job of the application, tagged the same                    |
| max_threads       | the most it may have, tagged the same                                        |
| min_threads       | the fewest it keeps, tagged the same                                         |
| queue             | jobs waiting for a thread, tagged the same                                   |
| utilization_pct   | how much of the pool is in use, tagged the same                              |
| low_on_threads    | 1 when it is low on threads, else 0, tagged the same                         |
| leased            | threads leased to Jetty's own work (acceptors, selectors), tagged the same   |
| reserved          | threads reserved and available, tagged the same                              |
| max_available     | the most that could run the application, tagged the same                     |
| reserved_capacity | the most threads it keeps reserved for quick work                            |
| reserved_pending  | reserved threads starting now                                                |
| ..._not_shown     | past 100 of a list (threads, busy, idle, ready, utilized, max_threads,       |
|                   | min_threads, queue, utilization_pct, low_on_threads, leased, reserved,       |
|                   | max_available, reserved_capacity, reserved_pending), how many were left out  |
+-------------------+------------------------------------------------------------------------------+
| GOOD  busy well below max_threads; queue 0; low_on_threads 0.                                    |
| WATCH utilization_pct above 80 for minutes; queue above 0 now and then.                          |
| BAD   queue growing and low_on_threads 1: every thread is busy and requests wait. Find what      |
|       holds them (the jvm pack's threads and deadlocks).                                         |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jetty_connections   jetty.connections.<metric>   every 1m                                        |
+-------------------------+------------------------------------------------------------------------+
| jmx_up                  | 1 when JMX answers, else 0, tagged jetty=<its name> and jmx=<its       |
|                         | address>                                                               |
| open                    | connections open now                                                   |
| open_max                | the most open at once                                                  |
| opened_count            | connections opened                                                     |
| duration_max_seconds    | the longest a connection lasted                                        |
| duration_mean_seconds   | how long a connection lasts, on average                                |
| received_bytes          | bytes received                                                         |
| sent_bytes              | bytes sent                                                             |
| received_messages_count | messages received (requests, frames)                                   |
| sent_messages_count     | messages sent                                                          |
| limited                 | connections the connection limit counts                                |
| limit                   | its limit                                                              |
| limit_pending           | connections accepted but waiting for it (12)                           |
| qos_max                 | the QoS handler's limit of requests at once (12)                       |
| qos_suspended           | requests suspended for it now (12)                                     |
| qos_exceeded_count      | requests refused for it (12.1)                                         |
| qos_expired_count       | requests that waited too long for it (12.1)                            |
| qos_requests_count      | requests it has seen (12.1)                                            |
| qos_suspended_count     | requests it has suspended (12.1)                                       |
| qos_max_suspended       | the most it suspends, then it refuses (12)                             |
| selector_keys           | connections Jetty's selectors watch, every one added up                |
| selects_count           | times they have selected                                               |
| ..._not_shown           | past 100 of a list (open, open_max, opened_count,                      |
|                         | duration_max_seconds, duration_mean_seconds, received_bytes,           |
|                         | sent_bytes, received_messages_count, sent_messages_count, limited,     |
|                         | limit, limit_pending, qos_max, qos_suspended, qos_exceeded_count,      |
|                         | qos_expired_count, qos_requests_count, qos_suspended_count,            |
|                         | qos_max_suspended, selector_keys, selects_count), how many were left   |
|                         | out                                                                    |
+-------------------------+------------------------------------------------------------------------+
| GOOD  open well below limit; limit_pending 0; qos_exceeded_count flat.                           |
| WATCH open near limit; qos_suspended above 0: requests wait for the QoS handler.                 |
| BAD   limited at limit with limit_pending above 0: Jetty is not accepting more;                  |
|       qos_exceeded_count rising: requests refused.                                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jetty_sessions   jetty.sessions.<metric>   every 1m                                              |
+--------------------+-----------------------------------------------------------------------------+
| jmx_up             | 1 when JMX answers, else 0, tagged jetty=<its name> and jmx=<its address>   |
| current            | sessions in the cache now, tagged context=<its app>; the most first         |
| most               | the most at once, tagged the same                                           |
| cached_count       | sessions it has held, tagged the same                                       |
| created_count      | sessions created, tagged the same                                           |
| alive_mean_seconds | how long a session lives, on average, tagged the same                       |
| alive_max_seconds  | the longest a session lived, tagged the same                                |
| timeout_seconds    | how long an idle session lives, tagged the same                             |
| ..._not_shown      | past 100 of a list (current, most, cached_count, created_count,             |
|                    | alive_mean_seconds, alive_max_seconds, timeout_seconds), how many were left |
|                    | out                                                                         |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  current rising and falling with traffic.                                                   |
| WATCH current climbing without falling back: sessions created and never used again hold memory   |
|       until they time out.                                                                       |
| BAD   current far above what your users explain: a client or a bot making a session each         |
|       request.                                                                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jetty_buffers   jetty.buffers.<metric>   cron 2/5 * * * *                                        |
+-------------------+------------------------------------------------------------------------------+
| jmx_up            | 1 when JMX answers, else 0, tagged jetty=<its name> and jmx=<its address>    |
| direct_bytes      | direct memory its pools hold                                                 |
| heap_bytes        | heap memory its pools hold                                                   |
| direct_free_bytes | of the direct, free to reuse (12)                                            |
| heap_free_bytes   | of the heap, free to reuse (12)                                              |
| ..._not_shown     | past 100 of a list (direct_bytes, heap_bytes, direct_free_bytes,             |
|                   | heap_free_bytes), how many were left out                                     |
+-------------------+------------------------------------------------------------------------------+
| GOOD  direct_bytes and heap_bytes steady.                                                        |
| WATCH direct_bytes growing without falling back.                                                 |
| BAD   direct_bytes near the JVM's -XX:MaxDirectMemorySize: Jetty will fail to allocate (the jvm  |
|       pack's buffers job shows the limit).                                                       |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points; "In our tests" is what four Jettys in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `jetty.jmx_up` | 1 | | 0: Jetty, or its JMX, is down | 0 for a target where nothing listens |
| `jetty.threads.queue` | 0 | Above 0 now and then | Growing, with `low_on_threads` 1: every thread busy, requests waiting | 56 on 9.4 and 22 on 11, with 24 and 23 of 24 threads busy and `low_on_threads` 1 |
| `jetty.low_on_resources` | 0 | | 1: Jetty is closing idle connections early, and may stop accepting | 1 on 9.4 and 11; 0 on 12, where QoS kept threads free |
| `jetty.connections.qos_suspended` (12) | 0 | Above 0: requests waiting for the QoS limit | Growing, with `qos_exceeded_count` rising: requests refused | 24 suspended, at the limit of 16 |
| `jetty.connections.limited` against `limit` | Well below | Near it | At it: Jetty stops accepting until one closes | 40 of 40 on 9.4, 12.0 and 12.1; 22 on 11, whose threads filled first |
| `jetty.requests.responses_5xx_count` (as a rate) | Flat | Rising | Rising fast: an app is failing, or one that failed to start answers 503 | 3 on 9.4 and 11, the failed app's 503s; 6 on 12, with the pages that threw |
| `jetty.requests.thrown_count` (9.4 to 11, as a rate) | Flat | Rising | | 3, the failing pages |
| `jetty.threads.utilization_pct` | Below 70 | Above 80 for minutes | Near 100 | 100 on 9.4, 95.5 on 11; 72.7 on 12 |
| `jetty.sessions.current` | Rising and falling with traffic | Climbing without falling back | | Not caused: 51 or 52, every visit's, then expiring |
| `jetty.app_up` | 1 | | 0: the app is FAILED or stopped | Not caused: the app that failed to start read 1, as Jetty keeps it STARTED (above) |

## How it was tested

**Tested** on 2026-11-23 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-jetty.sh`, against **Jetty 9.4.58 on Java 11, 11.0.26 on Java 17, 12.0.41 on Java 21 and 12.1.15 on Java 21**, each in Docker with JMX over TLS with a password and a `readonly` user, 24 threads, a connection limit of 40, the low resources monitor watching threads, QoS at 16 on 12, a shop of JSPs and an app that fails to start. Trouble on purpose, on each: 50 visits, 3 failing pages, 3 not there, 3 to the failed app, and 45 requests held for 4 minutes.
- **On Fedora**: every job directly, each reading checked on all four, then `service-packs.sh` through Vigil, then every job on Temurin's JRE 11, and a probe changed by one byte refused: **99 passed, 0 failed**, and through Vigil **22 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/fedora/pack-jetty/console.txt)).
  The macOS and Windows runs below read the pack before its last readings were added (time in the application, dispatch times, reserved threads, the QoS handler's totals, the selectors); those are rows of its table, read by the same jar, and were checked on Fedora.
- **On macOS** (12.7.6, bash 3.2), with the jar built there, through SSH tunnels: every job, then on Temurin's JRE 21, **12 passed, 0 failed**; through Vigil, **22 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/macos/pack-jetty-macos/console.txt)).
- **On Windows**, from a packs release built by `tools/release/packs.sh`, as an account that is not an administrator: `Service-Packs.ps1` through Vigil, **22 passed, 0 failed**, then every job from the release on a JRE, **2 passed, 0 failed**: on Windows PowerShell 5.1 and PowerShell 7 on Windows 11 ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows/pack-jetty-windows/console.txt)), and on Windows PowerShell 5.1 on Windows Server 2025 ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows-server-2025/pack-jetty-windows/console.txt)). The password came from an `env:` reference: Windows refuses its data protection to a logon by SSH key.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
