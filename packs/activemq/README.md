# The activemq pack

Apache ActiveMQ Classic 5.18 to 6.x, on this machine or any it can reach, over JMX with a password and TLS: the broker's health, its memory, store and temp against their limits, its queues (the deepest first), topics, dead letter queues, durable subscribers, producers held back by flow control, client connections and network bridges. ActiveMQ Artemis is another broker with other MBeans: the [artemis pack](../artemis/README.md) is its. The broker's JVM is the [jvm pack](../jvm/README.md)'s. Linux, macOS and Windows.

**Only tables, and one jar**, as the [tomcat pack](../tomcat/README.md): the probe and `_probe.tables` (written by `tools/activemq/gen.py`), run with Java 11 or later, a JDK or a JRE, once the jar matches the SHA-256 each script carries.

1. **Turn on the broker's JMX**, with a password and TLS. ActiveMQ's own `bin/setenv` on 6.x (`bin/env` on 5.x) takes the JVM's JMX options in `ACTIVEMQ_SUNJMX_START`: the same `com.sun.management.jmxremote` options as the [tomcat pack](../tomcat/README.md)'s step 1, with `java.rmi.server.hostname` set to the name the pack connects by. Leave `activemq.xml`'s `managementContext` at `createConnector="false"`: the JVM's connector is the one with a password and TLS. A `readonly` JMX user is all the pack needs.
2. `vigil pack enable activemq`, then in `vigil.config` set the jobs' `ACTIVEMQ_JMX` (`amq1: jmxs=broker1.example.com:1099; ...`), `ACTIVEMQ_JMX_USER`, `ACTIVEMQ_CACERT`, and a secret line on each job with the password, as the [tomcat pack](../tomcat/README.md)'s step 4: `secret = ACTIVEMQ_JMX_PASSWORD=secret:ACTIVEMQ_JMX_PASSWORD`, then `vigil secret set ACTIVEMQ_JMX_PASSWORD`.

**Advisory topics are left out** of `activemq_topics` and `activemq_subscribers`: ActiveMQ makes them for itself, many of them. Past 100 queues, topics, subscribers, producers or connections, the pack shows the worst first (the deepest, the most pending, the most held back) and counts the rest.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | Java 11 or later, a JDK or a JRE (`JAVA_HOME` or `java` on the PATH) | The same | The same |
| The broker | ActiveMQ Classic 5.18 to 6.x, with the JVM's JMX on (step 1) | | |
| A secret | `ACTIVEMQ_JMX_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 2) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `activemq_status` | Whether each broker answers, its version and name, uptime, its health check, whether it is a slave, each transport connector up and the connections it refused | minute |
| `activemq_broker` | Memory, store, temp and scheduler store in use against their limits, the store's size, connections, producers and consumers, messages, destinations, totals and message sizes | minute |
| `activemq_queues` | Each queue, the deepest first: waiting, sent, consumed, dispatched, expired, in flight, consumers, producers, memory and cursor, sends held back and for how long, waiting times, sizes, network traffic, duplicates | minute |
| `activemq_topics` | Each topic: pending for slow or offline subscribers, sent, delivered, expired, subscribers, producers, memory, sends held back | minute |
| `activemq_dlq` | Each dead letter queue (DLQ in its name): messages in it and sent to it | minute |
| `activemq_subscribers` | Each consumer and durable subscription, the most pending first: pending, dispatched, delivered, active or offline, slow | 2 minutes |
| `activemq_producers` | Each producer, the most held back first: held back now, its share of the time, the time added up, messages sent | 2 minutes |
| `activemq_connections` | Each client connection: waiting to be dispatched, blocked, slow, open transactions and the oldest's age; each network bridge and what it forwarded | 2 minutes |


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `activemq.version`.

```text
+--------------------------------------------------------------------------------------------------+
| activemq_status   activemq.<metric>   every 1m                                                   |
+---------------------------+----------------------------------------------------------------------+
| jmx_up                    | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its    |
|                           | address>                                                             |
| version                   | always 1, tagged version=<ActiveMQ's version, 6.2.0>                 |
| broker                    | always 1, tagged broker_name=<the broker's own name>                 |
| uptime_seconds            | since the broker started                                             |
| healthy                   | 1 when the broker's health check says Good, else 0                   |
| slave                     | 1 when it is a slave, waiting for the master (the store lock), else  |
|                           | 0                                                                    |
| connector_up              | 1 when the transport connector is started, tagged                    |
|                           | connectorName=<openwire, amqp...>                                    |
| connections_refused_count | connections refused for its maximumConnections, tagged the same      |
| ..._not_shown             | past 100 of a list (version, broker, uptime_seconds, healthy, slave, |
|                           | connector_up, connections_refused_count), how many were left out     |
+---------------------------+----------------------------------------------------------------------+
| GOOD  jmx_up 1; healthy 1; every connector_up 1; connections_refused_count flat.                 |
| WATCH uptime_seconds falling back: the broker restarted; version older than the newest of its    |
|       line.                                                                                      |
| BAD   jmx_up 0 or healthy 0: the broker is down or unwell (its log, and the health MBean, say    |
|       why); connections_refused_count rising: clients are turned away; slave 1 on the broker     |
|       that should be master.                                                                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| activemq_broker   activemq.broker.<metric>   every 1m                                            |
+-----------------------+--------------------------------------------------------------------------+
| jmx_up                | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its        |
|                       | address>                                                                 |
| memory_pct            | of the memory limit (systemUsage memoryUsage), in use                    |
| memory_limit_bytes    | the memory limit                                                         |
| store_pct             | of the store limit (storeUsage), in use                                  |
| store_limit_bytes     | the store limit                                                          |
| temp_pct              | of the temp limit (tempUsage: non-persistent messages on disk), in use   |
| temp_limit_bytes      | the temp limit                                                           |
| scheduler_pct         | of the scheduler store limit, in use                                     |
| scheduler_limit_bytes | the scheduler store limit                                                |
| store_bytes           | the persistence adapter's size (KahaDB, JDBC...)                         |
| connections           | client connections now                                                   |
| connections_count     | client connections since it started                                      |
| producers             | producers now                                                            |
| consumers             | consumers now                                                            |
| messages              | messages waiting, every destination                                      |
| enqueued_count        | messages sent to it                                                      |
| dequeued_count        | messages consumed                                                        |
| queues                | queues                                                                   |
| topics                | topics, advisory ones too                                                |
| temp_queues           | temporary queues                                                         |
| temp_topics           | temporary topics                                                         |
| message_mean_bytes    | the mean size of a message                                               |
| message_max_bytes     | the largest message                                                      |
| ..._not_shown         | past 100 of a list (memory_pct, memory_limit_bytes, store_pct,           |
|                       | store_limit_bytes, temp_pct, temp_limit_bytes, scheduler_pct,            |
|                       | scheduler_limit_bytes, store_bytes, connections, connections_count,      |
|                       | producers, consumers, messages, enqueued_count, dequeued_count, queues,  |
|                       | topics, temp_queues, temp_topics, message_mean_bytes,                    |
|                       | message_max_bytes), how many were left out                               |
+-----------------------+--------------------------------------------------------------------------+
| GOOD  memory_pct, store_pct and temp_pct well below 100; messages rising and falling with        |
|       traffic.                                                                                   |
| WATCH store_pct above 70: messages piling up on disk; messages growing without falling back.     |
| BAD   memory_pct, store_pct or temp_pct at 100: producer flow control blocks senders (or they    |
|       fail, with sendFailIfNoSpace). Find the queue that keeps them (activemq_queues).           |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| activemq_queues   activemq.queue.<metric>   every 1m                                             |
+----------------------------+---------------------------------------------------------------------+
| jmx_up                     | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its   |
|                            | address>                                                            |
| size                       | messages waiting, tagged destinationName=<the queue>; the deepest   |
|                            | first                                                               |
| enqueued_count             | messages sent to it, tagged the same                                |
| dequeued_count             | messages consumed and acknowledged, tagged the same                 |
| dispatched_count           | messages handed to consumers, tagged the same                       |
| expired_count              | messages that expired, tagged the same                              |
| in_flight                  | messages handed to consumers and not yet acknowledged, tagged the   |
|                            | same                                                                |
| consumers                  | consumers, tagged the same                                          |
| producers                  | producers, tagged the same                                          |
| memory_pct                 | of its memory limit, in use, tagged the same                        |
| memory_bytes               | memory its messages hold, tagged the same                           |
| cursor_pct                 | of its cursor's memory, in use, tagged the same                     |
| blocked_sends_count        | sends held back by flow control, tagged the same                    |
| blocked_seconds            | time sends were held back, added up, tagged the same                |
| enqueue_mean_seconds       | how long a message waits in it, on average, tagged the same         |
| enqueue_max_seconds        | the longest a message waited, tagged the same                       |
| message_mean_bytes         | the mean size of a message, tagged the same                         |
| paused                     | 1 when it is paused (no dispatch), tagged the same                  |
| forwarded_count            | messages forwarded to another broker, tagged the same               |
| store_bytes                | the size of its messages in the store (6.x), tagged the same        |
| temp_pct                   | of its temp limit (non-persistent messages on disk), in use, tagged |
|                            | the same                                                            |
| cursor_full                | 1 when its cursor is full: no more messages paged in to dispatch,   |
|                            | tagged the same                                                     |
| blocked_mean_seconds       | how long a held-back send waited, on average, tagged the same       |
| network_enqueued_count     | messages that came from another broker, tagged the same             |
| network_dequeued_count     | messages that went on to another broker, tagged the same            |
| message_max_bytes          | the largest message, tagged the same                                |
| duplicates_count           | duplicates found in the store, tagged the same                      |
| uncommitted_exceeded_count | transactions refused for holding too many messages, tagged the same |
| ..._not_shown              | past 100 of a list (size, enqueued_count, dequeued_count,           |
|                            | dispatched_count, expired_count, in_flight, consumers, producers,   |
|                            | memory_pct, memory_bytes, cursor_pct, blocked_sends_count,          |
|                            | blocked_seconds, enqueue_mean_seconds, enqueue_max_seconds,         |
|                            | message_mean_bytes, paused, forwarded_count, store_bytes, temp_pct, |
|                            | cursor_full, blocked_mean_seconds, network_enqueued_count,          |
|                            | network_dequeued_count, message_max_bytes, duplicates_count,        |
|                            | uncommitted_exceeded_count), how many were left out                 |
+----------------------------+---------------------------------------------------------------------+
| GOOD  size rising and falling; consumers above 0 on every queue that should be read;             |
|       blocked_sends_count flat.                                                                  |
| WATCH size growing on one queue; enqueue_mean_seconds growing: consumers are falling behind.     |
| BAD   size growing with consumers 0: nothing reads it; blocked_sends_count rising: flow control  |
|       holds producers back (its memory_pct at 100).                                              |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| activemq_topics   activemq.topic.<metric>   every 1m                                             |
+---------------------+----------------------------------------------------------------------------+
| jmx_up              | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its address> |
| pending             | messages pending for its subscribers, tagged destinationName=<the topic>;  |
|                     | the most first                                                             |
| enqueued_count      | messages sent to it, tagged the same                                       |
| dequeued_count      | messages delivered and acknowledged, tagged the same                       |
| dispatched_count    | messages handed to subscribers, tagged the same                            |
| expired_count       | messages that expired, tagged the same                                     |
| consumers           | subscribers, tagged the same                                               |
| producers           | producers, tagged the same                                                 |
| memory_pct          | of its memory limit, in use, tagged the same                               |
| blocked_sends_count | sends held back by flow control, tagged the same                           |
| ..._not_shown       | past 100 of a list (pending, enqueued_count, dequeued_count,               |
|                     | dispatched_count, expired_count, consumers, producers, memory_pct,         |
|                     | blocked_sends_count), how many were left out                               |
+---------------------+----------------------------------------------------------------------------+
| GOOD  pending near 0.                                                                            |
| WATCH pending growing on one topic: a subscriber is slow, or a durable one offline.              |
| BAD   pending growing for hours: an offline durable subscriber keeps every message on disk       |
|       (activemq_subscribers names it); store_pct rises with it.                                  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| activemq_dlq   activemq.dlq.<metric>   every 1m                                                  |
+----------------+---------------------------------------------------------------------------------+
| jmx_up         | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its address>      |
| size           | messages in it, tagged destinationName=<the queue>; the most first              |
| enqueued_count | messages sent to it, tagged the same                                            |
| ..._not_shown  | past 100 of a list (size, enqueued_count), how many were left out               |
+----------------+---------------------------------------------------------------------------------+
| GOOD  size 0, or flat.                                                                           |
| WATCH enqueued_count rising: messages are expiring or failing delivery.                          |
| BAD   size growing: messages nobody handled are piling up (and taking store); read or purge them |
|       once the cause is fixed.                                                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| activemq_subscribers   activemq.subscriber.<metric>   every 2m                                   |
+----------------+---------------------------------------------------------------------------------+
| jmx_up         | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its address>      |
| pending        | messages waiting for it, tagged destinationName=<its destination> and           |
|                | clientId=<its client>; the most first                                           |
| dispatched     | messages handed to it, not yet acknowledged, tagged the same                    |
| enqueued_count | messages for it, tagged the same                                                |
| dequeued_count | messages it acknowledged, tagged the same                                       |
| active         | 1 when it is connected, 0 for a durable subscriber offline, tagged the same     |
| slow           | 1 when the broker calls it slow, tagged the same                                |
| ..._not_shown  | past 100 of a list (pending, dispatched, enqueued_count, dequeued_count,        |
|                | active, slow), how many were left out                                           |
+----------------+---------------------------------------------------------------------------------+
| GOOD  pending near 0 for every subscriber; active 1.                                             |
| WATCH slow 1; pending growing on one.                                                            |
| BAD   active 0 with pending growing: an offline durable subscriber keeps every message for it.   |
|       Bring it back, or remove the subscription.                                                 |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| activemq_producers   activemq.producer.<metric>   every 2m                                       |
+-----------------+--------------------------------------------------------------------------------+
| jmx_up          | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its address>     |
| blocked_seconds | how long it has been held back by flow control, added up as each hold ends,    |
|                 | tagged destinationName=<its destination> and clientId=<its client>             |
| blocked         | 1 when flow control holds it back now, tagged the same                         |
| blocked_pct     | of its time, held back (a hold now counts at once), tagged the same; the most  |
|                 | first                                                                          |
| sent_count      | messages it sent, tagged the same                                              |
| ..._not_shown   | past 100 of a list (blocked_seconds, blocked, blocked_pct, sent_count), how    |
|                 | many were left out                                                             |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  blocked 0 for every producer.                                                              |
| WATCH blocked_pct climbing on one producer.                                                      |
| BAD   blocked 1 for minutes: its destination is at its memory limit (activemq_queues             |
|       memory_pct), and the producer waits; nothing reads what it sends.                          |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| activemq_connections   activemq.connection.<metric>   every 2m                                   |
+----------------------------+---------------------------------------------------------------------+
| jmx_up                     | 1 when JMX answers, else 0, tagged broker=<its name> and jmx=<its   |
|                            | address>                                                            |
| dispatch_queue             | messages waiting to be sent to it, tagged connectorName=<its        |
|                            | connector> and connectionName=<its client>; the most first          |
| blocked                    | 1 when it is blocked (flow control), tagged the same                |
| slow                       | 1 when it is slow, tagged the same                                  |
| transactions               | transactions open on it, tagged the same                            |
| oldest_transaction_seconds | how long its oldest open transaction has been open, tagged the same |
| bridge                     | always 1 for a network bridge up, tagged networkConnectorName=<its  |
|                            | connector> and remote=<the broker it reaches>                       |
| bridge_enqueued_count      | messages it took from this broker, tagged networkConnectorName and  |
|                            | networkBridge=<the bridge>                                          |
| bridge_dequeued_count      | messages it forwarded, tagged the same                              |
| ..._not_shown              | past 100 of a list (dispatch_queue, blocked, slow, transactions,    |
|                            | oldest_transaction_seconds, bridge, bridge_enqueued_count,          |
|                            | bridge_dequeued_count), how many were left out                      |
+----------------------------+---------------------------------------------------------------------+
| GOOD  dispatch_queue small; blocked 0; transactions few and short; a bridge for every network    |
|       connector.                                                                                 |
| WATCH slow 1 on a connection; oldest_transaction_seconds in minutes.                             |
| BAD   blocked 1: the client is held back by flow control; a bridge line gone: the brokers no     |
|       longer forward to each other.                                                              |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points; "In our tests" is what three brokers in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `activemq.jmx_up`, `activemq.healthy` | 1 | | 0: the broker, or its JMX, is down, or its health check is not Good | `jmx_up` 0 for a target where nothing listens; `healthy` 1 on each |
| `activemq.broker.temp_pct`, `store_pct`, `memory_pct` | Well below 100 | Above 70 | At 100: flow control holds producers back, or sends fail | `temp_pct` 100 on each, full of 10,169 to 10,174 non-persistent messages nobody read; `memory_pct` 11, `store_pct` 1 |
| `activemq.producer.blocked`, `blocked_pct` | 0 | | 1, and its share near 100: the producer waits, and nothing it sends arrives | 1 and 100 for the producer of `bulk` |
| `activemq.queue.size` with `consumers` 0 | Rising and falling | Growing on one queue | Growing with nobody reading it | `bulk` (10,169 to 10,174) and `orders` (2,998 or 2,999) deepest first; `orders` with 899 or 900 in flight to a slow consumer |
| `activemq.queue.memory_pct` | Well below 100 | Above 70 | At 100: that queue's sends are held back | 89 for `orders` |
| `activemq.dlq.size` | 0, or flat | `enqueued_count` rising | Growing | 50, every message that expired |
| `activemq.subscriber.pending` with `active` 0 | Near 0 | Growing | Growing for hours: an offline durable subscriber keeps every message on disk | 500 for `sub-billing`, gone |
| `activemq.connection.bridge` | 1 for each network connector | | Gone: the brokers no longer forward to each other | 1 on 5.18, to 6.2 |
| `activemq.connections_refused_count` (as a rate) | 0 | | Rising: `maximumConnections` reached | Not caused: 0 |

## How it was tested

**Tested** on 2026-11-23 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-activemq.sh`, against **ActiveMQ Classic 5.18.7, 5.19.2 and 6.2.0** (Java 17), each in Docker with JMX over TLS with a password and a `readonly` user, 16 MB of memory and 1 MB a destination, expiry checked every 5 seconds, and 5.18 bridged to 6.2. Trouble on purpose, with ActiveMQ's own producer and consumer: 3,000, 300 and 30 messages nobody read, 50 that expired, a durable subscriber gone with 500 kept for it, non-persistent messages until the temp store filled and flow control held the producer back, and a slow consumer.
- **On Fedora**: every job directly, each reading checked on all three, then `service-packs.sh` through Vigil, then every job on Temurin's JRE 11, and a probe changed by one byte refused: **79 passed, 0 failed**, and through Vigil **21 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/fedora/pack-activemq/console.txt)).
- **On macOS** (12.7.6, bash 3.2), with the jar built there, through SSH tunnels: every job, then on Temurin's JRE 21, **14 passed, 0 failed**; through Vigil, **21 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/macos/pack-activemq-macos/console.txt)).
- **On Windows**, from a packs release built by `tools/release/packs.sh`, as an account that is not an administrator: `Service-Packs.ps1` through Vigil, **21 passed, 0 failed**, then every job from the release on a JRE, **2 passed, 0 failed**: on Windows PowerShell 5.1 and PowerShell 7 on Windows 11 ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows/pack-activemq-windows/console.txt)), and on Windows PowerShell 5.1 on Windows Server 2025 ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows-server-2025/pack-activemq-windows/console.txt)). The password came from an `env:` reference: Windows refuses its data protection to a logon by SSH key.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
