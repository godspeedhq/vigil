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
