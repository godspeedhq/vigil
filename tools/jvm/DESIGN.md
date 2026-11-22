# The jvm pack: design

A pack that watches Java virtual machines: any Java application (Jenkins, Spring Boot, Elasticsearch, Keycloak, an application of your own) through the JVM it runs on. It reports the JVM, not the application. Linux and macOS in bash, Windows in PowerShell 5.1 and 7, like every pack.

Status: agreed design, not yet built.

## Scope: the JVM, and nothing above it

- **The JVM only.** Memory, garbage collection, threads, the JIT, classes, the process, crashes, settings and security.
- **No application server or library metrics.** Tomcat, Jetty, Undertow, HikariCP and the like get packs of their own, which report only what is theirs: a thread pool, connectors, requests, sessions, a connection pool.
- **No pack depends on another.** Every pack installs and works alone. A pack for something that runs on a JVM (`tomcat`, `jetty`) does not repeat this pack's metrics. It says, in its `needs` lines (shown by `vigil pack install` and `vigil pack info`) and its README section, that the `jvm` pack covers the JVM itself: advice, not a requirement. Installed together, the two read different things from the same JVM, and nothing is reported twice.
- **Shared code, not shared packs.** The packs that read JMX need the same Java client. Its source lives once in `tools/`, and each pack's generator copies it in, as `tools/kafka/gen.py` does with its head. Each pack ships its own copy, so each still stands alone, and a fix to the client reaches every pack at its next release.

## Three tiers: whatever can be reached

A JVM nobody configured is still watched. Each JVM gets every tier that reaches it, and each run says which tiers reached it (`tier_os`, `tier_counters`, `tier_jmx`, 1 or 0).

| Tier | Needs | Reads |
| --- | --- | --- |
| **1. The operating system** | Nothing | The process: up, memory, CPU, threads, open files by kind, disk I/O, uptime and restarts; the startup options it knows from the command line; crash reports and heap dumps on disk |
| **2. The JVM's own counters** | The same machine, and the account that runs the JVM, or root or an administrator. HotSpot JVMs (Oracle, OpenJDK, Temurin, Corretto…), unless started with `-XX:-UsePerfData` | The `hsperfdata` file `jstat` reads: heap and each pool, GC counts and times, promotion, TLABs, classes, the JIT, safepoints |
| **3. JMX** | The JVM's JMX address, given in the configuration | Everything else, local or remote |

Plus the **GC log**, when the JVM writes one (`-Xlog:gc*:file=...`) and its path is given: pauses and what caused them, from the log alone.

### The JMX address is the switch

There is no `JMX_ENABLED`. A JVM with a JMX address gets tier 3; one without gets tiers 1 and 2. Why:

1. A switch and an address can disagree (enabled with no address, or an address while disabled). One setting cannot.
2. It is per JVM, not per machine: one server often runs JVMs with JMX and without.
3. It keeps **not set up** apart from **broken**. No address: tiers 1 and 2, nothing to alert on. An address that does not answer: `jmx_up 0` for that JVM, which you should alert on, and tiers 1 and 2 still report.

Each JVM is one entry, named, with how to find it and, if it has one, its JMX address. For example (the exact format is settled when the pack is built):

```ini
env = JVM_TARGETS=jenkins:jmx=localhost:9010 billing:main=com.acme.Billing
```

Vigil never goes looking for JMX: no port scanning, no guessing.

### Turning JMX on, safely

The README shows the startup options for JMX with a password and TLS, listening on localhost only. The pack's `jvm_security` job reports a JMX port without a password or without TLS.

## The jobs: 41

The schedules here are a starting point: the real cost of each job is measured before they are fixed.

### Finding and knowing each JVM

| Job | Tier | Every | Reports |
| --- | --- | --- | --- |
| `jvm_process` | 1 | 1m | Up, resident and virtual memory, CPU, threads, open files against the limit, uptime |
| `jvm_discovery` | 1/2 | 1h | The JVMs on this machine, by main class, and which tiers reach each |
| `jvm_status` | 2/3 | 5m | Version, vendor, VM, uptime, the GC in use, the heap's maximum |
| `jvm_flags` | 1/3 | 15m | Settings at risk: no `-Xmx`, no heap dump on out-of-memory, an old GC, a heap larger than the machine or container allows |
| `jvm_container` | 3 | 1h | The CPUs and memory the JVM sees in a container, against the host's |
| `jvm_release_age` | 3 | 1h | Days since this Java was released (`java.version.date`): an unpatched JVM |
| `jvm_security` | 1/3 | 15m | A remote debugger listening (`-agentlib:jdwp`), JMX without a password or TLS, bytecode verification off, the attach mechanism open |
| `jvm_startup` | 1/2 | 15m | How long the JVM took to start, restarts in the last day: crash loops |

### Memory

| Job | Tier | Every | Reports |
| --- | --- | --- | --- |
| `jvm_heap` | 2/3 | 1m | Heap used, committed, maximum, and used against the maximum |
| `jvm_pools` | 2/3 | 2m | Each pool, and **each pool after the last GC**: old gen after GC is the leak signal |
| `jvm_metaspace` | 2/3 | 5m | Metaspace and compressed class space against their limits |
| `jvm_codecache` | 2/3 | 5m | Each code-cache segment, and whether the JIT stopped because it is full |
| `jvm_buffers` | 3 | 5m | Direct and mapped buffers: off-heap leaks |
| `jvm_native` | 3 | 15m | Native memory by category, when the JVM tracks it (`-XX:NativeMemoryTracking`) |
| `jvm_native_overhead` | 1+3 | 5m | Resident memory less the heap: native and off-heap leaks no Java bean shows |

### Garbage collection

| Job | Tier | Every | Reports |
| --- | --- | --- | --- |
| `jvm_gc` | 2/3 | 1m | Collections and time per collector, and the share of time spent collecting |
| `jvm_gc_cycles` | 2/3 | 2m | Pauses apart from concurrent work: with ZGC and Shenandoah, pauses are what users feel |
| `jvm_gc_last` | 3 | 2m | The last collection: how long, how much it freed |
| `jvm_gc_cpu` | 3 | 5m | CPU spent by the GC's threads (Java 22 and later) |
| `jvm_allocation` | 2/3 | 2m | Allocation rate |
| `jvm_promotion` | 2 | 5m | Promotion to old gen, and survivor overflow: objects promoted too early |
| `jvm_tlab` | 2 | 15m | Allocations outside thread-local buffers |
| `jvm_gclog` | log | 5m | From the GC log: pauses, their 99th percentile, full GCs, allocation stalls |
| `jvm_gclog_detail` | log | 15m | Pauses by size, G1 humongous allocations, to-space exhaustion, evacuation failures |

### Threads

| Job | Tier | Every | Reports |
| --- | --- | --- | --- |
| `jvm_threads` | 2/3 | 1m | Threads, daemon threads, peak, started, by state |
| `jvm_deadlocks` | 3 | 1m | **Deadlocked threads**, by name |
| `jvm_contention` | 3 | 15m | The most contended locks, and threads blocked on them |
| `jvm_hot_threads` | 3 | 15m | The busiest threads by CPU since the last run |
| `jvm_virtual_threads` | 3 | 5m | Java 21 and later: the virtual-thread scheduler's carriers, mounted and queued work (Java 24 and later), carriers pinned |

### The runtime

| Job | Tier | Every | Reports |
| --- | --- | --- | --- |
| `jvm_classes` | 2/3 | 5m | Classes loaded, ever loaded, unloaded |
| `jvm_classloaders` | 3 | 15m | Classloaders, and classes per loader: a redeploy leak shows here first |
| `jvm_jit` | 2/3 | 5m | Compile time, the compile queue |
| `jvm_deopt` | 2 | 15m | Deoptimizations: code the JIT keeps redoing |
| `jvm_safepoints` | 2 | 5m | Time stopped at safepoints: the pauses that are not the GC's |
| `jvm_finalization` | 3 | 15m | Objects waiting to be finalized |

### The machine, as the JVM sees it

| Job | Tier | Every | Reports |
| --- | --- | --- | --- |
| `jvm_os` | 3 | 2m | Process and system CPU, load, memory, swap, open files against the limit |
| `jvm_io` | 1 | 5m | The process's disk reads and writes, its open files by kind (sockets, files, pipes) |

### Trouble

| Job | Tier | Every | Reports |
| --- | --- | --- | --- |
| `jvm_crashes` | 1 | 5m | New crash reports (`hs_err_pid*.log`) and core dumps |
| `jvm_oom` | 1 | 5m | New heap dumps (`.hprof`): an out-of-memory |
| `jvm_jfr` | 3 | 1h | Flight Recorder recordings running |

### Your own

| Job | Tier | Every | Reports |
| --- | --- | --- | --- |
| `jvm_mbeans` | 3 | 5m | The MBean attributes you name, as metrics: one job for an application's own numbers |

## Rules every job keeps

- **Nothing heavy, ever.** No heap dumps, class histograms or full thread dumps: they can pause a production JVM. A job reads counters and makes calls that are cheap on any heap; a check with no cheap way is left out.
- **No secret anywhere it can leak.** A JMX password from the secret store, passed in the environment, never on a command line. TLS certificates are always checked.
- **A command line is read, never reported.** It can hold a password (`-Dpassword=...`); the pack reads only the options it knows.
- **A tool that hangs is stopped** (45 seconds, as in the Kafka pack), and judged by what it said.
- **Down is not refused.** A JVM that is not running reports `up 0`, and the run succeeds. A JMX login refused, or a certificate it cannot trust, fails the run and says why.
- **Readable at any size.** Lists (threads, pools, MBeans, JVMs) are capped, with `_not_shown` counts.

## The client

One Java source file, `_client.java`, which speaks JMX and reads `hsperfdata` for tier 2. A JDK runs it from source (`java _client.java`). A JRE cannot: compiling needs the `jdk.compiler` module, which a JRE leaves out. So from version 1.1.0 the pack also carries the client compiled, as `_client.jar` (next section). The machine that watches needs Java 11 or later, a JDK or a JRE. The JVMs watched may be Java 8 or later.

## On a JRE: the compiled client (1.1.0)

Many servers have only a JRE (a distribution's `-jre-headless` package, a vendor's JRE download), and Vigil should watch their JVMs without a JDK installed for it. That means shipping the client compiled, which every other pack avoids: a pack is meant to be text you can read before you run it. So the jar is held to rules that keep it as trustworthy as the source beside it.

### What ships

- **Both, side by side.** Each platform's archive carries `_client.java` and `_client.jar`. The jar is Java bytecode, not a native binary: one jar for Linux, macOS and Windows.
- **Java 11 bytecode** (`javac --release 11`), so any Java 11 or later runs it. Java 8 alone cannot; the JVMs watched may still be Java 8.
- **The jar when the pack has one, the source otherwise.** A pack from a packs release has the jar, and every script runs it, `java -cp _client.jar JvmClient <job>`, with a JDK or a JRE, once it matches the digest the script carries. A copy of the pack without one (from the repository) runs the source, which needs a JDK.
- **Why not the source whenever Java can run it.** That was the first idea, and the test machines ruled it out: whether a Java can run a source file cannot be told from outside it. Fedora's `java-25-openjdk` package runs source files with no `javac` beside its `java`; Temurin's JRE 11 cannot, though its `release` file names `jdk.compiler`. Only asking the JVM tells, at the cost of starting one more each run. The jar has no such question, and a run from it takes about half a second, where the source takes two or three.
- **Never committed.** The repository holds the source only. The jar is built when a packs release is built.

### Built so anyone can check it

- **Built by the release workflow, never by hand**: `tools/release/packs.sh` compiles every `_client.java` in a pack being released, from the tagged commit.
- **The same bytes every time** from the same source and the same `javac`: classes added in sorted order, no manifest (`jar --no-manifest`), and every entry dated 1980-01-01 (`jar --date`). The `javac` version that built it goes in each script's header, so anyone can compile the source with that version and compare digests.
- **Its SHA-256 written into each script** of that platform at release (`@CLIENT_JAR_SHA256@` in the repository's scripts). It is also covered as every file of a pack is: the archive's SHA-256 is in the signed `packs.index`.

### Checked before it runs

- **The script checks the jar against the digest it carries** before running it, with `sha256sum`, `shasum -a 256` or `openssl` (`Get-FileHash` on Windows). A jar that does not match fails the run: `_client.jar does not match this script's digest: reinstall the pack (vigil pack install jvm)`. So does a script with no digest stamped (one copied from the repository, which has no jar).
- **What that guards against, and what it does not.** It catches a jar replaced on its own, or damaged. It does not stop someone who can also rewrite the script. Nothing in a pack can: what stops them is who may write to `packs/`, which `vigil doctor` checks (below).
- **No jar and no JDK** (a copy from the repository, on a JRE) fails the run, with Java's own reason.

### Vigil's part (Vigil 1.4.0, in SPECIFICATION.md when built)

These help every pack, not just this one: a `.sh` or `.ps1` swapped on disk is as dangerous as a swapped jar, only easier to spot.

- **`vigil pack verify [<name>...] [--from <folder>]`**: checks the packs installed here against the packs release they came from. For each pack, it fetches the archive of the installed version for this platform (or reads it from a folder `vigil pack download` wrote), checks it against the signed index as `install` does, and compares every file, byte for byte:
  - `pack jvm 1.1.0: 44 files match packs-2026.11.23`
  - a file that differs (`changed`), one the archive has and this machine does not (`missing`), one here that is not in the archive (`not in the pack`) each fail it;
  - a script kept from an older version because a job still runs it (`vigil pack update` keeps such scripts) is a `note`, not a failure;
  - a pack that is not in the repository (one of your own) is `not from the repository: not checked`.
  
  It reads only and changes nothing. Exit code 0 when every pack checked matches, 1 otherwise.
- **`vigil doctor`: who can change what Vigil runs.** A new section. It warns (`WARN`) when anyone but the owner, root or the administrators can write to `app/`, `packs/` or `config/`, or to anything in them:
  - **Linux, macOS:** group- or world-writable files and folders;
  - **Windows:** an access rule that lets Everyone, Authenticated Users, Users or Interactive write, modify or create files.
  
  The installers already set this up; this finds it changed since. Like the rest of `doctor`, it reads only, and names the paths (the first few, and how many more).

### Tested

- **On a JRE**, on Linux, macOS and Windows: the jobs run from the jar, with the same lines as from the source.
- **The same lines** from the jar on a JRE as from the source on a JDK.
- **A jar changed by one byte** fails the run, on a JRE and on a JDK, and says why. A script with no digest runs no jar. **No jar on a JRE** fails, and Java says why.
- **Built twice, the jar is the same**, byte for byte; the release refuses one built differently from its scripts' digest.
- **`vigil pack verify`** against a test packs release: all match; a script changed, a file missing, a file added, each found; a kept script a note; a pack of your own skipped; `--from` offline.
- **`vigil doctor`**: a group-writable script in `packs/` (Linux, macOS), and Users given write to `packs\` (Windows), each a `WARN`; a fresh install, none.

## Verified before it is relied on

- Tier 2 across accounts: reading another account's `hsperfdata` as root (Linux, macOS) and as an administrator (Windows), and inside containers.
- What each job really costs, run by run, on each platform.
- Which counters each JVM version and GC has: a job prints what is there, and nothing for what is not.

## Testing

In Docker on the Fedora test machine:

- **JVMs:** Java 8, 11, 17, 21 and 25; the G1, ZGC, Parallel and Serial collectors; JMX with a password and TLS; one JVM with JMX off (tiers 1 and 2 only); one writing a GC log.
- **Each with a problem on purpose:** a heap leak, a GC storm, a real deadlock, a thread leak, an off-heap leak, a classloader leak, an out-of-memory with a heap dump, a crash with a crash report, a remote debugger listening.
- **Then** macOS and both Windows machines against them, through tunnels, as with Kafka; and tier 1 and 2 on each platform against a JVM of its own.

Evidence goes in `tests/integration/backends/reports/runs/<date>/`, with a tested-on paragraph in `packs/README.md`.

## After this pack: the kafka pack

The `kafka` pack has a `kafka_jvm` job (each broker's heap, GC, open files, CPU, threads), from before this rule: with both packs installed, those would be reported twice. Decided: once the `jvm` pack is released, the next `kafka` release drops `kafka_jvm`, and its `needs` line and README section point to the `jvm` pack for the brokers' JVMs.
