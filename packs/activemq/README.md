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
