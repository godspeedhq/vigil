# The kafka pack 2.0: design

Decided 2026-11-22. The kafka pack, redone from first principles: one client of our own instead of Kafka's command-line tools, JMX with a password and TLS, every Kafka version we can reach, and nothing the jvm pack already reports. Breaking changes are accepted: this is 2.0.

## Why a 2.0

The 1.0 pack works, and its limits come from how it was built:

- **Kafka's command-line tools, one JVM each.** A job runs one or more of `kafka-topics`, `kafka-consumer-groups`, `kafka-log-dirs`...: each starts Java with all of Kafka's libraries, about 4 seconds on Linux and 10 or more on Windows. A cycle of 19 jobs starts dozens of JVMs.
- **Text made for people.** The jobs parse what the tools print, and the tools change what they print between versions.
- **JMX without a password.** The JMX jobs run Kafka's `JmxTool`, which takes a password only on its command line, so the pack requires JMX with no password at all.
- **The broker's JVM, reported twice.** `kafka_jvm` reports heap, garbage collection, threads, CPU and open files: the jvm pack's job, and now done better there.

## The rule: Kafka's, and nothing below it

Every metric has one owner. **Would it exist for any Java program?** Then it is the jvm pack's: heap, GC, threads, CPU, open files, uptime, the JIT, deadlocks; in JMX, anything under `java.lang:*`, `java.nio:*` or `com.sun.management:*`. Otherwise it is this pack's: anything Kafka's admin API says, and anything under Kafka's own JMX domains (`kafka.server`, `kafka.controller`, `kafka.network`, `kafka.log`, `kafka.cluster`...).

So `kafka_jvm` goes. Its JVM half is the jvm pack's. Its Kafka half (log flush time, the log cleaner) moves into `kafka_logdirs`, "Kafka's data on disk"; its offline log directories were already there, from the admin API.

**Advised, never required.** The pack installs and works without the jvm pack. It says where the JVM is, in the same words everywhere:

- a `needs` line in `pack.config`, which `vigil pack info`, `install` and `enable` print:
  `needs for the brokers' JVMs (heap, garbage collection, threads, CPU, open files): the jvm pack, not this one: vigil pack install jvm, with each broker in JVM_TARGETS named as Kafka names it (kafka-1: jmxs=host:port)`;
- its section in `packs/README.md` ("What this pack does not report"), with the naming convention, so a broker's Kafka metrics and its JVM's line up on one dashboard;
- the header of each JMX job's script;
- the 2.0 release notes: "Where did `kafka_jvm` go?".

Two things that look like duplicates and are not: "is it up" asked of the service (does Kafka answer?) and of the process (is the JVM running?) are different questions, since a JVM can run while Kafka does not answer. And a Kafka-specific reading of a JVM figure (open files near the limit kills a broker) is said in the kafka pack's docs, pointing at `jvm_process open_files`, never reported again.

## One client, ours

Like the jvm pack: one Java source file, `_client.java`, and the release compiles it into `_client.jar` (`tools/release/client-jar.sh`):

- **Ours only.** The jar holds the classes we write, and nothing of Kafka's or anyone's. No third-party jar is ever shipped.
- **Built by the release**, never committed; Java 11 bytecode; the same bytes from the same source and `javac`; its SHA-256 and `javac` written into every script; checked before every run; covered by `vigil pack verify` and `vigil doctor`. A copy of the pack from the repository, with no jar, runs the source on a JDK.
- **One JVM a run.** A job starts Java once: the admin API for the cluster's view, JMX for each broker's own figures, then it prints its lines and ends.
- **Structured answers.** Kafka's admin API returns objects, not text.

**Kafka's library is the user's.** The admin API needs `kafka-clients` and what it uses (lz4, snappy, zstd, slf4j). The person installing the pack supplies them and says where:

- `KAFKA_HOME`: a Kafka download; its `libs/` has them all;
- or `KAFKA_LIBS`: a folder of just those jars.

A script runs `java -cp <_client.jar><sep><libs>/* KafkaClient <job>`. No `kafka-clients-*.jar` there is a clear error naming the setting, never a Java stack trace. The README advises the newest Kafka download, whatever the cluster runs.

**Compiled against Kafka's API, never shipping it.** The release downloads the `kafka-clients` jar the client is compiled against from Maven Central, checks it against a SHA-256 pinned in the repository (`tools/kafka/client.lib`), and compiles with it on the class path: like compiling against the JDK. That jar never enters the archive. `client-jar.sh` gains this: a pack may name the libraries its client compiles against.

## Versions

**The library: any `kafka-clients` from 3.x or 4.x.** The client is compiled against 3.9 and uses only what every accepted library has; what came later (Kafka 4's group listing, newer options) is looked up while it runs, and skipped when the library lacks it. What 4.0 removed is never called. A test build also compiles the client against the newest 4.x, so a method 4.x removed fails the build, not a user's run.

**The cluster: whatever the library reaches.** Clients and brokers agree a protocol version on every connection, so a recent library speaks to older brokers. Kafka 4.0's library reaches brokers from 2.1 on (to confirm in testing); for older ones, a 3.x library. What a broker cannot do (the KRaft quorum on ZooKeeper, describing transactions before 3.0, the new group protocol before 3.7), the job reports as not available, in its log, and the run succeeds: as the jvm pack treats a JVM without a counter.

**Tested, so claimed:**

| Cluster | Library 3.9 | Library 4.x |
| --- | --- | --- |
| Kafka 2.8, ZooKeeper | yes | yes |
| Kafka 3.9, ZooKeeper | yes | yes |
| Kafka 3.9, KRaft | yes | yes |
| Kafka 4.x (newest), KRaft | yes | yes |

Anything else from 2.1 to 4.x "should work", and the README says it is untested.

**Java:** 11 or later on the machine that watches, a JDK or a JRE (Kafka 4's library needs 11; 1.0 needed 17 for Kafka's tools).

## Settings

On the jobs' `env` lines, as in 1.0 where they mean the same:

| Setting | What |
| --- | --- |
| `KAFKA_BOOTSTRAP` | brokers, `host:port`, comma-separated |
| `KAFKA_SECURITY` | `PLAINTEXT`, `SSL`, `SASL_PLAINTEXT` or `SASL_SSL` |
| `KAFKA_SASL_MECHANISM` | `SCRAM-SHA-512`, `SCRAM-SHA-256` or `PLAIN` |
| `KAFKA_USER`, secret `KAFKA_PASSWORD` | the describe-only user, its password from `vigil secret set KAFKA_MONITOR_PASSWORD` |
| `KAFKA_CACERT` | a PEM file of CAs, for the brokers' TLS and JMX's |
| `KAFKA_CLIENT_CONFIG` | a client properties file of your own, for Kerberos or OAuth |
| `KAFKA_HOME` or `KAFKA_LIBS` | where Kafka's library is |
| `KAFKA_JMX` | the brokers' JMX: `jmx=host:port` or `jmxs=host:port` (TLS), `;`-separated, as `JVM_TARGETS` writes them; a bare `host:port` is `jmx=` |
| `KAFKA_JMX_USER`, secret `KAFKA_JMX_PASSWORD` | JMX's login |
| `KAFKA_TXN_LONG` | seconds after which an open transaction is long-running |

The password never touches a file: the client builds its configuration in memory, the CAs inline (`ssl.truststore.type=PEM`). Certificates are always checked, against `KAFKA_CACERT` or Java's own CAs, and against the broker's name. No setting trusts a certificate unchecked.

## The jobs

Worked out again from what someone running Kafka asks, not from what the tools printed. They come out close to 1.0's, less `kafka_jvm`: 18. Metric names stay as 1.0 had them unless a name was wrong, so dashboards carry over.

| Question | Job | Every | From |
| --- | --- | --- | --- |
| Is the cluster up, and in control? | `kafka_status` | 1m | admin |
| | `kafka_quorum` (KRaft) | 2m | admin |
| | `kafka_controller` | 2m | JMX |
| Is the data safe? | `kafka_replication` | 1m | admin |
| | `kafka_brokers` | 5m | admin |
| Are consumers keeping up? | `kafka_consumers` | 1m | admin |
| | `kafka_groups` | 5m | admin |
| Is it fast, or saturated? | `kafka_throughput` | 2m | JMX |
| | `kafka_requests` | 2m | JMX |
| | `kafka_connections` | 5m | JMX |
| Is the disk all right? | `kafka_logdirs` (with flush and the cleaner, from JMX) | 5m | admin, JMX |
| | `kafka_topics` | 5m | admin |
| What is stuck? | `kafka_reassignment` | 5m | admin |
| | `kafka_transactions` | 5m | admin |
| What is risky? | `kafka_config` | 15m | admin |
| | `kafka_security` | 15m | admin |
| | `kafka_features` | 15m | admin |
| | `kafka_tls` | 1h | TLS handshake |

The JMX jobs are tables run by the shared JMX engine (`tools/jmx/DESIGN.md`): an MBean pattern, its attributes, the metric names, the tags. A row whose MBean a broker does not have (ZooKeeper's metrics on Kafka 4, KRaft's on ZooKeeper) is simply not reported. Each broker is named by its id, read from its own MBeans, and each JMX metric also carries `jmx=<host:port>`.

## Rules every job keeps

- **Describe, never more.** The user may only describe; nothing is written, no message is read, no offset committed.
- **Down is a reading.** A cluster that does not answer reports `up 0`; a broker whose JMX does not answer, `jmx_up 0`. A login refused, or a certificate that cannot be trusted, fails the run and says why.
- **Bounded.** Every call has a timeout; lists (topics, groups) are capped, with `_not_shown` counts.
- **No secret anywhere it can leak:** not in a file, not on a command line, not in a log.

## From 1.0 to 2.0

- `kafka_jvm` is dropped. Where a job still runs it, `vigil pack update` keeps its script and says so (`dropped from the pack, still running: kafka_jvm`), so nothing goes silent; it stops when the job is disabled.
- The JMX jobs now take a password and TLS; `KAFKA_JMX` keeps accepting `host:port`.
- Kafka's command-line tools are no longer run; `KAFKA_HOME` still names the Kafka download, now for its library.
- Java 11 or later, JDK or JRE, where 1.0 needed 17.

## Testing

On the Fedora test machine, in Docker, as for 1.0 and the jvm pack: the four clusters above, each with SASL_SSL, SCRAM and a certificate from a test CA, JMX with a password and TLS, and the same troubles on purpose (a group behind, a partition move held back, a transaction held open, a broker stopped). Each cluster with both libraries. Then macOS, Windows 11 (PowerShell 5.1 and 7) and Windows Server 2025 through SSH tunnels; and every job on a JRE from the jar. Evidence in `tests/integration/backends/reports/runs/<date>/`, and a tested-on paragraph in `packs/README.md`.

## Order of work

1. The shared JMX engine, `tools/jmx/` (its own design).
2. `client-jar.sh`: libraries a client compiles against, pinned by SHA-256.
3. The kafka client: settings, connection and the admin jobs.
4. The JMX jobs, as tables.
5. The generator, scripts and `pack.config`; the README section.
6. The test clusters (2.8 and 3.9 on ZooKeeper, 3.9 and 4.x in KRaft mode), then the tests on every platform.
