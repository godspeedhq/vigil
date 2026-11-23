# Vigil packs

A pack is a set of scripts and jobs that gives a machine useful metrics for one thing it runs. Vigil comes with the base pack, which `vigil init` turns on; the others are installed from the pack repository: `vigil pack search`, `vigil pack install <name>`, then `vigil pack enable <name>`. [SPECIFICATION.md](../SPECIFICATION.md), section 18.10, has the full format.

## What's here

```text
packs/<name>/README.md      the pack's documentation: what it reads, how to set it up, what to alert on, how it was tested
packs/<name>/pack.config    the pack's version, jobs and metrics
packs/<name>/linux/         scripts for Linux
packs/<name>/macos/         scripts for macOS
packs/<name>/windows/       scripts for Windows
```

Packs are released on their own, as packs releases tagged `packs-<date>`: each new pack version gets an archive per platform, listed in an index signed with the release key. A machine holds only the packs installed on it, and only its own platform's scripts.

## The packs

Each pack has a page of its own: what it reads, how to turn it on, each job, what to alert on, and how it was tested, against which servers, with the console output kept.

| Pack | What it watches | Its page |
| --- | --- | --- |
| [`base`](base/README.md) | This machine: CPU, memory, disk and disk I/O, network, load, services, the busiest programs. On by default. | [packs/base/README.md](base/README.md) |
| [`postgres`](postgres/README.md) | PostgreSQL: up, connections, sessions and locks, replication, wraparound, vacuum, checkpoints and WAL, database sizes | [packs/postgres/README.md](postgres/README.md) |
| [`mysql`](mysql/README.md) | MySQL and MariaDB: up, connections, queries, sessions and locks, replication, InnoDB, database sizes | [packs/mysql/README.md](mysql/README.md) |
| [`redis`](redis/README.md) | Redis and Valkey: up, clients, commands and hit rate, memory and evictions, replication, persistence, keys | [packs/redis/README.md](redis/README.md) |
| [`mssql`](mssql/README.md) | Microsoft SQL Server: up, workload, sessions and blocking, CPU, Always On, waits, I/O, memory, tempdb, connections, databases, integrity, settings, backups, Agent jobs | [packs/mssql/README.md](mssql/README.md) |
| [`kafka`](kafka/README.md) | Apache Kafka: brokers, KRaft quorum, replication, consumer lag, groups, topics, disk, transactions, settings, ACLs, features, certificates; traffic, requests, controller and connections from JMX | [packs/kafka/README.md](kafka/README.md) |
| [`jvm`](jvm/README.md) | Java virtual machines: process, heap and pools, metaspace, code cache, buffers, native memory, GC, threads and deadlocks, JIT, classes, safepoints, crashes, heap dumps, settings, security | [packs/jvm/README.md](jvm/README.md) |
| [`tomcat`](tomcat/README.md) | Apache Tomcat over JMX: server, connectors, requests, threads and executors, requests running and stuck, apps, sessions, servlets, JDBC pools (DBCP, Tomcat JDBC, HikariCP), resource cache and JSPs | [packs/tomcat/README.md](tomcat/README.md) |
| [`jetty`](jetty/README.md) | Eclipse Jetty over JMX: server and apps, low resources, requests and responses by class, request times, the thread pool, connections and limits, QoS, sessions and byte buffers | [packs/jetty/README.md](jetty/README.md) |
| [`activemq`](activemq/README.md) | Apache ActiveMQ Classic over JMX: health, memory, store and temp limits, queues (the deepest first), topics, dead letter queues, durable subscribers, connections and network bridges | [packs/activemq/README.md](activemq/README.md) |
| [`artemis`](artemis/README.md) | Apache ActiveMQ Artemis over JMX: health and HA, address memory and disk against their limits, addresses and paging, queues (the deepest first, the oldest message), dead letter and expiry queues, logins refused, cluster connections and bridges | [packs/artemis/README.md](artemis/README.md) |
| [`nginx`](nginx/README.md) | nginx: up, connections and requests, from stub_status | [packs/nginx/README.md](nginx/README.md) |

## Service packs

For what a server runs. They are off until you turn one on: `vigil init` never enables them, and nothing touches a database or a web server uninvited.

### postgres

A PostgreSQL server, on this machine or any it can reach (a container, another server, a managed service such as RDS or Cloud SQL), through PostgreSQL's own client tools (`psql`, `pg_isready`): a machine that runs Vigil but not PostgreSQL needs only the client package. It logs in as a read-only role, never a superuser.

**Its page: [packs/postgres/README.md](postgres/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### mysql

A MySQL or MariaDB server, on this machine or any it can reach (a container, another server, a managed service such as RDS or Cloud SQL), through the `mysql` client (MySQL's, or MariaDB's `mariadb`): a machine that runs Vigil but not the database needs only the client package. It logs in as a read-only user, never root. Linux, macOS and Windows.

**Its page: [packs/mysql/README.md](mysql/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### redis

A Redis or Valkey server, on this machine or any it can reach (a container, another server, a managed service), from its `INFO`, as a user that may run `INFO` and `PING` and nothing else. On Linux and macOS through `redis-cli` or `valkey-cli`, whichever is there; on Windows the scripts speak the server's protocol themselves, with what ships with Windows, so there is nothing to install. Linux, macOS and Windows.

**Its page: [packs/redis/README.md](redis/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### mssql

A Microsoft SQL Server, 2019, 2022 or 2025, on Linux or Windows, on this machine or any it can reach, from what it says about itself: its counters and its dynamic management views, read by one short query per job, as a login that can change nothing and read no table. Never a query's text, nor a host, program or login name. On Linux and macOS through `sqlcmd`, Microsoft's or the Go one; on Windows through .NET's own SQL Server client, so there is nothing to install. Linux, macOS and Windows.

**Its page: [packs/mssql/README.md](mssql/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### kafka

An Apache Kafka cluster, from 2.8 to 4.x, in KRaft mode or on ZooKeeper, on this machine or any it can reach. Through Kafka's admin API, the pack asks the cluster what any Kafka admin would, as a user that may only describe; through each broker's JMX, with a password and TLS, it reads the broker's own figures. It reports Kafka's, never the broker's JVM: heap, garbage collection, threads, CPU and open files are the [jvm pack](jvm/README.md)'s. Linux, macOS and Windows. Its design: [`tools/kafka/DESIGN.md`](../tools/kafka/DESIGN.md).

**Its page: [packs/kafka/README.md](kafka/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### jvm

Java virtual machines: any Java application (Jenkins, Spring Boot, Elasticsearch, Keycloak, one of your own) through the JVM it runs on. The JVM, not the application: its process, memory, garbage collection, threads, JIT, classes, crashes, settings and security. Application servers and libraries (Tomcat, Jetty, connection pools) are for packs of their own, which report what is theirs and leave the JVM to this one. Linux, macOS and Windows; JVMs from Java 8.

**Its page: [packs/jvm/README.md](jvm/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### tomcat

Apache Tomcat 9, 10.1 and 11, on this machine or any it can reach, over JMX with a password and TLS. The pack reads Tomcat's own figures: its connectors and their requests, the threads and executors that serve them, the requests running now and those stuck, each web application, its sessions and servlets, the database connection pools Tomcat makes, the resource cache and JSPs. It reports Tomcat's, never its JVM: heap, garbage collection, threads, CPU and open files are the [jvm pack](jvm/README.md)'s. Linux, macOS and Windows.

**Its page: [packs/tomcat/README.md](tomcat/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### jetty

Eclipse Jetty 9.4 to 12, on this machine or any it can reach, over JMX with a password and TLS: the server and its web applications, whether it is low on resources, its requests and responses by class and their times, its thread pool, connections and their limits, the QoS handler (12), sessions and Jetty's own byte buffers. It reports Jetty's, never its JVM: heap, garbage collection, threads, CPU and open files are the [jvm pack](jvm/README.md)'s. Linux, macOS and Windows.

**Its page: [packs/jetty/README.md](jetty/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### activemq

Apache ActiveMQ Classic 5.18 to 6.x, on this machine or any it can reach, over JMX with a password and TLS: the broker's health, its memory, store and temp against their limits, its queues (the deepest first), topics, dead letter queues, durable subscribers, producers held back by flow control, client connections and network bridges. ActiveMQ Artemis is another broker with other MBeans: the [artemis pack](artemis/README.md) is its. The broker's JVM is the [jvm pack](jvm/README.md)'s. Linux, macOS and Windows.

**Its page: [packs/activemq/README.md](activemq/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### artemis

Apache ActiveMQ Artemis 2.x, on this machine or any it can reach, over JMX with a password and TLS: the broker's health and high availability role, its address memory and disk against their limits, its addresses (paging, blocked, messages routed nowhere), its queues (the deepest first, with the age of the oldest message), dead letter and expiry queues, logins refused, cluster connections and bridges. ActiveMQ Classic is the [activemq pack](activemq/README.md)'s; the broker's JVM is the [jvm pack](jvm/README.md)'s. Linux, macOS and Windows.

**Its page: [packs/artemis/README.md](artemis/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### nginx

An nginx server on this machine, from its `stub_status` page, which you turn on once, reachable from this machine only.

**Its page: [packs/nginx/README.md](nginx/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

## Writing a pack

`tools/new-pack.sh <name>` starts one, and `tools/check-pack.sh --run <name>` says what is left to fix. [CONTRIBUTING.md](../CONTRIBUTING.md#your-first-pack) has the steps. In short:

- Use only what ships with the operating system: bash 3.2 and PowerShell 5.1.
- Print metrics as `metric <name> <value> [key=value ...]`, and use plain ASCII.
- Exit 0 when the script worked. A high reading is not a failure.
- Read data; never change the machine.
- Give it a page of its own, `packs/<name>/README.md`: what it reads, how to turn it on, its jobs, what to alert on and how it was tested, as every pack has.
- Ship text you can read: scripts, and the source of anything they run. Nothing compiled goes in the repository. The one exception is Java, since a JRE cannot run source: a pack for an application that speaks JMX writes its jobs as tables (`_probe.tables`) for the generic probe ([`tools/probe/DESIGN.md`](../tools/probe/DESIGN.md)), which it carries as every such pack does, and only an application whose API needs code of its own (Kafka's admin API) adds a client (`_client.java`). The release compiles them into `_probe.jar` and `_client.jar` (`tools/release/client-jar.sh`), writes their digests into the scripts, and the scripts check them before running them, as the kafka and jvm packs' do. [A pack in Java](../CONTRIBUTING.md#a-pack-in-java) has the rest.
- Start with the same header as the other scripts: what it does, its metrics, an example of its output, what healthy and unhealthy look like, what it needs, its exit codes and the disclaimer.
- In `pack.config`, say what `vigil pack info` shows before anyone installs it: `works_with`, the servers it is meant for and tested with; `programs_linux`, `programs_macos` and `programs_windows`, the programs its scripts need on each; `docs`, its page (`packs/<name>/README.md`); and `needs`, what an administrator sets up first.

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../LICENSE) gives the full terms, and it takes precedence over this summary.
