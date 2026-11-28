# The nats pack

A NATS server and its JetStream, from its monitoring port. The pack reads whether the server answers and is healthy, its connections against its limit, the slow consumers it has cut off and the client with the most waiting; whether its cluster routes reach every other server, each named; and for JetStream, its storage and memory against their limits, its API errors, whether the cluster has a meta leader, and, from the server that leads each one, the streams with no leader, the replicas behind, the streams near their own limits, and the consumers falling behind, each named.

NATS is quiet when it fails. A subscriber that cannot keep up is cut off, and its messages are gone: the publisher never hears about it. A consumer falls behind by a few thousand messages an hour, and nobody notices until the backlog is a day old. A stream reaches its limit and starts dropping its oldest messages, or refusing new ones, exactly as configured. A cluster loses a server and carries on; it loses a second, and every stream stops taking writes. Each of these is in what the server says about itself, by name, and the pack reads it.

**Read-only: every request is a GET.** The pack reads NATS's own pages and changes nothing, whatever its login would allow. It needs `curl` and `awk` (and `jq` for the data sources) on Linux and macOS, and nothing but PowerShell on Windows.

1. Turn on the monitoring port: `-m 8222` on the command line, or `http: 8222` in the configuration. It answers with no login, so keep it on a private address. The pack reads it from the same machine or network.
2. `vigil pack enable nats`, and where the monitoring port is not `http://localhost:8222`, set `NATS_URL` in the jobs' `env` lines. On Linux and macOS the jobs need `jq`. In a cluster, enable the pack beside each server: each reports itself, and the streams and consumers it leads.

**NATS that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (a login refused on a page every job needs, or something that is not HTTP), and says why.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `awk`, `jq` | `curl`, `awk` (built in), `jq` (Homebrew; macOS 15 has it) | Nothing: PowerShell 5.1 or later, and .NET |
| NATS | NATS Server 2.10 and later, alone or in a cluster, with or without JetStream (tested: 2.15.3, a cluster of three, and 2.14.10 alone) | | |
| Its address | reachable from the Vigil machine: `NATS_URL` (default `http://localhost:8222`) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `nats_status` | Up and healthy; its name, version, cluster and JetStream; since it started and since its configuration loaded; connections against max_connections; subscriptions; slow consumers cut off, by kind; stale connections; messages and bytes in and out; the client with the most bytes waiting, named | minute |
| `nats_cluster` | In a cluster or not; the routes configured; the other servers it has routes to, each named; route connections, bytes waiting on them, the slowest round trip; leaf nodes | minute |
| `nats_jetstream` | JetStream on or off; storage and memory against their limits; streams, consumers, messages and bytes on this server; API calls and errors; the meta leader, known or not, and on it the servers behind, named; from the server that leads each: streams with no leader, replicas behind, each stream's size and how full against its limits, consumers' messages not given, not acked and redelivered, each named | minute |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `nats.up`.

```text
+--------------------------------------------------------------------------------------------------+
| nats_status   nats.<metric>   every 1m                                                           |
+------------------------------+-------------------------------------------------------------------+
| up                           | 1 when the server answered, else 0 (and nothing more is read)     |
| healthy                      | 1 when /healthz answers ok; 0 when it answers 503: not ready, or  |
|                              | JetStream not current with its cluster                            |
| info                         | always 1, tagged server=<its name>, version=, cluster=<its name,  |
|                              | or none> and jetstream=<on or off>                                |
| uptime_seconds               | since the server started                                          |
| last_reload_seconds          | since its configuration last loaded (started, or reloaded)        |
| connections                  | clients connected                                                 |
| max_connections              | the most it allows (max_connections)                              |
| connections_pct              | connections, of max_connections                                   |
| total_connections_count      | clients that have connected (a running total)                     |
| subscriptions                | subscriptions, routes' and the system's included                  |
| slow_consumers_count         | connections it cut off for not reading fast enough (a running     |
|                              | total)                                                            |
| slow_consumer_clients_count  | of them, clients (a running total; 2.10 and later, as the next    |
|                              | three)                                                            |
| slow_consumer_routes_count   | routes to other servers of its cluster                            |
| slow_consumer_gateways_count | gateways to other clusters                                        |
| slow_consumer_leafs_count    | leaf nodes                                                        |
| stale_connections_count      | connections closed for not answering its pings (a running total)  |
| in_msgs_count                | messages received, from clients and other servers (a running      |
|                              | total)                                                            |
| out_msgs_count               | messages sent (a running total)                                   |
| in_bytes_count               | bytes received (a running total)                                  |
| out_bytes_count              | bytes sent (a running total)                                      |
| pending_bytes_max            | bytes waiting to be sent to the client furthest behind, tagged    |
|                              | client=<its name, or address:port>                                |
+------------------------------+-------------------------------------------------------------------+
| GOOD  up 1; healthy 1; connections_pct well below 80; slow_consumers_count flat;                 |
|       pending_bytes_max small.                                                                   |
| WATCH connections_pct above 80; pending_bytes_max growing: that client is falling behind (client |
|       says which).                                                                               |
| BAD   up 0 or healthy 0; slow_consumers_count moving: the server is cutting off clients (or      |
|       routes) that cannot keep up, and they lose messages; connections_pct near 100: new clients |
|       are refused.                                                                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| nats_cluster   nats.cluster.<metric>   every 1m                                                  |
+---------------------+----------------------------------------------------------------------------+
| up                  | 1 when the server answered, else 0 (and nothing more is read)              |
| clustered           | 1 when it has a cluster port; 0 alone (and nothing more is read)           |
| routes_configured   | routes in its configuration (cluster.routes): the servers it is told to    |
|                     | reach                                                                      |
| route_peers         | other servers of its cluster it has a route to                             |
| route_peer          | always 1, one line for each of them, tagged peer=<its name>                |
| route_connections   | route connections: with route pooling (2.10 and later), several to each    |
|                     | server                                                                     |
| route_pending_bytes | bytes waiting to be sent on its routes                                     |
| route_rtt_max_ms    | the slowest route's round trip, in milliseconds                            |
| leafnodes           | leaf node connections                                                      |
| ..._not_shown       | past 100 of a list (route_peer), how many were left out                    |
+---------------------+----------------------------------------------------------------------------+
| GOOD  route_peers the cluster's size less one, steady; route_pending_bytes near 0.               |
| WATCH route_rtt_max_ms well above its usual; route_pending_bytes growing.                        |
| BAD   route_peers below the cluster's size less one: a server is down or cut off (route_peer     |
|       says which are there); with JetStream, a cluster that loses more than half its servers     |
|       stops accepting writes.                                                                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| nats_jetstream   nats.jetstream.<metric>   every 1m                                              |
+------------------------+-------------------------------------------------------------------------+
| up                     | 1 when the server answered, else 0 (and nothing more is read)           |
| jetstream              | 1 when JetStream is on; 0 (and nothing more) when it is off             |
| memory_bytes           | memory its streams use                                                  |
| storage_bytes          | file storage its streams use                                            |
| max_memory_bytes       | the memory it may use (max_memory_store)                                |
| max_storage_bytes      | the file storage it may use (max_file_store)                            |
| memory_pct             | memory_bytes, of max_memory_bytes                                       |
| storage_pct            | storage_bytes, of max_storage_bytes                                     |
| streams                | streams on this server, replicas included                               |
| consumers              | consumers on this server, replicas included                             |
| messages               | messages in them                                                        |
| bytes                  | bytes in them                                                           |
| api_count              | JetStream API calls (a running total)                                   |
| api_errors_count       | of them, errors: a stream full, a stream or consumer not found, no      |
|                        | leader (a running total)                                                |
| meta_cluster_size      | servers in the JetStream cluster                                        |
| meta_leader_known      | 1 when it knows the meta leader; 0: no leader, so no stream or consumer |
|                        | can be made or changed                                                  |
| meta_is_leader         | 1 on the meta leader                                                    |
| meta_replicas_behind   | on the meta leader: servers not current with it, or offline (a few      |
|                        | seconds after a new leader is elected)                                  |
| meta_behind            | always 1, one line for each, tagged server=<its name>                   |
| streams_led            | streams this server leads: the rest below are theirs                    |
| streams_no_leader      | streams it holds a replica of that have no leader: they take no writes  |
| stream_replicas_behind | replicas of its streams not current with it                             |
| stream_behind          | always 1, one line for each, tagged stream= and replica=<the server>    |
| stream_messages        | messages in a stream, tagged stream= (the 20 largest)                   |
| stream_bytes           | bytes in a stream, tagged stream=                                       |
| stream_used_pct        | how full a stream with limits is, of max_bytes or max_msgs, whichever   |
|                        | is fuller, tagged stream=                                               |
| consumers_led          | consumers this server leads                                             |
| consumers_pending      | messages their consumers have not been given yet, all together          |
| consumers_ack_pending  | messages given and not acked yet, all together                          |
| consumers_redelivered  | messages given more than once, all together                             |
| consumer_pending       | one consumer's messages not given yet, tagged stream= and consumer=     |
|                        | (the 20 furthest behind)                                                |
| consumer_ack_pending   | one consumer's messages given and not acked                             |
| consumer_redelivered   | one consumer's messages given more than once                            |
| ..._not_shown          | past 100 of a list (meta_behind, stream_behind, stream,                 |
|                        | stream_used_pct, consumer_pending, consumer_ack_pending,                |
|                        | consumer_redelivered), how many were left out                           |
+------------------------+-------------------------------------------------------------------------+
| GOOD  jetstream 1; storage_pct and memory_pct below 75; meta_leader_known 1; streams_no_leader   |
|       0; stream_replicas_behind 0; consumer_pending steady or falling.                           |
| WATCH storage_pct or memory_pct above 75; a stream_used_pct above 90 (at its limit it drops its  |
|       oldest messages, or refuses new ones); consumer_pending growing run after run: that        |
|       consumer is falling behind; consumer_redelivered growing: its messages are not being acked |
|       in time.                                                                                   |
| BAD   meta_leader_known 0 or streams_no_leader above 0: the cluster has lost its majority, and   |
|       those streams take no writes; stream_replicas_behind above 0 for long: a server is down or |
|       cannot keep up (stream_behind says which); storage_pct near 100: publishes to its streams  |
|       fail; api_errors_count moving fast.                                                        |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the stack in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `nats.up`, `nats.healthy` | 1 |  | 0: the server does not answer, or is not ready (JetStream not current with its cluster) | `healthy 0` on n1 alone, its two peers stopped |
| `nats.slow_consumers_count`, `slow_consumer_clients_count` | Flat |  | Moving: the server is cutting off clients that cannot keep up, and they lose messages | 2, the client that subscribed and stopped reading |
| `nats.connections_pct` | Well below 80 | Above 80 | Near 100: new clients are refused | 75: 15 clients of the 20 allowed |
| `nats.cluster.route_peers`, `route_peer` (by `peer`) | The cluster's size less one |  | Lower: a server is down or cut off; `route_peer` says which are there | 1, only `peer=n2`, with n3 stopped |
| `nats.jetstream.meta_leader_known` | 1 |  | 0: the cluster has lost its majority: no stream or consumer can be made or changed | 0 on n1 alone |
| `nats.jetstream.streams_no_leader` | 0 |  | Above 0: those streams take no writes | 2, both streams, on n1 alone |
| `nats.jetstream.stream_replicas_behind`, `stream_behind` (by `stream`, `replica`) | 0 | Above 0 for a minute | Above 0 for long: a server is down or cannot keep up | 2: `ORDERS` and `LIMITED`, `replica=n3`, with n3 stopped; `meta_behind 1 server=n3` on the meta leader |
| `nats.jetstream.storage_pct`, `memory_pct` | Below 75 | Above 75 | Near 100: publishes to its streams fail | Above 80 on the 2.14 server given 2 MB, with 4 MB published |
| `nats.jetstream.stream_used_pct` (by `stream`) | Below 90 | Above 90 |  | 98.94 for `LIMITED`, at its 64 KB, refusing more (discard new) |
| `nats.jetstream.consumer_pending` (by `stream`, `consumer`) | Steady or falling | Growing run after run: that consumer is falling behind |  | 450 for `billing`: 500 published, 50 fetched |
| `nats.jetstream.consumer_ack_pending`, `consumer_redelivered` | Low | Redelivered growing: messages not acked within the ack wait |  | 50 and 50 for `billing`: fetched, never acked, redelivered after its 2 s wait |

## How it was tested

**Tested** on 2026-11-28 by `tests/integration/backends/scripts/run-nats.sh`, against `compose.nats.yaml`: a JetStream **cluster of three NATS 2.15.3** servers; **NATS 2.14.10** alone, given 2 MB of file storage and 20 connections at most; and NATS 2.15.3 with neither JetStream nor a cluster. With `nats-box`, it made on the cluster a stream of 500 orders (three replicas) with a consumer whose messages were fetched and not acked, then redelivered after its 2-second ack wait; a stream limited to 64 KB, filled; and a client that subscribed and stopped reading, which the server cut off. On the 2.14 server, 4 MB published into its 2 MB, and 15 clients connected.

- **On Fedora** (Fedora 44, bash 5.3, jq 1.8): every job against every server, and what each read: healthy, routes to the two others named, one meta leader, each stream counted once by its leader, the consumer's 450 not given, 50 not acked and its redeliveries, the stream at its limit, the slow client cut off; the 2.14 server's connections and storage; the plain server's JetStream off. Then n3 stopped: n1's one peer named, both streams' replicas on n3 behind, the meta leader naming n3; then n2 too: no meta leader, both streams with no leader, not healthy; then both back. And nothing listening. **33 passed, 0 failed**; then `service-packs.sh` through Vigil: **12 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/fedora/pack-nats/console.txt)).
- **On Windows**, on the HP test machine (Windows 11) as an account that is not an administrator, against the same servers through SSH tunnels: every job under Windows PowerShell 5.1 and PowerShell 7, the same checks: **44 passed, 0 failed**; the same metric names and tags as the Linux scripts, every stream, consumer and peer included, for all 3 jobs against all 5 servers, under both shells (30 of 30); through Vigil, **10 passed, 0 failed** under each ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/windows/pack-nats-windows/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own awk, jq 1.8.2), the same: **22 passed, 0 failed**; through Vigil, **12 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/macos/pack-nats-macos/console.txt)).

**What the tests found.** Each server of a cluster lists the streams and consumers it holds a replica of, and only the leader's view of the replicas is current: a follower showed a healthy replica as not current. So the pack reads a stream or a consumer only on the server that leads it, and a cluster's are counted once. Route pooling (2.10 and later) opens several connections to each server, so `num_routes` read 8 for two peers: the pack counts the servers by name. A server with JetStream off still answers `/jsz`, with `disabled` and a configuration of zeros. After a new meta leader is elected, it takes a few seconds to mark a stopped server offline: right after n3 (the old leader) stopped, the new one still counted it current.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
