# The tomcat pack

Apache Tomcat 9, 10.1 and 11, on this machine or any it can reach, over JMX with a password and TLS. The pack reads Tomcat's own figures: its connectors and their requests, the threads and executors that serve them, the requests running now and those stuck, each web application, its sessions and servlets, the database connection pools Tomcat makes, the resource cache and JSPs. It reports Tomcat's, never its JVM: heap, garbage collection, threads, CPU and open files are the [jvm pack](../jvm/README.md)'s. Linux, macOS and Windows.

**Only tables, and one jar.** The pack is the probe ([`tools/probe/DESIGN.md`](../../tools/probe/DESIGN.md)) and a table of what to read (`_probe.tables`, written by `tools/tomcat/gen.py`): no code of its own, nothing of Tomcat's on the Vigil machine. It runs `_probe.jar` with Java 11 or later, a JDK or a JRE, once the jar matches the SHA-256 each script carries, as every pack on the probe does. A copy of the pack straight from the repository has no jar, and its scripts say so.

1. **Turn on Tomcat's JMX**, with a password and TLS, in `bin/setenv.sh` (`setenv.bat` on Windows) beside `catalina.sh`, which Tomcat reads as it starts:

   ```sh
   CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.port=9010 -Dcom.sun.management.jmxremote.rmi.port=9010 \
     -Djava.rmi.server.hostname=tomcat1.example.com -Dcom.sun.management.jmxremote.authenticate=true \
     -Dcom.sun.management.jmxremote.password.file=$CATALINA_BASE/conf/jmx.password \
     -Dcom.sun.management.jmxremote.access.file=$CATALINA_BASE/conf/jmx.access \
     -Dcom.sun.management.jmxremote.ssl=true -Dcom.sun.management.jmxremote.registry.ssl=true \
     -Djavax.net.ssl.keyStore=$CATALINA_BASE/conf/jmx.p12 -Djavax.net.ssl.keyStorePassword=..."
   ```

   `jmx.password` holds `vigil <password>` and must be readable by Tomcat's account alone; `jmx.access` holds `vigil readonly`. A `readonly` user is all the pack needs: it reads attributes and runs nothing. `java.rmi.server.hostname` is the name the pack connects by, and the name on the certificate: JMX hands that name back to the client, and a wrong one (or a container's own address) makes the connection fail after the login.
2. **For stuck requests**, put Tomcat's `StuckThreadDetectionValve` on the Host in `server.xml` (or on an app, in its `context.xml`): `<Valve className="org.apache.catalina.valves.StuckThreadDetectionValve" threshold="60"/>` calls a request stuck after 60 seconds. Without it, `tomcat_inflight` still reports every request running now, and how long it has run.
3. **For connection pools**: DBCP, Tomcat's default for a `<Resource>`, is read as it is. Tomcat's JDBC pool (`factory="org.apache.tomcat.jdbc.pool.DataSourceFactory"`) needs `jmxEnabled="true"`, its default. HikariCP is read when it registers its MBeans (`registerMbeans="true"`).
4. `vigil pack enable tomcat`, then in `vigil.config` set the jobs' `TOMCAT_JMX` to each Tomcat (a name, then its address: `web1: jmxs=tomcat1.example.com:9010; web2: jmxs=tomcat2.example.com:9010`), `TOMCAT_JMX_USER` to `vigil`, `TOMCAT_CACERT` to the CA that signed the certificate (or leave it empty for Java's own), and add a secret line to each job, under its `env` lines, and the password:

   ```ini
   secret = TOMCAT_JMX_PASSWORD=secret:TOMCAT_JMX_PASSWORD
   ```

   ```sh
   vigil secret set TOMCAT_JMX_PASSWORD
   ```

**Tomcat's JVM: the jvm pack.** Install it beside this one and name each Tomcat in `JVM_TARGETS` as here (`web1: jmxs=tomcat1.example.com:9010`), so a Tomcat's figures and its JVM's line up on one dashboard. Threads stuck here are threads blocked there: `jvm_deadlocks` and `jvm_contention` say on what.

**The certificate is always checked**, against `TOMCAT_CACERT` or Java's own CAs, and against the name the pack connects by. A wrong password or a certificate it cannot trust fails the run, saying so; a Tomcat that does not answer is a reading, `jmx_up 0`, and the run succeeds.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | Java 11 or later, a JDK or a JRE (`JAVA_HOME` or `java` on the PATH) | The same | The same |
| The server | Apache Tomcat 9, 10.1 or 11, with JMX on (step 1) | | |
| A secret | `TOMCAT_JMX_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 4) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `tomcat_status` | Whether each Tomcat answers, its version, and its server, engine, hosts and connectors started | minute |
| `tomcat_requests` | Each connector's requests, errors (status 400 and up), bytes in and out, time spent and slowest request | minute |
| `tomcat_threads` | Each connector's threads busy against its most, connections open, kept alive and their limit, paused; each Executor's threads, queue and the most it may queue | minute |
| `tomcat_inflight` | The requests running now, the longest first, each with how long so far; the threads the stuck thread valve calls stuck, and those it interrupted | minute |
| `tomcat_apps` | Each web application: started or not (FAILED), since when, how long it took to start, its requests, errors, time and slowest; the most errors first | 2 minutes |
| `tomcat_sessions` | Each app's sessions now, the most at once, its limit and those refused for it, created and expired and their rates, how long sessions live | minute |
| `tomcat_servlets` | Each servlet's (JSPs too) time, requests, errors and slowest request; where the time goes, first | 5 minutes |
| `tomcat_jdbc` | Each connection pool (DBCP, Tomcat's JDBC pool, HikariCP): in use, idle, at most, threads waiting; borrowed, returned, created, abandoned | minute |
| `tomcat_cache` | Each app's resource cache (lookups, hits, size against its most) and its JSPs loaded, reloaded and unloaded | 5 minutes |

Past 100 of anything (apps, servlets, sessions' apps, requests running), the pack shows the worst first (the most errors, sessions, time; the longest running) and counts the rest in a `_not_shown` line.


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `tomcat.version`.

```text
+--------------------------------------------------------------------------------------------------+
| tomcat_status   tomcat.<metric>   every 1m                                                       |
+---------------+----------------------------------------------------------------------------------+
| jmx_up        | 1 when JMX answers, else 0, tagged tomcat=<its name> and jmx=<its address>       |
| version       | always 1, tagged version=<Tomcat's version, 11.0.29.0>                           |
| up            | 1 when the server is started, else 0                                             |
| engine_up     | 1 when the engine is started, else 0                                             |
| jvm_route     | always 1, tagged route=<its jvmRoute>, when it has one (behind a load balancer)  |
| host_up       | 1 when the host is started, else 0, tagged host=<its name>                       |
| connector_up  | 1 when the connector is started, else 0 (stopped, or its port taken), tagged     |
|               | port=<its port>                                                                  |
| ..._not_shown | past 100 of a list (host_up, connector_up), how many were left out               |
+---------------+----------------------------------------------------------------------------------+
| GOOD  jmx_up 1; up, engine_up, host_up and every connector_up 1.                                 |
| WATCH version older than the newest of its line: Tomcat fixes security issues in most releases.  |
| BAD   jmx_up 0: Tomcat is down, or its JMX is; connector_up 0: that port takes no requests.      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| tomcat_requests   tomcat.requests.<metric>   every 1m                                            |
+--------------------+-----------------------------------------------------------------------------+
| jmx_up             | 1 when JMX answers, else 0, tagged tomcat=<its name> and jmx=<its address>  |
| requests_count     | requests, tagged name=<the connector: http-nio-8080>                        |
| errors_count       | of those, answered with a status of 400 or more, tagged the same            |
| sent_bytes         | bytes sent, tagged the same                                                 |
| received_bytes     | bytes received, tagged the same                                             |
| processing_seconds | time spent on requests, tagged the same                                     |
| slowest_seconds    | the slowest request since Tomcat started, tagged the same                   |
| ..._not_shown      | past 100 of a list (requests_count, errors_count, sent_bytes,               |
|                    | received_bytes, processing_seconds, slowest_seconds), how many were left    |
|                    | out                                                                         |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  errors_count rising far slower than requests_count; processing_seconds rising in step with |
|       requests.                                                                                  |
| WATCH errors_count rising faster than usual: clients or the apps are failing (404s count too).   |
| BAD   requests_count flat where there should be traffic; the share of errors climbing;           |
|       processing_seconds per request climbing: the apps or what they call are slow.              |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| tomcat_threads   tomcat.threads.<metric>   every 1m                                              |
+----------------------+---------------------------------------------------------------------------+
| jmx_up               | 1 when JMX answers, else 0, tagged tomcat=<its name> and jmx=<its         |
|                      | address>                                                                  |
| busy                 | threads handling a request now, tagged name=<the connector> (none for a   |
|                      | connector on an Executor)                                                 |
| threads              | threads it has, tagged the same                                           |
| max_threads          | the most it may have, tagged the same                                     |
| connections          | connections open, tagged the same                                         |
| max_connections      | the most it accepts, then they wait in the backlog, tagged the same       |
| keep_alive           | connections kept alive between requests, tagged the same                  |
| backlog_max          | the backlog of connections waiting to be accepted, its size, tagged the   |
|                      | same                                                                      |
| paused               | 1 when the connector is paused (takes no requests), tagged the same       |
| executor_busy        | an Executor's threads handling a request now, tagged name=<the Executor>  |
| executor_threads     | threads it has, tagged the same                                           |
| executor_max_threads | the most it may have, tagged the same                                     |
| executor_largest     | the most it has had at once, tagged the same                              |
| executor_queue       | requests waiting for a thread, tagged the same                            |
| executor_max_queue   | the most that may wait, then they are refused, tagged the same            |
| executor_done_count  | requests it has handled, tagged the same                                  |
| utility_busy         | Tomcat's utility executor's threads busy (background work: session        |
|                      | expiry, reloading)                                                        |
| utility_threads      | its threads                                                               |
| utility_tasks_count  | tasks given to it                                                         |
| ..._not_shown        | past 100 of a list (busy, threads, max_threads, connections,              |
|                      | max_connections, keep_alive, backlog_max, paused, executor_busy,          |
|                      | executor_threads, executor_max_threads, executor_largest, executor_queue, |
|                      | executor_max_queue, executor_done_count), how many were left out          |
+----------------------+---------------------------------------------------------------------------+
| GOOD  busy, or executor_busy, well below max_threads; executor_queue 0; connections well below   |
|       max_connections.                                                                           |
| WATCH busy near max_threads for minutes; executor_queue above 0: requests are waiting for a      |
|       thread.                                                                                    |
| BAD   busy at max_threads with executor_queue near executor_max_queue, or connections at         |
|       max_connections: Tomcat is turning requests away. Find what holds the threads              |
|       (tomcat_inflight, the jvm pack's threads and deadlocks).                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| tomcat_inflight   tomcat.inflight.<metric>   every 1m                                            |
+-------------------------+------------------------------------------------------------------------+
| jmx_up                  | 1 when JMX answers, else 0, tagged tomcat=<its name> and jmx=<its      |
|                         | address>                                                               |
| running_seconds         | how long a request running now has run, tagged worker=<the connector>  |
|                         | and name=<its processor>; the longest first                            |
| stuck_threads           | threads on a request longer than the valve's threshold, tagged         |
|                         | host=<its host>                                                        |
| stuck_threshold_seconds | the valve's threshold, tagged the same                                 |
| interrupted_count       | stuck threads the valve has interrupted (with                          |
|                         | interruptThreadThreshold), tagged the same                             |
| ..._not_shown           | past 100 of a list (running_seconds, stuck_threads,                    |
|                         | stuck_threshold_seconds, interrupted_count), how many were left out    |
+-------------------------+------------------------------------------------------------------------+
| GOOD  running_seconds of a second or less; stuck_threads 0.                                      |
| WATCH running_seconds in tens of seconds for some requests; stuck_threads above 0 now and then.  |
| BAD   stuck_threads staying above 0, or rising: requests that never end hold threads until none  |
|       are left. A thread dump shows where they wait (a database, a lock, another service).       |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| tomcat_apps   tomcat.app.<metric>   every 2m                                                     |
+--------------------+-----------------------------------------------------------------------------+
| jmx_up             | 1 when JMX answers, else 0, tagged tomcat=<its name> and jmx=<its address>  |
| up                 | 1 when the app is started, else 0 (FAILED, STOPPED), tagged                 |
|                    | name=<//host/path>                                                          |
| uptime_seconds     | since the app started, tagged the same                                      |
| startup_seconds    | how long it took to start, tagged the same                                  |
| errors_count       | requests that ended in an exception, tagged the same; the most first        |
| requests_count     | requests, tagged the same                                                   |
| processing_seconds | time spent on requests, tagged the same                                     |
| slowest_seconds    | the slowest request, tagged the same                                        |
| ..._not_shown      | past 100 of a list (up, uptime_seconds, startup_seconds, errors_count,      |
|                    | requests_count, processing_seconds, slowest_seconds), how many were left    |
|                    | out                                                                         |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  up 1 for every app; uptime_seconds only growing; errors_count flat or rising slowly.       |
| WATCH uptime_seconds falling back: the app was restarted or redeployed; errors_count rising.     |
| BAD   up 0: the app failed to start or was stopped, and answers 404 (Tomcat's log says why).     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| tomcat_sessions   tomcat.sessions.<metric>   every 1m                                            |
+-----------------------+--------------------------------------------------------------------------+
| jmx_up                | 1 when JMX answers, else 0, tagged tomcat=<its name> and jmx=<its        |
|                       | address>                                                                 |
| active                | sessions active now, tagged host=<its host> and context=<its path>; the  |
|                       | most first                                                               |
| most                  | the most active at once since the app started, tagged the same           |
| limit                 | the most it allows (maxActiveSessions), when one is set, tagged the same |
| rejected_count        | sessions refused for the limit, tagged the same                          |
| created_count         | sessions created, tagged the same                                        |
| expired_count         | sessions expired, tagged the same                                        |
| created_per_minute    | sessions created a minute, over the last 100, tagged the same            |
| expired_per_minute    | sessions expired a minute, over the last 100, tagged the same            |
| average_alive_seconds | how long the last 100 expired sessions lived, on average, tagged the     |
|                       | same                                                                     |
| longest_alive_seconds | the longest any expired session lived, tagged the same                   |
| ..._not_shown         | past 100 of a list (active, most, limit, rejected_count, created_count,  |
|                       | expired_count, created_per_minute, expired_per_minute,                   |
|                       | average_alive_seconds, longest_alive_seconds), how many were left out    |
+-----------------------+--------------------------------------------------------------------------+
| GOOD  active rising and falling with traffic; rejected_count 0.                                  |
| WATCH active climbing without falling back: sessions created and never used again (bots, a       |
|       client that keeps no cookie) hold memory until they expire.                                |
| BAD   rejected_count rising: users are refused a session at the limit; active near limit.        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| tomcat_servlets   tomcat.servlet.<metric>   cron 3/5 * * * *                                     |
+--------------------+-----------------------------------------------------------------------------+
| jmx_up             | 1 when JMX answers, else 0, tagged tomcat=<its name> and jmx=<its address>  |
| processing_seconds | time spent in the servlet, tagged WebModule=<//host/path> and name=<the     |
|                    | servlet>; the most first                                                    |
| requests_count     | requests, tagged the same                                                   |
| errors_count       | requests that ended in an exception, tagged the same                        |
| slowest_seconds    | the slowest request, tagged the same                                        |
| load_seconds       | how long it took to load, tagged the same                                   |
| ..._not_shown      | past 100 of a list (processing_seconds, requests_count, errors_count,       |
|                    | slowest_seconds, load_seconds), how many were left out                      |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  processing_seconds rising in step with requests_count; errors_count flat.                  |
| WATCH one servlet's share of the time growing.                                                   |
| BAD   a servlet's errors_count rising: it is failing; its processing_seconds per request         |
|       climbing: it is slow.                                                                      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| tomcat_jdbc   tomcat.jdbc.<metric>   every 1m                                                    |
+------------------------+-------------------------------------------------------------------------+
| jmx_up                 | 1 when JMX answers, else 0, tagged tomcat=<its name> and jmx=<its       |
|                        | address>                                                                |
| active                 | connections in use, tagged context=<the app, or none for a global one>  |
|                        | and name=<its JNDI name>                                                |
| idle                   | connections idle in the pool, tagged the same                           |
| max                    | the most it may open (DBCP maxTotal, the JDBC pool maxActive), tagged   |
|                        | the same                                                                |
| max_idle               | the most it keeps idle, tagged the same                                 |
| min_idle               | the fewest it keeps idle, tagged the same                               |
| max_wait_seconds       | how long a request waits for a connection before it fails, tagged the   |
|                        | same                                                                    |
| size                   | connections open, in use or idle (the JDBC pool), tagged the same       |
| waiting                | threads waiting for a connection now (the JDBC pool), tagged the same   |
| borrowed_count         | connections taken from it (the JDBC pool), tagged the same              |
| returned_count         | connections given back (the JDBC pool), tagged the same                 |
| created_count          | connections opened (the JDBC pool), tagged the same                     |
| released_count         | connections closed (the JDBC pool), tagged the same                     |
| abandoned_count        | connections taken back from code that never returned them (the JDBC     |
|                        | pool, removeAbandoned), tagged the same                                 |
| reconnected_count      | connections reopened (the JDBC pool), tagged the same                   |
| hikari_active          | a HikariCP pool's connections in use, tagged type=<Pool (its name)>     |
| hikari_idle            | its connections idle, tagged the same                                   |
| hikari_total           | its connections open, tagged the same                                   |
| hikari_waiting         | threads waiting for one of its connections, tagged the same             |
| hikari_max             | a HikariCP pool's most connections, tagged type=<PoolConfig (its name)> |
| hikari_min_idle        | the fewest it keeps idle, tagged the same                               |
| hikari_timeout_seconds | how long a request waits for a connection before it fails, tagged the   |
|                        | same                                                                    |
| ..._not_shown          | past 100 of a list (active, idle, max, max_idle, min_idle,              |
|                        | max_wait_seconds, size, waiting, borrowed_count, returned_count,        |
|                        | created_count, released_count, abandoned_count, reconnected_count,      |
|                        | hikari_active, hikari_idle, hikari_total, hikari_waiting, hikari_max,   |
|                        | hikari_min_idle, hikari_timeout_seconds), how many were left out        |
+------------------------+-------------------------------------------------------------------------+
| GOOD  active well below max; waiting and hikari_waiting 0; abandoned_count flat.                 |
| WATCH active at max now and then; waiting above 0: requests queue for a connection.              |
| BAD   active at max and waiting above 0 for minutes: requests fail after max_wait_seconds.       |
|       Either the database is slow or code keeps connections (abandoned_count rising says code    |
|       leaks them).                                                                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| tomcat_cache   tomcat.cache.<metric>   cron 4/5 * * * *                                          |
+----------------------------+---------------------------------------------------------------------+
| jmx_up                     | 1 when JMX answers, else 0, tagged tomcat=<its name> and jmx=<its   |
|                            | address>                                                            |
| lookups_count              | lookups in the app's resource cache, tagged host=<its host> and     |
|                            | context=<its path>                                                  |
| hits_count                 | of those, found in the cache, tagged the same                       |
| size_bytes                 | what the cache holds, tagged the same                               |
| max_bytes                  | the most it may hold, tagged the same                               |
| jsps                       | JSPs loaded, tagged WebModule=<//host/path>                         |
| jsp_reloads_count          | JSPs reloaded after a change, tagged the same                       |
| jsp_unloads_count          | JSPs unloaded (maxLoadedJsps), tagged the same                      |
| jsp_queue                  | JSPs waiting to be unloaded, when there is a limit, tagged the same |
| string_cache_lookups_count | lookups in Tomcat's string cache (when it is on)                    |
| string_cache_hits_count    | of those, found                                                     |
| ..._not_shown              | past 100 of a list (lookups_count, hits_count, size_bytes,          |
|                            | max_bytes, jsps, jsp_reloads_count, jsp_unloads_count, jsp_queue),  |
|                            | how many were left out                                              |
+----------------------------+---------------------------------------------------------------------+
| GOOD  hits_count close to lookups_count; size_bytes below max_bytes; jsp_reloads_count flat in   |
|       production.                                                                                |
| WATCH size_bytes at max_bytes with hits falling behind lookups: the cache is too small (Tomcat   |
|       warns).                                                                                    |
| BAD   jsp_reloads_count rising in production: JSPs are being changed under a running Tomcat.     |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what three Tomcats in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `tomcat.jmx_up` | 1 | | 0: Tomcat, or its JMX, is down | 0 for a target where nothing listens |
| `tomcat.app.up` | 1 for every app | | 0: the app failed to start or was stopped, and answers 404 | 0 for `//localhost/broken`, whose listener is not there; 1 for the shop |
| `tomcat.threads.executor_busy` against `executor_max_threads`, and `busy` against `max_threads` | Well below | Near it for minutes | At it, with `executor_queue` above 0: requests wait for a thread | 8 of 8, with 4 queued; the admin connector's 6 of 6 |
| `tomcat.inflight.stuck_threads` | 0 | Above 0 now and then | Above 0 and staying, or rising: requests that never end hold threads until none are left | 14 on each, every held request past the valve's 5 seconds |
| `tomcat.inflight.running_seconds` | A second or less | Tens of seconds | Minutes | 27.3 for the longest when it was read |
| `tomcat.jdbc.active` against `max`; `hikari_active` against its pool | Well below | At it now and then; `waiting` above 0 | At it for minutes: requests fail after `max_wait_seconds` | 4 of 4 in DBCP's pool and Tomcat's JDBC pool, 3 of 3 in HikariCP's |
| `tomcat.sessions.rejected_count` (as a rate) | 0 | | Rising: users refused a session at the limit | 11, with `active` 40 at the `limit` of 40 |
| `tomcat.requests.errors_count` against `requests_count` (as rates) | A small, steady share | Rising faster than requests | Most requests failing | 14 of 54: 3 failing pages and 11 refused sessions |
| `tomcat.app.uptime_seconds` | Only growing | Falling back: the app was restarted or redeployed | | Not caused: only growing |
| `tomcat.cache.hits_count` against `lookups_count` (as rates) | Most lookups hit | Hits falling behind, `size_bytes` at `max_bytes` | | Not caused: 53 of 72, far below its most |

## How it was tested

**Tested** on 2026-11-23 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-tomcat.sh`, which builds the pack's jar as a release does, against **Tomcat 9.0.124 on Java 11, 10.1.62 on Java 17 and 11.0.29 on Java 21**, each in Docker with JMX over TLS with a password and a `readonly` user, a small shared Executor (8 threads, 10 queued at most), an admin connector of 6 threads, the stuck thread valve at 5 seconds, a shop with at most 40 sessions and three connection pools of an in-memory H2 database (DBCP, Tomcat's JDBC pool and HikariCP), and an app that cannot start. Trouble on purpose, on each: 50 visits (past the session limit), 3 failing pages, every pool's connections held for 4 minutes, the Executor's threads all held with 4 requests queued behind them, the admin connector's threads all held.
- **On Fedora**: every job directly, each reading checked on all three, then `service-packs.sh` through Vigil (enable, the secret line, every job, a wrong password and a certificate it cannot trust failing the run, a server that does not answer read as `jmx_up 0`, the password written nowhere), then every job on Temurin's JRE 11, and a probe changed by one byte refused: **102 passed, 0 failed**, and through Vigil **21 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/fedora/pack-tomcat/console.txt)). The jar built there was `_probe.jar` `1c3abd00…`, the one the kafka pack 2.0.1 and the jvm pack 1.2.1 carry.
  The macOS and Windows runs below read the pack before its last readings were added (HikariCP's configured limits, servlet load times, the utility executor, the string cache, `jvmRoute`); those are rows of its table, read by the same jar, and were checked on Fedora.
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2), with the jar built there (the same bytes), against the three Tomcats through SSH tunnels: every job, then on Temurin's JRE 21, **15 passed, 0 failed**; through Vigil, **21 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/macos/pack-tomcat-macos/console.txt)).
- **On Windows**, from a packs release built by `tools/release/packs.sh`, as an account that is not an administrator: `Service-Packs.ps1` through Vigil, **21 passed, 0 failed**, then every job from the release on a JRE, **2 passed, 0 failed**: on Windows PowerShell 5.1 and PowerShell 7 on Windows 11 ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows/pack-tomcat-windows/console.txt)), and on Windows PowerShell 5.1 on Windows Server 2025 ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows-server-2025/pack-tomcat-windows/console.txt)).
  The password came from an `env:` reference: Windows refuses its data protection to a logon by SSH key, as the test machines' were.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
