# The shared JMX engine: design

Decided 2026-11-22, with the kafka pack 2.0. The JMX code every pack for a Java application needs (Kafka now; ActiveMQ, Tomcat, Jetty and others later), written once, here, and copied into each pack's client when the pack is generated. No pack depends on another: each ships its own copy, and the repository has one source.

## What it does

- **Connects** to a JVM's JMX over RMI: `jmx=host:port` plain, `jmxs=host:port` over TLS (the RMI registry too), with a user and a password when the server asks for them.
- **Checks TLS always**: the chain against the pack's CA file or Java's own CAs, and the server's name, as a DNS name, a one-label wildcard or an IP address. No setting trusts a certificate unchecked.
- **Gives up in time**: 30 seconds to connect, RMI's own timeouts for each call, so a run is never left hanging.
- **Says what went wrong, in the pack's words**: a server that does not answer is a reading (`jmx_up 0`, and why in the job's log); a login refused or a certificate not trusted fails the run, naming the pack's settings (`KAFKA_JMX_USER`, the secret behind `KAFKA_JMX_PASSWORD`, `KAFKA_CACERT`).
- **Reads tables.** Most of what an application's JMX says is "this MBean's attribute, as this metric, tagged so". A pack writes that as rows, and the engine reads them.

It reads only: attributes, and never an operation, unless the pack names one.

## Where it lives, and how a pack gets it

- `tools/jmx/Jmx.java`: the engine, one top-level class, `Jmx`, with its own imports.
- A pack's generator (`tools/<pack>/gen.py`) writes the pack's `_client.java` as the pack's own client followed by the engine, with the two files' imports merged at the top. So each pack's `_client.java` stands alone: one file, readable, compiled into the pack's own `_client.jar` by the release.
- A change to the engine changes every pack that copies it, at its next generation, and each such pack gets a new version. `tools/check-pack.sh` checks that a pack's copy is the engine as it is now, so none is left behind by accident.

The jvm pack has its own JMX code from before the engine; it moves onto the engine at its next version.

## Settings, named by the pack

The engine reads no setting of its own. A pack tells it its names, so the messages and the README match:

```java
Jmx.settings("KAFKA_JMX_USER", "KAFKA_JMX_PASSWORD", "KAFKA_CACERT");
```

The password comes from the environment (a `secret` line), never from a file or a command line.

## Targets

`Jmx.targets("KAFKA_JMX")` reads a list in `JVM_TARGETS`' form: `jmx=host:port` or `jmxs=host:port`, separated by `;` or `,`. A bare `host:port` is `jmx=`. Each target is named by what the application says it is (Kafka: its broker id, from `kafka.server:type=app-info`), else by its `host:port`; every metric from it is tagged with that name, and with `jmx=<host:port>`.

## Tables

A row says:

| Field | Example |
| --- | --- |
| the metric | `messages_in_count` |
| the MBean, a pattern | `kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec,topic=*` |
| the attribute, or a key of a composite one | `Count`; `HeapMemoryUsage.used` |
| tags, from the MBean's own keys | `topic` (as `topic=<its value>`) |
| a scale, optional | `0.001` (ns to µs) |

Written as Java, in the pack's client, so the rows are as readable as the rest of it:

```java
row("messages_in_count", "kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec", "Count");
row("topic_messages_in_count", "kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec,topic=*", "Count", "topic");
```

- **A row whose MBean the server does not have is not reported.** Kafka 4 has no ZooKeeper metrics; a ZooKeeper cluster has no KRaft controller metrics. A missing MBean is not an error.
- **Many MBeans from one pattern** are capped, with a `<metric>_not_shown` count of the rest, as every list in Vigil is.
- **Numbers as Vigil prints them:** no exponent, at most four decimals; something that is not a number is skipped.
- **One round trip per MBean**, with all its attributes asked for at once, so a table of a hundred rows is quick.

What a table cannot say (a figure worked out from several MBeans, a choice between them) the pack writes as code, with the engine's connection and helpers.

## Output

The engine prints as every client does: `metric <name> <value> <tag>=<value>...`, plain ASCII, tag values without spaces or quotes. Its messages go to stderr, prefixed with the job's name, and `Jmx.fail` sets the run's exit code to 1 after what could be printed.

## One generic jar, for packs that are only MBeans (decided 2026-11-22)

Most packs for a Java application (ActiveMQ, Tomcat, Jetty) only read MBeans. They need no Java of their own: the engine, with a small `main`, reads a **table** (a text file in the pack: metric, MBean pattern, attribute, tags, scale) and prints its metrics. So:

- **One jar, `_jmx.jar`, built once by the release from `tools/jmx/`**, the same bytes and SHA-256 in every pack that carries it. Each pack carries its own copy, so none depends on another; there is one Java program to review and trust, its digest the same everywhere. The scripts check it before every run, as now; `vigil pack verify` covers it.
- **A pack of this kind ships no Java of its own:** scripts, its table, its README. A new one needs no change to the jar.
- **A pack whose application speaks something other than JMX keeps a client of its own.** Kafka's admin API needs Kafka's library and code: the kafka pack has its own client, with the engine built in, and its JMX jobs are tables already.
- **Before the jar, the application's own HTTP.** ActiveMQ (Classic and Artemis) serves its MBeans as JSON over HTTP (Jolokia, in its web console; to be confirmed per version). Where an application does, its pack asks with `curl` or PowerShell and ships no Java at all; the jar is for what HTTP does not reach.

The generic `main` and the table format are built with the first pack that needs them.

## Tested

With the kafka pack 2.0, and every pack after it that copies the engine:

- plain JMX, and JMX over TLS with a password, against the pack's servers;
- a wrong password, a certificate from another CA, and one that names another host: each fails the run, saying why;
- a server that does not answer: `jmx_up 0`, and the run succeeds;
- a row for an MBean that is not there: nothing, and no error.
