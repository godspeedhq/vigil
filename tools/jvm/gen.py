# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""Writes packs/jvm: pack.config, each job's script for Linux and macOS
(bash) and Windows (PowerShell), and beside them _client.java, the client
every script runs (tools/jvm/_client.java). The scripts are thin: each runs
the client for its job, so every platform prints the same lines. Run from
the repository: python tools/jvm/gen.py ."""
import os
import sys
import textwrap

repo = sys.argv[1]
src = os.path.join(repo, 'tools', 'jvm')
out = os.path.join(repo, 'packs', 'jvm')

NOTICE = [
    'Copyright (c) Bankole Ogundero and the Vigil contributors',
    'SPDX-License-Identifier: Apache-2.0',
    '',
    'Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or',
    'implied. Run it at your own risk: review it first, and test it before you',
    'rely on it. In no event shall the authors or copyright holders be liable',
    'for any claim, damages or other liability arising from its use. See the',
    'LICENSE file for the full terms.',
]

TIERS = {
    'os': "From the operating system: the JVM's process, which needs nothing set up.",
    'counters': ("From the JVM's own counters, the hsperfdata file HotSpot JVMs keep (unless started with "
                 "-XX:-UsePerfData): on this machine, readable by the account that runs the JVM, or by root or an "
                 "administrator."),
    'jmx': ("From JMX, for each JVM given a JMX address in JVM_TARGETS (jmx=host:port, or jmxs=host:port for "
            "JMX over TLS, its certificate checked against JVM_CACERT or Java's own CAs, and against its name), as "
            "JVM_JMX_USER with the password in JVM_JMX_PASSWORD (a secret line, never a command line). A JVM "
            "with an address that does not answer reports jmx_up 0."),
    'log': ("From the JVM's GC log, for each JVM given one in JVM_TARGETS (gclog=<path>): unified logging "
            "(Java 9 and later: -Xlog:gc*:file=<path>; -Xlog:gc alone leaves out ZGC's and Shenandoah's pauses) "
            "or Java 8's -XX:+PrintGCDetails -XX:+PrintGCTimeStamps, readable by this account."),
}
TARGETS = ("JVM_TARGETS names the JVMs: name: key=value, ...; name: ... with main=<its main class or jar, or any "
           "text on its command line> or pid=<a pid file> to find it on this machine, and jmx= or jmxs= for its JMX address. Empty, it "
           "watches every JVM on this machine, each named by its main class. Each metric is tagged jvm=<name>; "
           "jvms is how many JVMs the job looked at.")
READONLY = "Read-only: it changes nothing in the JVM, and nothing it does pauses one."

M = lambda *pairs: list(pairs)
JMX_UP = ('jmx_up', '1 when the JVM answered at its JMX address, 0 when not (only for a JVM with one)')
JVMS = ('jvms', 'the JVMs the job looked at (untagged)')

# job, schedule, tiers, title, what, metrics, healthy, watch, act
JOBS = [
    # -- finding and knowing each JVM --
    dict(job='process', when='run_every   = 1m', tiers=['os'], title="a JVM's process",
         what="Reports each JVM's process as the operating system sees it: whether it runs, its memory, CPU, "
              "threads, open files against its limit, and how long it has run. A JVM named by main= or pid= that "
              "is not running reports running 0.",
         metrics=M(JVMS, JMX_UP,
                   ('running', '1 when the process runs, 0 when a JVM looked for is not found'),
                   ('rss_bytes', 'resident memory: what it holds in RAM'),
                   ('virtual_bytes', 'virtual memory reserved'),
                   ('cpu_seconds', 'CPU used since it started (a running total: graph its rate)'),
                   ('threads', 'its threads, as the operating system counts them (Linux, Windows)'),
                   ('open_files', 'open files and sockets (Linux, as root or its own account; Windows: handles)'),
                   ('open_files_max', 'its limit on open files (Linux)'),
                   ('uptime_seconds', 'since it started')),
         healthy="running 1; rss_bytes steady; uptime_seconds rising.",
         watch="rss_bytes rising over days with a steady heap: memory outside the heap (jvm_native_overhead).",
         act="running 0; uptime_seconds falling back to near 0: it restarted; open_files near open_files_max."),
    dict(job='discovery', when='cron        = 7 * * * *', tiers=['os', 'counters'], title="the JVMs on a machine",
         what="Lists the JVMs running on this machine, by main class and account, whether this pack watches each, "
              "and whether their counters can be read here: what is running that nobody watches.",
         metrics=M(('jvms', 'JVMs running on this machine (untagged)'),
                   ('found', 'always 1, for each JVM, tagged main=<its main class or jar>, user=<its account>, '
                             'watched=<yes or no> and counters=<yes or no>'),
                   ('jvms_not_shown', 'JVMs past the first 50, left out')),
         healthy="Every JVM you run, watched=yes.",
         watch="A JVM you did not expect; counters=no for a JVM: Vigil runs as an account that cannot read them.",
         act="watched=no for a JVM that matters: add it to JVM_TARGETS."),
    dict(job='status', when='cron        = 1/5 * * * *', tiers=['os', 'counters', 'jmx'], title="a JVM's identity",
         what="Reports whether each JVM is up, which tiers reach it (its process, its counters, JMX), and what it "
              "is: Java version, vendor, VM and garbage collectors; its uptime and its heap's maximum.",
         metrics=M(JVMS, JMX_UP,
                   ('up', '1 when any tier finds the JVM, else 0'),
                   ('tier_os', '1 when its process is found on this machine'),
                   ('tier_counters', '1 when its counters can be read here'),
                   ('tier_jmx', '1 when it answers over JMX'),
                   ('info', 'always 1, tagged version=, vendor=, vm= and gc=<its collectors, joined by +>'),
                   ('uptime_seconds', 'since it started'),
                   ('heap_max_bytes', 'the most heap it may use')),
         healthy="up 1, and the tiers you expect at 1.",
         watch="info's version changing: the JVM was upgraded; a tier at 0 that was 1.",
         act="up 0: the JVM is gone; tier_jmx 0 with an address: JMX stopped answering (jmx_up says the same)."),
    dict(job='flags', when='cron        = 4/15 * * * *', tiers=['os', 'jmx'], title="a JVM's risky settings",
         what="Reports settings that hurt when something goes wrong: no maximum heap, no heap dump on "
              "out-of-memory, no exit on out-of-memory, a removed or deprecated collector, a heap larger than the "
              "machine's memory. From its startup options; with JMX, the values it really runs with.",
         metrics=M(JVMS, JMX_UP,
                   ('heap_max_set', '1 when the heap has a maximum set (-Xmx, MaxRAMPercentage or the like)'),
                   ('heap_dump_on_oom', '1 when it writes a heap dump on out-of-memory'),
                   ('exit_on_oom', '1 when it exits (or crashes, or runs a command) on out-of-memory'),
                   ('deprecated_gc', '1 when it asks for CMS or ParNew, removed in Java 14'),
                   ('heap_over_memory', "1 when its heap's maximum is more than the machine's memory (JMX)"),
                   ('explicit_gc_disabled', '1 when System.gc() does nothing (-XX:+DisableExplicitGC)'),
                   ('risks', 'how many of: no maximum heap, no heap dump, a deprecated collector, a heap over memory')),
         healthy="risks 0.",
         watch="exit_on_oom 0: a JVM out of memory may limp on, half-working, rather than restart.",
         act="heap_over_memory 1: the machine will swap or kill it before the heap fills; heap_dump_on_oom 0 on "
             "a JVM that has run out of memory before: the next one will leave nothing to look at."),
    dict(job='container', when='cron        = 11 * * * *', tiers=['jmx'], title="what a JVM sees of its machine",
         what="Reports the CPUs and memory each JVM sees, and for a JVM on this machine, the machine's own: a JVM "
              "in a container sees its limits, and sizes its heap and thread pools by them.",
         metrics=M(JVMS, JMX_UP,
                   ('cpus', 'CPUs the JVM may use'),
                   ('memory_bytes', 'memory the JVM sees'),
                   ('cpus_host', "this machine's CPUs (a JVM here only)"),
                   ('memory_host_bytes', "this machine's memory (a JVM here only)"),
                   ('cpus_limited', '1 when it sees fewer CPUs than the machine has'),
                   ('memory_limited', '1 when it sees less memory than the machine has')),
         healthy="cpus and memory_bytes what you meant it to have.",
         watch="cpus 1 in a container: the JVM picks the Serial collector and single-threaded pools.",
         act="memory_bytes far below what the heap needs: raise the container's limit, or lower the heap."),
    dict(job='release_age', when='cron        = 13 * * * *', tiers=['counters', 'jmx'], title="how old a JVM's Java is",
         what="Reports each JVM's Java: its feature release, whether that is a long-term support release, and, "
              "with JMX, how many days since its release (java.version.date): a JVM not patched in months.",
         metrics=M(JVMS, JMX_UP,
                   ('feature_version', 'its feature release: 8, 11, 17, 21, 25...'),
                   ('lts', '1 for a long-term support release (8, 11, 17, 21, 25)'),
                   ('release_age_days', 'days since this Java was released (Java 10 and later, JMX), tagged version=')),
         healthy="release_age_days under about 100: Java updates come every three months.",
         watch="release_age_days over 100: a quarterly update was missed.",
         act="release_age_days over 200; lts 0 on a JVM you keep for years: a non-LTS release gets updates for "
             "six months only."),
    dict(job='security', when='cron        = 8/15 * * * *', tiers=['os', 'jmx'], title="a JVM's dangerous settings",
         what="Reports settings that let others in: a debugger listening (anyone who reaches its port can run code "
              "in the JVM), JMX without a password or without TLS, bytecode verification turned off. From its "
              "startup options, as the process or JMX gives them. Its command line is read, and never printed.",
         metrics=M(JVMS, JMX_UP,
                   ('debug_agent', '1 when a debugger agent is loaded (-agentlib:jdwp)'),
                   ('debug_agent_remote', '1 when it listens beyond this machine'),
                   ('jmx_remote', '1 when it opens a JMX port'),
                   ('jmx_no_password', '1 when that port asks no password'),
                   ('jmx_no_tls', '1 when that port has no TLS'),
                   ('verify_off', '1 when bytecode verification is off'),
                   ('risks', 'how many of the above are 1, jmx_remote aside')),
         healthy="risks 0.",
         watch="debug_agent 1 on a production JVM, even on localhost.",
         act="debug_agent_remote 1: anyone who reaches that port can run code as the JVM's account; jmx_no_password 1 "
             "with jmx_remote 1: the same, through JMX."),
    dict(job='startup', when='cron        = 9/15 * * * *', tiers=['os', 'counters', 'jmx'], title="a JVM's start",
         what="Reports when each JVM started, and, from its counters, how long the JVM took to start: a restart "
              "shows as uptime_seconds falling.",
         metrics=M(JVMS, JMX_UP,
                   ('startup_seconds', 'how long the JVM took to create itself (counters)'),
                   ('init_seconds', 'until the JVM had initialised (counters)'),
                   ('started_epoch_seconds', 'when it started, in seconds since 1970'),
                   ('uptime_seconds', 'since it started')),
         healthy="started_epoch_seconds changing only when you restart it.",
         watch="startup_seconds rising: a slow disk, or a big class-data archive.",
         act="started_epoch_seconds changing several times an hour: it is crash-looping."),

    # -- memory --
    dict(job='heap', when='run_every   = 1m', tiers=['counters', 'jmx'], title="a JVM's heap",
         what="Reports each JVM's heap: used, committed, its maximum, and used against the maximum.",
         metrics=M(JVMS, JMX_UP,
                   ('used_bytes', 'heap in use, live objects and garbage alike'),
                   ('committed_bytes', 'heap the JVM holds from the operating system'),
                   ('max_bytes', 'the most it may use'),
                   ('used_percent', 'used against max')),
         healthy="used_percent rising and falling in a saw-tooth, falling well below half after each collection.",
         watch="the bottom of the saw-tooth rising over hours: live data growing (jvm_pools' after_gc_bytes says it "
               "plainly).",
         act="used_percent above 90 and staying there: the JVM is about to run out of memory."),
    dict(job='pools', when='cron        = 1/2 * * * *', tiers=['counters', 'jmx'], title="a JVM's memory pools",
         what="Reports each memory pool (eden, survivor, old gen, metaspace, code cache...), and with JMX, each pool "
              "as the last collection left it: old gen after a collection is what is really alive, and the surest "
              "sign of a leak.",
         metrics=M(JVMS, JMX_UP,
                   ('used_bytes', 'in use, tagged pool=<its name> and type=<heap or non_heap>'),
                   ('committed_bytes', 'held, tagged the same'),
                   ('max_bytes', 'its maximum, where it has one, tagged the same'),
                   ('after_gc_bytes', 'in use after the last collection (JMX), tagged the same'),
                   ('after_gc_percent', 'that, against max, tagged the same')),
         healthy="Old gen's after_gc_percent steady.",
         watch="Old gen's after_gc_bytes rising after each collection, over hours: a leak.",
         act="Old gen's after_gc_percent above 80: the collector cannot free enough, and will spend ever more time "
             "trying."),
    dict(job='metaspace', when='cron        = 2/5 * * * *', tiers=['counters', 'jmx'], title="a JVM's metaspace",
         what="Reports metaspace, where the JVM keeps class metadata, and compressed class space within it, against "
              "their limits: a classloader leak fills them.",
         metrics=M(JVMS, JMX_UP,
                   ('metaspace_used_bytes', 'metaspace in use'),
                   ('metaspace_committed_bytes', 'held'),
                   ('metaspace_max_bytes', 'its limit, when MaxMetaspaceSize sets one'),
                   ('metaspace_used_percent', 'used against that limit'),
                   ('class_space_used_bytes', 'compressed class space in use'),
                   ('class_space_committed_bytes', 'held'),
                   ('class_space_max_bytes', 'its limit (1 GB by default)'),
                   ('class_space_used_percent', 'used against it')),
         healthy="Steady once the application has started.",
         watch="Rising with each redeploy: the old classes are not freed (jvm_classloaders).",
         act="class_space_used_percent or metaspace_used_percent above 90: OutOfMemoryError: Metaspace is near."),
    dict(job='codecache', when='cron        = 3/5 * * * *', tiers=['counters', 'jmx'], title="a JVM's code cache",
         what="Reports the code cache, where the JIT keeps compiled code, by segment: when it fills, the JIT "
              "stops, and the application slows down for good without a word in its own log.",
         metrics=M(JVMS, JMX_UP,
                   ('used_bytes', 'in use, tagged segment=<non-nmethods, profiled nmethods, non-profiled nmethods, or Code Cache>'),
                   ('max_bytes', 'its size, tagged the same'),
                   ('used_percent', 'used against it, tagged the same'),
                   ('nmethod_code_bytes', 'compiled code, from the counters, without JMX')),
         healthy="used_percent under 80 in every segment.",
         watch="used_percent creeping up over days.",
         act="used_percent above 95: raise -XX:ReservedCodeCacheSize."),
    dict(job='buffers', when='cron        = 4/5 * * * *', tiers=['jmx'], title="a JVM's direct and mapped buffers",
         what="Reports the buffers a JVM keeps outside its heap: direct buffers (network and I/O libraries such as "
              "Netty) and mapped files. They do not show in the heap, and leak where nothing else can see them.",
         metrics=M(JVMS, JMX_UP,
                   ('count', 'buffers, tagged pool=<direct, mapped, mapped_non_volatile_memory>'),
                   ('used_bytes', 'memory they use, tagged the same'),
                   ('capacity_bytes', 'their total capacity, tagged the same')),
         healthy="direct used_bytes steady under load.",
         watch="direct used_bytes rising with no rise in load.",
         act="direct used_bytes near -XX:MaxDirectMemorySize (the heap's maximum, by default): "
             "OutOfMemoryError: Direct buffer memory is near."),
    dict(job='native', when='cron        = 5/15 * * * *', tiers=['jmx'], title="a JVM's native memory",
         what="Reports the JVM's own memory by what it is for (heap, classes, threads, code, GC, symbols...), when "
              "the JVM tracks it: started with -XX:NativeMemoryTracking=summary. Otherwise tracking 0, and nothing more.",
         metrics=M(JVMS, JMX_UP,
                   ('tracking', '1 when the JVM tracks its native memory'),
                   ('reserved_bytes', 'reserved, in all'),
                   ('committed_bytes', 'committed, in all'),
                   ('category_committed_bytes', 'committed, tagged category=<java_heap, class, thread, code, gc, ...>')),
         healthy="Every category steady once started.",
         watch="thread rising: threads are made and not ended; class rising: a classloader leak.",
         act="committed_bytes near the machine's or container's memory: it will be killed."),
    dict(job='native_overhead', when='cron        = 2/5 * * * *', tiers=['os', 'counters', 'jmx'], title="a JVM's memory outside its heap",
         what="Reports how much of a JVM's resident memory is outside its heap: its resident memory, less the heap "
              "it holds. Off-heap buffers, native libraries, threads' stacks, metaspace and the JVM itself are in "
              "it, and a native leak shows here when no Java figure moves.",
         metrics=M(JVMS, JMX_UP,
                   ('rss_bytes', 'resident memory'),
                   ('heap_committed_bytes', 'the heap it holds'),
                   ('outside_heap_bytes', 'resident memory less that heap'),
                   ('outside_heap_percent', 'that, against resident memory')),
         healthy="outside_heap_bytes steady once started.",
         watch="outside_heap_bytes rising over hours with a steady heap.",
         act="outside_heap_bytes rising without end: a native leak (jvm_buffers, jvm_native)."),

    # -- garbage collection --
    dict(job='gc', when='run_every   = 1m', tiers=['counters', 'jmx'], title="a JVM's garbage collection",
         what="Reports each collector's collections and time, and the share of the JVM's life spent collecting.",
         metrics=M(JVMS, JMX_UP,
                   ('collections', 'collections, a running total, tagged collector=<its name>'),
                   ('time_seconds', 'time collecting, a running total, tagged the same'),
                   ('collections_total', 'all collections, a running total'),
                   ('time_seconds_total', 'all time collecting, a running total'),
                   ('time_percent_lifetime', 'time collecting, against the time it has run'),
                   ('last_cause', 'always 1, tagged cause=<why the last collection ran> (counters)')),
         healthy="time_seconds_total's rate under 0.05 (5% of the time).",
         watch="time_seconds_total's rate rising; an old or full collector's collections rising.",
         act="time_seconds_total's rate above 0.2: the JVM spends a fifth of its time collecting; with the heap "
             "near full, it is out of memory in all but name."),
    dict(job='gc_cycles', when='cron        = 1/2 * * * *', tiers=['jmx'], title="a JVM's GC pauses, apart from concurrent work",
         what="Reports a JVM's pauses apart from its collectors' concurrent work. With ZGC, Shenandoah and G1's "
              "concurrent cycles, the time collecting can be seconds of harmless background work: pauses are what "
              "requests feel.",
         metrics=M(JVMS, JMX_UP,
                   ('pauses', 'pauses, a running total'),
                   ('pause_seconds', 'time paused, a running total'),
                   ('pause_avg_ms', 'the average pause'),
                   ('concurrent_cycles', 'concurrent cycles, a running total'),
                   ('concurrent_seconds', 'their time, a running total')),
         healthy="pause_avg_ms small for the collector (ZGC: under 1 ms; G1: tens of ms).",
         watch="pause_seconds' rate rising.",
         act="pause_avg_ms in the hundreds for G1, or above 10 for ZGC: the collector is behind."),
    dict(job='gc_last', when='cron        = 1/2 * * * *', tiers=['jmx'], title="a JVM's last collection",
         what="Reports each collector's last collection: how long it took, how long ago, what it freed and what "
              "it left.",
         metrics=M(JVMS, JMX_UP,
                   ('duration_ms', 'how long it took, tagged collector=<its name>'),
                   ('seconds_ago', 'since it ended, tagged the same'),
                   ('freed_bytes', 'what it freed, tagged the same'),
                   ('after_bytes', 'memory in use after it, tagged the same')),
         healthy="freed_bytes large, after_bytes small.",
         watch="an old collector's freed_bytes small: little to free, much alive.",
         act="duration_ms in seconds; an old collector run seconds_ago a few seconds, again and again."),
    dict(job='gc_cpu', when='cron        = 2/5 * * * *', tiers=['counters', 'jmx'], title="the CPU a JVM's GC uses",
         what="Reports the CPU the garbage collector's own threads have used, against the process's, where the "
              "JVM keeps it (HotSpot 22 and later): a collector quietly eating a core.",
         metrics=M(JVMS, JMX_UP,
                   ('gc_cpu_seconds', "the GC threads' CPU, a running total"),
                   ('process_cpu_seconds', "the process's CPU, a running total"),
                   ('gc_cpu_percent_lifetime', 'the GC threads\' share of it')),
         healthy="gc_cpu_percent_lifetime under 10.",
         watch="gc_cpu_seconds' rate rising.",
         act="gc_cpu_percent_lifetime above 25: the collector takes a quarter of the JVM's CPU."),
    dict(job='allocation', when='cron        = 1/2 * * * *', tiers=['jmx'], title="how fast a JVM allocates",
         what="Reports how fast a JVM allocates memory: over two seconds, every live thread's allocations; and "
              "where the JVM keeps it (Java 21 and later), its running total.",
         metrics=M(JVMS, JMX_UP,
                   ('allocated_bytes', 'allocated since it started, a running total (Java 21 and later)'),
                   ('allocation_bytes_per_second', 'allocated per second, over two seconds')),
         healthy="Steady for steady load.",
         watch="allocation rising with no rise in load: a change made the code allocate more.",
         act="allocation high with young collections every few hundred milliseconds: the collector cannot keep up."),
    dict(job='promotion', when='cron        = 3/5 * * * *', tiers=['counters'], title="what a JVM promotes to old gen",
         what="Reports what moves from young gen to old gen, from the counters the Serial and Parallel collectors "
              "keep: objects promoted too early fill old gen and bring on old collections.",
         metrics=M(JVMS,
                   ('promoted_last_bytes', 'promoted by the last young collection'),
                   ('survived_last_bytes', 'survived it, in the survivor spaces'),
                   ('promoted_avg_bytes', 'promoted, on average'),
                   ('tenuring_threshold', 'collections an object survives before promotion, now'),
                   ('tenuring_threshold_max', 'and at most'),
                   ('survivor_desired_bytes', 'the survivor space wanted'),
                   ('survivor_overflowed', '1 when the last young collection overflowed the survivors')),
         healthy="tenuring_threshold near tenuring_threshold_max; survivor_overflowed 0.",
         watch="tenuring_threshold falling to 1: survivors are too small.",
         act="survivor_overflowed 1, again and again: objects go straight to old gen."),
    dict(job='tlab', when='cron        = 6/15 * * * *', tiers=['counters'], title="a JVM's thread-local allocation",
         what="Reports allocation outside the threads' own buffers, where it is slow: a sign of heavy allocation, "
              "or of big objects.",
         metrics=M(JVMS,
                   ('allocated_words', 'allocated in buffers since the last collection, in words'),
                   ('threads', 'threads that allocated'),
                   ('refills', 'buffers refilled'),
                   ('refills_max', 'the most refills by one thread'),
                   ('slow_allocations', 'allocations outside a buffer'),
                   ('slow_allocations_max', 'the most by one thread'),
                   ('waste_gc_words', 'buffer left unused at a collection, in words'),
                   ('waste_refill_words', 'buffer left unused at a refill, in words')),
         healthy="slow_allocations small against refills.",
         watch="slow_allocations rising.",
         act="slow_allocations as many as refills: allocation is going the slow way."),
    dict(job='gclog', when='cron        = 4/5 * * * *', tiers=['log'], title="a JVM's GC pauses, from its log",
         what="Reports the pauses in the last five minutes of a JVM's GC log: how many, the longest, the 99th "
              "percentile and in all; full collections; allocation stalls (ZGC). By the log's own clock, from its "
              "last 4 MB.",
         metrics=M(JVMS,
                   ('window_seconds', 'the window: 300'),
                   ('pauses', 'pauses in it'),
                   ('pause_max_ms', 'the longest'),
                   ('pause_p99_ms', 'the 99th percentile'),
                   ('pause_total_ms', 'all of them'),
                   ('full_gcs', 'full collections in it'),
                   ('allocation_stalls_in_log', 'ZGC allocation stalls in the log read')),
         healthy="pause_p99_ms small for the collector; full_gcs 0.",
         watch="pause_max_ms rising.",
         act="full_gcs above 0 with G1 or ZGC: they fell back to a full collection; allocation_stalls_in_log rising: "
             "ZGC could not keep up, and threads waited."),
    dict(job='gclog_detail', when='cron        = 10/15 * * * *', tiers=['log'], title="what a JVM's GC log says went wrong",
         what="Reports the last fifteen minutes of a JVM's GC log: pauses by length, and what goes wrong: G1's "
              "humongous allocations (objects of half a region or more), to-space exhaustion, evacuation failure, "
              "promotion failure.",
         metrics=M(JVMS,
                   ('window_seconds', 'the window: 900'),
                   ('pauses', 'pauses in it, tagged length=<under_10ms, 10_to_100ms, 100ms_to_1s, over_1s>'),
                   ('humongous_allocations_in_log', 'collections caused by humongous allocations, in the log read'),
                   ('to_space_exhausted_in_log', 'to-space exhaustion, in the log read'),
                   ('evacuation_failures_in_log', 'evacuation failures, in the log read'),
                   ('promotion_failed_in_log', 'promotion failures, in the log read')),
         healthy="Nothing over_1s; the failures 0.",
         watch="humongous_allocations_in_log rising: big arrays; raise -XX:G1HeapRegionSize, or make them smaller.",
         act="to_space_exhausted_in_log or evacuation_failures_in_log rising: G1 is out of room, and its pauses grow."),

    # -- threads --
    dict(job='threads', when='run_every   = 1m', tiers=['counters', 'jmx'], title="a JVM's threads",
         what="Reports each JVM's threads: live, daemon, the peak, started since it began, and with JMX, how many "
              "are in each state.",
         metrics=M(JVMS, JMX_UP,
                   ('live', 'threads now'),
                   ('daemon', 'of those, daemon threads'),
                   ('peak', 'the most at once'),
                   ('started', 'started since it began, a running total'),
                   ('state', 'threads in a state, tagged state=<runnable, blocked, waiting, timed_waiting, new> (JMX)')),
         healthy="live steady under steady load.",
         watch="live rising without end: a thread leak; blocked rising: contention (jvm_contention).",
         act="live in the thousands and rising: the JVM will run out of memory or of the system's thread limit."),
    dict(job='deadlocks', when='run_every   = 1m', tiers=['jmx'], title="a JVM's deadlocked threads",
         what="Reports threads deadlocked: each waiting for a lock another holds, for ever. A deadlock never ends "
              "by itself. It names each thread, the lock it waits for, and the thread that holds it.",
         metrics=M(JVMS, JMX_UP,
                   ('deadlocked', 'threads deadlocked, on monitors or java.util.concurrent locks'),
                   ('monitor_deadlocked', 'of those, on monitors (synchronized)'),
                   ('thread', 'always 1, for each (the first 20), tagged thread=, waits_on=<the lock, by its class> and held_by=<a thread>')),
         healthy="deadlocked 0.",
         watch="Nothing to watch: a deadlock is an act.",
         act="deadlocked above 0: those threads will never run again; a thread dump, then a restart."),
    dict(job='contention', when='cron        = 12/15 * * * *', tiers=['jmx'], title="a JVM's contended locks",
         what="Reports threads blocked on locks now, and the locks most waited for, by their class, with the thread "
              "that holds each.",
         metrics=M(JVMS, JMX_UP,
                   ('blocked', 'threads blocked on a lock now'),
                   ('waiting', 'threads waiting (for work, a condition, a timeout)'),
                   ('blocked_times_total', 'times threads have blocked, a running total'),
                   ('lock_waiters', 'threads waiting for a lock, tagged lock=<its class> and held_by=<a thread> (the top 10)')),
         healthy="blocked near 0.",
         watch="blocked_times_total's rate rising; one lock always at the top.",
         act="blocked a large share of live: the threads queue for one lock."),
    dict(job='hot_threads', when='cron        = 14/15 * * * *', tiers=['jmx'], title="a JVM's busiest threads",
         what="Reports the threads using the most CPU, over two seconds: what is busy, by name.",
         metrics=M(JVMS, JMX_UP,
                   ('cpu_time_enabled', '0 when the JVM does not measure threads\' CPU (and nothing else is shown)'),
                   ('cpu_percent_total', 'all threads, in percent of one CPU'),
                   ('cpu_percent', 'a thread, tagged thread=<its name> (the top 10, from 0.5%)'),
                   ('busy_threads_shown', 'threads shown')),
         healthy="The threads you expect at the top.",
         watch="GC threads at the top: see jvm_gc.",
         act="one thread near 100 for a long time: a loop that does not end."),
    dict(job='virtual_threads', when='cron        = 1/5 * * * *', tiers=['jmx'], title="a JVM's virtual threads",
         what="Reports the scheduler of virtual threads (Java 21 and later): its carriers, and from Java 24, the "
              "virtual threads mounted on them and queued. Before Java 24, the carriers, by their names.",
         metrics=M(JVMS, JMX_UP,
                   ('scheduler_parallelism', "the scheduler's parallelism (Java 24 and later)"),
                   ('carriers', 'carrier threads'),
                   ('mounted', 'virtual threads running on a carrier (Java 24 and later)'),
                   ('queued', 'virtual threads waiting for one (Java 24 and later)'),
                   ('carriers_runnable', 'carriers runnable now (Java 21 to 23)')),
         healthy="queued near 0.",
         watch="carriers above scheduler_parallelism: carriers were added for threads pinned in blocking calls.",
         act="queued rising: virtual threads wait for carriers; something pins them."),

    # -- the runtime --
    dict(job='classes', when='cron        = 0/5 * * * *', tiers=['counters', 'jmx'], title="a JVM's classes",
         what="Reports classes loaded now, ever loaded, and unloaded.",
         metrics=M(JVMS, JMX_UP,
                   ('loaded', 'classes loaded now'),
                   ('loaded_total', 'ever loaded, a running total'),
                   ('unloaded', 'unloaded, a running total'),
                   ('load_seconds', 'time spent loading classes (counters)')),
         healthy="loaded steady once started.",
         watch="loaded rising with each redeploy, and never falling.",
         act="loaded rising without end: a classloader leak, or code generating classes (jvm_classloaders)."),
    dict(job='classloaders', when='cron        = 3/15 * * * *', tiers=['jmx'], title="a JVM's classloaders",
         what="Reports classloaders, and classes by the type of loader that holds them. A redeploy leak shows here "
              "first: loaders that are never freed.",
         metrics=M(JVMS, JMX_UP,
                   ('loaders', 'classloaders'),
                   ('loaders_of_type', 'loaders of a type, tagged type=<its class> (the top 15)'),
                   ('classes_of_type', 'classes they hold, tagged the same'),
                   ('types_not_shown', 'loader types past the first 15')),
         healthy="loaders steady once started.",
         watch="A web application's loader type counting more than one: an old one was not freed.",
         act="loaders rising with each redeploy: restart, and look for what keeps the old loader."),
    dict(job='jit', when='cron        = 1/5 * * * *', tiers=['counters', 'jmx'], title="a JVM's JIT compiler",
         what="Reports the JIT: its time compiling, compilations, on-stack replacements and compiled code.",
         metrics=M(JVMS, JMX_UP,
                   ('compile_seconds', 'time compiling, a running total'),
                   ('compiles', 'compilations, a running total (counters)'),
                   ('osr_compiles', 'on-stack replacements, a running total (counters)'),
                   ('compiled_code_bytes', 'compiled code (counters)')),
         healthy="compile_seconds' rate near 0 once warm.",
         watch="compile_seconds' rate high long after start: code keeps changing shape.",
         act="compile_seconds' rate rising late in life: see jvm_deopt and jvm_codecache."),
    dict(job='deopt', when='cron        = 7/15 * * * *', tiers=['counters'], title="a JVM's JIT churn",
         what="Reports code the JIT threw away, and gave up on: invalidated compilations and bailouts.",
         metrics=M(JVMS,
                   ('invalidated', 'compiled methods thrown away, a running total'),
                   ('bailouts', 'compilations given up, a running total'),
                   ('compiles', 'compilations, a running total'),
                   ('invalidated_percent', 'invalidated against compiles')),
         healthy="invalidated_percent small.",
         watch="invalidated rising: code compiled on one assumption keeps being redone.",
         act="bailouts rising: methods the JIT cannot compile run slowly for good."),
    dict(job='safepoints', when='cron        = 2/5 * * * *', tiers=['counters'], title="a JVM's safepoints",
         what="Reports safepoints, when every thread stops: the GC's pauses and the JVM's own (code deoptimised, "
              "biased locks revoked, a thread dump). Time stopped here and not in jvm_gc is the JVM's own.",
         metrics=M(JVMS,
                   ('safepoints', 'safepoints, a running total'),
                   ('stopped_seconds', 'time stopped, a running total'),
                   ('sync_seconds', 'time waiting for every thread to stop, a running total'),
                   ('stopped_percent_lifetime', 'time stopped, against the time it has run')),
         healthy="stopped_seconds' rate close to the GC's pause rate.",
         watch="sync_seconds large against stopped_seconds: a thread slow to stop (a long counted loop).",
         act="stopped_percent_lifetime above 5: the JVM spends that much of its time stopped."),
    dict(job='finalization', when='cron        = 11/15 * * * *', tiers=['jmx'], title="a JVM's finalization queue",
         what="Reports objects waiting to be finalized: one finalizer thread runs them, and a slow finalizer lets "
              "them pile up, and the memory they hold.",
         metrics=M(JVMS, JMX_UP,
                   ('pending', 'objects waiting to be finalized')),
         healthy="pending near 0.",
         watch="pending rising.",
         act="pending in the thousands: the finalizer is stuck; the memory will not come back."),

    # -- the machine, as the JVM sees it --
    dict(job='os', when='cron        = 1/2 * * * *', tiers=['jmx'], title="a JVM's machine, as it sees it",
         what="Reports the CPU and memory of the JVM's machine as the JVM sees it: its own CPU and the system's, "
              "the load, memory and swap, and its open files against its limit.",
         metrics=M(JVMS, JMX_UP,
                   ('process_cpu_percent', 'its CPU, in percent of all CPUs'),
                   ('system_cpu_percent', "the machine's (or container's), the same way"),
                   ('process_cpu_seconds', 'its CPU, a running total'),
                   ('load_average', 'the load average (not on Windows)'),
                   ('cpus', 'CPUs it may use'),
                   ('memory_bytes', 'memory it sees'),
                   ('memory_free_bytes', 'of that, free'),
                   ('swap_bytes', 'swap'),
                   ('swap_free_bytes', 'of that, free'),
                   ('open_files', 'its open files (not on Windows)'),
                   ('open_files_max', 'its limit'),
                   ('open_files_percent', 'open against the limit')),
         healthy="process_cpu_percent within what you expect; open_files_percent low.",
         watch="swap_free_bytes falling: the machine is swapping, and GC pauses with it.",
         act="open_files_percent above 90: 'Too many open files' is near."),
    dict(job='io', when='cron        = 3/5 * * * *', tiers=['os'], title="a JVM's I/O and open files",
         what="Reports a JVM's disk reads and writes (Linux and Windows), and on Linux, its open files by kind: "
              "sockets, files and pipes. Linux needs root or the JVM's own account for these.",
         metrics=M(JVMS, JMX_UP,
                   ('read_bytes', 'read from disk, a running total'),
                   ('write_bytes', 'written, a running total'),
                   ('open', 'open, tagged kind=<socket, file, pipe or other> (Linux)')),
         healthy="Steady for steady load.",
         watch="open kind=socket rising: connections not closed.",
         act="open rising without end: a leak of connections or files."),

    # -- trouble --
    dict(job='crashes', when='cron        = 0/5 * * * *', tiers=['os'], title="a JVM's crashes",
         what="Reports crash reports (hs_err_pid*.log), compiler replay files and core dumps, where the JVM writes "
              "them: -XX:ErrorFile's folder, its working folder (Linux), and JVM_DUMP_DIRS. A crash report is the "
              "JVM itself failing: what is in it says why.",
         metrics=M(JVMS, JMX_UP,
                   ('crash_reports_day', 'crash reports written in the last day'),
                   ('crash_reports', 'crash reports there'),
                   ('crash_reports_bytes', 'their size'),
                   ('newest_crash_report_age_seconds', 'since the newest was written'),
                   ('compiler_replays_day', 'compiler replay files in the last day'),
                   ('compiler_replays', 'compiler replay files there'),
                   ('compiler_replays_bytes', 'their size'),
                   ('newest_compiler_replay_age_seconds', 'since the newest'),
                   ('core_dumps_day', 'core dumps in the last day'),
                   ('core_dumps', 'core dumps there'),
                   ('core_dumps_bytes', 'their size'),
                   ('newest_core_dump_age_seconds', 'since the newest')),
         healthy="crash_reports_day 0.",
         watch="core_dumps_bytes large: they fill the disk.",
         act="crash_reports_day above 0: the JVM crashed; read the report, it names the frame that failed."),
    dict(job='oom', when='cron        = 1/5 * * * *', tiers=['os'], title="a JVM's heap dumps",
         what="Reports heap dumps (*.hprof) where the JVM writes them on out-of-memory: -XX:HeapDumpPath, its "
              "working folder (Linux), and JVM_DUMP_DIRS. A new one means the JVM ran out of memory.",
         metrics=M(JVMS, JMX_UP,
                   ('heap_dumps_day', 'heap dumps written in the last day'),
                   ('heap_dumps', 'heap dumps there'),
                   ('heap_dumps_bytes', 'their size'),
                   ('newest_heap_dump_age_seconds', 'since the newest was written')),
         healthy="heap_dumps_day 0.",
         watch="heap_dumps_bytes large: each is as big as the heap, and they fill the disk.",
         act="heap_dumps_day above 0: the JVM ran out of memory; the dump says what filled it."),
    dict(job='jfr', when='cron        = 17 * * * *', tiers=['jmx'], title="a JVM's Flight Recorder",
         what="Reports whether a JVM has Java Flight Recorder, and its recordings: running ones cost a little CPU "
              "and disk, and are there to read when something goes wrong.",
         metrics=M(JVMS, JMX_UP,
                   ('available', '1 when the JVM has Flight Recorder (Java 11 and later, and 8u262)'),
                   ('recordings', 'recordings'),
                   ('recordings_running', 'of those, running')),
         healthy="As you set it up.",
         watch="recordings_running 0 where you meant one to run, for the record when something goes wrong.",
         act="recordings growing without end: recordings started and never stopped."),

    # -- your own --
    dict(job='mbeans', when='cron        = 4/5 * * * *', tiers=['jmx'], title="MBeans of your own",
         what="Reports MBean attributes you name, as numbers: an application's own figures, from any JMX bean. "
              "JVM_MBEANS lists them: <object name>/<attribute>, or <attribute>.<key> for a part of a composite "
              "value; ... An object name may be a pattern (*), for every bean it matches, up to 100. Booleans "
              "are 1 or 0; anything not a number is left out.",
         metrics=M(JVMS, JMX_UP,
                   ('value', 'an attribute, tagged mbean=<its object name> and attribute=<the attribute>')),
         healthy="As your application defines it.",
         watch="As your application defines it.",
         act="As your application defines it."),
]

assert len(JOBS) == 41, len(JOBS)


def wrap(text, width, first='', rest=''):
    return textwrap.wrap(text, width, initial_indent=first, subsequent_indent=rest, break_on_hyphens=False) or [first]


def metrics_doc(metrics):
    w = max(len(n) for n, _ in metrics) + 2
    lines = []
    for n, d in metrics:
        lines += wrap(d, 76, first=('  ' + n).ljust(2 + w), rest=' ' * (2 + w))
    return lines


def examples():
    """Each job's example output: tools/jvm/examples.txt, '== job' then lines."""
    ex, cur = {}, None
    path = os.path.join(src, 'examples.txt')
    if not os.path.exists(path):
        return ex
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if line.startswith('== '):
            cur = line[3:].strip()
            ex[cur] = []
        elif cur and line:
            ex[cur].append(line)
    return ex


EXAMPLES = examples()


def doc(j, ps):
    c = []
    c += wrap(j['what'] + ' ' + READONLY, 76)
    c += ['']
    for t in j['tiers']:
        c += wrap(TIERS[t], 76)
    c += wrap(TARGETS, 76)
    c += ['', 'Metrics:']
    c += metrics_doc(j['metrics'])
    ex = EXAMPLES.get(j['job'])
    if not ex:
        # JVM_GEN_DRAFT=1: scripts to run, before their real output is in.
        if os.environ.get('JVM_GEN_DRAFT') != '1':
            sys.exit('no example output for %s in tools/jvm/examples.txt' % j['job'])
        ex = ['(draft: no example yet)']
    c += ['', 'Example output:']
    c += ['  ' + e for e in ex]
    c += ['', 'Reading the results (starting points: tune them to the JVM):']
    c += wrap(j['healthy'], 76, first='  Healthy  ', rest=' ' * 11)
    c += wrap(j['watch'], 76, first='  Watch    ', rest=' ' * 11)
    c += wrap(j['act'], 76, first='  Act      ', rest=' ' * 11)
    c += ['']
    c += wrap(('Requires: Windows PowerShell 5.1 or PowerShell 7, ' if ps else 'Requires: bash, ') +
              'Java 11 or later (JAVA_HOME, or java on the PATH): a JDK runs _client.java, beside this script; '
              'any other runs _client.jar, built from it, once it matches its digest', 76, rest='  ')
    c += wrap('Exit code: 0 on success, JVMs up or down; 1 if java is missing, _client.jar does not match its '
              'digest, JVM_TARGETS is wrong, or a JVM '
              'refuses the JMX login or its certificate', 76, rest='  ')
    return c


SH_BODY = r'''set -u

# _client.jar's SHA-256, written when the pack was released: built from
# _client.java, beside it, by javac @CLIENT_JAR_JAVAC@ (tools/release/client-jar.sh).
jar_sha256=@CLIENT_JAR_SHA256@

# The client, beside this script, run by Java 11 or later: JAVA_HOME's, else
# the PATH's.
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    java=$JAVA_HOME/bin/java
elif command -v java > /dev/null 2>&1; then
    java=$(command -v java)
else
    echo "@JOB@: java not found: the jvm pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A JDK, with javac beside its java (links followed; on macOS, /usr/bin/java
# runs the JDK java_home names), runs the source. Any other Java runs the
# jar, once it matches the digest above.
bin=$java
n=0
while [ -L "$bin" ] && [ "$n" -lt 20 ]; do
    l=$(readlink "$bin")
    case $l in /*) bin=$l ;; *) bin=$(dirname "$bin")/$l ;; esac
    n=$((n + 1))
done
bin=$(dirname "$bin")
if [ "$bin" = /usr/bin ] && [ -x /usr/libexec/java_home ]; then
    bin=$(/usr/libexec/java_home 2> /dev/null)/bin
fi
if [ -x "$bin/javac" ]; then
    set -- "$here/_client.java"
elif [ ! -f "$here/_client.jar" ]; then
    echo "@JOB@: $java is not a JDK, and this pack has no _client.jar to run instead: install the pack from a packs release (vigil pack install jvm), or use a JDK 11 or later" >&2
    exit 1
else
    if command -v sha256sum > /dev/null 2>&1; then
        sum=$(sha256sum < "$here/_client.jar")
    elif command -v shasum > /dev/null 2>&1; then
        sum=$(shasum -a 256 < "$here/_client.jar")
    else
        sum=$(openssl dgst -sha256 -r < "$here/_client.jar")
    fi
    if [ "${sum%% *}" != "$jar_sha256" ]; then
        echo "@JOB@: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify jvm says what differs" >&2
        exit 1
    fi
    set -- -cp "$here/_client.jar" JvmClient
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-jvm.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (it would
# find itself among the JVMs it watches).
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" "$@" @JOB@
exit $?
'''

PS_BODY = r'''$ErrorActionPreference = 'Stop'
$job = '@JOB@'

# _client.jar's SHA-256, written when the pack was released: built from
# _client.java, beside it, by javac @CLIENT_JAR_JAVAC@ (tools/release/client-jar.sh).
$jarSha256 = '@CLIENT_JAR_SHA256@'

# The client, beside this script, run by Java 11 or later: JAVA_HOME's, else
# the PATH's.
$java = $null
if ($env:JAVA_HOME -and [System.IO.File]::Exists((Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
    $java = Join-Path $env:JAVA_HOME 'bin\java.exe'
}
else {
    $c = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($c) { $java = $c.Source }
}
if (-not $java) {
    [Console]::Error.WriteLine("${job}: java not found: the jvm pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME")
    exit 1
}

# A JDK, with javac.exe beside its java.exe, runs the source. Any other Java
# runs the jar, once it matches the digest above.
$jar = Join-Path $PSScriptRoot '_client.jar'
if ([System.IO.File]::Exists((Join-Path (Split-Path -Parent $java) 'javac.exe'))) {
    $client = @((Join-Path $PSScriptRoot '_client.java'))
}
elseif (-not [System.IO.File]::Exists($jar)) {
    [Console]::Error.WriteLine("${job}: $java is not a JDK, and this pack has no _client.jar to run instead: install the pack from a packs release (vigil pack install jvm), or use a JDK 11 or later")
    exit 1
}
else {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $f = [System.IO.File]::OpenRead($jar)
    try { $sum = -join ($sha.ComputeHash($f) | ForEach-Object { $_.ToString('x2') }) }
    finally { $f.Dispose(); $sha.Dispose() }
    if ($sum -ne $jarSha256) {
        [Console]::Error.WriteLine("${job}: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify jvm says what differs")
        exit 1
    }
    $client = @('-cp', $jar, 'JvmClient')
}

# A folder of this run's own, for the process table and what Java writes
# while it runs: gone when the run ends.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-jvm.' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$code = 1
try {
    # The JVMs on this machine, as Windows lists them, for the client: one a
    # line, tab-separated. Another account's command line needs an
    # administrator (Vigil's service is one).
    $rows = New-Object System.Collections.Generic.List[string]
    $epoch = [datetime]'1970-01-01'
    $cim = $true
    try { $procs = @(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction Stop) }
    catch { $cim = $false; $procs = @() }
    foreach ($p in $procs) {
        $cmd = [string]$p.CommandLine
        if (-not $cmd) { $cmd = [string]$p.ExecutablePath }
        $cmd = $cmd -replace '[\t\r\n]', ' '
        $start = ''
        if ($p.CreationDate) { $start = [string][long](($p.CreationDate.ToUniversalTime() - $epoch).TotalSeconds) }
        $rows.Add((@($p.ProcessId, '', $cmd, $p.WorkingSetSize, $p.VirtualSize, $p.ThreadCount, $p.HandleCount,
                    ([long]$p.KernelModeTime + [long]$p.UserModeTime), $start, $p.ReadTransferCount, $p.WriteTransferCount) -join "`t"))
    }
    # An account CIM refuses (one logged on over the network, not an
    # administrator): the processes without their command lines, which the
    # client reads from each JVM's counters instead.
    if (-not $cim) {
        foreach ($p in @(Get-Process -Name java, javaw -ErrorAction SilentlyContinue)) {
            $cpu = ''; $start = ''
            try { if ($null -ne $p.TotalProcessorTime) { $cpu = [string]$p.TotalProcessorTime.Ticks } } catch { }
            try { if ($null -ne $p.StartTime) { $start = [string][long](($p.StartTime.ToUniversalTime() - $epoch).TotalSeconds) } } catch { }
            $rows.Add((@($p.Id, '', '', $p.WorkingSet64, $p.VirtualMemorySize64, $p.Threads.Count, $p.HandleCount, $cpu, $start, '', '') -join "`t"))
        }
    }
    $table = Join-Path $work 'procs.tsv'
    [System.IO.File]::WriteAllLines($table, $rows, (New-Object System.Text.UTF8Encoding $false))
    $env:JVM_PROCS_FILE = $table

    # A small JVM, quick to start, that keeps no counters of its own (it
    # would find itself among the JVMs it watches).
    & $java -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m "-Djava.io.tmpdir=$work" @client $job
    $code = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
'''


def sh_script(j):
    head = ['#!/usr/bin/env bash', '#', '# %s.sh - %s' % (j['job'], j['title']), '#']
    head += [('# ' + n).rstrip() for n in NOTICE] + ['#']
    head += [('# ' + l).rstrip() for l in doc(j, False)]
    return '\n'.join(head) + '\n\n' + SH_BODY.replace('@JOB@', 'jvm_' + j['job'])


def ps_script(j):
    head = ['#Requires -Version 5.1', '', '<#', '.SYNOPSIS', '    %s.ps1 - %s, on Windows' % (j['job'], j['title']), '.NOTES']
    head += [('    ' + n).rstrip() for n in NOTICE]
    head += ['.DESCRIPTION']
    head += [('    ' + l).rstrip() for l in doc(j, True)]
    head += ['#>']
    return '\n'.join(head) + '\n\n' + PS_BODY.replace('@JOB@', 'jvm_' + j['job'])


def pack_config():
    p = ['# jvm - Java virtual machines, any Java application through the JVM it runs',
         '# on: its process, memory (heap, pools, metaspace, code cache, buffers,',
         '# native), garbage collection, threads (deadlocks too), JIT, classes,',
         '# safepoints, crashes, heap dumps, settings and security. Linux, macOS and',
         '# Windows. See SPECIFICATION.md section 18.10 for this format.',
         '#',
         '# Three tiers, each used where it reaches: the process (nothing to set',
         '# up); the JVM\'s own counters (this machine, and root, an administrator',
         '# or the JVM\'s own account); JMX, at an address given in JVM_TARGETS.',
         '# Every script runs the client beside it with Java 11 or later: a JDK',
         '# runs _client.java, any other Java _client.jar, compiled from it when the',
         '# pack was released, once it matches its digest. From source a run takes',
         '# two or three seconds (Java compiles it each run), so the jobs every',
         '# minute are the cheap ones, and the rest run every 2, 5 or 15 minutes,',
         '# or each hour, each on minutes of its own (cron, local time).',
         '#',
         '# Off until enabled: vigil pack enable jvm. With JVM_TARGETS empty, every',
         '# JVM on this machine is watched, named by its main class. To name them,',
         '# or reach one over JMX, set JVM_TARGETS on the jobs\' env lines:',
         '#   env = JVM_TARGETS=shop: main=com.acme.Shop, jmx=localhost:9010',
         '# For JMX with a password, add to each job (packs/README.md has it all):',
         '#   secret = JVM_JMX_PASSWORD=secret:JVM_JMX_PASSWORD',
         '# and: vigil secret set JVM_JMX_PASSWORD',
         '#']
    p += [('# ' + n).rstrip() for n in NOTICE]
    p += ['',
          '[pack]',
          'version     = 1.1.0',
          '# vigil: the oldest Vigil this pack runs on. vigil pack update refuses the',
          '# pack on an older one.',
          'vigil       = 0.3.0',
          'description = Java virtual machines: process, heap and pools, metaspace, code cache, buffers, native memory, GC, threads and deadlocks, JIT, classes, safepoints, crashes, heap dumps, settings, security',
          '# What vigil pack info shows besides: the JVMs it is meant for, the',
          '# programs its scripts need on each platform, and where it is explained.',
          'works_with  = Java 8 and later (HotSpot for the counters: OpenJDK, Oracle, Temurin, Corretto, Zulu...); any Java application',
          'programs_linux = Java 11 or later, a JDK or a JRE, to run its client',
          'programs_macos = Java 11 or later, a JDK or a JRE, to run its client',
          'programs_windows = Java 11 or later, a JDK or a JRE, to run its client',
          'docs        = https://github.com/godspeedhq/vigil/blob/main/packs/README.md#jvm',
          'needs       = for the JVM\'s own counters (heap, GC, threads without JMX): Vigil running as root or an administrator, or as the JVM\'s own account',
          'needs       = for everything else: each JVM\'s JMX address in JVM_TARGETS (jmx=host:port), with -Dcom.sun.management.jmxremote.port and a password and TLS (packs/README.md shows how)',
          'needs       = for JMX with a password: a secret line on the jobs: secret = JVM_JMX_PASSWORD=secret:JVM_JMX_PASSWORD, then vigil secret set JVM_JMX_PASSWORD',
          '']
    for j in JOBS:
        names = [n for n, _ in j['metrics']]
        p += ['[job.%s]' % j['job'],
              'metric_name = jvm.%s' % j['job'],
              'metrics     = %s' % ', '.join(names),
              j['when'],
              'max_runtime = %s' % ('2m' if j['job'] in ('discovery', 'hot_threads', 'allocation', 'classloaders') else '90s'),
              'env         = JVM_TARGETS=',
              'env         = JVM_JMX_USER=',
              'env         = JVM_CACERT=']
        if j['job'] == 'mbeans':
            p += ['env         = JVM_MBEANS=java.lang:type=Threading/ThreadCount; java.lang:type=Memory/HeapMemoryUsage.used']
        if j['job'] in ('crashes', 'oom'):
            p += ['env         = JVM_DUMP_DIRS=']
        p += ['']
    return '\n'.join(p).rstrip('\n') + '\n'


client = open(os.path.join(src, '_client.java'), encoding='utf-8').read()
for d in ('linux', 'macos', 'windows'):
    os.makedirs(os.path.join(out, d), exist_ok=True)
    open(os.path.join(out, d, '_client.java'), 'w', encoding='utf-8', newline='\n').write(client)
open(os.path.join(out, 'pack.config'), 'w', encoding='utf-8', newline='\n').write(pack_config())
for j in JOBS:
    s = sh_script(j)
    for d in ('linux', 'macos'):
        open(os.path.join(out, d, j['job'] + '.sh'), 'w', encoding='utf-8', newline='\n').write(s)
    open(os.path.join(out, 'windows', j['job'] + '.ps1'), 'w', encoding='utf-8', newline='\n').write(ps_script(j))
print('wrote', len(JOBS), 'jobs')
