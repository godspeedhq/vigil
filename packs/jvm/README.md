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
