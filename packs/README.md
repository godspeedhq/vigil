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
2. Print its jobs, anywhere, even on a laptop with no pack installed: `vigil pack config nginx --os linux` (or `macos`, `windows`, since each platform's jobs name their own scripts).
3. Paste the block into the configuration the hosts fetch, set what differs per host in the per-host files (and, for secrets kept in a store, change `secret:` to `store:<store>/…`), and commit. Each host picks it up at its next `check_every`.

A host that doesn't have the pack, or has a version without one of its jobs, fails just those jobs, and `vigil precheck` and the job's log say why: `(pack nginx is not installed here: vigil pack install nginx)`. Secrets are placed however the fleet places them (`vigil secret set --stdin` as the service account, the environment, a secret store): Vigil only needs them there, and right, when the job runs.

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
| [`cockroachdb`](cockroachdb/README.md) | CockroachDB, a node or a cluster: health and readiness, clock offset, certificates, ranges unavailable and under-replicated, slow requests, storage and write stalls, admission control, SQL, nodes live and dead, decommissioning, upgrades, jobs, backups and changefeeds | [packs/cockroachdb/README.md](cockroachdb/README.md) |
| [`clickhouse`](clickhouse/README.md) | ClickHouse, a server or a replicated cluster: up, memory, inserts delayed and refused for too many parts, parts per table, replicated tables read-only or behind, replicas missing, mutations failing, merges, parts detached and broken, disks, slow queries and errors by name | [packs/clickhouse/README.md](clickhouse/README.md) |
| [`zookeeper`](zookeeper/README.md) | ZooKeeper, a server or an ensemble: up and serving, one leader, followers in sync, read-only mode, latency, requests waiting, znodes, watches and ephemerals, fsync and JVM pauses, elections | [packs/zookeeper/README.md](zookeeper/README.md) |
| [`mongodb`](mongodb/README.md) | MongoDB, a server or a replica set member: up, connections, operations and latency, the WiredTiger cache, queues; a primary or not, members down, lag, the oplog window; databases; operations running long | [packs/mongodb/README.md](mongodb/README.md) |
| [`cassandra`](cassandra/README.md) | Cassandra over JMX: each node up and normal, gossip and CQL, nodes down, hints; requests, latency, timeouts and unavailables; thread pools, blocked tasks, dropped messages; compactions, SSTables and tombstones per table | [packs/cassandra/README.md](cassandra/README.md) |
| [`oracle`](oracle/README.md) | Oracle Database 19c, 21c and 23ai, a CDB and every PDB: up and open (and why not), sessions and processes against their limits, workload, blocking and transactions left open, waits, every tablespace against the most it can grow to, the recovery area and the archiver, redo, memory and the PGA limit, RMAN backups, invalid objects, corrupt blocks, Scheduler jobs failed, the alert log; nothing from a paid pack | [packs/oracle/README.md](oracle/README.md) |
| [`etcd`](etcd/README.md) | etcd, each member: healthy or not, a leader and quorum, leader changes, members it cannot reach, proposals waiting and failed, the database against its quota (the NOSPACE alarm) and its fragmentation, revisions since compaction, watchers, the WAL's and the backend's disk latency, gRPC requests failed by code | [packs/etcd/README.md](etcd/README.md) |
| [`openbao`](openbao/README.md) | OpenBao and HashiCorp Vault, each node: sealed or not, initialized, active or standby, an unseal under way; the Raft cluster as autopilot sees it (healthy, failure tolerance, the unhealthy node named), followers behind, storage latency; leases and those it could not revoke, tokens by auth method; logins that failed, users locked out, responses refused, audit devices that failed | [packs/openbao/README.md](openbao/README.md) |
| [`traefik`](traefik/README.md) | Traefik: up, configuration reloads, connections and requests on each entrypoint, 4xx and 5xx; backend servers up and down, each named; services and routers answering 5xx; routers, services and middlewares in error, each router named with why; TLS certificates and the soonest to expire | [packs/traefik/README.md](traefik/README.md) |
| [`nginx`](nginx/README.md) | nginx: connections and requests, processes and reloads, an edit not reloaded, how full the workers are, the access log minute by minute (status, errors, response and upstream times), certificate expiry | [packs/nginx/README.md](nginx/README.md) |
| [`httpd`](httpd/README.md) | Apache httpd: workers and the scoreboard, requests, connections, the TLS session cache, an edit not loaded, the access log minute by minute (status, errors, response times), certificate expiry | [packs/httpd/README.md](httpd/README.md) |
| [`caddy`](caddy/README.md) | Caddy: its configuration and reloads, traffic per server, reverse proxy upstreams and their health, the certificate of every site, from its admin API | [packs/caddy/README.md](caddy/README.md) |
| [`haproxy`](haproxy/README.md) | HAProxy: connections, rates, TLS and load; frontends, backends and every server with its health check, queues, times and errors, from its runtime API | [packs/haproxy/README.md](haproxy/README.md) |
| [`phpfpm`](phpfpm/README.md) | PHP-FPM: each pool's workers, listen queue, max_children reached, slow requests, the busiest worker, and a status page that waits because every worker is busy | [packs/phpfpm/README.md](phpfpm/README.md) |
| [`iis`](iis/README.md) | IIS on Windows, with no administrator: sites, application pools and their request queues, worker processes, each site's log and what HTTP.sys turned away, pools stopped by rapid-fail protection and crashed workers, certificate expiry | [packs/iis/README.md](iis/README.md) |
| [`prometheus`](prometheus/README.md) | Prometheus: ready and its configuration loaded, targets up and down for each job, the TSDB and what failed in it, rules that cannot be evaluated and alerts firing, alerts that do not reach an Alertmanager, remote write queues and how far they are behind | [packs/prometheus/README.md](prometheus/README.md) |
| [`alertmanager`](alertmanager/README.md) | Alertmanager: ready and its configuration loaded, alerts and silences, notifications sent and failed for each integration and reason, its cluster (members, peers lost) | [packs/alertmanager/README.md](alertmanager/README.md) |
| [`grafana`](grafana/README.md) | Grafana: healthy (its database too), requests and those that failed, whether each data source answers, its alert rules (evaluated, failed, alerts by state) and their notifications | [packs/grafana/README.md](grafana/README.md) |
| [`loki`](loki/README.md) | Loki: ready and its rings whole, lines received and entries discarded with the reason, streams and chunks, flushes that failed, its compactor and retention | [packs/loki/README.md](loki/README.md) |
| [`mimir`](mimir/README.md) | Grafana Mimir: ready and its rings whole, samples received and discarded with the reason, series in memory, requests failed or refused, blocks shipped, the compactor, the store-gateway and the bucket | [packs/mimir/README.md](mimir/README.md) |
| [`tempo`](tempo/README.md) | Grafana Tempo: ready and its ring whole, spans received, refused and discarded with the reason, live traces, blocks flushed, compaction and retention | [packs/tempo/README.md](tempo/README.md) |
| [`otelcol`](otelcol/README.md) | The OpenTelemetry Collector: what its receivers accept and refuse, what its exporters send and fail to send for each exporter, what is dropped at a full queue, and how full the fullest queue is | [packs/otelcol/README.md](otelcol/README.md) |
| [`victoriametrics`](victoriametrics/README.md) | VictoriaMetrics: up and writable, disk left, rows ingested for each protocol and rows refused with the reason, queries against the concurrency limit, slow and failed ones, the targets it scrapes | [packs/victoriametrics/README.md](victoriametrics/README.md) |
| [`victorialogs`](victorialogs/README.md) | VictoriaLogs: up and writable, disk left, entries ingested for each protocol and entries dropped with the reason, queries against the concurrency limit | [packs/victorialogs/README.md](victorialogs/README.md) |
| [`docker`](docker/README.md) | Docker: whether the engine answers, its containers by state, each container (running, restarts, health, exit code, killed for memory), each one's CPU, memory against its limit, network and disk, and the disk the engine uses (images, containers, volumes, build cache) | [packs/docker/README.md](docker/README.md) |
| [`podman`](podman/README.md) | Podman: whether it answers, its containers by state, each container (running, restarts, health, exit code, killed for memory), each one's CPU, memory against its limit, network and disk, and the disk it uses (images, containers, volumes) | [packs/podman/README.md](podman/README.md) |
| [`sqlite`](sqlite/README.md) | SQLite databases, from their files: there or not, size and free pages, a write-ahead log that keeps growing, a rollback journal left in use, and, when asked, `PRAGMA quick_check` | [packs/sqlite/README.md](sqlite/README.md) |

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

### cockroachdb

CockroachDB, one node or a whole cluster, from its HTTP API, with `curl` and `jq` (on Windows, PowerShell alone), and no SQL client. On every node, from its own metrics with no login: up and ready, version, the nodes it sees live, clock offset, the days left on its certificates, CPU, memory and admission control; its ranges unavailable, under-replicated or decommissioning, and requests stuck; its stores, the LSM's level 0, write stalls and a slow disk; and the SQL it serves. For the cluster, as a user with three read-only system privileges: every node's status, the versions they run and an upgrade left unfinished, and the jobs: backups and changefeeds failed, paused or behind. Linux, macOS and Windows.

**Its page: [packs/cockroachdb/README.md](cockroachdb/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### clickhouse

ClickHouse, one server or a replicated cluster, from its HTTP interface, with `curl` and `jq` (on Windows, PowerShell alone), and no ClickHouse client, as a user the server keeps read-only. Up, memory against its limit, and inserts delayed and refused for too many parts; each table's parts, the most first; replicated tables read-only (Keeper lost), behind, their queues and the replicas missing; mutations that fail and never finish; merges; parts detached, broken ones apart; disks; queries running long, and the errors the server has counted, by name. Linux, macOS and Windows.

**Its page: [packs/clickhouse/README.md](clickhouse/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### zookeeper

Apache ZooKeeper, one server or a whole ensemble, from its four-letter words (`ruok`, `mntr`, `isro`), with bash alone (on Windows, PowerShell alone), no login and no client. Each server up, and serving (a server without its quorum answers, and serves nothing); its role, read-only mode, latency, requests waiting, znodes, watches and ephemerals, file descriptors, the longest fsync and JVM pause, and elections; on the leader, its followers in sync. And the ensemble: servers serving, and one leader. The servers must allow the words (`4lw.commands.whitelist=mntr,ruok,isro`). Linux, macOS and Windows.

**Its page: [packs/zookeeper/README.md](zookeeper/README.md)**, with how to set it up, the job, what to alert on, and how it was tested.

### mongodb

MongoDB, a server or a member of a replica set, with `mongosh`, as a user with MongoDB's own `clusterMonitor` role (it reads the server's state, none of its data). Up, connections, operations and their latency, the WiredTiger cache and how dirty it is, operations queued; the replica set as each member sees it: a primary or not, members down, how far each is behind, the oplog's window; databases and their size; and the operations running past a minute, by namespace and ID, never their text. Each job is a script mongosh runs with no connection of its own, so the password is never on a command line. Linux, macOS and Windows.

**Its page: [packs/mongodb/README.md](mongodb/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### cassandra

Apache Cassandra, every node, over JMX, with the probe every JMX pack shares (Java 11 or later on the Vigil machine, nothing of Cassandra's). Each node up and in normal operation (or draining, leaving, decommissioned), gossip and CQL, the nodes it sees down, hints for nodes that were away; the requests it coordinates, their latency, those that timed out or found too few replicas; its thread pools, blocked tasks, dropped messages; its compactions and, for each of the application's tables, its SSTables, how many a read looks in, and the tombstones a read scans. On localhost with no password, or with a read-only JMX user. Linux, macOS and Windows.

**Its page: [packs/cassandra/README.md](cassandra/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### oracle

Oracle Database 19c, 21c or 23ai, a container database and its pluggable databases or one that is not a CDB, on this machine or any it can reach, through SQL*Plus from Oracle Instant Client, as a user with Oracle's own read-only `SELECT_CATALOG_ROLE`. Only Oracle's basic views: nothing from the Diagnostics or Tuning Pack, so running it never makes a database owe Oracle a license. The password goes to SQL*Plus on its standard input, and Oracle Net's encryption is required. Linux, macOS and Windows.

**Its page: [packs/oracle/README.md](oracle/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### etcd

An etcd member, each one, from its metrics listener (`--listen-metrics-urls`, plain HTTP, as kubeadm sets it up): healthy or not, and why not (no leader, or an alarm such as NOSPACE); a leader and quorum, leader changes, members it cannot reach; proposals waiting and failed; the database against its quota; how fast its disk is where etcd needs it. With `curl` and `awk` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/etcd/README.md](etcd/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### openbao

OpenBao, or HashiCorp Vault (the two answer the same paths and publish the same metrics, so one pack reads both, and says which), each node. With no token: sealed or not, initialized, active or standby, how far an unseal has got. With a token that may read `sys/metrics` and nothing else: the Raft cluster as autopilot sees it, storage latency, leases and those it could not revoke, logins that failed and users locked out. With `curl` and `awk` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/openbao/README.md](openbao/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### traefik

A Traefik proxy, from its Prometheus metrics and its read-only API on the `traefik` entrypoint: up, its requests and 5xx, the backend servers its health checks find down (each by its URL), the services and routers that fail, the routers in its configuration that are broken and why, and the certificate that expires first. With `curl`, `awk` and `jq` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/traefik/README.md](traefik/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

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

### prometheus

A Prometheus server, from what it says about itself. The pack reads whether it is ready and its last configuration reload worked; its targets, up and down, for each job; its TSDB (the series in its head, its WAL, its blocks, and everything that failed); its rules (evaluations that failed, for each group, and the alerts firing); the alerts it sends to its Alertmanagers and those that do not get there; and its remote write queues, with how far the slowest remote is behind. Every request is a GET. With `curl` and `awk` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/prometheus/README.md](prometheus/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### alertmanager

An Alertmanager, from what it says about itself. The pack reads whether it is ready and its configuration loaded; the alerts and silences it holds; the notifications it sent and those that failed, for each integration and each reason; and its view of its cluster: the members it sees and the peers it has lost. Every request is a GET. With `curl` and `awk` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/alertmanager/README.md](alertmanager/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### grafana

A Grafana, from what it says about itself and, for its data sources, from its API with a read-only token. The pack reads whether it is healthy (its database too); the requests it answered and those that failed; its database connections; whether each data source answers; and its own alerting: rules evaluated and failed, alerts in each state, and the notifications that got through and did not. Every request is a GET. With `curl` and `awk` and, for its data sources, `jq` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/grafana/README.md](grafana/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### loki

A Loki, from what it says about itself. The pack reads whether it is ready and its rings whole; the lines and bytes it received, and the entries it discarded with the reason for each; the streams and chunks its ingester holds, and whether its chunks reach storage; and its compactor: when it last ran, whether retention is applied, and the delete requests waiting. Every request is a GET. With `curl` and `awk` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/loki/README.md](loki/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### mimir

A Grafana Mimir, from what it says about itself. The pack reads whether it is ready and its rings whole; the samples it received, and those it discarded with the reason for each; the series its ingester holds; the requests it failed or refused to protect itself; and what happens to its data afterwards: blocks shipped to the bucket, the compactor, the store-gateway, and the bucket itself. Every request is a GET. With `curl` and `awk` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/mimir/README.md](mimir/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### tempo

A Grafana Tempo, from what it says about itself. The pack reads whether it is ready and its ingester ring whole; the spans it received, those its receivers refused and those it discarded, with the reason for each; the traces it holds live and the blocks it flushes; and its storage: compaction, retention and the list of blocks. Every request is a GET. With `curl` and `awk` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/tempo/README.md](tempo/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### otelcol

An OpenTelemetry Collector, from what it says about itself. The pack reads what its receivers accepted and refused, for spans, metric points and log records and for each receiver; what its exporters delivered and could not, for each exporter; what was dropped because a queue was full; and how full the fullest queue is. Every request is a GET. With `curl` and `awk` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/otelcol/README.md](otelcol/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### victoriametrics

A VictoriaMetrics server, from what it says about itself. The pack reads whether it answers and whether its storage has gone read-only for lack of disk; the disk space left; what it ingests for each protocol, and what it refuses or ignores and why; its queries against the limit on running at once, the slow ones and those that failed; and the targets it scrapes itself. Every request is a GET. With `curl` and `awk` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/victoriametrics/README.md](victoriametrics/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### victorialogs

A VictoriaLogs server, from what it says about itself. The pack reads whether it answers and whether its storage has gone read-only for lack of disk; the disk space left; the log entries and bytes it ingests for each protocol; the entries it dropped and why; and its queries against the limit on running at once. Every request is a GET. With `curl` and `awk` (on Windows, PowerShell alone). Linux, macOS and Windows.

**Its page: [packs/victorialogs/README.md](victorialogs/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### docker

A Docker engine, from its own API: whether it answers; every container's state; each container by name (running or not, restarts, healthy or not, the exit code it ended with, killed for memory); what each running container uses (CPU, memory against its limit, processes, network and disk); and the disk the engine takes (images, containers, volumes, the build cache). Every request is a GET: nothing is started, stopped, removed or pruned. With `curl` and `jq` (on Windows, PowerShell alone). Linux, macOS and Windows, Linux and Windows containers.

**Its page: [packs/docker/README.md](docker/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### podman

Podman, asked with its own command, as the account Vigil runs as (root's containers as root, an account's own when rootless): whether it answers; every container's state; each container by name (running or not, restarts, healthy or not, the exit code it ended with, killed for memory); what each running container uses; and the disk it takes (images, containers, volumes). It only reads: nothing is started, stopped, removed or pruned. With `podman` and `jq`. Linux and macOS.

**Its page: [packs/podman/README.md](podman/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

### sqlite

SQLite databases, the files an application keeps them in: each one there or not, its size, its free pages (space a `VACUUM` would give back), its write-ahead log (one that keeps growing is a reader that never lets a checkpoint finish), and a rollback journal still in use long after a transaction should have ended. It reads each database's first 100 bytes and the sizes and times of its files, with no SQLite library and no lock: nothing the application can notice. Only when asked, once a day, `PRAGMA quick_check`, read-only, with `sqlite3`. Linux, macOS and Windows.

**Its page: [packs/sqlite/README.md](sqlite/README.md)**, with how to set it up, each job, what to alert on, and how it was tested.

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
