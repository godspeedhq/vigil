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


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `kafka.up`.

```text
+--------------------------------------------------------------------------------------------------+
| kafka_status   kafka.<metric>   every 1m                                                         |
+----------------+---------------------------------------------------------------------------------+
| up             | 1 when the cluster answers, else 0                                              |
| info           | always 1, tagged cluster_id=<its id> and kraft=<yes or no>                      |
| brokers        | brokers the cluster lists                                                       |
| brokers_fenced | of those, brokers fenced: registered, but not serving                           |
| controller_id  | the node that is the active controller (KRaft)                                  |
+----------------+---------------------------------------------------------------------------------+
| GOOD  up 1; brokers steady at as many as you run; brokers_fenced 0.                              |
| WATCH controller_id changing often: the controllers keep electing a new leader.                  |
| BAD   up 0; brokers below what you run: a broker is down; brokers_fenced above 0 for minutes.    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_quorum   kafka.quorum.<metric>   cron 1/2 * * * *                                          |
+----------------------------+---------------------------------------------------------------------+
| kraft                      | 1 when the cluster runs on KRaft, else 0                            |
| leader_id                  | the quorum's leader, the active controller                          |
| leader_epoch               | its epoch: it rises with each new leader                            |
| high_watermark             | the metadata log's committed end                                    |
| max_follower_lag           | the most any follower is behind, in records                         |
| max_follower_lag_ms        | the same, in milliseconds                                           |
| voters                     | controllers that vote                                               |
| observers                  | nodes that only follow (brokers)                                    |
| node_lag                   | how many records a node is behind, tagged node=<id> and             |
|                            | role=<leader, follower or observer>                                 |
| node_fetch_age_seconds     | since the node last fetched, tagged the same                        |
| node_caught_up_age_seconds | since the node was last caught up, tagged the same                  |
+----------------------------+---------------------------------------------------------------------+
| GOOD  kraft 1; max_follower_lag near 0; every node's node_caught_up_age_seconds a few seconds.   |
| WATCH leader_epoch rising often: the controllers keep losing their leader; node_lag growing for  |
|       one node.                                                                                  |
| BAD   voters fewer than you run, or a voter's node_caught_up_age_seconds in minutes: a           |
|       controller is gone or stuck. Lose a majority of voters and the cluster can change nothing. |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_brokers   kafka.broker.<metric>   cron 1/5 * * * *                                         |
+----------------------+---------------------------------------------------------------------------+
| online               | 1 when the broker is listed and not fenced, 0 when it holds replicas but  |
|                      | is not, or is fenced, tagged broker=<id> and rack=<its rack, or none>     |
| fenced               | 1 when it is fenced, tagged broker=<id>                                   |
| leaders              | partitions it leads, tagged the same                                      |
| replicas             | replicas it holds, tagged the same                                        |
| out_of_sync_replicas | of those, replicas not in sync, tagged the same                           |
| preferred_leaders    | partitions whose preferred leader it is, tagged the same                  |
| ..._not_shown        | past 100 of a list (brokers), how many were left out                      |
+----------------------+---------------------------------------------------------------------------+
| GOOD  online 1 for every broker; out_of_sync_replicas 0; leaders close to preferred_leaders.     |
| WATCH leaders far from preferred_leaders on one broker: leadership is unbalanced                 |
|       (kafka-leader-election puts it back).                                                      |
| BAD   online 0; out_of_sync_replicas above 0 on one broker: it cannot keep up (disk, network,    |
|       CPU).                                                                                      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_replication   kafka.replication.<metric>   every 1m                                        |
+------------------------+-------------------------------------------------------------------------+
| topics                 | topics                                                                  |
| partitions             | partitions                                                              |
| under_replicated       | partitions with fewer replicas in sync than they have                   |
| offline                | partitions with no leader: no one can read or write them                |
| under_min_isr          | partitions with fewer in sync than min.insync.replicas: writes with     |
|                        | acks=all fail                                                           |
| at_min_isr             | partitions exactly at min.insync.replicas, with replicas to spare       |
| not_preferred_leader   | partitions not led by their preferred leader                            |
| with_eligible_leaders  | partitions with eligible leader replicas (Kafka 4)                      |
| reassigning            | partitions being moved between brokers                                  |
| topic_under_replicated | under-replicated partitions of a topic, tagged topic=<name> (at most    |
|                        | 100 topics)                                                             |
| topic_offline          | offline partitions of a topic, tagged the same                          |
| topic_under_min_isr    | partitions of a topic under min.insync.replicas, tagged the same        |
+------------------------+-------------------------------------------------------------------------+
| GOOD  under_replicated, offline and under_min_isr 0.                                             |
| WATCH at_min_isr above 0: one more replica lost and writes fail; not_preferred_leader growing.   |
| BAD   offline above 0: data unreachable; under_min_isr above 0: producers with acks=all fail;    |
|       under_replicated above 0 for minutes when no broker is restarting.                         |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_reassignment   kafka.reassignment.<metric>   cron 2/5 * * * *                              |
+-------------------+------------------------------------------------------------------------------+
| partitions        | partitions being moved                                                       |
| adding_replicas   | replicas being added                                                         |
| removing_replicas | replicas being removed                                                       |
| topics            | topics with a partition being moved                                          |
| topic_partitions  | a topic's partitions being moved, tagged topic=<name> (at most 100)          |
+-------------------+------------------------------------------------------------------------------+
| GOOD  partitions 0, except while you move partitions.                                            |
| WATCH partitions above 0 for hours: a move held back by a throttle, or by a broker that cannot   |
|       catch up.                                                                                  |
| BAD   partitions not falling during a move you started: check the throttle and the brokers it    |
|       moves to.                                                                                  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_consumers   kafka.consumer.<metric>   every 1m                                             |
+----------------------+---------------------------------------------------------------------------+
| groups               | groups with committed offsets                                             |
| total_lag            | all groups' lag, in messages                                              |
| lag                  | a group's lag on a topic, in messages, tagged group=<name> and            |
|                      | topic=<name> (at most 150 pairs)                                          |
| lag_max              | its worst partition, tagged the same                                      |
| no_offset_partitions | partitions the group has no committed offset for, tagged the same; left   |
|                      | out when none                                                             |
| group_lag            | a group's lag on all its topics, tagged group=<name> (at most 150)        |
| ..._not_shown        | past 100 of a list (pairs), how many were left out                        |
+----------------------+---------------------------------------------------------------------------+
| GOOD  lag steady or falling: consumers keep up.                                                  |
| WATCH lag rising for minutes: consumers fall behind; lag_max far above lag divided by            |
|       partitions: one partition is stuck, or one consumer is slow.                               |
| BAD   lag rising with the group empty (kafka_groups): nothing consumes; lag near what retention  |
|       keeps: consumers are about to lose messages they never read.                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_groups   kafka.group.<metric>   cron 3/5 * * * *                                           |
+---------------+----------------------------------------------------------------------------------+
| all_groups    | groups                                                                           |
| all_members   | all groups' members                                                              |
| rebalancing   | groups rebalancing now                                                           |
| empty         | groups with no members                                                           |
| dead          | groups that are dead (being removed)                                             |
| groups        | groups of a type in a state, tagged type=<classic, consumer, share or streams>   |
|               | and state=<stable, empty, ...>                                                   |
| members       | a group's members, tagged group=<name> and type=<its type> (at most 150)         |
| ..._not_shown | past 100 of a list (groups), how many were left out                              |
+---------------+----------------------------------------------------------------------------------+
| GOOD  rebalancing 0 most of the time; each group's members steady.                               |
| WATCH rebalancing often above 0: consumers join and leave, or time out (max.poll.interval.ms).   |
| BAD   a group you expect to consume shows empty, or its members fall to 0: its consumers         |
|       stopped.                                                                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_topics   kafka.topic.<metric>   cron 4/5 * * * *                                           |
+--------------------+-----------------------------------------------------------------------------+
| topics             | topics                                                                      |
| internal_topics    | Kafka's own topics (their names start with __)                              |
| rf1_topics         | topics of your own with a single replica: a broker lost is data lost        |
| compacted_topics   | topics compacted (cleanup.policy compact)                                   |
| partitions         | a topic's partitions, tagged topic=<name> (at most 100 topics)              |
| replication_factor | its replication factor, tagged the same                                     |
| messages_count     | messages ever written to it, a running total, tagged the same               |
| retained_messages  | messages it still holds, tagged the same                                    |
| ..._not_shown      | past 100 of a list (topics), how many were left out                         |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  rf1_topics 0, unless on purpose; messages_count rising on every topic you write to.        |
| WATCH messages_count flat on a topic that should be written to: its producers stopped.           |
| BAD   rf1_topics above 0 for data you cannot lose.                                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_logdirs   kafka.logdir.<metric>   cron 0/5 * * * *                                         |
+---------------------------+----------------------------------------------------------------------+
| size_bytes                | a directory's size, tagged broker=<id> and dir=<its path>            |
| partitions                | its partitions, tagged the same                                      |
| offline                   | 1 when the broker reports an error for it, tagged the same           |
| future_replicas           | replicas being moved into it, tagged the same                        |
| dirs                      | directories                                                          |
| dirs_offline              | of those, offline                                                    |
| broker_size_bytes         | a broker's data, tagged broker=<id>                                  |
| topic_size_bytes          | a topic's data, every replica counted, tagged topic=<name> (at most  |
|                           | 100)                                                                 |
| jmx_up                    | with KAFKA_JMX: 1 when a broker's JMX answers, tagged broker=<id, or |
|                           | its JMX host:port>                                                   |
| remote_size_bytes         | a broker's data in remote storage (tiered storage), tagged           |
|                           | broker=<id>                                                          |
| remote_copy_lag_bytes     | data it has yet to copy there, tagged the same                       |
| flush_ms_p99              | the time a log flush takes, in ms, 99th percentile, tagged           |
|                           | broker=<id>                                                          |
| flushes_count             | log flushes, a running total, tagged the same                        |
| cleaner_max_dirty_pct     | the most of a compacted log not yet compacted, as a percent, tagged  |
|                           | the same                                                             |
| cleaner_idle_seconds      | since the log cleaner last ran, tagged the same; left out before it  |
|                           | first has                                                            |
| cleaner_dead_threads      | log cleaner threads that died, tagged the same                       |
| cleaner_max_clean_seconds | the longest a clean took, tagged the same; left out before the first |
| ..._not_shown             | past 100 of a list (topics), how many were left out                  |
+---------------------------+----------------------------------------------------------------------+
| GOOD  dirs_offline 0; sizes growing and shrinking with retention; cleaner_dead_threads 0.        |
| WATCH a broker's broker_size_bytes far above the others': partitions are unbalanced;             |
|       remote_copy_lag_bytes growing; flush_ms_p99 rising: the disk is slow.                      |
| BAD   offline 1: a disk failed, and its partitions moved away or went offline;                   |
|       cleaner_dead_threads above 0: compacted topics grow without bound.                         |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_transactions   kafka.transaction.<metric>   cron 1/5 * * * *                               |
+------------------+-------------------------------------------------------------------------------+
| all_transactions | transactional producers the cluster knows                                     |
| transactions     | of those, in a state, tagged state=<ongoing, completecommit, empty, ...>      |
| ongoing          | transactions open now                                                         |
| long_running     | transactions open longer than KAFKA_TXN_LONG                                  |
+------------------+-------------------------------------------------------------------------------+
| GOOD  long_running 0.                                                                            |
| WATCH ongoing growing without falling back.                                                      |
| BAD   long_running above 0: a transaction left open holds up consumers that read committed       |
|       messages (isolation.level read_committed) on its partitions.                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_config   kafka.config.<metric>   cron 6/15 * * * *                                         |
+--------------------------------+-----------------------------------------------------------------+
| unclean_leader_election        | 1 when an out-of-sync replica may become leader, losing data    |
| auto_create_topics             | 1 when a client creates a topic just by naming it               |
| auto_leader_rebalance          | 1 when leadership moves back to preferred leaders by itself     |
| authorizer                     | 1 when ACLs are checked                                         |
| min_insync_replicas            | the default min.insync.replicas                                 |
| default_replication_factor     | the replication factor of a topic created without one           |
| offsets_replication_factor     | the consumer offsets topic's                                    |
| transactions_replication_facto | the transaction state topic's                                   |
| r                              |                                                                 |
| message_max_bytes              | the largest batch a broker takes                                |
| retention_hours                | how long messages are kept by default; -1 forever               |
| plaintext_listeners            | listeners without TLS or a login, the controllers' left out     |
| settings_differ                | settings with different values on different brokers             |
| topics_unclean_election        | topics that allow unclean leader election                       |
| topics_min_isr_ge_rf           | topics with more replicas than one whose min.insync.replicas is |
|                                | at least their replication factor: one replica down and writes  |
|                                | with acks=all fail                                              |
| topics_min_isr_1               | topics with 3 or more replicas but min.insync.replicas 1:       |
|                                | acks=all keeps only one copy                                    |
+--------------------------------+-----------------------------------------------------------------+
| GOOD  unclean_leader_election 0; min_insync_replicas 2 with a replication factor of 3;           |
|       settings_differ 0.                                                                         |
| WATCH auto_create_topics 1 in production: a typo makes a topic; plaintext_listeners above 0.     |
| BAD   unclean_leader_election 1, or topics_unclean_election above 0, where data must not be      |
|       lost; topics_min_isr_ge_rf above 0.                                                        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_security   kafka.security.<metric>   cron 8/15 * * * *                                     |
+---------------------+----------------------------------------------------------------------------+
| authorizer          | 1 when the cluster checks ACLs, 0 when it has no authorizer                |
| all_acls            | ACLs                                                                       |
| any_principal_acls  | ACLs for every principal (User:*)                                          |
| all_operations_acls | ACLs for every operation (ALL)                                             |
| acls                | ACLs, tagged resource=<topic, group, cluster, ...> and permission=<allow   |
|                     | or deny>                                                                   |
| scram_users         | users with SCRAM credentials                                               |
| quotas              | quotas set, tagged entity=<user or client>                                 |
+---------------------+----------------------------------------------------------------------------+
| GOOD  authorizer 1; all_acls and scram_users changing only when you change them.                 |
| WATCH any_principal_acls or all_operations_acls above 0: check they are meant.                   |
| BAD   authorizer 0 on a cluster that should check ACLs; all_acls or scram_users changing when no |
|       one changed them.                                                                          |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_features   kafka.feature.<metric>   cron 10/15 * * * *                                     |
+------------------+-------------------------------------------------------------------------------+
| metadata_version | always 1, tagged version=<finalized> and supported=<the most supported>       |
| level            | a feature's finalized level, tagged feature=<name>                            |
| supported_level  | the most the brokers support, tagged the same                                 |
| behind           | 1 when the feature is below that, tagged the same                             |
| features         | features                                                                      |
| features_behind  | of those, behind                                                              |
+------------------+-------------------------------------------------------------------------------+
| GOOD  features_behind 0, after an upgrade is finished.                                           |
| WATCH features_behind above 0 for long after an upgrade: it was never finalized, and the cluster |
|       does not use what the new version brings.                                                  |
| BAD   metadata_version far behind supported: finalize it once every broker runs the new version. |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_throughput   kafka.throughput.<metric>   every 2m                                          |
+--------------------------------+-----------------------------------------------------------------+
| jmx_up                         | 1 when a broker's JMX answers, tagged broker=<id, or its JMX    |
|                                | host:port>                                                      |
| messages_in_count              | messages written to it, tagged broker=<id>                      |
| bytes_in_count                 | bytes written to it by clients, tagged the same                 |
| bytes_out_count                | bytes read from it by clients, tagged the same                  |
| bytes_rejected_count           | bytes rejected, too large, tagged the same                      |
| replication_bytes_in_count     | bytes copied to it from other brokers, tagged the same          |
| replication_bytes_out_count    | bytes copied from it to other brokers, tagged the same          |
| produce_requests_count         | produce requests, tagged the same                               |
| fetch_requests_count           | fetch requests, tagged the same                                 |
| failed_produce_requests_count  | produce requests that failed, tagged the same                   |
| failed_fetch_requests_count    | fetch requests that failed, tagged the same                     |
| produce_conversions_count      | messages converted to another format on produce, tagged the     |
|                                | same                                                            |
| fetch_conversions_count        | messages converted on fetch, tagged the same                    |
| invalid_crc_records_count      | records rejected for a bad checksum, tagged the same            |
| invalid_sequence_records_count | records rejected for an offset or sequence out of order, tagged |
|                                | the same                                                        |
+--------------------------------+-----------------------------------------------------------------+
| GOOD  jmx_up 1; traffic spread evenly between brokers; the failed counts flat.                   |
| WATCH one broker's bytes far above the others': partitions are unbalanced; the conversion counts |
|       rising: old clients make the broker do extra work.                                         |
| BAD   failed_produce_requests_count rising: producers' writes fail; bytes_rejected_count rising: |
|       messages too large for message.max.bytes.                                                  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_requests   kafka.request.<metric>   cron 1/2 * * * *                                       |
+------------------+-------------------------------------------------------------------------------+
| jmx_up           | 1 when a broker's JMX answers, tagged broker=<id, or its JMX host:port>       |
| total_ms_p99     | the time a request takes, in ms, tagged broker=<id> and request=<Produce,     |
|                  | FetchConsumer or FetchFollower>                                               |
| queue_ms_p99     | of that, the time it waits in the queue, tagged the same                      |
| remote_ms_p99    | of that, the time it waits on other brokers (acks=all) or for data (fetch),   |
|                  | tagged the same                                                               |
| requests_count   | requests served, a running total, tagged the same                             |
| request_queue    | requests waiting for a handler thread, tagged broker=<id>                     |
| response_queue   | responses waiting to be sent, tagged the same                                 |
| purgatory        | requests waiting in purgatory, tagged broker=<id> and operation=<produce or   |
|                  | fetch>                                                                        |
| handler_idle_pct | how idle the request handler threads are, as a percent, tagged broker=<id>    |
| network_idle_pct | how idle the network threads are, as a percent, tagged the same               |
+------------------+-------------------------------------------------------------------------------+
| GOOD  handler_idle_pct and network_idle_pct above 30; request_queue near 0; Produce total_ms_p99 |
|       steady.                                                                                    |
| WATCH handler_idle_pct below 30: the broker is busy; queue_ms_p99 rising: requests wait for      |
|       threads.                                                                                   |
| BAD   handler_idle_pct or network_idle_pct below 10: the broker is saturated; Produce            |
|       total_ms_p99 climbing with remote_ms_p99: followers are slow to replicate.                 |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_controller   kafka.controller.<metric>   every 2m                                          |
+--------------------------------+-----------------------------------------------------------------+
| jmx_up                         | 1 when a node's JMX answers, tagged broker=<id, or its JMX      |
|                                | host:port>                                                      |
| active_controller              | 1 on the active controller, else 0, tagged broker=<id>          |
| brokers                        | brokers active, tagged the same                                 |
| fenced_brokers                 | brokers fenced, tagged the same                                 |
| topics                         | topics, tagged the same                                         |
| partitions                     | partitions, tagged the same                                     |
| offline_partitions             | partitions with no leader, tagged the same                      |
| preferred_imbalance            | partitions not led by their preferred leader, tagged the same   |
| metadata_errors                | errors applying metadata, tagged the same                       |
| metadata_lag_ms                | how far behind its metadata is, in ms, tagged the same          |
| timed_out_heartbeats           | broker heartbeats that timed out, tagged the same               |
| controller_changes             | times a new controller became active, tagged the same           |
| elections_count                | leader elections, a running total, tagged the same              |
| unclean_elections_count        | unclean leader elections (data lost), a running total, tagged   |
|                                | the same                                                        |
| eligible_leader_elections_coun | leaders elected from eligible leader replicas (Kafka 4), a      |
| t                              | running total, tagged the same                                  |
| event_queue                    | events waiting in the controller's queue, tagged the same       |
| event_queue_ms_p99             | the time an event waits there, in ms, tagged the same           |
+--------------------------------+-----------------------------------------------------------------+
| GOOD  one node with active_controller 1; offline_partitions 0; metadata_errors 0.                |
| WATCH elections_count rising fast: leaders keep changing; timed_out_heartbeats rising.           |
| BAD   no node with active_controller 1; offline_partitions above 0; unclean_elections_count      |
|       rising: data was lost.                                                                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_connections   kafka.connection.<metric>   cron 3/5 * * * *                                 |
+-----------------------+--------------------------------------------------------------------------+
| jmx_up                | 1 when a broker's JMX answers, tagged broker=<id, or its JMX host:port>  |
| connections           | connections open, tagged broker=<id> and listener=<name>                 |
| created_count         | connections made, a running total, tagged the same                       |
| logins_count          | logins that succeeded, a running total, tagged the same                  |
| failed_logins_count   | logins that failed, a running total, tagged the same                     |
| failed_relogins_count | re-authentications that failed, a running total, tagged the same         |
+-----------------------+--------------------------------------------------------------------------+
| GOOD  failed_logins_count flat; connections steady.                                              |
| WATCH created_count rising fast while connections stays flat: clients connect and drop.          |
| BAD   failed_logins_count rising: a client with a wrong password or certificate, or someone      |
|       guessing.                                                                                  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| kafka_tls   kafka.tls.<metric>   cron 12 * * * *                                                 |
+--------------+-----------------------------------------------------------------------------------+
| tls          | 1 when the listener uses TLS, else 0                                              |
| endpoints    | brokers checked                                                                   |
| reachable    | 1 when a broker gave its certificate, tagged endpoint=<host:port>                 |
| expires_days | days until it expires, below 0 once it has, tagged the same                       |
| trusted      | 1 when it is trusted and names the broker, tagged the same                        |
+--------------+-----------------------------------------------------------------------------------+
| GOOD  expires_days above 30 everywhere; trusted 1.                                               |
| WATCH expires_days below 30: renew it.                                                           |
| BAD   expires_days below 7, or trusted 0: clients that check certificates will refuse the        |
|       broker.                                                                                    |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

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
