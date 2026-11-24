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

## A fleet whose configuration comes from a source

Where each host's configuration is fetched from Git or another source, Vigil never edits it: `vigil pack enable` refuses there and says what to do instead. The order is **install, then commit**:

1. Install the pack on each host, with whatever deploys software there: `vigil pack install nginx`. It stays off.
2. Print its jobs, anywhere, even on a laptop with no pack installed: `vigil pack config nginx --os linux` (or `macos`, `windows`, since each platform's jobs name their own scripts). `--store vault` writes the jobs' secrets as `store:vault/<NAME>`.
3. Paste the block into the configuration the hosts fetch, set what differs per host in the per-host files, and commit. Each host picks it up at its next `check_every`.

A host that doesn't have the pack, or has a version without one of its jobs, fails just those jobs, and `vigil precheck` and `vigil status` say why: `(pack nginx is not installed here: vigil pack install nginx)`. Secrets are placed however the fleet places them (`vigil secret set --stdin` as the service account, the environment, a secret store): Vigil only needs them there, and right, when the job runs.

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
| [`beam`](beam/README.md) | Erlang and Elixir VMs: process, epmd, memory by kind, processes, ports, atoms and ETS against their limits, run queues, GC, mailboxes, ETS tables, distribution, applications, crash dumps | [packs/beam/README.md](beam/README.md) |
| [`rabbitmq`](rabbitmq/README.md) | RabbitMQ: up, memory, disk and file descriptors against their limits and alarms, messages in and out and lost, queues (the deepest first), quorum queues, memory by use, disk work, cluster links, vhosts | [packs/rabbitmq/README.md](rabbitmq/README.md) |
| [`jenkins`](jenkins/README.md) | Jenkins: up, version, executors, labels, the queue and what is stuck, nodes online and why not, builds running and stuck, jobs failing, unstable and their health, load averages, plugins | [packs/jenkins/README.md](jenkins/README.md) |
| [`elasticsearch`](elasticsearch/README.md) | Elasticsearch: cluster health and its own health report, nodes, thread pools and rejections, circuit breakers, indices, shards and why one is unassigned, disks and watermarks, node work, ingest, tasks, ILM, SLM, snapshots, transforms, license | [packs/elasticsearch/README.md](elasticsearch/README.md) |
| [`opensearch`](opensearch/README.md) | OpenSearch: cluster health, nodes, thread pools and rejections, circuit breakers, backpressure and admission control, indices, shards and why one is unassigned, disks and watermarks, node work, ingest, tasks, ISM, snapshot management, snapshots | [packs/opensearch/README.md](opensearch/README.md) |
| [`nginx`](nginx/README.md) | nginx: connections and requests, processes and reloads, an edit not reloaded, how full the workers are, the access log minute by minute (status, errors, response and upstream times), certificate expiry | [packs/nginx/README.md](nginx/README.md) |
| [`httpd`](httpd/README.md) | Apache httpd: workers and the scoreboard, requests, connections, the TLS session cache, an edit not loaded, the access log minute by minute (status, errors, response times), certificate expiry | [packs/httpd/README.md](httpd/README.md) |
| [`caddy`](caddy/README.md) | Caddy: its configuration and reloads, traffic per server, reverse proxy upstreams and their health, the certificate of every site, from its admin API | [packs/caddy/README.md](caddy/README.md) |
| [`haproxy`](haproxy/README.md) | HAProxy: connections, rates, TLS and load; frontends, backends and every server with its health check, queues, times and errors, from its runtime API | [packs/haproxy/README.md](haproxy/README.md) |
| [`phpfpm`](phpfpm/README.md) | PHP-FPM: each pool's workers, listen queue, max_children reached, slow requests, the busiest worker, and a status page that waits because every worker is busy | [packs/phpfpm/README.md](phpfpm/README.md) |
| [`iis`](iis/README.md) | IIS on Windows, with no administrator: sites, application pools and their request queues, worker processes, each site's log and what HTTP.sys turned away, pools stopped by rapid-fail protection and crashed workers, certificate expiry | [packs/iis/README.md](iis/README.md) |

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

### beam

Erlang and Elixir virtual machines: any application on the BEAM (RabbitMQ, CouchDB, ejabberd, EMQX, Phoenix, a release of your own) through the VM it runs on. The VM, not the application: its process, the nodes epmd knows, memory by kind, processes, ports, atoms and ETS tables against their limits, run queues, garbage collection, the longest mailboxes and largest tables, its peers, its applications, and the crash dumps a VM leaves when it dies. No Java: shell, PowerShell and one Erlang script. Its deepest tier needs the node's cookie, which lets whoever holds it run anything on the node: the pack only reads, and its page says how, call by call. Linux, macOS and Windows; Erlang/OTP 25 and later.

**Its page: [packs/beam/README.md](beam/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### rabbitmq

RabbitMQ 3.13 and 4.x, a node or a cluster, from the Prometheus pages it serves itself, read with `curl`: no login, no cookie. Each node's memory, disk and file descriptors against their limits and its alarms; messages received, routed, delivered, acknowledged and lost; every queue, the deepest first; quorum queues' Raft logs and the metadata store; what its memory holds; its links to the other nodes. Its Erlang VM is the beam pack's. Linux, macOS and Windows.

**Its page: [packs/rabbitmq/README.md](rabbitmq/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### jenkins

A Jenkins controller, from its REST API, as a read-only user with an API token, with `curl` and `jq` (on Windows, PowerShell alone). Its nodes online or not and why, each label's executors, the queue and what is stuck in it, the builds running against their estimate, every job failing or unstable with its health and recent builds, Jenkins' own load averages, its plugins. Its JVM is the jvm pack's. Linux, macOS and Windows.

**Its page: [packs/jenkins/README.md](jenkins/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### elasticsearch

An Elasticsearch cluster, from its REST API, as a user (or an API key) that may only monitor, with `curl` and `jq` (on Windows, PowerShell alone). The cluster's health and Elasticsearch's own health report, every node, the thread pools and the work they refuse, the circuit breakers, every index and its blocks, every shard and Elasticsearch's own explanation of why one is unassigned, the disks against the watermarks and the settings left behind after maintenance, the work each node does, ingest pipelines, tasks, ILM, SLM and the data stream lifecycle, snapshots, the license, transforms, Watcher and enrich. Its JVM is the jvm pack's. Linux, macOS and Windows.

**Its page: [packs/elasticsearch/README.md](elasticsearch/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### opensearch

An OpenSearch cluster, from its REST API, as a user that may only monitor, with `curl` and `jq` (on Windows, PowerShell alone). The cluster's health and its cluster manager, every node, the thread pools and the work they refuse, the circuit breakers, search backpressure, shard indexing pressure and admission control, every index and its blocks, every shard and OpenSearch's own explanation of why one is unassigned, the disks against the watermarks and the settings left behind after maintenance, the work each node does, ingest pipelines, tasks, Index State Management, snapshot management and snapshots. Its JVM is the jvm pack's. Linux, macOS and Windows.

**Its page: [packs/opensearch/README.md](opensearch/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### nginx

An nginx server on this machine: its `stub_status` page, its processes (old workers still finishing after a reload, how full the workers are, a configuration edited and not reloaded), its access log minute by minute (requests by status, the 5xx share, response and upstream times with percentiles), and the certificates it serves. With `curl` and `openssl` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/nginx/README.md](nginx/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### httpd

An Apache httpd server on this machine: its `server-status` page (workers busy and idle, every scoreboard state, requests, connections, the TLS session cache), a configuration edited and not loaded, its access log minute by minute, and the certificates it serves. With `curl` and `openssl` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/httpd/README.md](httpd/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### caddy

A Caddy server, from its admin API, GET only: what its configuration serves and whether the last change loaded, the traffic each server handles, its reverse proxies' upstreams and their health, and the certificate of every site it serves (Caddy's own CA's too). With `curl`, `jq` and `openssl` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/caddy/README.md](caddy/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### haproxy

An HAProxy process, from its runtime API at `level user` (`show info` and `show stat` only): connections, rates, TLS and load, every frontend, every backend, and every server with its health check, the worst first. With bash alone over TCP, or `socat` or `nc` for a socket file. Linux and macOS.

**Its page: [packs/haproxy/README.md](haproxy/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### phpfpm

PHP-FPM's pools, from their status pages, passed on by the web server: workers, the listen queue, `pm.max_children` reached, slow requests, the busiest worker, and a status page that does not answer in time because every worker is busy. With `curl`. Linux and macOS.

**Its page: [packs/phpfpm/README.md](phpfpm/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### iis

IIS on this Windows machine, read by an account that is not an administrator: its sites, its application pools and their request queues in HTTP.sys, its worker processes, each site's log minute by minute and HTTP.sys's own error log (what it turned away before any site saw it), its events (pools stopped by rapid-fail protection, workers that crashed or hung), and the certificates its https bindings serve. From the performance counters, the event logs and `netsh`, with PowerShell alone. Windows only.

**Its page: [packs/iis/README.md](iis/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

## Writing a pack

`tools/new-pack.sh <name>` starts one, and `tools/check-pack.sh --run <name>` says what is left to fix. [CONTRIBUTING.md](../CONTRIBUTING.md#your-first-pack) has the steps. In short:

- Use only what ships with the operating system: bash 3.2 and PowerShell 5.1.
- Print metrics as `metric <name> <value> [key=value ...]`, and use plain ASCII.
- Exit 0 when the script worked. A high reading is not a failure.
- Read data; never change the machine.
- Give it a page of its own, `packs/<name>/README.md`: what it reads, how to turn it on, its jobs, what to alert on and how it was tested, as every pack has, and its grid of metrics (`python tools/pack-grid.py . <name>`).
- Ship text you can read: scripts, and the source of anything they run. Nothing compiled goes in the repository. The one exception is Java, since a JRE cannot run source: a pack for an application that speaks JMX writes its jobs as tables (`_probe.tables`) for the generic probe ([`tools/probe/DESIGN.md`](../tools/probe/DESIGN.md)), which it carries as every such pack does, and only an application whose API needs code of its own (Kafka's admin API) adds a client (`_client.java`). The release compiles them into `_probe.jar` and `_client.jar` (`tools/release/client-jar.sh`), writes their digests into the scripts, and the scripts check them before running them, as the kafka and jvm packs' do. [A pack in Java](../CONTRIBUTING.md#a-pack-in-java) has the rest.
- Start with the same header as the other scripts: what it does, its metrics, an example of its output, what healthy and unhealthy look like, what it needs, its exit codes and the disclaimer.
- In `pack.config`, say what `vigil pack info` shows before anyone installs it: `works_with`, the servers it is meant for and tested with; `programs_linux`, `programs_macos` and `programs_windows`, the programs its scripts need on each; `docs`, its page (`packs/<name>/README.md`); and `needs`, what an administrator sets up first.

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../LICENSE) gives the full terms, and it takes precedence over this summary.
