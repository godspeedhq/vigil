# The artemis pack

Apache ActiveMQ Artemis 2.x, on this machine or any it can reach, over JMX with a password and TLS: the broker's health and high availability role, its address memory and disk against their limits, its addresses (paging, blocked, messages routed nowhere), its queues (the deepest first, with the age of the oldest message), dead letter and expiry queues, logins refused, cluster connections and bridges. ActiveMQ Classic is the [activemq pack](../activemq/README.md)'s; the broker's JVM is the [jvm pack](../jvm/README.md)'s. Linux, macOS and Windows.

**Only tables, and one jar**, as the [tomcat pack](../tomcat/README.md): the probe and `_probe.tables` (written by `tools/artemis/gen.py`), run with Java 11 or later, a JDK or a JRE, once the jar matches the SHA-256 each script carries.

1. **Turn on the JVM's JMX**, with a password and TLS on the registry too, in the broker's `JAVA_ARGS_APPEND` (or its `etc/artemis.profile`): the same `com.sun.management.jmxremote` options as the [tomcat pack](../tomcat/README.md)'s step 1, with `registry.ssl=true`. **Not** `management.xml`'s `<connector>`: with `secured="true"` it puts the connector on TLS but not its RMI registry, and the pack refuses it, saying so (`JMX at broker1:1099 does not speak TLS`). Nor `com.sun.management.jmxremote.login.config=activemq`: the JVM's JMX cannot load the broker's login modules (`No LoginModule found for ...PropertiesLoginModule`). A `readonly` user in the JVM's own access file is all the pack needs.
2. `vigil pack enable artemis`, then in `vigil.config` set the jobs' `ARTEMIS_JMX` (`art1: jmxs=broker1.example.com:1099; ...`), `ARTEMIS_JMX_USER`, `ARTEMIS_CACERT`, and a secret line on each job with the password, as the [tomcat pack](../tomcat/README.md)'s step 4: `secret = ARTEMIS_JMX_PASSWORD=secret:ARTEMIS_JMX_PASSWORD`, then `vigil secret set ARTEMIS_JMX_PASSWORD`.

**Artemis's own addresses are left out** (`$sys.*`, `activemq.notifications`, `activemq.management*`). Past 100 addresses or queues, the pack shows the largest and the deepest first, and counts the rest. Some figures are newer than some brokers: 2.33 does not count logins refused, and prints nothing for them.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | Java 11 or later, a JDK or a JRE (`JAVA_HOME` or `java` on the PATH) | The same | The same |
| The broker | ActiveMQ Artemis 2.x, with the JVM's JMX on (step 1) | | |
| A secret | `ARTEMIS_JMX_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 2) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `artemis_status` | Whether each broker answers, its version, name, HA policy and node, uptime, started, active, a backup, its replica in sync, clustered, each acceptor up | minute |
| `artemis_broker` | Address memory against `global-max-size`, disk against `max-disk-usage`, connections and sessions now and since, consumers, messages and totals, addresses and queues, logins and authorizations refused, mirror acknowledgements owed | minute |
| `artemis_addresses` | Each address, the largest first: its size and against its limit, messages, paging and pages, routed and routed nowhere, queues, paused, the duplicate cache | minute |
| `artemis_queues` | Each queue, the deepest first: messages and the oldest's age, delivering, scheduled, added, acknowledged, expired, killed, consumers, sizes, groups, prepared transactions, paused, enabled | minute |
| `artemis_dlq` | Each dead letter queue (DLQ in its name) and expiry queue (Expiry): messages, the oldest's age, added | minute |
| `artemis_cluster` | Each cluster connection, bridge and broker connection: up, and messages not yet acknowledged by the other side | 2 minutes |


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `artemis.version`.

```text
+--------------------------------------------------------------------------------------------------+
| artemis_status   artemis.<metric>   every 1m                                                     |
+----------------+---------------------------------------------------------------------------------+
| jmx_up         | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its address>      |
| version        | always 1, tagged version=<Artemis's version, 2.44.0>                            |
| broker         | always 1, tagged broker_name=<the broker's own name>                            |
| ha_policy      | always 1, tagged policy=<its high availability policy, Primary Only...>         |
| uptime_seconds | since the broker started                                                        |
| started        | 1 when the broker is started, else 0                                            |
| active         | 1 when it is active (serving clients), else 0: a backup waiting                 |
| backup         | 1 when it is a backup, else 0                                                   |
| replica_sync   | 1 when its replica is in sync (replication), else 0                             |
| clustered      | 1 when it is in a cluster, else 0                                               |
| node           | always 1, tagged node_id=<its node in the cluster>                              |
| acceptor_up    | 1 when the acceptor is started, tagged name=<the acceptor>                      |
| ..._not_shown  | past 100 of a list (version, broker, ha_policy, uptime_seconds, started,        |
|                | active, backup, replica_sync, clustered, node, acceptor_up), how many were left |
|                | out                                                                             |
+----------------+---------------------------------------------------------------------------------+
| GOOD  jmx_up 1; started 1; active 1 on the primary and 0 on a backup; every acceptor_up 1;       |
|       replica_sync 1 under replication.                                                          |
| WATCH uptime_seconds falling back: the broker restarted; version older than the newest of its    |
|       line.                                                                                      |
| BAD   jmx_up 0 or started 0: the broker is down; active 1 on a backup: it has taken over         |
|       (failover); replica_sync 0 for minutes: the backup is not in sync, and a failover now      |
|       loses messages.                                                                            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| artemis_broker   artemis.broker.<metric>   every 1m                                              |
+----------------------------+---------------------------------------------------------------------+
| jmx_up                     | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its   |
|                            | address>                                                            |
| address_memory_bytes       | memory the addresses hold                                           |
| address_memory_pct         | of global-max-size, in use                                          |
| global_max_bytes           | global-max-size                                                     |
| disk_pct                   | of the disk the journal is on, in use                               |
| disk_max_pct               | max-disk-usage: past it, producers are blocked                      |
| connections                | client connections now                                              |
| connections_count          | client connections since it started                                 |
| sessions                   | sessions now                                                        |
| sessions_count             | sessions since it started                                           |
| consumers                  | consumers now                                                       |
| messages                   | messages waiting, every queue                                       |
| added_count                | messages added to queues                                            |
| acknowledged_count         | messages acknowledged                                               |
| addresses                  | addresses                                                           |
| queues                     | queues                                                              |
| login_failed_count         | logins refused                                                      |
| login_count                | logins                                                              |
| authorization_failed_count | actions refused for a role                                          |
| mirror_pending             | acknowledgements a mirror owes (AMQP mirroring)                     |
| ..._not_shown              | past 100 of a list (address_memory_bytes, address_memory_pct,       |
|                            | global_max_bytes, disk_pct, disk_max_pct, connections,              |
|                            | connections_count, sessions, sessions_count, consumers, messages,   |
|                            | added_count, acknowledged_count, addresses, queues,                 |
|                            | login_failed_count, login_count, authorization_failed_count,        |
|                            | mirror_pending), how many were left out                             |
+----------------------------+---------------------------------------------------------------------+
| GOOD  address_memory_pct and disk_pct well below their limits; login_failed_count flat.          |
| WATCH address_memory_pct above 70: addresses near paging; disk_pct nearing disk_max_pct.         |
| BAD   disk_pct at disk_max_pct: producers are blocked; address_memory_pct at 100: addresses page |
|       to disk, block or drop (artemis_addresses says which are paging); login_failed_count       |
|       rising: a client with a wrong password, or someone guessing.                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| artemis_addresses   artemis.address.<metric>   every 1m                                          |
+-----------------+--------------------------------------------------------------------------------+
| jmx_up          | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its address>     |
| size_bytes      | memory its messages hold, tagged address=<the address>; the largest first      |
| limit_pct       | of its max-size-bytes, in use, tagged the same                                 |
| messages        | messages in its queues, tagged the same                                        |
| paging          | 1 when it is paging to disk, tagged the same                                   |
| pages           | pages on disk, tagged the same                                                 |
| routed_count    | messages routed to its queues, tagged the same                                 |
| unrouted_count  | messages sent to it and routed nowhere (no queue), tagged the same             |
| queues          | its queues, tagged the same                                                    |
| paused          | 1 when it is paused, tagged the same                                           |
| duplicate_cache | IDs in its duplicate detection cache, tagged the same                          |
| ..._not_shown   | past 100 of a list (size_bytes, limit_pct, messages, paging, pages,            |
|                 | routed_count, unrouted_count, queues, paused, duplicate_cache), how many were  |
|                 | left out                                                                       |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  paging 0; limit_pct well below 100; unrouted_count flat.                                   |
| WATCH paging 1: the address holds more than memory allows, on disk now; pages growing.           |
| BAD   limit_pct at 100 on an address with BLOCK or FAIL: producers are blocked or refused;       |
|       unrouted_count rising: messages sent where no queue reads them are lost.                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| artemis_queues   artemis.queue.<metric>   every 1m                                               |
+----------------------------+---------------------------------------------------------------------+
| jmx_up                     | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its   |
|                            | address>                                                            |
| messages                   | messages waiting, tagged address=<its address> and queue=<the       |
|                            | queue>; the deepest first                                           |
| oldest_seconds             | the age of its oldest message, tagged the same                      |
| delivering                 | messages being delivered, not yet acknowledged, tagged the same     |
| scheduled                  | messages scheduled for later, tagged the same                       |
| added_count                | messages added, tagged the same                                     |
| acknowledged_count         | messages acknowledged, tagged the same                              |
| expired_count              | messages that expired, tagged the same                              |
| killed_count               | messages sent to the dead letter address (too many deliveries),     |
|                            | tagged the same                                                     |
| consumers                  | consumers, tagged the same                                          |
| persistent_bytes           | the size of its messages, tagged the same                           |
| groups                     | message groups, tagged the same                                     |
| prepared                   | messages in prepared (XA) transactions, tagged the same             |
| paused                     | 1 when it is paused, tagged the same                                |
| enabled                    | 1 when it is enabled (receives messages), tagged the same           |
| durable_messages           | of its messages, those that are durable, tagged the same            |
| delivering_bytes           | the size of the messages being delivered, tagged the same           |
| scheduled_bytes            | the size of the messages scheduled, tagged the same                 |
| acknowledge_attempts_count | acknowledgements tried, tagged the same                             |
| max_consumers              | the most consumers it allows, when it has a limit, tagged the same  |
| ..._not_shown              | past 100 of a list (messages, oldest_seconds, delivering,           |
|                            | scheduled, added_count, acknowledged_count, expired_count,          |
|                            | killed_count, consumers, persistent_bytes, groups, prepared,        |
|                            | paused, enabled, durable_messages, delivering_bytes,                |
|                            | scheduled_bytes, acknowledge_attempts_count, max_consumers), how    |
|                            | many were left out                                                  |
+----------------------------+---------------------------------------------------------------------+
| GOOD  messages rising and falling; oldest_seconds small; consumers above 0 on every queue that   |
|       should be read.                                                                            |
| WATCH oldest_seconds growing: consumers are falling behind; killed_count rising.                 |
| BAD   messages growing with consumers 0: nothing reads it; oldest_seconds in hours; prepared     |
|       above 0 for long: an XA transaction left in doubt.                                         |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| artemis_dlq   artemis.dlq.<metric>   every 1m                                                    |
+---------------------+----------------------------------------------------------------------------+
| jmx_up              | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its address> |
| dead                | messages in a dead letter queue, tagged address and queue; the most first  |
| dead_oldest_seconds | the age of its oldest, tagged the same                                     |
| dead_added_count    | messages added to it, tagged the same                                      |
| expired             | messages in an expiry queue, tagged the same; the most first               |
| expired_added_count | messages added to it, tagged the same                                      |
| ..._not_shown       | past 100 of a list (dead, dead_oldest_seconds, dead_added_count, expired,  |
|                     | expired_added_count), how many were left out                               |
+---------------------+----------------------------------------------------------------------------+
| GOOD  dead and expired 0, or flat.                                                               |
| WATCH dead_added_count rising: messages are failing delivery.                                    |
| BAD   dead growing: messages nobody handled are piling up; read or purge them once the cause is  |
|       fixed.                                                                                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| artemis_cluster   artemis.cluster.<metric>   every 2m                                            |
+----------------------------+---------------------------------------------------------------------+
| jmx_up                     | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its   |
|                            | address>                                                            |
| cluster_up                 | 1 when the cluster connection is started, tagged name=<it>          |
| cluster_pending            | messages sent to other nodes, not yet acknowledged, tagged the same |
| cluster_acknowledged_count | messages the other nodes acknowledged, tagged the same              |
| bridge_up                  | 1 when the bridge is started, tagged name=<it>                      |
| bridge_pending             | messages it sent, not yet acknowledged, tagged the same             |
| bridge_acknowledged_count  | messages acknowledged by the other side, tagged the same            |
| connection_up              | 1 when the broker connection is open, tagged name=<it>              |
| ..._not_shown              | past 100 of a list (cluster_up, cluster_pending,                    |
|                            | cluster_acknowledged_count, bridge_up, bridge_pending,              |
|                            | bridge_acknowledged_count, connection_up), how many were left out   |
+----------------------------+---------------------------------------------------------------------+
| GOOD  every cluster_up, bridge_up and connection_up 1; pending small.                            |
| WATCH pending growing: the other side is slow, or the network is.                                |
| BAD   cluster_up, bridge_up or connection_up 0: messages for the other brokers wait here.        |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points; "In our tests" is what three brokers in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `artemis.jmx_up`, `artemis.started`, `artemis.active` | 1 (`active` 0 on a backup) | | 0: the broker is down; `active` 1 on a backup: it has taken over | `jmx_up` 0 for a target where nothing listens; 1 and 1 on each |
| `artemis.address.limit_pct` on an address that blocks | Well below 100 | Above 70 | At 100: its producers are blocked | 102 for `blocked`, its producer held |
| `artemis.address.paging`, `pages` | 0 | 1: the address holds more than memory allows, on disk | `pages` growing for hours | 1 and 1 page for `orders`, at 99 of its limit |
| `artemis.address.unrouted_count` (as a rate) | Flat | | Rising: messages sent where no queue reads them are lost | 50 for `nowhere` |
| `artemis.queue.oldest_seconds` | Small | Growing: consumers fall behind | Hours | 139 to 378 for `orders` (the brokers got their trouble one after another), read by a consumer too slow |
| `artemis.queue.messages` with `consumers` 0 | Rising and falling | Growing on one queue | Growing with nobody reading | 2,999 in `orders`, 434 being delivered to its slow consumer |
| `artemis.dlq.expired`, `dead` | 0, or flat | Rising | Growing | 100 in `ExpiryQueue`, every message that expired; `dead` 0 |
| `artemis.broker.login_failed_count` (as a rate) | Flat | | Rising: a client with a wrong password, or someone guessing | 9 on 2.40 and 2.44 after 3 refused clients (each tried again); 2.33 does not count them |
| `artemis.broker.disk_pct` against `disk_max_pct` | Well below | Within 10 | At it: producers are blocked | Not caused: 53.5 of 90 |

## How it was tested

**Tested** on 2026-11-23 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-artemis.sh`, against **Artemis 2.33.0, 2.40.0 and 2.44.0** (Java 21), each in Docker with the JVM's JMX over TLS with a password and a `readonly` user, 32 MB for every address, 1 MB for `orders` (paging) and for `blocked` (blocking), and expiry checked every 5 seconds. Trouble on purpose, with Artemis's own producer and consumer: 3,000 messages of 2 KB, 300 and 30 more, 100 that expired, 50 sent where no queue read them, a producer blocked, 3 clients with a wrong password, and a slow consumer.
- **On Fedora**: every job directly, each reading checked on all three, then `service-packs.sh` through Vigil, then every job on Temurin's JRE 11, and a probe changed by one byte refused: **75 passed, 0 failed**, and through Vigil **21 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/fedora/pack-artemis/console.txt)).
- **On macOS** (12.7.6, bash 3.2), with the jar built there, through SSH tunnels: every job, then on Temurin's JRE 21, **12 passed, 0 failed**; through Vigil, **21 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/macos/pack-artemis-macos/console.txt)).
- **On Windows**, from a packs release built by `tools/release/packs.sh`, as an account that is not an administrator: `Service-Packs.ps1` through Vigil, **21 passed, 0 failed**, then every job from the release on a JRE, **2 passed, 0 failed**: on Windows PowerShell 5.1 and PowerShell 7 on Windows 11 ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows/pack-artemis-windows/console.txt)), and on Windows PowerShell 5.1 on Windows Server 2025 ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows-server-2025/pack-artemis-windows/console.txt)). The password came from an `env:` reference: Windows refuses its data protection to a logon by SSH key.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
