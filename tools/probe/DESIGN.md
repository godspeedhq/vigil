# The probe: one generic tool for application packs

Decided 2026-11-22, with the kafka pack 2.0. Most packs for an application (Kafka's brokers, ActiveMQ, Tomcat, Jetty, Elasticsearch) read the same kind of thing: named figures from the application's management interface, as metrics. The probe does that, from **tables** a pack writes, so a pack ships scripts and tables and no code of its own. It is one Java program, built once, and every pack that needs it carries the same file: the same bytes, the same SHA-256. No pack depends on another.

## What it reads

| Reader | From | For | Built |
| --- | --- | --- | --- |
| **JMX** | MBeans over RMI, plain or TLS, with a login | Kafka's brokers; Tomcat, Jetty, ActiveMQ over JMX | now, with the kafka pack 2.0 |
| **HTTP + JSON** | a URL's JSON, by path | Elasticsearch (`_cluster/health`, `_nodes/stats`); ActiveMQ's Jolokia (JMX as JSON over HTTP); any JSON stats page | with the first pack that needs it |

It reads only: attributes and pages, never an operation or a write.

## The jar

- **Sources in `tools/probe/`**: `Jmx.java` (the JMX engine), `Probe.java` (its `main` and the tables), and later the HTTP reader.
- **In a pack, `_probe.java`**: the generator writes the sources merged into one file, imports at the top, so the source a pack ships beside its jar is one file anyone can read.
- **`_probe.jar`**, built by the release from `_probe.java` (`tools/release/client-jar.sh`), never committed: Java 11 bytecode, the same bytes from the same source and `javac`. Its SHA-256 is written into every script that runs it, and checked before each run, as the jvm pack's client is; `vigil pack verify` covers it.
- **Every pack's `_probe.java` is the same**: `tools/check-pack.sh` checks each against `tools/probe/` as it is now, so none is left behind. A change to the probe gives every pack that carries it a new version.
- **A pack with code of its own** has its own `_client.jar` as well, compiled with `_probe.jar` on its class path and run with it, so it uses the engine without a copy of it: the kafka pack's (Kafka's admin API, which needs Kafka's library), and from 1.2.0 the jvm pack's (processes, the JVM's own counters, GC logs, and JMX through the engine). Such a client uses the engine's connection, output and exit code; what it reads over that connection is its own, so the jvm pack's client still runs the read-only operations it always has (finding deadlocks, a thread's CPU time, `DiagnosticCommand`'s reports), which the probe's tables never do.

## Running it

```text
java -cp _probe.jar Probe <tables file> <job>
```

The script finds Java (11 or later, a JDK or a JRE), checks the jar's digest, and runs it with the pack's tables file, beside it. A copy of a pack without its jars (straight from the repository, not a release) does not run: its scripts say to install the pack from a release, or to build it (`tools/release/client-jar.sh`).

## The tables file

One per pack, beside its scripts (`_probe.tables`). Settings first, then a section for each job:

```text
# The pack's settings, by name: the messages name them, the README matches.
targets   KAFKA_JMX
user      KAFKA_JMX_USER
password  KAFKA_JMX_PASSWORD
cacert    KAFKA_CACERT
# Each target named by an MBean's key: tag, pattern, key.
name      broker  kafka.server:type=app-info,id=*  id

[throughput]
messages_in_count  kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec  Count

[requests]
total_ms_p99  kafka.network:type=RequestMetrics,name=TotalTimeMs,request=Produce  99thPercentile  request
purgatory     kafka.server:type=DelayedOperationPurgatory,name=PurgatorySize,delayedOperation=Produce  Value  +operation=produce
handler_idle_pct  kafka.server:type=KafkaRequestHandlerPool,name=RequestHandlerAvgIdlePercent  OneMinuteRate  *100

[controller]
active_controller  kafka.controller:type=KafkaController,name=ActiveControllerCount  Value
when               kafka.controller:type=KafkaController,name=ActiveControllerCount  Value
brokers            kafka.controller:type=KafkaController,name=ActiveBrokerCount  Value

[connections]
connections  kafka.server:type=socket-server-metrics,listener=*,networkProcessor=*  connection-count  listener  sum
```

A row is: the metric, the MBean (a pattern or one name), the attribute (or `attribute.key` of a composite one), then any of:

| Word | Meaning |
| --- | --- |
| `name` | a key of the MBean's name, as a tag (`topic`, `listener`) |
| `name/` | the same, after its last `/`: Jetty's `context=oejs_Server@70e9c95d/_shop` is `context=_shop`, without the hash a restart changes |
| `+name=value` | a tag of the row's own |
| `*n` | its value times n (`*100`: a fraction as a percent; `*0.001`: ms to seconds) |
| `>=n` | a value below n is no reading, and not printed (a figure never measured) |
| `sum` | the MBeans that match, added up by their tags: one line per listener, not per processor |
| `top` | the MBeans that match in order of this row's value, largest first, for every row of the same MBeans in the job: past 100, the worst are shown, not the first by name (the deepest queues of thousands) |
| `-key=pattern` | leaves out the MBeans whose key is like the pattern, `*` any characters (`-destinationName=ActiveMQ.Advisory.*`); rows with the same MBean and the same words read the same MBeans |
| `=STATE` | a state as a number: 1 when the attribute's text is `STATE`, else 0; several with `\|` (`=STARTED\|STARTING`), case aside (a web application `STARTED`, or `FAILED`) |
| `@tag` | a text as a tag, the value 1: `version 1 version=11.0.29.0` |
| `age` | the seconds since the attribute's time, in milliseconds since 1970: since a web application started; a time never set (0) is no reading |

And `when <MBean> <attribute>`: the rows after it print only when that value is above 0 (Kafka's controller figures, on the active controller only).

- **A key's value in quotes** (`name="http-nio-8080"`) is a tag without them.
- **An MBean a server does not have prints nothing.** Kafka 4 has no ZooKeeper metrics; a ZooKeeper cluster no KRaft controller metrics.
- **Many MBeans from one pattern** are capped at 100, with a `<metric>_not_shown` count: the first 100 by name, or with `top`, the 100 largest.
- **Each target's `jmx_up`**, 1 or 0, tagged with its name and address, starts every job.
- **One round trip per MBean**, with all its rows' attributes at once.

## Connecting, and what goes wrong

- `jmx=host:port` plain, `jmxs=host:port` TLS (the RMI registry too), `;`- or `,`-separated; a bare `host:port` is `jmx=`. A name first names the target (`web1: jmxs=host:port`); else the pack's `name` row names it by an MBean's key, or its address does. `name <tag>` alone gives the tag, with no MBean.
- **TLS always checked**: the chain against the pack's CA file or Java's own, and the server's name (DNS, a one-label wildcard, or an IP address). No setting trusts a certificate unchecked.
- **In time**: 30 seconds to connect, RMI's own timeouts for each call.
- **Down is a reading** (`jmx_up 0`, and why in the log). A login refused, a certificate not trusted, or `jmxs=` at a server that does not speak TLS fails the run, naming the pack's settings.
- **The password from the environment** (a `secret` line), never a file or a command line.

## Tested

With the kafka pack 2.0, on every platform and every cluster it is tested on, and again with each pack that carries the probe after it:

- plain JMX, and JMX over TLS with a password;
- a wrong password, a certificate from another CA, one naming another host, TLS against a plain server: each fails the run, saying why;
- a server that does not answer: `jmx_up 0`, and the run succeeds;
- a row for an MBean that is not there: nothing, and no error; `when`, `sum`, `*n`, `>=n` and `+tag` against real MBeans.

And on its own, every time it changes (CI's pack java job): `tools/probe/test/probe-test.sh` runs it against MBeans made for it (`Fixture.java`): the worst of 150 queues with `top`, noise left out, states, texts, ages, quoted names, a key after its last `/`, composite keys, named targets, and the tables it refuses.
