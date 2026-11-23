# The jvm pack

Java virtual machines: any Java application (Jenkins, Spring Boot, Elasticsearch, Keycloak, one of your own) through the JVM it runs on. The JVM, not the application: its process, memory, garbage collection, threads, JIT, classes, crashes, settings and security. Application servers and libraries (Tomcat, Jetty, connection pools) are for packs of their own, which report what is theirs and leave the JVM to this one. Linux, macOS and Windows; JVMs from Java 8.

Each script runs the pack's client, beside it, with Java 11 or later, a JDK or a JRE: one client for every platform, so each prints the same lines. It reaches each JVM in three tiers, and uses every one that reaches it:

| Tier | Needs | Reads |
| --- | --- | --- |
| 1. The operating system | Nothing | The process: up, memory, CPU, threads, open files, disk I/O, uptime; its startup options; crash reports and heap dumps on disk |
| 2. The JVM's own counters | The same machine, and Vigil running as root, an administrator or the JVM's own account. HotSpot JVMs (OpenJDK, Oracle, Temurin, Corretto, Zulu...), unless started with `-XX:-UsePerfData` | The `hsperfdata` file `jstat` reads: heap and pools, collections, threads, classes, the JIT, safepoints, promotion |
| 3. JMX | The JVM's JMX address, given in `JVM_TARGETS` | Everything else, on this machine or another |

So a JVM nobody set up is still watched: its process always, its counters when Vigil may read them. `jvm_status` says which tiers reach each JVM, and `jvm_discovery` lists the JVMs on the machine, and whether each is watched.

1. `vigil pack enable jvm`. With `JVM_TARGETS` empty, every JVM on this machine is watched, each named by its main class.
2. To name them, or to reach one over JMX, set `JVM_TARGETS` on the jobs' `env` lines: `name: key=value, ...; name: ...`, with `main=` (its main class or jar, or any text on its command line) or `pid=` (a pid file) to find it here, `jmx=host:port` or `jmxs=host:port` (JMX over TLS) for its JMX address, and `gclog=` for its GC log (written with `-Xlog:gc*:file=<path>`: plain `-Xlog:gc` leaves out ZGC's and Shenandoah's pauses; on Java 8, `-XX:+PrintGCDetails -XX:+PrintGCTimeStamps`):

   ```ini
   env = JVM_TARGETS=shop: main=com.acme.Shop, jmxs=localhost:9010, gclog=/var/log/shop/gc.log; jenkins: main=jenkins.war
   ```

   **The JMX address is the switch**: a JVM with one gets tier 3, one without gets tiers 1 and 2. A JVM with an address that does not answer reports `jmx_up 0`, which is worth an alert, and the other tiers still report. Vigil never looks for JMX ports by itself.
3. For JMX with a password (and it should have one), add a secret line to each job, under its `env` lines, and give Vigil the password, as the account Vigil runs as:

   ```ini
   secret = JVM_JMX_PASSWORD=secret:JVM_JMX_PASSWORD
   ```

   ```sh
   vigil secret set JVM_JMX_PASSWORD
   ```

   and the user in `JVM_JMX_USER`. With `jmxs=`, the JVM's certificate is checked against `JVM_CACERT` (a PEM file of CAs) or Java's own, and against its name: connect by the name on its certificate. No setting trusts a certificate unchecked.

**Turning JMX on, safely.** On the JVM, with a password, TLS, and only this machine's address when Vigil runs here:

```sh
java -Dcom.sun.management.jmxremote.port=9010 -Dcom.sun.management.jmxremote.rmi.port=9010 \
  -Dcom.sun.management.jmxremote.host=127.0.0.1 -Djava.rmi.server.hostname=localhost \
  -Dcom.sun.management.jmxremote.authenticate=true \
  -Dcom.sun.management.jmxremote.password.file=/etc/shop/jmx.password \
  -Dcom.sun.management.jmxremote.access.file=/etc/shop/jmx.access \
  -Dcom.sun.management.jmxremote.ssl=true -Dcom.sun.management.jmxremote.registry.ssl=true \
  -Djavax.net.ssl.keyStore=/etc/shop/jmx.p12 -Djavax.net.ssl.keyStorePassword=... ...
```

The password file holds `vigil <password>` and must be readable by the JVM's account alone; the access file gives the user its role. **`readonly` or `readwrite`**: JMX has only these two. A `readonly` user may read attributes, which is most of this pack. It may not run operations, which `jvm_deadlocks`, `jvm_contention`, `jvm_hot_threads`, `jvm_allocation`, `jvm_classloaders`, `jvm_native` and part of `jvm_threads` and `jvm_virtual_threads` need: with `readonly` they say so in their log, and print what they can. `readwrite` lets them run, and also lets the user run anything else a JVM offers over JMX (a heap dump, a setting changed): choose it knowing that.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | Java 11 or later, a JDK or a JRE, `JAVA_HOME` or `java` on the PATH | The same | The same |
| For tier 2 | Vigil as root, or the JVM's account | Vigil as root, or the JVM's account | Vigil as an administrator, or the JVM's account |
| For tier 3 | Each JVM's JMX address in `JVM_TARGETS`, and with a password, a `secret` line and `vigil secret set JVM_JMX_PASSWORD` (step 3) | | |

## Its jobs

| Job | Every | Tiers | Reports |
| --- | --- | --- | --- |
| `jvm_process` | 1m | 1 | Running, resident and virtual memory, CPU, threads, open files against the limit, uptime |
| `jvm_heap` | 1m | 2, 3 | Heap used, committed, maximum, used against the maximum |
| `jvm_gc` | 1m | 2, 3 | Collections and time per collector, the share of its life spent collecting |
| `jvm_threads` | 1m | 2, 3 | Live, daemon, peak, started; by state (JMX) |
| `jvm_deadlocks` | 1m | 3 | Deadlocked threads, each named with the lock it waits for and the thread that holds it |
| `jvm_pools` | 2m | 2, 3 | Each memory pool, and each as the last collection left it: old gen after a collection, the leak signal |
| `jvm_gc_cycles` | 2m | 3 | Pauses apart from concurrent work (ZGC, Shenandoah, G1's cycles) |
| `jvm_gc_last` | 2m | 3 | The last collection: how long, how long ago, what it freed and left |
| `jvm_allocation` | 2m | 3 | Allocation per second, over two seconds; the running total (Java 21 and later) |
| `jvm_os` | 2m | 3 | The JVM's and the system's CPU, load, memory, swap, open files against the limit |
| `jvm_status` | 5m | 1, 2, 3 | Up, which tiers reach it, version, vendor, VM, collectors, uptime, the heap's maximum |
| `jvm_metaspace` | 5m | 2, 3 | Metaspace and compressed class space against their limits |
| `jvm_codecache` | 5m | 2, 3 | The code cache by segment: when full, the JIT stops |
| `jvm_buffers` | 5m | 3 | Direct and mapped buffers: off-heap memory |
| `jvm_native_overhead` | 5m | 1 with 2 or 3 | Resident memory outside the heap: native leaks no Java figure shows |
| `jvm_gc_cpu` | 5m | 2, 3 | The GC threads' CPU against the process's (HotSpot 22 and later) |
| `jvm_promotion` | 5m | 2 | Promotion to old gen, tenuring, survivor overflow (Serial and Parallel) |
| `jvm_gclog` | 5m | GC log | Pauses in the last five minutes: count, longest, 99th percentile; full collections; allocation stalls |
| `jvm_virtual_threads` | 5m | 3 | Virtual threads' carriers; mounted and queued (Java 24 and later) |
| `jvm_classes` | 5m | 2, 3 | Classes loaded, ever loaded, unloaded |
| `jvm_jit` | 5m | 2, 3 | Time compiling, compilations, compiled code |
| `jvm_safepoints` | 5m | 2 | Time stopped at safepoints, and waiting for threads to stop |
| `jvm_io` | 5m | 1 | Disk reads and writes; open files by kind (Linux) |
| `jvm_crashes` | 5m | 1 | Crash reports, compiler replays and core dumps written |
| `jvm_oom` | 5m | 1 | Heap dumps written: out of memory |
| `jvm_mbeans` | 5m | 3 | MBean attributes you name in `JVM_MBEANS`, as numbers |
| `jvm_flags` | 15m | 1, 3 | No maximum heap, no heap dump or exit on out-of-memory, a removed collector, a heap over the machine's memory |
| `jvm_security` | 15m | 1, 3 | A debugger listening, beyond this machine too; JMX without a password or TLS; verification off |
| `jvm_startup` | 15m | 1, 2, 3 | When it started, how long the JVM took to start |
| `jvm_native` | 15m | 3 | Native memory by category, when the JVM tracks it |
| `jvm_tlab` | 15m | 2 | Allocation outside the threads' own buffers |
| `jvm_gclog_detail` | 15m | GC log | Pauses by length; humongous allocations, to-space exhaustion, evacuation and promotion failures |
| `jvm_contention` | 15m | 3 | Threads blocked, and the locks most waited for, with who holds them |
| `jvm_hot_threads` | 15m | 3 | The busiest threads by CPU, over two seconds |
| `jvm_classloaders` | 15m | 3 | Classloaders, and classes by loader type: redeploy leaks |
| `jvm_deopt` | 15m | 2 | Compilations thrown away and given up |
| `jvm_finalization` | 15m | 3 | Objects waiting to be finalized |
| `jvm_discovery` | 1h | 1, 2 | The JVMs on this machine, by main class and account, watched or not, counters readable or not |
| `jvm_container` | 1h | 3 | The CPUs and memory the JVM sees, against this machine's |
| `jvm_release_age` | 1h | 2, 3 | Its Java's feature release, long-term support or not, days since its release |
| `jvm_jfr` | 1h | 3 | Flight Recorder there, and its recordings |

Each script's header says what its metrics mean and how to read them. Worth knowing:

- **Nothing here pauses a JVM.** No heap dump, class histogram or thread dump with stacks: the jobs read counters, and make calls that are cheap on any heap.
- **A command line is read, never reported**: it can hold a password. The pack reads only the options it knows.
- **Two jars, compiled, and checked before they run.** The pack's client, `_client.jar`, runs with the generic probe beside it, `_probe.jar` ([`tools/probe/DESIGN.md`](../../tools/probe/DESIGN.md)), the same file the kafka pack carries: every JMX connection, its login, TLS and the certificate's chain and name, is the probe's engine, one copy for every pack that reads JMX (from 1.2.0; 1.1 had a copy of its own). Both are built from the sources beside them, `_client.java` and `_probe.java`, when the pack is released, and before every run the script checks each against the SHA-256 it carries: a jar that does not match is not run (`_probe.jar does not match the digest in this script`). The archive they come in is checked against the signed pack index when the pack is installed. They are Java 11 bytecode, built so the same source gives the same bytes: each script names the `javac` that built them, so you can compile the sources with that version (`tools/release/client-jar.sh`) and compare. A copy of the pack without its jars, straight from the repository, does not run: its scripts say to install the pack from a packs release, or to build them.
- **How long a run takes.** The client starts in about half a second; on Windows, PowerShell starts first. Then each JVM it reaches over JMX adds its own connection, more with TLS: on the Fedora test machine, the 41 jobs one after another against eight JVMs, six over JMX, took about three minutes in all. So only the cheap jobs run every minute; the rest every 2, 5 or 15 minutes, or each hour.
- **On Windows, an account CIM refuses** (one that is not an administrator, logged on over the network) still finds its own JVMs: Windows lists them without their command lines, and the pack reads each one's options and main class from its counters instead. Such a JVM has no disk reads and writes in `jvm_io`.
- `JVM_DUMP_DIRS` adds folders to look in for crash reports and heap dumps, for every JVM: the JVM's own `-XX:ErrorFile` and `-XX:HeapDumpPath`, and its working folder on Linux, are looked in already.

A JVM that is not running reports `running 0` (`jvm_process`) and `up 0` (`jvm_status`), and the run succeeds: that is a reading. A JMX login refused, or a certificate that cannot be trusted, fails the run, and its log says why.


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `jvm.process.jvms`.

```text
+--------------------------------------------------------------------------------------------------+
| jvm_process   jvm.process.<metric>   every 1m                                                    |
+----------------+---------------------------------------------------------------------------------+
| jvms           | the JVMs the job looked at (untagged)                                           |
| jmx_up         | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with     |
|                | one)                                                                            |
| running        | 1 when the process runs, 0 when a JVM looked for is not found                   |
| rss_bytes      | resident memory: what it holds in RAM                                           |
| virtual_bytes  | virtual memory reserved                                                         |
| cpu_seconds    | CPU used since it started (a running total: graph its rate)                     |
| threads        | its threads, as the operating system counts them (Linux, Windows)               |
| open_files     | open files and sockets (Linux, as root or its own account; Windows: handles)    |
| open_files_max | its limit on open files (Linux)                                                 |
| uptime_seconds | since it started                                                                |
+----------------+---------------------------------------------------------------------------------+
| GOOD  running 1; rss_bytes steady; uptime_seconds rising.                                        |
| WATCH rss_bytes rising over days with a steady heap: memory outside the heap                     |
|       (jvm_native_overhead).                                                                     |
| BAD   running 0; uptime_seconds falling back to near 0: it restarted; open_files near            |
|       open_files_max.                                                                            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_discovery   jvm.discovery.<metric>   cron 7 * * * *                                          |
+---------------+----------------------------------------------------------------------------------+
| jvms          | JVMs running on this machine (untagged)                                          |
| found         | always 1, for each JVM, tagged main=<its main class or jar>, user=<its account>, |
|               | watched=<yes or no> and counters=<yes or no>                                     |
| ..._not_shown | past 100 of a list (jvms), how many were left out                                |
+---------------+----------------------------------------------------------------------------------+
| GOOD  Every JVM you run, watched=yes.                                                            |
| WATCH A JVM you did not expect; counters=no for a JVM: Vigil runs as an account that cannot read |
|       them.                                                                                      |
| BAD   watched=no for a JVM that matters: add it to JVM_TARGETS.                                  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_status   jvm.status.<metric>   cron 1/5 * * * *                                              |
+----------------+---------------------------------------------------------------------------------+
| jvms           | the JVMs the job looked at (untagged)                                           |
| jmx_up         | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with     |
|                | one)                                                                            |
| up             | 1 when any tier finds the JVM, else 0                                           |
| tier_os        | 1 when its process is found on this machine                                     |
| tier_counters  | 1 when its counters can be read here                                            |
| tier_jmx       | 1 when it answers over JMX                                                      |
| info           | always 1, tagged version=, vendor=, vm= and gc=<its collectors, joined by +>    |
| uptime_seconds | since it started                                                                |
| heap_max_bytes | the most heap it may use                                                        |
+----------------+---------------------------------------------------------------------------------+
| GOOD  up 1, and the tiers you expect at 1.                                                       |
| WATCH info's version changing: the JVM was upgraded; a tier at 0 that was 1.                     |
| BAD   up 0: the JVM is gone; tier_jmx 0 with an address: JMX stopped answering (jmx_up says the  |
|       same).                                                                                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_flags   jvm.flags.<metric>   cron 4/15 * * * *                                               |
+----------------------+---------------------------------------------------------------------------+
| jvms                 | the JVMs the job looked at (untagged)                                     |
| jmx_up               | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM    |
|                      | with one)                                                                 |
| heap_max_set         | 1 when the heap has a maximum set (-Xmx, MaxRAMPercentage or the like)    |
| heap_dump_on_oom     | 1 when it writes a heap dump on out-of-memory                             |
| exit_on_oom          | 1 when it exits (or crashes, or runs a command) on out-of-memory          |
| deprecated_gc        | 1 when it asks for CMS or ParNew, removed in Java 14                      |
| heap_over_memory     | 1 when its heap's maximum is more than the machine's memory (JMX)         |
| explicit_gc_disabled | 1 when System.gc() does nothing (-XX:+DisableExplicitGC)                  |
| risks                | how many of: no maximum heap, no heap dump, a deprecated collector, a     |
|                      | heap over memory                                                          |
+----------------------+---------------------------------------------------------------------------+
| GOOD  risks 0.                                                                                   |
| WATCH exit_on_oom 0: a JVM out of memory may limp on, half-working, rather than restart.         |
| BAD   heap_over_memory 1: the machine will swap or kill it before the heap fills;                |
|       heap_dump_on_oom 0 on a JVM that has run out of memory before: the next one will leave     |
|       nothing to look at.                                                                        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_container   jvm.container.<metric>   cron 11 * * * *                                         |
+-------------------+------------------------------------------------------------------------------+
| jvms              | the JVMs the job looked at (untagged)                                        |
| jmx_up            | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with  |
|                   | one)                                                                         |
| cpus              | CPUs the JVM may use                                                         |
| memory_bytes      | memory the JVM sees                                                          |
| cpus_host         | this machine's CPUs (a JVM here only)                                        |
| memory_host_bytes | this machine's memory (a JVM here only)                                      |
| cpus_limited      | 1 when it sees fewer CPUs than the machine has                               |
| memory_limited    | 1 when it sees less memory than the machine has                              |
+-------------------+------------------------------------------------------------------------------+
| GOOD  cpus and memory_bytes what you meant it to have.                                           |
| WATCH cpus 1 in a container: the JVM picks the Serial collector and single-threaded pools.       |
| BAD   memory_bytes far below what the heap needs: raise the container's limit, or lower the      |
|       heap.                                                                                      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_release_age   jvm.release_age.<metric>   cron 13 * * * *                                     |
+------------------+-------------------------------------------------------------------------------+
| jvms             | the JVMs the job looked at (untagged)                                         |
| jmx_up           | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with   |
|                  | one)                                                                          |
| feature_version  | its feature release: 8, 11, 17, 21, 25...                                     |
| lts              | 1 for a long-term support release (8, 11, 17, 21, 25)                         |
| release_age_days | days since this Java was released (Java 10 and later, JMX), tagged version=   |
+------------------+-------------------------------------------------------------------------------+
| GOOD  release_age_days under about 100: Java updates come every three months.                    |
| WATCH release_age_days over 100: a quarterly update was missed.                                  |
| BAD   release_age_days over 200; lts 0 on a JVM you keep for years: a non-LTS release gets       |
|       updates for six months only.                                                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_security   jvm.security.<metric>   cron 8/15 * * * *                                         |
+--------------------+-----------------------------------------------------------------------------+
| jvms               | the JVMs the job looked at (untagged)                                       |
| jmx_up             | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with |
|                    | one)                                                                        |
| debug_agent        | 1 when a debugger agent is loaded (-agentlib:jdwp)                          |
| debug_agent_remote | 1 when it listens beyond this machine                                       |
| jmx_remote         | 1 when it opens a JMX port                                                  |
| jmx_no_password    | 1 when that port asks no password                                           |
| jmx_no_tls         | 1 when that port has no TLS                                                 |
| verify_off         | 1 when bytecode verification is off                                         |
| risks              | how many of the above are 1, jmx_remote aside                               |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  risks 0.                                                                                   |
| WATCH debug_agent 1 on a production JVM, even on localhost.                                      |
| BAD   debug_agent_remote 1: anyone who reaches that port can run code as the JVM's account;      |
|       jmx_no_password 1 with jmx_remote 1: the same, through JMX.                                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_startup   jvm.startup.<metric>   cron 9/15 * * * *                                           |
+-----------------------+--------------------------------------------------------------------------+
| jvms                  | the JVMs the job looked at (untagged)                                    |
| jmx_up                | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM   |
|                       | with one)                                                                |
| startup_seconds       | how long the JVM took to create itself (counters)                        |
| init_seconds          | until the JVM had initialised (counters)                                 |
| started_epoch_seconds | when it started, in seconds since 1970                                   |
| uptime_seconds        | since it started                                                         |
+-----------------------+--------------------------------------------------------------------------+
| GOOD  started_epoch_seconds changing only when you restart it.                                   |
| WATCH startup_seconds rising: a slow disk, or a big class-data archive.                          |
| BAD   started_epoch_seconds changing several times an hour: it is crash-looping.                 |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_heap   jvm.heap.<metric>   every 1m                                                          |
+-----------------+--------------------------------------------------------------------------------+
| jvms            | the JVMs the job looked at (untagged)                                          |
| jmx_up          | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with    |
|                 | one)                                                                           |
| used_bytes      | heap in use, live objects and garbage alike                                    |
| committed_bytes | heap the JVM holds from the operating system                                   |
| max_bytes       | the most it may use                                                            |
| used_percent    | used against max                                                               |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  used_percent rising and falling in a saw-tooth, falling well below half after each         |
|       collection.                                                                                |
| WATCH the bottom of the saw-tooth rising over hours: live data growing (jvm_pools'               |
|       after_gc_bytes says it plainly).                                                           |
| BAD   used_percent above 90 and staying there: the JVM is about to run out of memory.            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_pools   jvm.pools.<metric>   cron 1/2 * * * *                                                |
+------------------+-------------------------------------------------------------------------------+
| jvms             | the JVMs the job looked at (untagged)                                         |
| jmx_up           | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with   |
|                  | one)                                                                          |
| used_bytes       | in use, tagged pool=<its name> and type=<heap or non_heap>                    |
| committed_bytes  | held, tagged the same                                                         |
| max_bytes        | its maximum, where it has one, tagged the same                                |
| after_gc_bytes   | in use after the last collection (JMX), tagged the same                       |
| after_gc_percent | that, against max, tagged the same                                            |
+------------------+-------------------------------------------------------------------------------+
| GOOD  Old gen's after_gc_percent steady.                                                         |
| WATCH Old gen's after_gc_bytes rising after each collection, over hours: a leak.                 |
| BAD   Old gen's after_gc_percent above 80: the collector cannot free enough, and will spend ever |
|       more time trying.                                                                          |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_metaspace   jvm.metaspace.<metric>   cron 2/5 * * * *                                        |
+-----------------------------+--------------------------------------------------------------------+
| jvms                        | the JVMs the job looked at (untagged)                              |
| jmx_up                      | 1 when the JVM answered at its JMX address, 0 when not (only for a |
|                             | JVM with one)                                                      |
| metaspace_used_bytes        | metaspace in use                                                   |
| metaspace_committed_bytes   | held                                                               |
| metaspace_max_bytes         | its limit, when MaxMetaspaceSize sets one                          |
| metaspace_used_percent      | used against that limit                                            |
| class_space_used_bytes      | compressed class space in use                                      |
| class_space_committed_bytes | held                                                               |
| class_space_max_bytes       | its limit (1 GB by default)                                        |
| class_space_used_percent    | used against it                                                    |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  Steady once the application has started.                                                   |
| WATCH Rising with each redeploy: the old classes are not freed (jvm_classloaders).               |
| BAD   class_space_used_percent or metaspace_used_percent above 90: OutOfMemoryError: Metaspace   |
|       is near.                                                                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_codecache   jvm.codecache.<metric>   cron 3/5 * * * *                                        |
+--------------------+-----------------------------------------------------------------------------+
| jvms               | the JVMs the job looked at (untagged)                                       |
| jmx_up             | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with |
|                    | one)                                                                        |
| used_bytes         | in use, tagged segment=<non-nmethods, profiled nmethods, non-profiled       |
|                    | nmethods, or Code Cache>                                                    |
| max_bytes          | its size, tagged the same                                                   |
| used_percent       | used against it, tagged the same                                            |
| nmethod_code_bytes | compiled code, from the counters, without JMX                               |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  used_percent under 80 in every segment.                                                    |
| WATCH used_percent creeping up over days.                                                        |
| BAD   used_percent above 95: raise -XX:ReservedCodeCacheSize.                                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_buffers   jvm.buffers.<metric>   cron 4/5 * * * *                                            |
+----------------+---------------------------------------------------------------------------------+
| jvms           | the JVMs the job looked at (untagged)                                           |
| jmx_up         | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with     |
|                | one)                                                                            |
| count          | buffers, tagged pool=<direct, mapped, mapped_non_volatile_memory>               |
| used_bytes     | memory they use, tagged the same                                                |
| capacity_bytes | their total capacity, tagged the same                                           |
+----------------+---------------------------------------------------------------------------------+
| GOOD  direct used_bytes steady under load.                                                       |
| WATCH direct used_bytes rising with no rise in load.                                             |
| BAD   direct used_bytes near -XX:MaxDirectMemorySize (the heap's maximum, by default):           |
|       OutOfMemoryError: Direct buffer memory is near.                                            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_native   jvm.native.<metric>   cron 5/15 * * * *                                             |
+--------------------------+-----------------------------------------------------------------------+
| jvms                     | the JVMs the job looked at (untagged)                                 |
| jmx_up                   | 1 when the JVM answered at its JMX address, 0 when not (only for a    |
|                          | JVM with one)                                                         |
| tracking                 | 1 when the JVM tracks its native memory                               |
| reserved_bytes           | reserved, in all                                                      |
| committed_bytes          | committed, in all                                                     |
| category_committed_bytes | committed, tagged category=<java_heap, class, thread, code, gc, ...>  |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  Every category steady once started.                                                        |
| WATCH thread rising: threads are made and not ended; class rising: a classloader leak.           |
| BAD   committed_bytes near the machine's or container's memory: it will be killed.               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_native_overhead   jvm.native_overhead.<metric>   cron 2/5 * * * *                            |
+----------------------+---------------------------------------------------------------------------+
| jvms                 | the JVMs the job looked at (untagged)                                     |
| jmx_up               | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM    |
|                      | with one)                                                                 |
| rss_bytes            | resident memory                                                           |
| heap_committed_bytes | the heap it holds                                                         |
| outside_heap_bytes   | resident memory less that heap                                            |
| outside_heap_percent | that, against resident memory                                             |
+----------------------+---------------------------------------------------------------------------+
| GOOD  outside_heap_bytes steady once started.                                                    |
| WATCH outside_heap_bytes rising over hours with a steady heap.                                   |
| BAD   outside_heap_bytes rising without end: a native leak (jvm_buffers, jvm_native).            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_gc   jvm.gc.<metric>   every 1m                                                              |
+-----------------------+--------------------------------------------------------------------------+
| jvms                  | the JVMs the job looked at (untagged)                                    |
| jmx_up                | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM   |
|                       | with one)                                                                |
| collections           | collections, a running total, tagged collector=<its name>                |
| time_seconds          | time collecting, a running total, tagged the same                        |
| collections_total     | all collections, a running total                                         |
| time_seconds_total    | all time collecting, a running total                                     |
| time_percent_lifetime | time collecting, against the time it has run                             |
| last_cause            | always 1, tagged cause=<why the last collection ran> (counters)          |
+-----------------------+--------------------------------------------------------------------------+
| GOOD  time_seconds_total's rate under 0.05 (5% of the time).                                     |
| WATCH time_seconds_total's rate rising; an old or full collector's collections rising.           |
| BAD   time_seconds_total's rate above 0.2: the JVM spends a fifth of its time collecting; with   |
|       the heap near full, it is out of memory in all but name.                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_gc_cycles   jvm.gc_cycles.<metric>   cron 1/2 * * * *                                        |
+--------------------+-----------------------------------------------------------------------------+
| jvms               | the JVMs the job looked at (untagged)                                       |
| jmx_up             | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with |
|                    | one)                                                                        |
| pauses             | pauses, a running total                                                     |
| pause_seconds      | time paused, a running total                                                |
| pause_avg_ms       | the average pause                                                           |
| concurrent_cycles  | concurrent cycles, a running total                                          |
| concurrent_seconds | their time, a running total                                                 |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  pause_avg_ms small for the collector (ZGC: under 1 ms; G1: tens of ms).                    |
| WATCH pause_seconds' rate rising.                                                                |
| BAD   pause_avg_ms in the hundreds for G1, or above 10 for ZGC: the collector is behind.         |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_gc_last   jvm.gc_last.<metric>   cron 1/2 * * * *                                            |
+-------------+------------------------------------------------------------------------------------+
| jvms        | the JVMs the job looked at (untagged)                                              |
| jmx_up      | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with one)   |
| duration_ms | how long it took, tagged collector=<its name>                                      |
| seconds_ago | since it ended, tagged the same                                                    |
| freed_bytes | what it freed, tagged the same                                                     |
| after_bytes | memory in use after it, tagged the same                                            |
+-------------+------------------------------------------------------------------------------------+
| GOOD  freed_bytes large, after_bytes small.                                                      |
| WATCH an old collector's freed_bytes small: little to free, much alive.                          |
| BAD   duration_ms in seconds; an old collector run seconds_ago a few seconds, again and again.   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_gc_cpu   jvm.gc_cpu.<metric>   cron 2/5 * * * *                                              |
+-------------------------+------------------------------------------------------------------------+
| jvms                    | the JVMs the job looked at (untagged)                                  |
| jmx_up                  | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM |
|                         | with one)                                                              |
| gc_cpu_seconds          | the GC threads' CPU, a running total                                   |
| process_cpu_seconds     | the process's CPU, a running total                                     |
| gc_cpu_percent_lifetime | the GC threads' share of it                                            |
+-------------------------+------------------------------------------------------------------------+
| GOOD  gc_cpu_percent_lifetime under 10.                                                          |
| WATCH gc_cpu_seconds' rate rising.                                                               |
| BAD   gc_cpu_percent_lifetime above 25: the collector takes a quarter of the JVM's CPU.          |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_allocation   jvm.allocation.<metric>   cron 1/2 * * * *                                      |
+-----------------------------+--------------------------------------------------------------------+
| jvms                        | the JVMs the job looked at (untagged)                              |
| jmx_up                      | 1 when the JVM answered at its JMX address, 0 when not (only for a |
|                             | JVM with one)                                                      |
| allocated_bytes             | allocated since it started, a running total (Java 21 and later)    |
| allocation_bytes_per_second | allocated per second, over two seconds                             |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  Steady for steady load.                                                                    |
| WATCH allocation rising with no rise in load: a change made the code allocate more.              |
| BAD   allocation high with young collections every few hundred milliseconds: the collector       |
|       cannot keep up.                                                                            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_promotion   jvm.promotion.<metric>   cron 3/5 * * * *                                        |
+------------------------+-------------------------------------------------------------------------+
| jvms                   | the JVMs the job looked at (untagged)                                   |
| promoted_last_bytes    | promoted by the last young collection                                   |
| survived_last_bytes    | survived it, in the survivor spaces                                     |
| promoted_avg_bytes     | promoted, on average                                                    |
| tenuring_threshold     | collections an object survives before promotion, now                    |
| tenuring_threshold_max | and at most                                                             |
| survivor_desired_bytes | the survivor space wanted                                               |
| survivor_overflowed    | 1 when the last young collection overflowed the survivors               |
+------------------------+-------------------------------------------------------------------------+
| GOOD  tenuring_threshold near tenuring_threshold_max; survivor_overflowed 0.                     |
| WATCH tenuring_threshold falling to 1: survivors are too small.                                  |
| BAD   survivor_overflowed 1, again and again: objects go straight to old gen.                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_tlab   jvm.tlab.<metric>   cron 6/15 * * * *                                                 |
+----------------------+---------------------------------------------------------------------------+
| jvms                 | the JVMs the job looked at (untagged)                                     |
| allocated_words      | allocated in buffers since the last collection, in words                  |
| threads              | threads that allocated                                                    |
| refills              | buffers refilled                                                          |
| refills_max          | the most refills by one thread                                            |
| slow_allocations     | allocations outside a buffer                                              |
| slow_allocations_max | the most by one thread                                                    |
| waste_gc_words       | buffer left unused at a collection, in words                              |
| waste_refill_words   | buffer left unused at a refill, in words                                  |
+----------------------+---------------------------------------------------------------------------+
| GOOD  slow_allocations small against refills.                                                    |
| WATCH slow_allocations rising.                                                                   |
| BAD   slow_allocations as many as refills: allocation is going the slow way.                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_gclog   jvm.gclog.<metric>   cron 4/5 * * * *                                                |
+--------------------------+-----------------------------------------------------------------------+
| jvms                     | the JVMs the job looked at (untagged)                                 |
| window_seconds           | the window: 300                                                       |
| pauses                   | pauses in it                                                          |
| pause_max_ms             | the longest                                                           |
| pause_p99_ms             | the 99th percentile                                                   |
| pause_total_ms           | all of them                                                           |
| full_gcs                 | full collections in it                                                |
| allocation_stalls_in_log | ZGC allocation stalls in the log read                                 |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  pause_p99_ms small for the collector; full_gcs 0.                                          |
| WATCH pause_max_ms rising.                                                                       |
| BAD   full_gcs above 0 with G1 or ZGC: they fell back to a full collection;                      |
|       allocation_stalls_in_log rising: ZGC could not keep up, and threads waited.                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_gclog_detail   jvm.gclog_detail.<metric>   cron 10/15 * * * *                                |
+------------------------------+-------------------------------------------------------------------+
| jvms                         | the JVMs the job looked at (untagged)                             |
| window_seconds               | the window: 900                                                   |
| pauses                       | pauses in it, tagged length=<under_10ms, 10_to_100ms,             |
|                              | 100ms_to_1s, over_1s>                                             |
| humongous_allocations_in_log | collections caused by humongous allocations, in the log read      |
| to_space_exhausted_in_log    | to-space exhaustion, in the log read                              |
| evacuation_failures_in_log   | evacuation failures, in the log read                              |
| promotion_failed_in_log      | promotion failures, in the log read                               |
+------------------------------+-------------------------------------------------------------------+
| GOOD  Nothing over_1s; the failures 0.                                                           |
| WATCH humongous_allocations_in_log rising: big arrays; raise -XX:G1HeapRegionSize, or make them  |
|       smaller.                                                                                   |
| BAD   to_space_exhausted_in_log or evacuation_failures_in_log rising: G1 is out of room, and its |
|       pauses grow.                                                                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_threads   jvm.threads.<metric>   every 1m                                                    |
+---------+----------------------------------------------------------------------------------------+
| jvms    | the JVMs the job looked at (untagged)                                                  |
| jmx_up  | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with one)       |
| live    | threads now                                                                            |
| daemon  | of those, daemon threads                                                               |
| peak    | the most at once                                                                       |
| started | started since it began, a running total                                                |
| state   | threads in a state, tagged state=<runnable, blocked, waiting, timed_waiting, new>      |
|         | (JMX)                                                                                  |
+---------+----------------------------------------------------------------------------------------+
| GOOD  live steady under steady load.                                                             |
| WATCH live rising without end: a thread leak; blocked rising: contention (jvm_contention).       |
| BAD   live in the thousands and rising: the JVM will run out of memory or of the system's thread |
|       limit.                                                                                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_deadlocks   jvm.deadlocks.<metric>   every 1m                                                |
+--------------------+-----------------------------------------------------------------------------+
| jvms               | the JVMs the job looked at (untagged)                                       |
| jmx_up             | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with |
|                    | one)                                                                        |
| deadlocked         | threads deadlocked, on monitors or java.util.concurrent locks               |
| monitor_deadlocked | of those, on monitors (synchronized)                                        |
| thread             | always 1, for each (the first 20), tagged thread=, waits_on=<the lock, by   |
|                    | its class> and held_by=<a thread>                                           |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  deadlocked 0.                                                                              |
| WATCH Nothing to watch: a deadlock is an act.                                                    |
| BAD   deadlocked above 0: those threads will never run again; a thread dump, then a restart.     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_contention   jvm.contention.<metric>   cron 12/15 * * * *                                    |
+---------------------+----------------------------------------------------------------------------+
| jvms                | the JVMs the job looked at (untagged)                                      |
| jmx_up              | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM     |
|                     | with one)                                                                  |
| blocked             | threads blocked on a lock now                                              |
| waiting             | threads waiting (for work, a condition, a timeout)                         |
| blocked_times_total | times threads have blocked, a running total                                |
| lock_waiters        | threads waiting for a lock, tagged lock=<its class> and held_by=<a thread> |
|                     | (the top 10)                                                               |
+---------------------+----------------------------------------------------------------------------+
| GOOD  blocked near 0.                                                                            |
| WATCH blocked_times_total's rate rising; one lock always at the top.                             |
| BAD   blocked a large share of live: the threads queue for one lock.                             |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_hot_threads   jvm.hot_threads.<metric>   cron 14/15 * * * *                                  |
+--------------------+-----------------------------------------------------------------------------+
| jvms               | the JVMs the job looked at (untagged)                                       |
| jmx_up             | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with |
|                    | one)                                                                        |
| cpu_time_enabled   | 0 when the JVM does not measure threads' CPU (and nothing else is shown)    |
| cpu_percent_total  | all threads, in percent of one CPU                                          |
| cpu_percent        | a thread, tagged thread=<its name> (the top 10, from 0.5%)                  |
| busy_threads_shown | threads shown                                                               |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  The threads you expect at the top.                                                         |
| WATCH GC threads at the top: see jvm_gc.                                                         |
| BAD   one thread near 100 for a long time: a loop that does not end.                             |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_virtual_threads   jvm.virtual_threads.<metric>   cron 1/5 * * * *                            |
+-----------------------+--------------------------------------------------------------------------+
| jvms                  | the JVMs the job looked at (untagged)                                    |
| jmx_up                | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM   |
|                       | with one)                                                                |
| scheduler_parallelism | the scheduler's parallelism (Java 24 and later)                          |
| carriers              | carrier threads                                                          |
| mounted               | virtual threads running on a carrier (Java 24 and later)                 |
| queued                | virtual threads waiting for one (Java 24 and later)                      |
| carriers_runnable     | carriers runnable now (Java 21 to 23)                                    |
+-----------------------+--------------------------------------------------------------------------+
| GOOD  queued near 0.                                                                             |
| WATCH carriers above scheduler_parallelism: carriers were added for threads pinned in blocking   |
|       calls.                                                                                     |
| BAD   queued rising: virtual threads wait for carriers; something pins them.                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_classes   jvm.classes.<metric>   cron 0/5 * * * *                                            |
+--------------+-----------------------------------------------------------------------------------+
| jvms         | the JVMs the job looked at (untagged)                                             |
| jmx_up       | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with one)  |
| loaded       | classes loaded now                                                                |
| loaded_total | ever loaded, a running total                                                      |
| unloaded     | unloaded, a running total                                                         |
| load_seconds | time spent loading classes (counters)                                             |
+--------------+-----------------------------------------------------------------------------------+
| GOOD  loaded steady once started.                                                                |
| WATCH loaded rising with each redeploy, and never falling.                                       |
| BAD   loaded rising without end: a classloader leak, or code generating classes                  |
|       (jvm_classloaders).                                                                        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_classloaders   jvm.classloaders.<metric>   cron 3/15 * * * *                                 |
+-----------------+--------------------------------------------------------------------------------+
| jvms            | the JVMs the job looked at (untagged)                                          |
| jmx_up          | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with    |
|                 | one)                                                                           |
| loaders         | classloaders                                                                   |
| loaders_of_type | loaders of a type, tagged type=<its class> (the top 15)                        |
| classes_of_type | classes they hold, tagged the same                                             |
| ..._not_shown   | past 100 of a list (types), how many were left out                             |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  loaders steady once started.                                                               |
| WATCH A web application's loader type counting more than one: an old one was not freed.          |
| BAD   loaders rising with each redeploy: restart, and look for what keeps the old loader.        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_jit   jvm.jit.<metric>   cron 1/5 * * * *                                                    |
+---------------------+----------------------------------------------------------------------------+
| jvms                | the JVMs the job looked at (untagged)                                      |
| jmx_up              | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM     |
|                     | with one)                                                                  |
| compile_seconds     | time compiling, a running total                                            |
| compiles            | compilations, a running total (counters)                                   |
| osr_compiles        | on-stack replacements, a running total (counters)                          |
| compiled_code_bytes | compiled code (counters)                                                   |
+---------------------+----------------------------------------------------------------------------+
| GOOD  compile_seconds' rate near 0 once warm.                                                    |
| WATCH compile_seconds' rate high long after start: code keeps changing shape.                    |
| BAD   compile_seconds' rate rising late in life: see jvm_deopt and jvm_codecache.                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_deopt   jvm.deopt.<metric>   cron 7/15 * * * *                                               |
+---------------------+----------------------------------------------------------------------------+
| jvms                | the JVMs the job looked at (untagged)                                      |
| invalidated         | compiled methods thrown away, a running total                              |
| bailouts            | compilations given up, a running total                                     |
| compiles            | compilations, a running total                                              |
| invalidated_percent | invalidated against compiles                                               |
+---------------------+----------------------------------------------------------------------------+
| GOOD  invalidated_percent small.                                                                 |
| WATCH invalidated rising: code compiled on one assumption keeps being redone.                    |
| BAD   bailouts rising: methods the JIT cannot compile run slowly for good.                       |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_safepoints   jvm.safepoints.<metric>   cron 2/5 * * * *                                      |
+--------------------------+-----------------------------------------------------------------------+
| jvms                     | the JVMs the job looked at (untagged)                                 |
| safepoints               | safepoints, a running total                                           |
| stopped_seconds          | time stopped, a running total                                         |
| sync_seconds             | time waiting for every thread to stop, a running total                |
| stopped_percent_lifetime | time stopped, against the time it has run                             |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  stopped_seconds' rate close to the GC's pause rate.                                        |
| WATCH sync_seconds large against stopped_seconds: a thread slow to stop (a long counted loop).   |
| BAD   stopped_percent_lifetime above 5: the JVM spends that much of its time stopped.            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_finalization   jvm.finalization.<metric>   cron 11/15 * * * *                                |
+---------+----------------------------------------------------------------------------------------+
| jvms    | the JVMs the job looked at (untagged)                                                  |
| jmx_up  | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with one)       |
| pending | objects waiting to be finalized                                                        |
+---------+----------------------------------------------------------------------------------------+
| GOOD  pending near 0.                                                                            |
| WATCH pending rising.                                                                            |
| BAD   pending in the thousands: the finalizer is stuck; the memory will not come back.           |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_os   jvm.os.<metric>   cron 1/2 * * * *                                                      |
+---------------------+----------------------------------------------------------------------------+
| jvms                | the JVMs the job looked at (untagged)                                      |
| jmx_up              | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM     |
|                     | with one)                                                                  |
| process_cpu_percent | its CPU, in percent of all CPUs                                            |
| system_cpu_percent  | the machine's (or container's), the same way                               |
| process_cpu_seconds | its CPU, a running total                                                   |
| load_average        | the load average (not on Windows)                                          |
| cpus                | CPUs it may use                                                            |
| memory_bytes        | memory it sees                                                             |
| memory_free_bytes   | of that, free                                                              |
| swap_bytes          | swap                                                                       |
| swap_free_bytes     | of that, free                                                              |
| open_files          | its open files (not on Windows)                                            |
| open_files_max      | its limit                                                                  |
| open_files_percent  | open against the limit                                                     |
+---------------------+----------------------------------------------------------------------------+
| GOOD  process_cpu_percent within what you expect; open_files_percent low.                        |
| WATCH swap_free_bytes falling: the machine is swapping, and GC pauses with it.                   |
| BAD   open_files_percent above 90: 'Too many open files' is near.                                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_io   jvm.io.<metric>   cron 3/5 * * * *                                                      |
+-------------+------------------------------------------------------------------------------------+
| jvms        | the JVMs the job looked at (untagged)                                              |
| jmx_up      | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with one)   |
| read_bytes  | read from disk, a running total                                                    |
| write_bytes | written, a running total                                                           |
| open        | open, tagged kind=<socket, file, pipe or other> (Linux)                            |
+-------------+------------------------------------------------------------------------------------+
| GOOD  Steady for steady load.                                                                    |
| WATCH open kind=socket rising: connections not closed.                                           |
| BAD   open rising without end: a leak of connections or files.                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_crashes   jvm.crashes.<metric>   cron 0/5 * * * *                                            |
+--------------------------------+-----------------------------------------------------------------+
| jvms                           | the JVMs the job looked at (untagged)                           |
| jmx_up                         | 1 when the JVM answered at its JMX address, 0 when not (only    |
|                                | for a JVM with one)                                             |
| crash_reports_day              | crash reports written in the last day                           |
| crash_reports                  | crash reports there                                             |
| crash_reports_bytes            | their size                                                      |
| newest_crash_report_age_second | since the newest was written                                    |
| s                              |                                                                 |
| compiler_replays_day           | compiler replay files in the last day                           |
| compiler_replays               | compiler replay files there                                     |
| compiler_replays_bytes         | their size                                                      |
| newest_compiler_replay_age_sec | since the newest                                                |
| onds                           |                                                                 |
| core_dumps_day                 | core dumps in the last day                                      |
| core_dumps                     | core dumps there                                                |
| core_dumps_bytes               | their size                                                      |
| newest_core_dump_age_seconds   | since the newest                                                |
+--------------------------------+-----------------------------------------------------------------+
| GOOD  crash_reports_day 0.                                                                       |
| WATCH core_dumps_bytes large: they fill the disk.                                                |
| BAD   crash_reports_day above 0: the JVM crashed; read the report, it names the frame that       |
|       failed.                                                                                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_oom   jvm.oom.<metric>   cron 1/5 * * * *                                                    |
+------------------------------+-------------------------------------------------------------------+
| jvms                         | the JVMs the job looked at (untagged)                             |
| jmx_up                       | 1 when the JVM answered at its JMX address, 0 when not (only for  |
|                              | a JVM with one)                                                   |
| heap_dumps_day               | heap dumps written in the last day                                |
| heap_dumps                   | heap dumps there                                                  |
| heap_dumps_bytes             | their size                                                        |
| newest_heap_dump_age_seconds | since the newest was written                                      |
+------------------------------+-------------------------------------------------------------------+
| GOOD  heap_dumps_day 0.                                                                          |
| WATCH heap_dumps_bytes large: each is as big as the heap, and they fill the disk.                |
| BAD   heap_dumps_day above 0: the JVM ran out of memory; the dump says what filled it.           |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_jfr   jvm.jfr.<metric>   cron 17 * * * *                                                     |
+--------------------+-----------------------------------------------------------------------------+
| jvms               | the JVMs the job looked at (untagged)                                       |
| jmx_up             | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with |
|                    | one)                                                                        |
| available          | 1 when the JVM has Flight Recorder (Java 11 and later, and 8u262)           |
| recordings         | recordings                                                                  |
| recordings_running | of those, running                                                           |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  As you set it up.                                                                          |
| WATCH recordings_running 0 where you meant one to run, for the record when something goes wrong. |
| BAD   recordings growing without end: recordings started and never stopped.                      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jvm_mbeans   jvm.mbeans.<metric>   cron 4/5 * * * *                                              |
+--------+-----------------------------------------------------------------------------------------+
| jvms   | the JVMs the job looked at (untagged)                                                   |
| jmx_up | 1 when the JVM answered at its JMX address, 0 when not (only for a JVM with one)        |
| value  | an attribute, tagged mbean=<its object name> and attribute=<the attribute>              |
+--------+-----------------------------------------------------------------------------------------+
| GOOD  As your application defines it.                                                            |
| WATCH As your application defines it.                                                            |
| BAD   As your application defines it.                                                            |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, not rules: Vigil runs the jobs and delivers what they print, and the alerts are yours, in the backend you already use. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Give most alerts a few minutes, since a heap fills and empties between collections, and a busy moment leaves threads blocked for a while, and that is healthy. The last column is what the test JVMs showed, in [the Fedora run's console output](../../tests/integration/backends/reports/runs/2026-11-22/fedora/pack-jvm/console.txt), each tagged as the test named it (`j8` is the Java 8, and so on; `host` and `plain` ran on the machine itself): most of it caused on purpose by `Trouble.java`, and where we caused nothing, it says so. Everything not here (memory pools, the JIT, classes, I/O, settings) is for dashboards.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `jvm.process.running`, `jvm.status.up`, `jvm.process.uptime_seconds` | 1, and uptime rising | `uptime_seconds` back near 0: it restarted | `running` or `up` 0: the JVM is gone | `running 0` for a target whose JVM was not running. Restarts not caused |
| `jvm.status.jmx_up` (every JMX job reports it) | 1 for each JVM with a JMX address | | 0: JMX stopped answering, and that JVM's JMX figures are missing. The other tiers still report | `jmx_up 0` with the job pointed at a port where nothing listens |
| `jvm.heap.used_percent` | A saw-tooth, falling well below half after each collection | The low points rising over hours | Above 90 and staying there: out of memory is near | 95.0 on `j8`: a leak, and two threads allocating flat out, on a 256 MB heap |
| `jvm.pools.after_gc_percent`, `after_gc_bytes` (old gen; ZGC and Shenandoah have one pool) | Steady | `after_gc_bytes` rising over hours: a leak | `after_gc_percent` above 80: collections no longer free enough | 99.99 for `j8`'s `PS_Old_Gen` |
| `jvm.gc.time_seconds_total` (as a rate), `time_percent_lifetime` | Under 0.05: 5% of the time | Above 0.05 and rising | Above 0.2: a fifth of its time collecting. ZGC and Shenandoah collect beside the application, and count that here too: alert on their pauses instead | `time_percent_lifetime` 44.9 on `j8`; 81.6 on ZGC's `j17`, nearly all of it concurrent, with 0.149 seconds of pauses in all |
| `jvm.gclog.pause_p99_ms`, `pause_max_ms`; `jvm.gclog_detail.pauses` (with `gclog=`) | Small for the collector: under 1 ms for ZGC, tens of ms for G1 | Rising for an hour | Any pause in `length=over_1s` | `j8`: longest 262.9 ms, 99th percentile 139.3 ms in five minutes; 594 pauses of 100 ms to 1 s in 15 minutes, none over 1 s |
| `jvm.gclog.full_gcs`, `allocation_stalls_in_log` (with `gclog=`) | 0 with G1, ZGC and Shenandoah | `full_gcs` rising with Parallel or Serial | Above 0 with G1 or ZGC: it fell back to a full collection, or ZGC could not keep up and threads waited | `allocation_stalls_in_log` 3,905 on ZGC's `j17`, two threads allocating flat out; `full_gcs` 2,639 on Parallel's `j8`, 0 on G1 and ZGC |
| `jvm.gclog_detail.to_space_exhausted_in_log`, `evacuation_failures_in_log`, `promotion_failed_in_log` | 0 | | Rising: the collector is out of room, and its pauses grow | 22 evacuation failures on G1's `j21`: a leak, big arrays and an out-of-memory, on 256 MB |
| `jvm.safepoints.stopped_seconds` (as a rate), `stopped_percent_lifetime`, `sync_seconds` | Under 5% of the time, close to the GC's pauses | `sync_seconds` large against `stopped_seconds`: a thread slow to stop | Above 5% of the time stopped | 47.3 on `j8`, 8.3 on `j21` |
| `jvm.oom.heap_dumps_day` | 0 | `heap_dumps_bytes` large: each is as big as the heap, and they fill the disk | Above 0: the JVM ran out of memory; the dump says what filled it | 1 on `j21`, after it ran out of memory on purpose. Every test JVM looked in the same folder (`JVM_DUMP_DIRS`), so each showed it |
| `jvm.crashes.crash_reports_day` | 0 | `core_dumps_bytes` large | Above 0: the JVM crashed; the report names the frame that failed | 1, from a Java 17 crashed on purpose, seen on every JVM through the same shared folder |
| `jvm.deadlocks.deadlocked` (JMX, `readwrite`) | 0 | | Any: those threads never run again. A thread dump, then a restart | 2 on `j21` and on `host`: `deadlock-a` and `deadlock-b`, each holding the lock the other wants |
| `jvm.threads.live` | Steady under steady load | Rising for an hour without falling: a thread leak | In the thousands and rising: memory or the system's thread limit runs out | 414 on `j8` and 409 on `plain`, each leaking a thread a second, to 400 |
| `jvm.contention.blocked`, `lock_waiters` | Near 0 | Rising, or one lock always at the top of `lock_waiters` | A large share of `jvm.threads.live` for 15 minutes or more: threads queue for one lock | 7 of `j17`'s 22 threads, all waiting for one lock held by `contender-3`: eight threads taking turns on it |
| `jvm.hot_threads.cpu_percent` (percent of one CPU) | The threads you expect at the top | GC threads at the top: see `jvm.gc` | One thread near 100, run after run: a loop that does not end | 69.0 for `busy-loop` on `j25`, a thread in a loop on purpose |
| `jvm.os.open_files_percent`; `jvm.process.open_files` against `open_files_max` | Low | Above 80 | Above 90: `Too many open files` is near | Not caused: 0.0044 (23 of 524,288) on `j8` |
| `jvm.buffers.used_bytes` (`pool=direct`) | Steady under load | Rising with no rise in load | Near `-XX:MaxDirectMemorySize` (by default, the heap's maximum): `OutOfMemoryError: Direct buffer memory` is near | 268,451,840 on `j11`, in 66 buffers: 4 MB leaked every two seconds, to 256 MB, under its 512 MB limit |
| `jvm.native_overhead.outside_heap_bytes` | Steady once started | Rising over hours with a steady heap | Rising without end: a native leak (see `jvm.buffers`, `jvm.native`) | 348,848,128 on `j11`, 90.6% of its resident memory, most of it the leaked buffers |
| `jvm.metaspace.metaspace_used_percent`, `class_space_used_percent` | Steady once started | Rising with each redeploy: old classes not freed | Above 90: `OutOfMemoryError: Metaspace` is near | Not caused: class space 0.15% used on `j11`, even with its 200 leaked classloaders |
| `jvm.classloaders.loaders`, `jvm.classes.loaded` | Steady once started | Rising with each redeploy | Rising without end: restart, and look for what keeps the old loaders | 302 loaders on `j11`, 200 of them `URLClassLoader`: one leaked every five seconds, to 200 |
| `jvm.finalization.pending` | Near 0 | Rising | In the thousands: the finalizer is stuck, and that memory will not come back | 208,285 on `j11`, whose objects' finalizer sleeps 50 ms each |
| `jvm.security.debug_agent_remote`, `jmx_no_password`, `jmx_no_tls`, `risks`; `jvm.flags.risks` | 0 | Any: a risk to decide on, not an outage | | `debug_agent_remote 1` on `j25`, a debugger listening on every address; `jmx_no_tls 1` on `j8`; `flags.risks 1` on every JVM but `j21`, the one set to dump its heap on out-of-memory |

## How it was tested

**Tested** on 2026-11-22 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-jvm.sh`, with the client on Java 25.0.4, against eight JVMs made to misbehave (`Trouble.java`: a deadlock, leaked threads, a busy thread, blocked threads, leaking direct buffers and classloaders, an out-of-memory heap dump). Six were in Docker: **Java 8** with Parallel GC and JMX with a password but no TLS; **Java 11** tracking its native memory, **Java 17** with ZGC, **Java 21** with G1 and **Java 25** with Shenandoah and a debugger listening, each with JMX over TLS and a password; and a Java 21 with no JMX, run as root. Two ran on the machine itself on Java 25, one with JMX and one without. Beside them, a Java 17 crashed once, on purpose, for its crash report. `service-packs.sh` through Vigil, then every job: **93 passed, 0 failed**. That covers each tier alone and together, GC logs from Java 8, G1 and ZGC, a `readonly` JMX user, a wrong password, a certificate it cannot trust, JMX that does not answer and a JVM not running. Then from a container that sees the machine's processes as root, as Vigil running as root would, `jvm_discovery` and `jvm_heap` read the counters of all eight: [the console output](../../tests/integration/backends/reports/runs/2026-11-22/fedora/pack-jvm/console.txt). **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, Java 21), against a JVM of its own without JMX and the Fedora JVMs over JMX through SSH tunnels: every job directly, then `service-packs.sh` through Vigil, **64 passed, 0 failed**: [the console output](../../tests/integration/backends/reports/runs/2026-11-22/macos/pack-jvm-macos/console.txt). **On Windows**, the same way with Java 21, `Service-Packs.ps1` through Vigil, **74 passed, 0 failed**: on Windows PowerShell 5.1 and PowerShell 7 on Windows 11 ([the console output](../../tests/integration/backends/reports/runs/2026-11-22/windows/pack-jvm-windows/console.txt)), and on Windows PowerShell 5.1 on Windows Server 2025 ([the console output](../../tests/integration/backends/reports/runs/2026-11-22/windows-server-2025/pack-jvm-windows/console.txt)). Both Windows machines ran it as an account that is not an administrator, logged on by SSH key. CIM refused that account, so the JVMs were found as above, without CIM. Windows also refuses its data protection to such a logon, so the password came from an `env:` reference.

**Version 1.1.0, on a JRE**, tested on 2026-11-22 the same way, against the same JVMs, then every job again on a JRE, from `_client.jar`.
- **On Fedora**, on Temurin's JRE 11, the oldest Java the client runs on, with the jar compiled by `tools/release/client-jar.sh` with `javac` 21: **106 passed, 0 failed**.
  - The jar built twice was the same, byte for byte, and its digest was in every script.
  - All 41 jobs ran from the jar, about three minutes in all, and every JVM was up.
  - Ten of the jobs printed the same lines, values apart, as the source does on a JDK.
  - A jar changed by one byte was refused, on the JRE and on a JDK, saying why. A script with no digest ran no jar. Without the jar, the JRE could not run the source, and Java said so.
  - [The console output](../../tests/integration/backends/reports/runs/2026-11-22/fedora/pack-jvm-1.1.0/console.txt).
- **On macOS**, on the Intel Mac test machine, on Temurin's JRE 21: **77 passed, 0 failed**. [The console output](../../tests/integration/backends/reports/runs/2026-11-22/macos/pack-jvm-1.1.0-macos/console.txt).
- **On Windows**, from a packs release built by `tools/release/packs.sh`, on Temurin's JRE 21: **86 passed, 0 failed** on each run.
  - Windows 11, on Windows PowerShell 5.1 and PowerShell 7: [the console output](../../tests/integration/backends/reports/runs/2026-11-22/windows/pack-jvm-1.1.0-windows/console.txt).
  - Windows Server 2025, on Windows PowerShell 5.1: [the console output](../../tests/integration/backends/reports/runs/2026-11-22/windows-server-2025/pack-jvm-1.1.0-windows/console.txt).

**Version 1.2.0, on the probe's engine**, tested on 2026-11-22 the same way, against the same eight JVMs, with the pack built as a release builds it: both jars compiled by `tools/release/client-jar.sh` with `javac` 21, and their digests in every script.
- **On Fedora**: `service-packs.sh` through Vigil, then every job on Temurin's JRE 11: **110 passed, 0 failed**.
  - The probe built there was `_probe.jar` `debab93f…`, byte for byte the one in the kafka pack 2.0's release, and the pack's `_probe.java` the shared one.
  - Both jars built twice were the same, byte for byte, and both digests were in every script.
  - All 41 jobs ran from the jars on the JRE, and ten printed the same lines, values apart, as the same jars on a JDK.
  - A client or a probe changed by one byte was refused, saying which. Without the probe, nothing ran, and the script said so.
  - [The console output](../../tests/integration/backends/reports/runs/2026-11-22/fedora/pack-jvm-1.2.0/console.txt).
- **On macOS**, on the Intel Mac test machine, with the jars built there (the same bytes as on Fedora), every job on Java 21, then on Temurin's JRE 21: **83 passed, 0 failed**. [The console output](../../tests/integration/backends/reports/runs/2026-11-22/macos/pack-jvm-1.2.0-macos/console.txt).
- **On Windows**, from a packs release built by `tools/release/packs.sh`: `Service-Packs.ps1` through Vigil, then every job on Temurin's JRE 21, **90 passed, 0 failed** on each run.
  - Windows 11, on Windows PowerShell 5.1 and PowerShell 7: [the console output](../../tests/integration/backends/reports/runs/2026-11-22/windows/pack-jvm-1.2.0-windows/console.txt).
  - Windows Server 2025, on Windows PowerShell 5.1: [the console output](../../tests/integration/backends/reports/runs/2026-11-22/windows-server-2025/pack-jvm-1.2.0-windows/console.txt).

**Version 1.2.1** carries the probe with the words the Tomcat, Jetty and ActiveMQ packs need: nothing of the jvm pack's own changes, and its client is the same, byte for byte (`fb88b458…`). Tested on 2026-11-23 the same way, against the same eight JVMs, then every job on Temurin's JRE 11: **110 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/fedora/pack-jvm-1.2.1/console.txt)).

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
