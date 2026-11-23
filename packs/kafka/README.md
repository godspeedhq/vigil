# The kafka pack

An Apache Kafka cluster, from 2.8 to 4.x, in KRaft mode or on ZooKeeper, on this machine or any it can reach. Through Kafka's admin API, the pack asks the cluster what any Kafka admin would, as a user that may only describe; through each broker's JMX, with a password and TLS, it reads the broker's own figures. It reports Kafka's, never the broker's JVM: heap, garbage collection, threads, CPU and open files are the [jvm pack](../jvm/README.md)'s. Linux, macOS and Windows. Its design: [`tools/kafka/DESIGN.md`](../../tools/kafka/DESIGN.md).

**Two jars, both ours, and your Kafka library.** The pack runs Java, 11 or later, a JDK or a JRE:

- `_probe.jar`, the generic probe ([`tools/probe/DESIGN.md`](../../tools/probe/DESIGN.md)), the same file every application pack carries, runs the four jobs that only read the brokers' JMX, from the pack's `_probe.tables`. They need no Kafka library.
- `_client.jar`, the pack's own, asks the admin API for the other fourteen. It needs Kafka's library, which is yours, not the pack's: `KAFKA_HOME`, a Kafka download (its `libs/`), or `KAFKA_LIBS`, a folder of its jars. Any `kafka-clients` from 3.x or 4.x; the newest Kafka download is best, whatever the cluster runs, since a newer library speaks to older brokers.
- Both are built when the pack is released, from the sources beside them (`_probe.java`, `_client.java`), the same bytes from the same source and `javac`, and each script checks the jars it runs against the SHA-256 it carries before running them, as the [jvm pack](../jvm/README.md) does. A copy of the pack straight from the repository has no jars, and its scripts say so.

1. Create the user once, as an administrator. With SCRAM:

   ```sh
   kafka-configs --bootstrap-server <broker> --alter --entity-type users --entity-name vigil_monitor \
     --add-config 'SCRAM-SHA-512=[password=...]'
   ```

   and give it only what it needs to describe the cluster, its topics, groups and transactions:

   ```sh
   kafka-acls --bootstrap-server <broker> --add --allow-principal User:vigil_monitor \
     --operation Describe --operation DescribeConfigs --cluster --topic '*'
   kafka-acls --bootstrap-server <broker> --add --allow-principal User:vigil_monitor \
     --operation Describe --group '*' --transactional-id '*'
   ```

   Not `Read`: that would let it read messages. Kafka hides from a user the topics it may not describe, so a user without these sees no topics at all, and the jobs say so in their log. Without an authorizer (no ACLs), any login will do.
2. Give Vigil its password: `vigil secret set KAFKA_MONITOR_PASSWORD`, as the account Vigil runs as. The client builds its configuration in memory: the password is never in a file or on a command line.
3. `vigil pack enable kafka`. The jobs connect to `localhost:9092` over `SASL_SSL` with SCRAM-SHA-512, as `vigil_monitor`. For anything else, edit their `env` lines in `vigil.config`: `KAFKA_BOOTSTRAP` (host:port, comma-separated), `KAFKA_SECURITY` (`PLAINTEXT`, `SSL`, `SASL_PLAINTEXT` or `SASL_SSL`), `KAFKA_SASL_MECHANISM` (`SCRAM-SHA-512`, `SCRAM-SHA-256` or `PLAIN`), `KAFKA_USER`, `KAFKA_CACERT` (a PEM file of the CAs that signed the brokers' certificates), `KAFKA_CERT` and `KAFKA_KEY` (a client certificate and its PKCS#8 key, for brokers that ask for one), `KAFKA_HOME` or `KAFKA_LIBS`. For Kerberos or OAuth, `KAFKA_CLIENT_CONFIG` names a client properties file of your own, whose settings come first.
4. For the brokers' own figures (`kafka_throughput`, `kafka_requests`, `kafka_controller`, `kafka_connections`, and the flushes and log cleaner of `kafka_logdirs`), give each broker's JMX in their `KAFKA_JMX` line: `jmxs=host:port` over TLS, `jmx=host:port` without, separated by `;`. With a JMX user (`KAFKA_JMX_USER`) and its password, add a secret line to those jobs, under their `env` lines, and give Vigil the password:

   ```ini
   secret = KAFKA_JMX_PASSWORD=secret:KAFKA_JMX_PASSWORD
   ```

   ```sh
   vigil secret set KAFKA_JMX_PASSWORD
   ```

   On the brokers, a JMX user that may only read is enough (`monitor readonly` in the access file): the jobs read attributes and run nothing. Kafka's start scripts take the JMX options from `KAFKA_JMX_OPTS` and the port from `JMX_PORT`, as the [jvm pack](../jvm/README.md) shows for any JVM: a password file, an access file, and TLS with `com.sun.management.jmxremote.ssl=true` and `registry.ssl=true`.

**The brokers' JVMs: the jvm pack.** Heap, garbage collection, threads, CPU and open files against the limit are any JVM's, and the [jvm pack](../jvm/README.md) reports them, so this one does not. Install it beside this one, and name each broker in `JVM_TARGETS` as Kafka names it, so a broker's Kafka metrics and its JVM's line up on one dashboard:

```ini
env = JVM_TARGETS=kafka-1: jmxs=broker1:9999; kafka-2: jmxs=broker2:9999; kafka-3: jmxs=broker3:9999
```

Open files near the limit stop a broker taking connections and writing segments: watch `jvm_process` `open_files` against `open_files_max` for each.

**The certificate is always checked**, against `KAFKA_CACERT` or Java's own CAs, and against the broker's name: connect by the name on its certificate. There is no setting that trusts a certificate unchecked. `kafka_tls` reads each broker's certificate whether it is trusted or not, to say how long it has, and reports `trusted 0` for one that is not.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | Java 11 or later, a JDK or a JRE (`JAVA_HOME` or `java` on the PATH); for all but the four JMX jobs, Kafka's library (`KAFKA_HOME` or `KAFKA_LIBS`) | The same | The same |
| The cluster | Apache Kafka 2.8 to 4.x, KRaft or ZooKeeper | | |
| A user | `vigil_monitor`, with the ACLs step 1 grants | | |
| A secret | `KAFKA_MONITOR_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 2) | | |
| For the JMX jobs | Each broker's JMX in `KAFKA_JMX`, and with a password, `KAFKA_JMX_PASSWORD` (step 4) | | |

## Its jobs

| Job | Every | From | Reports |
| --- | --- | --- | --- |
| `kafka_status` | 1m | admin | Up, the cluster's id, KRaft or ZooKeeper, brokers and brokers fenced, the active controller |
| `kafka_replication` | 1m | admin | Partitions under-replicated, offline, under and at `min.insync.replicas`, not led by their preferred leader, with eligible leader replicas, being moved; by name, the topics with such partitions |
| `kafka_consumers` | 1m | admin | Each consumer group's lag on each topic, and its worst partition; partitions with no committed offset; each group's total |
| `kafka_quorum` | 2m | admin | KRaft's controller quorum: its leader and epoch, high watermark, voters and observers, and for each node how far behind it is and how long since it last fetched and caught up |
| `kafka_brokers` | 5m | admin | Each broker: listed or down, fenced, its rack, partitions it leads, replicas, replicas out of sync, partitions that prefer it as leader |
| `kafka_reassignment` | 5m | admin | Partition moves in progress: partitions, replicas being added and removed, each topic's |
| `kafka_groups` | 5m | admin | Every group by type (classic, consumer, share, streams) and state, each group's members, groups rebalancing, empty or dead |
| `kafka_topics` | 5m | admin | Topics, internal, with a single replica, compacted; each topic's partitions, replication factor, messages ever written (a running total) and messages it still holds |
| `kafka_logdirs` | 5m | admin, JMX | Each broker's log directories: size, partitions, offline, replicas being moved in; each broker's and topic's size on disk; with JMX, tiered storage, flush times and the log cleaner |
| `kafka_transactions` | 5m | admin | Transactions by state, those ongoing, those open longer than `KAFKA_TXN_LONG` (default 300 seconds): counts only |
| `kafka_config` | 15m | admin | Settings at risk: unclean leader election, topics created on demand, `min.insync.replicas`, replication factors (default, offsets, transactions), retention, listeners without TLS or a login, settings that differ between brokers, topics at risk |
| `kafka_security` | 15m | admin | ACLs by resource and permission, ACLs for every principal or every operation, users with SCRAM credentials, quotas: counts only |
| `kafka_features` | 15m | admin | The finalized features (`metadata.version` by name, when Kafka's server library is in `KAFKA_HOME`) against what the brokers support: an upgrade not finalized |
| `kafka_tls` | 1h | TLS | Each broker's certificate: days until it expires, trusted and naming the broker |
| `kafka_throughput` | 2m | JMX | Each broker's messages and bytes in and out, replication, produce and fetch requests and those that failed, bytes rejected, conversions, invalid records |
| `kafka_requests` | 2m | JMX | Produce, consumer fetch and follower fetch time (99th percentile), queue and remote time, requests served; request and response queues, purgatory; how idle the request handler and network threads are |
| `kafka_controller` | 2m | JMX | The active controller, and from it brokers, topics, partitions, offline partitions, leaders not where they prefer, metadata errors and lag, heartbeats timed out, leader elections (unclean ones too), its event queue |
| `kafka_connections` | 5m | JMX | Each broker's connections per listener, and logins that succeeded and failed |

Each script's header says what its metrics mean and how to read them. Worth knowing:

- **One JVM a run.** A job starts Java once, asks what it needs, and ends: no command-line tools, no text to parse.
- **What the library or the cluster does not have is left out, never a failure.** The KRaft quorum on ZooKeeper, transactions before 3.0, share and Streams groups before Kafka 4's library: the job says so in its log and prints the rest.
- The `_count` metrics are running totals: graph them as rates. `messages_count` is every message ever written to a topic, so its rate is the topic's write rate.
- Lists are capped (150 brokers, 150 group and topic pairs, 150 groups, 100 topics) so a big cluster stays under the 1000 lines Vigil takes from a run; the `_not_shown` metrics count the rest.
- `kraft.version` shows as behind on a cluster whose controllers are a fixed list (`controller.quorum.voters`): such a quorum cannot move to version 1, by design.

A cluster that cannot be reached reports `kafka.up` 0, and the run succeeds: that is a reading. The other jobs then print nothing and succeed. A refused login, a certificate that cannot be trusted, or a jar that does not match its digest fails the run, and its log says why; so does a JMX login refused, or a JMX certificate not trusted, for the jobs that read JMX.

## What to alert on

Starting points, not rules: Vigil runs the jobs and delivers what they print, and the alerts are yours, in the backend you already use. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Give most alerts a few minutes, since a rolling restart fences a broker and leaves partitions under-replicated for a moment, and that is healthy. The last column is what the test cluster showed, in [the 4.4.0 run's console output](../../tests/integration/backends/reports/runs/2026-11-22/fedora/pack-kafka-4.4.0/console.txt): most of it caused on purpose, and where we caused nothing, it says so. Everything not here (topics, partitions, sizes, traffic) is for dashboards.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `kafka.up` | 1 | | 0: the cluster does not answer | 0, with the job pointed at a port where nothing listens |
| `kafka.replication.offline` | 0 | | Any: no one can read or write those partitions | 1 with broker 3 stopped: a partition of `audit`, whose only replica was there |
| `kafka.replication.under_min_isr` | 0 | | Any: producers with `acks=all` are refused | 4 on the busy cluster (`audit` has one replica where two must be in sync), 7 with broker 3 stopped |
| `kafka.replication.at_min_isr` | 0 | Any: one more replica lost and writes fail | | 165 with broker 3 stopped |
| `kafka.replication.under_replicated` | 0 | Any, for 5 minutes or more | Many, or not falling | 1 during the throttled partition move, 169 with broker 3 stopped |
| `kafka.brokers_fenced`, `kafka.broker.online` | 0, and 1 for each broker | A broker fenced or not online for a few minutes | Still so after 10 minutes, or more than one broker | `brokers_fenced 1` and `online 0 broker=3` with broker 3 stopped |
| `kafka.quorum.max_follower_lag_ms` (KRaft) | Under a second | Several seconds | Tens of seconds and rising: a controller has stopped fetching | 277 to 448 on the busy cluster; 30,338 with broker 3, a controller too, stopped |
| `kafka.controller.active_controller`, added up over the brokers | 1 | | 0 or more than 1: no controller, or two | Not caused: every run read 1 |
| `jmx_up` of the JMX jobs (`kafka.throughput.jmx_up` and the rest) | 1 for each broker | | 0: that broker's figures are missing. A broker whose JMX does not answer cannot give its id, so it is tagged with its address | `jmx_up 0 broker=127.0.0.1:19993` with broker 3 stopped |
| `kafka.consumer.group_lag` | Steady, or falling | Rising for 15 minutes or more | Rising for an hour, or near what retention keeps: messages will be deleted unread | `billing`, whose consumer stopped: 16,387, then 21,428 later in the run |
| `kafka.transaction.long_running` | 0 | Any: an open transaction holds back consumers that read only committed messages | | The transaction held open read `ongoing 1`, then `long_running 1` once open longer than 300 seconds |
| `kafka.connection.failed_logins_count` (as a rate) | 0 | Any | Rising: a client with a wrong password, or someone guessing | 1 and 3 on the `SECURE` listener, after the test logged in with a wrong password |
| `kafka.controller.unclean_elections_count` (as a rate) | 0 | | Any: a leader was elected without all the data, and messages were lost | Not caused: unclean election is off |
| `kafka.logdir.dirs_offline` | 0 | | Any: a disk failed, and its partitions went elsewhere or offline | Not caused |
| `kafka.logdir.cleaner_dead_threads` | 0 | | Any: compacted topics, `__consumer_offsets` among them, are no longer cleaned and grow | Not caused: 0 on every broker |
| `kafka.request.handler_idle_pct` | Above 50 | Below 30 for 15 minutes or more | Below 10: requests wait | Not caused: 99.3 to 99.8 |
| `kafka.throughput.failed_produce_requests_count` (as a rate) | 0 | Any | Rising | Not caused: 0 |
| `kafka.tls.expires_days` | Above 30 | 30 or fewer | 7 or fewer | 1: the test's certificates last two days |
| `kafka.tls.trusted` | 1 | | 0: clients that check certificates will refuse it | 0 when checked against Java's own CAs, which do not include the test's |
| `kafka.config.unclean_leader_election`, `plaintext_listeners`, `settings_differ`, `topics_min_isr_ge_rf`; `kafka.security.any_principal_acls`, `all_operations_acls` | 0 | Any: a risk to decide on, not an outage | | `plaintext_listeners 2`, `settings_differ 2` and `topics_min_isr_ge_rf 2` on the test cluster |
| `kafka.feature.features_behind` | 0 | Any, for days: an upgrade not finalized. A quorum with a fixed list of controllers always shows `kraft.version` behind | | 0 |

**From 1.0.** `kafka_jvm` is gone: its JVM half is the jvm pack's, and its Kafka half (flush times, the log cleaner) is in `kafka_logdirs`. Where a job still runs it, `vigil pack update` keeps its script and says so (`dropped from the pack, still running: kafka_jvm`); `vigil pack disable kafka_jvm` stops it. Kafka's command-line tools are no longer run; `KAFKA_HOME` still names the Kafka download, now for its library. JMX takes a password and TLS, and `KAFKA_JMX` its targets as `jmxs=host:port` or `jmx=host:port` (a bare `host:port` still works, as `jmx=`). Java 11 or later, where 1.0 needed 17.

## How it was tested

**Tested** (2.0) on 2026-11-22 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-kafka.sh`, which builds the pack's jars as a release does. Each cluster ran in Docker with SASL_SSL, SCRAM-SHA-512, a certificate from a test CA, JMX over TLS with a password and a `readonly` user, and trouble on purpose: a group behind, a share group (Kafka 4), a transaction held open, a partition move held back.
- Each run: `service-packs.sh` through Vigil, with Kafka 4.4.0's library; then every job again with **the 3.9.2 library on Temurin's JRE 11**, printing the same lines; then every job with a broker stopped and started again.
- Results:
  - **Kafka 4.4.0, KRaft, three nodes: 75 passed, 0 failed.** The stopped broker read `fenced 1`, `online 0`, and its 169 replicas out of sync.
  - **Kafka 3.9.2, KRaft, three nodes: 75 passed, 0 failed.**
  - **Kafka 3.9.2 on ZooKeeper, one broker: 74 passed, 0 failed.**
  - **Kafka 2.8.2 on ZooKeeper, one broker: 74 passed, 0 failed**, from Apache's download, which has no image; there `kafka_transactions` says the cluster cannot list transactions (3.0 and later), and the run succeeds.
- The console output: [4.4.0](../../tests/integration/backends/reports/runs/2026-11-22/fedora/pack-kafka-4.4.0/console.txt), [3.9.2](../../tests/integration/backends/reports/runs/2026-11-22/fedora/pack-kafka-3.9.2/console.txt), [3.9.2 on ZooKeeper](../../tests/integration/backends/reports/runs/2026-11-22/fedora/pack-kafka-3.9.2-zookeeper/console.txt), [2.8.2 on ZooKeeper](../../tests/integration/backends/reports/runs/2026-11-22/fedora/pack-kafka-2.8.2-zookeeper/console.txt).
- **Against 1.0**, on the 4.4.0 cluster, each job three times from each: the 14 jobs that ask the cluster took **45.38 s of CPU against 1.0's 220.67 s**, and 36.70 s against 126.10 s of time: [the measurements](../../tests/integration/backends/reports/runs/2026-11-22/fedora/pack-kafka-cpu/console.txt).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2), with the jars built there (the same bytes as on Fedora), against the 4.4.0 cluster through SSH tunnels: every job directly, then `service-packs.sh` through Vigil with the 3.9.2 library on Temurin's JRE 21, **74 passed, 0 failed**: [the console output](../../tests/integration/backends/reports/runs/2026-11-22/macos/pack-kafka-2.0-macos/console.txt).
- **On Windows**, from a packs release built by `tools/release/packs.sh`, the same way: every job directly, then `Service-Packs.ps1` through Vigil, **63 passed, 0 failed**.
  - On Windows PowerShell 5.1 and PowerShell 7 on Windows 11: [the console output](../../tests/integration/backends/reports/runs/2026-11-22/windows/pack-kafka-2.0-windows/console.txt).
  - On Windows PowerShell 5.1 on Windows Server 2025: [the console output](../../tests/integration/backends/reports/runs/2026-11-22/windows-server-2025/pack-kafka-2.0-windows/console.txt).
  - The passwords came from `env:` references: Windows refuses its data protection to a logon by SSH key, as the test machines' were.

**Version 2.0.1** carries the probe with the words the Tomcat, Jetty and ActiveMQ packs need (`top`, `-key=pattern`, `=STATE`, `@tag`, `age`, `key/`, and a name for each target): nothing of the kafka pack's own changes, and its client is the same, byte for byte (`d3729acc…`). Tested on 2026-11-23 the same way, on the Kafka 4.4.0 cluster: **75 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/fedora/pack-kafka-4.4.0/console.txt)). The probe is also tested on its own, against MBeans made for it, every time it changes (`tools/probe/test/probe-test.sh`).

**Version 1.0, tested** on 2026-11-21 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-kafka.sh`, against clusters in Docker with SASL_SSL, SCRAM-SHA-512, a certificate from a test CA and the brokers' JMX open, made busy: a group that read part of a topic and stopped, one that keeps reading, a transaction held open, and a partition move held back by a throttle. `service-packs.sh` through Vigil, then every job as the busy cluster has it, with a broker stopped, and with it started again: **64 passed, 0 failed** against **Kafka 4.4.0**, three nodes in KRaft mode, with the 4.4.0 tools, the open transaction seen as `ongoing`, and later as `long_running`; **63 passed, 0 failed** against **Kafka 3.9.2**, three nodes in KRaft mode, with its own 3.9.2 tools; and **63 passed, 0 failed** against **Kafka 3.9.2 on ZooKeeper**, one broker (`--zookeeper`), so with no partition move and no broker stopped, with the 4.4.0 tools. In the 3.9.2 runs, and those of macOS and Windows below, the transaction did not stay open: the test then held it at Kafka's default timeout, a minute, and the broker ended it, so there `kafka_transactions` was seen to run and count, not to see one open. The full console output: [4.4.0](../../tests/integration/backends/reports/runs/2026-11-21/fedora/pack-kafka-4.4.0/console.txt), [3.9.2](../../tests/integration/backends/reports/runs/2026-11-21/fedora/pack-kafka-3.9.2/console.txt), [3.9.2 on ZooKeeper](../../tests/integration/backends/reports/runs/2026-11-21/fedora/pack-kafka-3.9.2-zookeeper/console.txt). **On macOS**, on the Intel Mac test machine under its bash 3.2, with the 4.4.0 tools, against the 4.4.0 cluster on the Fedora machine through SSH tunnels: `service-packs.sh` through Vigil, **63 passed, 0 failed**: [the console output](../../tests/integration/backends/reports/runs/2026-11-21/macos/pack-kafka-macos/console.txt). **On Windows**, against the same cluster the same way: every job directly, then `Service-Packs.ps1` through Vigil, **54 passed, 0 failed**, on Windows PowerShell 5.1 and PowerShell 7 on Windows 11 ([the console output](../../tests/integration/backends/reports/runs/2026-11-21/windows/pack-kafka-windows/console.txt)), and on Windows PowerShell 5.1 on Windows Server 2025 ([the console output](../../tests/integration/backends/reports/runs/2026-11-21/windows-server-2025/pack-kafka-windows/console.txt)). On Windows the password came from an `env:` reference: Windows refuses its data protection to a logon by SSH key, as the test machines' were.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
