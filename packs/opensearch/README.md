# The opensearch pack

An OpenSearch cluster, from its REST API. The pack reads the cluster's health and its elected cluster manager, every node (its CPU, memory, open files, disk, connections and indexing pressure), the thread pools and the work they refuse, the circuit breakers and how often they trip, OpenSearch's own protections under load (search backpressure, shard indexing pressure, admission control), every index (its health, size, deleted documents and blocks), every shard and, for an unassigned one, OpenSearch's own explanation of why, each node's disk against the watermarks and the settings that stop shards moving, the work each node does (indexing, searches, merges, refreshes, caches), the ingest pipelines and their failures, the tasks running and the cluster tasks waiting, Index State Management and snapshot management, the snapshots in each repository, and the cluster as a whole. Never its JVM: heap and garbage collection are the [jvm pack](../jvm/README.md)'s. Linux, macOS and Windows.

**It only reads.** Every request is a GET, as a user that may only monitor. Nothing the pack asks for changes the cluster.

**curl and jq, or PowerShell alone.** On Linux and macOS each job reads the API with `curl` and `jq`; on Windows, with PowerShell alone: it speaks HTTP itself, over .NET's own TCP and TLS, so there is nothing to install, on Windows PowerShell 5.1 and PowerShell 7 alike, and the security plugin's certificates are checked against your CA (`OPENSEARCH_CACERT`) there too.

1. **A role that may only monitor, and a user with it**, with the security plugin, as an administrator (OpenSearch Dashboards' Dev Tools, or curl):

   ```json
   PUT _plugins/_security/api/roles/vigil_monitor
   {
     "cluster_permissions": [
       "cluster_monitor",
       "cluster:admin/repository/get", "cluster:admin/snapshot/get", "cluster:admin/snapshot/status",
       "cluster:admin/opendistro/ism/managedindex/explain",
       "cluster:admin/opensearch/snapshot_management/policy/get",
       "cluster:admin/opensearch/snapshot_management/policy/search",
       "cluster:admin/opensearch/snapshot_management/policy/explain"
     ],
     "index_permissions": [{
       "index_patterns": ["*"],
       "allowed_actions": ["indices_monitor", "indices:admin/get", "indices:monitor/settings/get"]
     }]
   }

   PUT _plugins/_security/api/internalusers/vigil
   { "password": "...", "backend_roles": [] }

   PUT _plugins/_security/api/rolesmapping/vigil_monitor
   { "users": ["vigil"] }
   ```

   Or map the role to a user or a backend role your own authentication already has.

2. `vigil pack enable opensearch`, then in `vigil.config` set the jobs' `OPENSEARCH_URL` (`https://search.example.com:9200`), `OPENSEARCH_USER` (`vigil`), and for https with a private CA (the security plugin's own, say), `OPENSEARCH_CACERT` (the CA's PEM file; on Windows too). Add a secret line to each job, under its `env` lines, and the password:

   ```ini
   secret = OPENSEARCH_PASSWORD=secret:OPENSEARCH_PASSWORD
   ```

   ```sh
   vigil secret set OPENSEARCH_PASSWORD
   ```

   The login reaches `curl` on its standard input (its config, `-K -`), and PowerShell in a header made in memory: never on a command line.

**Point it at any node.** Every job reads the whole cluster through the node at `OPENSEARCH_URL`; one set of jobs a cluster is enough. A coordinating node, or a load balancer in front of the cluster, is a good address. Without the security plugin, leave `OPENSEARCH_USER` empty and add no secret.

**A wrong password fails the run, saying so** (HTTP 401). A cluster that does not answer is a reading, `up 0`, and the run succeeds; a cluster with no elected cluster manager is a reading too (`status 3`, `cluster_manager 0`). An address that answers but is not OpenSearch fails the run, and says when it is Elasticsearch (the [elasticsearch pack](../elasticsearch/README.md) reads that).

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `jq` | `curl`, `jq` (Homebrew; macOS 15 has it) | Nothing: PowerShell 5.1 or 7 |
| OpenSearch | 2.x or 3.x, with the security plugin on or off | | |
| A user | the `vigil_monitor` role above | | |
| A secret | `OPENSEARCH_PASSWORD` | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `opensearch_status` | Whether it answers, its version, the cluster's health (green, yellow, red), its nodes and data nodes, shards active, relocating, initializing and unassigned, the cluster tasks waiting, and the elected cluster manager | minute |
| `opensearch_nodes` | The nodes by role and version, and each node: version and roles, cluster manager or not, CPU and load, memory, open files against the limit, its data disk, HTTP and transport connections and traffic, indexing pressure and the writes it refused | minute |
| `opensearch_thread_pools` | Each node's thread pools (write, search, get always; others when busy): threads busy, work queued against the queue's size, work refused (HTTP 429), done, threads | minute |
| `opensearch_breakers` | Each node's circuit breakers (parent, request, field data, in flight...): what each holds against its limit, and its trips | minute |
| `opensearch_backpressure` | Each node's search backpressure (its mode, and the searches it cancelled for CPU, time or heap), shard indexing pressure (on, enforced, the writes it refused) and admission control (the requests it refused for CPU, I/O or memory) | minute |
| `opensearch_indices` | Every index, hidden and data streams' too: how many, open and closed, green, yellow, red, documents, size, those blocked; then each, the worst first: health, documents, deleted share, size, shards, replicas, age, blocks | 5 minutes |
| `opensearch_shards` | Every shard by state, the largest (by size and documents), each node's share, each unassigned shard with why and since when, OpenSearch's own explanation for the first, and the recoveries in progress | minute |
| `opensearch_allocation` | Each data node's disk as OpenSearch weighs it: shards, bytes, used and free, and the watermark it is past; the watermarks themselves; allocation and rebalancing turned off, nodes excluded, and the shard limit against the shards there are | minute |
| `opensearch_operations` | Each node's work, as counters: indexing and deletes, searches and fetches, gets, merges, refreshes, flushes, the query, request and field data caches, segments, the translog | minute |
| `opensearch_ingest` | The ingest pipelines: documents, failures and time, and each pipeline that has run, the failing first | minute |
| `opensearch_tasks` | The tasks running (searches, bulk writes, reindexing, by-query work, snapshots...): how many, the longest, those past a minute, those cancelled but running, each kind; the 20 longest; the cluster tasks waiting | minute |
| `opensearch_lifecycle` | Index State Management: the indices it manages by state, those whose action failed (with OpenSearch's message) and those it no longer runs; snapshot management: each policy's last snapshot, failing or not and why, and its next | 5 minutes |
| `opensearch_snapshots` | Each repository (the first 20): its snapshots, failed and partial, the last one's state, age, length and failed shards, the last success; the snapshots being taken | 15 minutes |
| `opensearch_cluster` | The cluster as a whole: indices, shards and replication, documents, size, segments, mapped fields, caches, nodes by role, versions, processors, disks, pipelines, plugins | 5 minutes |

Past a limit of anything (100 nodes, indices, unassigned shards and pipelines; 200 thread pools; 20 tasks and repositories), the worst first, and the rest counted in a `_not_shown` line. Tasks never show a search's query: only, for reindexing and by-query work, what it reads and writes.


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `opensearch.up`.

```text
+--------------------------------------------------------------------------------------------------+
| opensearch_status   opensearch.<metric>   every 1m                                               |
+---------------------------+----------------------------------------------------------------------+
| up                        | 1 when OpenSearch answers, else 0                                    |
| version                   | always 1, tagged version=<its version> and cluster=<its name>        |
| status                    | the cluster's health: 0 green, 1 yellow (a replica unassigned), 2    |
|                           | red (a primary unassigned: data missing), 3 when there is no elected |
|                           | cluster manager; tagged status=<it>                                  |
| timed_out                 | 1 when the health check timed out                                    |
| nodes                     | nodes in the cluster                                                 |
| data_nodes                | of those, nodes that hold data                                       |
| active_primary_shards     | primary shards active                                                |
| active_shards             | shards active, primaries and replicas                                |
| active_shards_pct         | shards active, as a percentage of all                                |
| relocating_shards         | shards moving between nodes                                          |
| initializing_shards       | shards being created or recovered                                    |
| unassigned_shards         | shards on no node                                                    |
| unassigned_primary_shards | of those, primaries (when OpenSearch says)                           |
| delayed_unassigned_shards | unassigned shards whose allocation waits, on purpose, for a node to  |
|                           | come back                                                            |
| pending_tasks             | cluster tasks waiting for the cluster manager                        |
| task_max_wait_ms          | how long the oldest of those has waited                              |
| in_flight_fetch           | shard information being fetched from the nodes                       |
| cluster_manager           | 1 when a node is the elected cluster manager, tagged node=<its       |
|                           | name>; 0 when none is                                                |
+---------------------------+----------------------------------------------------------------------+
| GOOD  up 1; status 0; unassigned_shards 0; pending_tasks 0.                                      |
| WATCH status 1 for long: replicas unassigned, one node from losing data; relocating_shards or    |
|       initializing_shards for long; task_max_wait_ms in seconds.                                 |
| BAD   up 0; status 2: primaries unassigned, data unreachable (the shards job says which, and     |
|       why); cluster_manager 0 or status 3: no elected cluster manager, the cluster changes       |
|       nothing.                                                                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| opensearch_nodes   opensearch.nodes.<metric>   every 1m                                          |
+-------------------------------+------------------------------------------------------------------+
| up                            | 1 when OpenSearch answers, else 0                                |
| nodes                         | nodes in the cluster                                             |
| master_eligible               | of those, nodes that may be elected cluster manager              |
| data_nodes                    | nodes that hold data                                             |
| ingest_nodes                  | nodes that run ingest pipelines                                  |
| coordinating_only             | nodes with no role: they only route requests                     |
| versions                      | OpenSearch versions among the nodes: more than 1 during an       |
|                               | upgrade, or one left behind                                      |
| info                          | always 1, tagged node=<its name>, version=<its version> and      |
|                               | roles=<its roles, as _cat/nodes abbreviates them>                |
| cluster_manager               | 1 when the node is the elected cluster manager, tagged node=<its |
|                               | name>                                                            |
| cpu_pct                       | the CPU in use on the node's machine (or container), tagged the  |
|                               | same                                                             |
| load_1m                       | its load average over a minute, tagged the same (not on Windows) |
| load_5m                       | over 5 minutes                                                   |
| load_15m                      | over 15 minutes                                                  |
| mem_used_pct                  | the machine's (or container's) memory in use                     |
| process_cpu_pct               | the CPU OpenSearch's process uses                                |
| open_fds                      | files it has open                                                |
| max_fds                       | files it may have open                                           |
| fds_pct                       | open_fds, as a percentage of max_fds                             |
| disk_total_bytes              | the size of the node's data disks                                |
| disk_free_bytes               | of that, free for OpenSearch                                     |
| disk_used_pct                 | the data disks in use                                            |
| http_open                     | HTTP connections open                                            |
| http_opened                   | HTTP connections opened since it started (a counter)             |
| transport_open                | connections open to the other nodes                              |
| transport_rx_bytes            | bytes received from the other nodes (a counter)                  |
| transport_tx_bytes            | bytes sent to them (a counter)                                   |
| indexing_pressure_bytes       | memory held by writes in flight on the node                      |
| indexing_pressure_limit_bytes | the most it may hold                                             |
| indexing_pressure_pct         | indexing_pressure_bytes, as a percentage of the limit            |
| indexing_rejections           | writes refused for it, since the node started (a counter)        |
| ..._not_shown                 | past 100 of a list (nodes), how many were left out               |
+-------------------------------+------------------------------------------------------------------+
| GOOD  nodes as many as you run; versions 1; fds_pct and disk_used_pct well below 80;             |
|       indexing_rejections flat.                                                                  |
| WATCH cpu_pct high on one node only: a hot shard; fds_pct above 80; disk_used_pct nearing the    |
|       disk watermarks (the allocation job); indexing_pressure_pct above 50.                      |
| BAD   nodes below what you run: a node left; versions above 1 when no upgrade runs;              |
|       indexing_rejections rising: writes refused, clients see HTTP 429.                          |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| opensearch_thread_pools   opensearch.thread_pools.<metric>   every 1m                            |
+----------------+---------------------------------------------------------------------------------+
| up             | 1 when OpenSearch answers, else 0                                               |
| rejected_total | work refused by every pool of every node, since each started (a counter)        |
| queued_total   | work waiting in every pool now                                                  |
| active_total   | threads busy in every pool now                                                  |
| active         | a pool's threads busy, tagged node=<its name> and pool=<the pool>               |
| queue          | its work waiting, tagged the same                                               |
| queue_pct      | queue, as a percentage of the queue's size, when it has one                     |
| rejected       | its work refused, since the node started (a counter)                            |
| completed      | its work done (a counter)                                                       |
| threads        | its threads                                                                     |
| largest        | the most threads it has had at once                                             |
| ..._not_shown  | past 100 of a list (pools), how many were left out                              |
+----------------+---------------------------------------------------------------------------------+
| GOOD  rejected_total flat; queue near 0 most of the time.                                        |
| WATCH queue_pct above 50 on the write or search pool: the node falls behind.                     |
| BAD   rejected rising on write: writes refused, clients see HTTP 429 (bulk requests partly       |
|       fail); on search: searches refused.                                                        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| opensearch_breakers   opensearch.breakers.<metric>   every 1m                                    |
+-----------------+--------------------------------------------------------------------------------+
| up              | 1 when OpenSearch answers, else 0                                              |
| tripped_total   | trips of every breaker of every node, since each started (a counter)           |
| max_used_pct    | the fullest breaker, as a percentage of its limit                              |
| estimated_bytes | what a breaker holds, tagged node=<its name> and breaker=<the breaker>         |
| limit_bytes     | its limit, tagged the same                                                     |
| used_pct        | estimated_bytes, as a percentage of the limit                                  |
| tripped         | its trips, since the node started (a counter)                                  |
| ..._not_shown   | past 100 of a list (breakers), how many were left out                          |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  tripped_total flat; the parent breaker's used_pct below 85.                                |
| WATCH the parent breaker's used_pct above 85: the node is short of memory for what it is asked.  |
| BAD   tripped rising: requests refused (HTTP 429, circuit_breaking_exception); on parent, the    |
|       node's memory is too small for its load; on fielddata, a text field aggregated.            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| opensearch_indices   opensearch.indices.<metric>   cron 1/5 * * * *                              |
+---------------------------+----------------------------------------------------------------------+
| up                        | 1 when OpenSearch answers, else 0                                    |
| indices                   | indices                                                              |
| open                      | of those, open                                                       |
| closed                    | closed                                                               |
| green                     | green: every shard assigned                                          |
| yellow                    | yellow: a replica unassigned                                         |
| red                       | red: a primary unassigned                                            |
| hidden                    | indices whose names start with a dot (hidden, and data streams'      |
|                           | backing indices)                                                     |
| docs                      | documents in every index, primaries only                             |
| deleted_docs              | documents deleted but not yet merged away                            |
| store_bytes               | the size of every index, replicas too                                |
| primary_store_bytes       | the size of the primaries alone                                      |
| blocked                   | indices with a block of any kind                                     |
| write_blocked             | indices that take no writes: a write, read_only or                   |
|                           | read_only_allow_delete block                                         |
| health                    | an index's health: 0 green, 1 yellow, 2 red; tagged index=<its name> |
| is_open                   | 1 when it is open, tagged the same                                   |
| index_docs                | its documents, primaries only                                        |
| deleted_pct               | its deleted documents, as a percentage of all                        |
| index_store_bytes         | its size, replicas too                                               |
| index_primary_store_bytes | its primaries' size                                                  |
| primaries                 | its primary shards                                                   |
| replicas                  | its replicas of each                                                 |
| age_days                  | days since it was created                                            |
| block                     | always 1, for each block it has, tagged index=<its name> and         |
|                           | block=<the block>                                                    |
| ..._not_shown             | past 100 of a list (indices), how many were left out                 |
+---------------------------+----------------------------------------------------------------------+
| GOOD  red 0; yellow 0 (on a cluster of more than one node); write_blocked 0.                     |
| WATCH deleted_pct above 30 on a large index: space held by deleted documents until merges; an    |
|       index far larger than the rest.                                                            |
| BAD   red above 0: data unreachable (the shards job says why); write_blocked above 0: writes to  |
|       it fail, often after a disk passed the flood stage (free space, then clear the block).     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| opensearch_shards   opensearch.shards.<metric>   every 1m                                        |
+-----------------------+--------------------------------------------------------------------------+
| up                    | 1 when OpenSearch answers, else 0                                        |
| shards                | shards, primaries and replicas                                           |
| primaries             | of those, primaries                                                      |
| replicas              | replicas                                                                 |
| started               | shards started                                                           |
| relocating            | shards moving to another node                                            |
| initializing          | shards being created or recovered                                        |
| unassigned            | shards on no node                                                        |
| unassigned_primaries  | of those, primaries: their data is unreachable                           |
| unassigned_replicas   | replicas                                                                 |
| largest_shard_bytes   | the largest shard                                                        |
| largest_shard_docs    | the most documents in a shard                                            |
| shards_over_50gb      | shards larger than 50 GB, the most OpenSearch advises                    |
| shards_over_200m_docs | shards of more than 200 million documents, the most OpenSearch advises   |
| node_shards           | shards on a node, tagged node=<its name>                                 |
| unassigned_seconds    | how long a shard has been unassigned, tagged index=<it>, shard=<its      |
|                       | number>, prirep=<p or r> and reason=<why OpenSearch unassigned it>       |
| explained             | always 1, for the first unassigned shard: OpenSearch's explanation,      |
|                       | tagged index, shard, prirep, can_allocate=<no, yes, throttled,           |
|                       | awaiting_info...>, decider=<what refused it> and why=<its words>         |
| recoveries            | shard recoveries in progress                                             |
| recovery_pct          | how far one has come, in bytes, tagged index, shard, type=<why it        |
|                       | recovers> and stage=<where it is>                                        |
| recovery_ms           | how long it has run, tagged the same                                     |
| ..._not_shown         | past 100 of a list (unassigned, recoveries), how many were left out      |
+-----------------------+--------------------------------------------------------------------------+
| GOOD  unassigned 0; relocating and initializing 0 most of the time; shards_over_50gb 0.          |
| WATCH unassigned_replicas above 0 for minutes: a node gone, or replicas the cluster cannot place |
|       (explained says why); recoveries running for long; shards_over_50gb above 0: split the     |
|       index, or roll it over sooner.                                                             |
| BAD   unassigned_primaries above 0: data unreachable; explained says why (a node gone, a disk    |
|       full, a filter no node matches, a corrupt shard).                                          |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| opensearch_allocation   opensearch.allocation.<metric>   every 1m                                |
+------------------------+-------------------------------------------------------------------------+
| up                     | 1 when OpenSearch answers, else 0                                       |
| shards                 | a node's shards, tagged node=<its name>                                 |
| undesired_shards       | of those, shards the balancer wants elsewhere (Elasticsearch 8.6 and    |
|                        | later)                                                                  |
| disk_indices_bytes     | the bytes its indices take                                              |
| disk_used_bytes        | its disk used, by anything                                              |
| disk_free_bytes        | its disk free                                                           |
| disk_total_bytes       | its disk size                                                           |
| disk_used_pct          | its disk used, as OpenSearch counts it                                  |
| watermark              | the disk watermark it is past: 0 none, 1 low, 2 high, 3 flood stage;    |
|                        | tagged the same                                                         |
| nodes_over_low         | nodes past the low watermark: no new shards come to them                |
| nodes_over_high        | past the high watermark: shards move off them                           |
| nodes_over_flood       | past the flood stage: their indices take no more writes                 |
| watermark_pct          | a watermark set as a percentage of the disk used, tagged level=<low,    |
|                        | high or flood_stage>                                                    |
| watermark_free_bytes   | a watermark set as free space, tagged the same                          |
| disk_threshold_enabled | 1 when OpenSearch weighs disks at all (the default)                     |
| allocation_enabled     | 1 when shards may be allocated (cluster.routing.allocation.enable all), |
|                        | tagged setting=<all, primaries, new_primaries or none>                  |
| rebalance_enabled      | 1 when shards may be rebalanced (cluster.routing.rebalance.enable all), |
|                        | tagged setting=<it>                                                     |
| exclusions             | allocation filters excluding nodes (cluster.routing.allocation.exclude) |
| exclusion              | always 1, for each, tagged attribute=<_name, _ip, _host or yours> and   |
|                        | value=<what is excluded>                                                |
| max_shards_per_node    | the cluster's limit of open shards a data node                          |
| shards_capacity_pct    | the cluster's shards, as a percentage of the limit for its data nodes:  |
|                        | at 100, no index can be created                                         |
| ..._not_shown          | past 100 of a list (nodes), how many were left out                      |
+------------------------+-------------------------------------------------------------------------+
| GOOD  watermark 0 on every node; allocation_enabled and rebalance_enabled 1; exclusions 0;       |
|       shards_capacity_pct below 80.                                                              |
| WATCH nodes_over_low above 0: that node takes no new shards; exclusions above 0 after            |
|       maintenance; undesired_shards staying above 0.                                             |
| BAD   nodes_over_high above 0: shards moving off a full disk; nodes_over_flood above 0: writes   |
|       to its indices fail; allocation_enabled 0 left after a restart: replicas stay unassigned;  |
|       shards_capacity_pct near 100: new indices fail.                                            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| opensearch_operations   opensearch.operations.<metric>   every 1m                                |
+----------------------------+---------------------------------------------------------------------+
| up                         | 1 when OpenSearch answers, else 0                                   |
| docs                       | documents in the node's shards, tagged node=<its name>              |
| store_bytes                | the size of the node's shards                                       |
| index_total                | documents indexed (a counter)                                       |
| index_time_ms              | time spent indexing (a counter)                                     |
| index_current              | documents being indexed now                                         |
| index_failed               | documents that failed to index (a counter)                          |
| delete_total               | documents deleted (a counter)                                       |
| index_throttle_ms          | time indexing was throttled for merges (a counter)                  |
| query_total                | search queries, each shard counted (a counter)                      |
| query_time_ms              | time spent in them (a counter)                                      |
| query_current              | queries running now                                                 |
| fetch_total                | fetches of search hits (a counter)                                  |
| fetch_time_ms              | time spent in them (a counter)                                      |
| scroll_current             | scrolls open now                                                    |
| open_contexts              | search contexts open now (scrolls and point-in-time searches)       |
| get_total                  | gets by id (a counter)                                              |
| get_missing                | of those, for documents that were not there (a counter)             |
| get_time_ms                | time spent in gets (a counter)                                      |
| merges_current             | segment merges running now                                          |
| merges_total               | merges (a counter)                                                  |
| merges_time_ms             | time spent merging (a counter)                                      |
| merges_throttled_ms        | time merges were throttled (a counter)                              |
| refresh_total              | refreshes (a counter)                                               |
| refresh_time_ms            | time spent refreshing (a counter)                                   |
| flush_total                | flushes (a counter)                                                 |
| flush_time_ms              | time spent flushing (a counter)                                     |
| query_cache_bytes          | memory the query cache holds                                        |
| query_cache_hits           | query cache hits (a counter)                                        |
| query_cache_misses         | its misses (a counter)                                              |
| query_cache_evictions      | its evictions (a counter)                                           |
| request_cache_bytes        | memory the request cache holds                                      |
| request_cache_hits         | request cache hits (a counter)                                      |
| request_cache_misses       | its misses (a counter)                                              |
| request_cache_evictions    | its evictions (a counter)                                           |
| fielddata_bytes            | memory field data holds                                             |
| fielddata_evictions        | its evictions (a counter)                                           |
| segments                   | Lucene segments in the node's shards                                |
| translog_ops               | operations in the translog                                          |
| translog_bytes             | its size                                                            |
| translog_uncommitted_bytes | of that, not yet committed to Lucene                                |
| ..._not_shown              | past 100 of a list (nodes), how many were left out                  |
+----------------------------+---------------------------------------------------------------------+
| GOOD  index_failed flat; query_time_ms rising in step with query_total; merges_throttled_ms and  |
|       index_throttle_ms flat.                                                                    |
| WATCH query_time_ms rising faster than query_total: queries slow down; index_throttle_ms rising: |
|       merges cannot keep up with indexing; query_cache_evictions or fielddata_evictions          |
|       climbing.                                                                                  |
| BAD   index_failed rising: documents refused (mapping conflicts, ingest failures); open_contexts |
|       climbing without end: scrolls or point-in-time searches never closed.                      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| opensearch_ingest   opensearch.ingest.<metric>   every 1m                                        |
+---------------------+----------------------------------------------------------------------------+
| up                  | 1 when OpenSearch answers, else 0                                          |
| count               | documents through any pipeline, every node (a counter)                     |
| failed              | of those, failed (a counter)                                               |
| time_ms             | time spent in pipelines (a counter)                                        |
| current             | documents in a pipeline now                                                |
| failed_pct          | failed, as a percentage of count                                           |
| pipelines           | pipelines that have run                                                    |
| pipeline_count      | a pipeline's documents, tagged pipeline=<its name> (a counter)             |
| pipeline_failed     | its failures (a counter)                                                   |
| pipeline_failed_pct | its failures, as a percentage of its documents                             |
| pipeline_time_ms    | its time (a counter)                                                       |
| pipeline_avg_ms     | its average time a document                                                |
| ..._not_shown       | past 100 of a list (pipelines), how many were left out                     |
+---------------------+----------------------------------------------------------------------------+
| GOOD  failed flat.                                                                               |
| WATCH pipeline_avg_ms rising: a pipeline slows every write through it.                           |
| BAD   pipeline_failed rising: documents refused, or indexed with an error (a grok pattern that   |
|       no longer matches, a field of a type the pipeline did not expect).                         |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| opensearch_tasks   opensearch.tasks.<metric>   every 1m                                          |
+-------------------+------------------------------------------------------------------------------+
| up                | 1 when OpenSearch answers, else 0                                            |
| tasks             | tasks running                                                                |
| longest_seconds   | how long the longest has run                                                 |
| over_60s          | tasks running for more than a minute                                         |
| cancellable       | tasks that may be cancelled                                                  |
| cancelled         | tasks cancelled but still running                                            |
| searches          | searches running                                                             |
| action_tasks      | tasks of a kind, tagged action=<it> (the 10 most)                            |
| running_seconds   | how long a task has run, tagged action=<it>, node=<where it runs> and        |
|                   | what=<for reindexing and by-query work, what it reads and writes; else none> |
| pending           | cluster tasks waiting for the cluster manager                                |
| pending_oldest_ms | how long the oldest has waited                                               |
| pending_ms        | how long one has waited, tagged priority=<it> and source=<what asked for it> |
|                   | (the 20 oldest)                                                              |
| ..._not_shown     | past 100 of a list (tasks), how many were left out                           |
+-------------------+------------------------------------------------------------------------------+
| GOOD  over_60s 0, but for reindexing, snapshots and force merges you started; pending 0.         |
| WATCH searches running for minutes: an expensive query (searches, and the running_seconds of     |
|       indices:data/read/search); cancelled above 0 for long.                                     |
| BAD   pending above 0 and pending_oldest_ms in seconds: the cluster manager falls behind, and    |
|       mappings, settings and shard moves wait; a search running for many minutes, holding memory |
|       and threads.                                                                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| opensearch_snapshots   opensearch.snapshots.<metric>   cron 7/15 * * * *                         |
+--------------------------+-----------------------------------------------------------------------+
| up                       | 1 when OpenSearch answers, else 0                                     |
| repositories             | snapshot repositories                                                 |
| running                  | snapshots being taken now                                             |
| readable                 | 1 when the cluster could list a repository, tagged repository=<its    |
|                          | name>                                                                 |
| snapshots                | its snapshots, tagged the same                                        |
| failed                   | of those, failed                                                      |
| partial                  | partial: some shards missing                                          |
| last_status              | the last one's state: 0 SUCCESS, 1 IN_PROGRESS, 2 PARTIAL, 3 FAILED,  |
|                          | 4 other; tagged repository and status=<it>                            |
| last_age_seconds         | since the last one ended (or started, while it runs)                  |
| last_duration_seconds    | how long it took                                                      |
| last_failed_shards       | its shards that failed                                                |
| last_success_age_seconds | since the last that succeeded ended; absent when none has             |
| ..._not_shown            | past 100 of a list (repositories), how many were left out             |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  last_status 0; last_success_age_seconds within your snapshot schedule.                     |
| WATCH partial above 0; last_duration_seconds growing.                                            |
| BAD   last_success_age_seconds past your schedule, or absent: no good backup; last_status 3;     |
|       readable 0: the repository is gone or broken.                                              |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| opensearch_cluster   opensearch.cluster.<metric>   cron 3/5 * * * *                              |
+-------------------+------------------------------------------------------------------------------+
| up                | 1 when OpenSearch answers, else 0                                            |
| indices           | indices                                                                      |
| shards            | shards, primaries and replicas                                               |
| primary_shards    | primaries                                                                    |
| replication       | replicas a primary, on average                                               |
| docs              | documents, primaries only                                                    |
| deleted_docs      | documents deleted, not yet merged away                                       |
| store_bytes       | the size of every shard                                                      |
| segments          | Lucene segments                                                              |
| fields            | fields every mapping defines, together                                       |
| fielddata_bytes   | memory field data holds                                                      |
| query_cache_bytes | memory the query cache holds                                                 |
| nodes             | nodes                                                                        |
| role_nodes        | nodes with a role, tagged role=<it>                                          |
| versions          | versions the nodes run                                                       |
| version_info      | always 1, for each version, tagged version=<it>                              |
| processors        | processors OpenSearch uses, every node together                              |
| fs_total_bytes    | data disks, every node together                                              |
| fs_free_bytes     | of those, free                                                               |
| fs_used_pct       | of those, used                                                               |
| pipelines         | ingest pipelines defined                                                     |
| plugins           | plugins installed                                                            |
+-------------------+------------------------------------------------------------------------------+
| GOOD  versions 1; fields steady.                                                                 |
| WATCH fields climbing fast: a mapping explosion (dynamic fields from data); replication below 1  |
|       on a cluster of more than one node.                                                        |
| BAD   versions above 1 when no upgrade runs: a node left behind.                                 |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| opensearch_backpressure   opensearch.backpressure.<metric>   every 1m                            |
+---------------------------+----------------------------------------------------------------------+
| up                        | 1 when OpenSearch answers, else 0                                    |
| search_mode               | search backpressure: 0 disabled, 1 monitor only, 2 enforced; tagged  |
|                           | node=<its name> and mode=<it>                                        |
| search_cancellations      | searches it cancelled, every kind (a counter), tagged node           |
| search_limit_reached      | times it would have cancelled but reached its limit (a counter),     |
|                           | tagged node                                                          |
| search_cancelled_for      | shard searches cancelled for one reason (a counter), tagged node and |
|                           | reason=<cpu_usage, elapsed_time or heap_usage>                       |
| shard_indexing_enabled    | 1 when shard indexing pressure is on, tagged node                    |
| shard_indexing_enforced   | 1 when it is enforced, not only counted, tagged node                 |
| shard_indexing_rejections | writes it refused (or, not enforced, would have), tagged node and    |
|                           | limit=<which>                                                        |
| admission_rejections      | requests admission control refused (a counter), tagged node,         |
|                           | controller=<cpu, io or native memory> and action=<indexing or        |
|                           | search>                                                              |
| ..._not_shown             | past 100 of a list (nodes), how many were left out                   |
+---------------------------+----------------------------------------------------------------------+
| GOOD  search_cancellations and admission_rejections flat.                                        |
| WATCH search_cancellations rising in monitor-only mode: enforced, those searches would fail;     |
|       shard_indexing_rejections rising while not enforced.                                       |
| BAD   search_cancellations rising in enforced mode: searches fail; admission_rejections rising:  |
|       the node refuses requests for its CPU or I/O.                                              |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| opensearch_lifecycle   opensearch.lifecycle.<metric>   cron 2/5 * * * *                          |
+---------------------+----------------------------------------------------------------------------+
| up                  | 1 when OpenSearch answers, else 0                                          |
| ism_managed         | indices ISM manages                                                        |
| ism_failed          | of those, whose action failed                                              |
| ism_disabled        | whose policy ISM no longer runs (it stops after an action fails for good)  |
| ism_in_state        | indices in a state of their policy, tagged state=<its name>                |
| ism_failure         | always 1, for each index whose action failed, tagged index, policy,        |
|                     | action=<it> and reason=<OpenSearch's message> (the first 100)              |
| ism_retries         | times its action was retried, tagged index                                 |
| sm_policies         | snapshot management policies                                               |
| sm_enabled          | of those, on                                                               |
| sm_last_status      | a policy's last snapshot: 0 SUCCESS, 1 IN_PROGRESS or RETRYING, 2          |
|                     | TIME_LIMIT_EXCEEDED, 3 FAILED, 4 none yet; tagged policy=<its name> and    |
|                     | status=<it>                                                                |
| sm_failing          | 1 when its last snapshot failed, tagged policy and reason=<why, or         |
|                     | not_given when OpenSearch does not say>                                    |
| sm_last_age_seconds | since its last snapshot ended (or began), tagged policy                    |
| sm_next_seconds     | until its next snapshot, tagged policy                                     |
| sm_deletion_failing | 1 when its last deletion of old snapshots failed, tagged policy            |
| ..._not_shown       | past 100 of a list (ism), how many were left out                           |
+---------------------+----------------------------------------------------------------------------+
| GOOD  ism_failed 0; every sm_last_status 0, sm_failing 0.                                        |
| WATCH ism_disabled above 0: ISM gave up on those indices; sm_last_age_seconds past the policy's  |
|       schedule.                                                                                  |
| BAD   ism_failed above 0: indices not rolled over or deleted, disks fill (the reason says why);  |
|       sm_failing 1: no new snapshots (the reason says why); sm_last_status 4 for long on a red   |
|       cluster: snapshot management skips every run until it is green or yellow.                  |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what two clusters in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `opensearch.up` | 1 | | 0: the cluster does not answer; a wrong password fails the run instead, saying so | 0 for an address where nothing listened |
| `opensearch.status`, `cluster_manager` | 0; 1 | 1 for long: a replica unassigned | 2: a primary unassigned, data unreachable; 3 or `cluster_manager` 0: none elected | 2 on both clusters; 3 and `cluster_manager 0` with two of three nodes stopped |
| `opensearch.nodes.nodes`, `versions` | As many as you run; 1 | | Fewer: a node left; `versions` above 1 with no upgrade running | 3, then 2 when a node stopped |
| `opensearch.thread_pools.rejected` | Flat | `queue_pct` above 50 on write or search | Rising: clients get HTTP 429 | @REJ@ |
| `opensearch.breakers.tripped`, `used_pct` | Flat; parent below 85 | Parent above 85 | Rising: requests refused (`circuit_breaking_exception`) | `request` tripped, with its limit set to 1 KB |
| `opensearch.backpressure.search_cancellations`, `admission_rejections` | Flat | Rising in monitor-only mode: enforced, those searches would fail | Rising when enforced: searches fail, requests refused | Search backpressure in monitor-only mode on every node, nothing cancelled |
| `opensearch.indices.red`, `write_blocked` | 0; 0 | `yellow` above 0 for long | Above 0: data unreachable; writes fail (often after the flood stage) | `red` 1, `yellow` 1, `write_blocked` 1 |
| `opensearch.shards.unassigned_primaries`, `explained` | 0 | `unassigned_replicas` above 0 for minutes | Above 0: `explained` gives OpenSearch's reason | `decider=filter why=node does not match index setting [index.routing.allocation.require] filters [_name:"nowhere"]` |
| `opensearch.allocation.watermark`, `allocation_enabled`, `exclusions` | 0; 1; 0 | 1 (low): no new shards come; exclusions left after maintenance | 2 (high): shards move off; 3: writes fail; `allocation_enabled` 0 left after a restart | `watermark` 2 on every node; `allocation_enabled 0 setting=primaries`; one exclusion; `shards_capacity_pct` near 100 |
| `opensearch.ingest.pipeline_failed` | Flat | | Rising: documents refused or indexed with errors | 3 of 6 through `parse` (50%) |
| `opensearch.tasks.over_60s`, `pending` | 0, but for work you started; 0 | A search running for minutes | `pending_oldest_ms` in seconds: the cluster manager falls behind | A reindex throttled to a crawl, named by what it reads and writes |
| `opensearch.lifecycle.ism_failed`, `sm_failing` | 0; 0 | `ism_disabled` above 0: ISM gave up | Above 0: indices not rolled over or deleted; no new snapshots | `ism_failure` for a rollover with no alias; `sm_failing` for a read-only repository, both in OpenSearch's words |
| `opensearch.snapshots.last_success_age_seconds` | Within your schedule | | Past it, or absent: no good backup | Snapshots every minute, by snapshot management |

**Snapshot management skips every run while the cluster is red** (OpenSearch logs "Skipping current execution ... because of red cluster health"), and may then hold its lock for a long while. A red cluster soon shows as old snapshots too: alert on `last_success_age_seconds`, not only on `sm_failing`.

## How it was tested

**Tested** on 2026-11-23 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-opensearch.sh`, against `compose.opensearch-cluster.yaml`: **OpenSearch 3.10.0, three nodes**, and **OpenSearch 2.19.7, two nodes**, both with the security plugin on, over https with its demo certificates (so `OPENSEARCH_CACERT` is tested), put in trouble on purpose as admin: a role of the security plugin that may only monitor, and a user with it (vigil); Index State Management that fails (a rollover with no alias); snapshot management to a repository and to a read-only one, given time to act before the cluster turned red; an ingest pipeline that fails half its documents; an index red (a primary no node may take), one yellow, one closed, one blocked for writes; the request breaker tripped; writes refused (one write thread, a queue of ten, 200 bulk requests at once); a reindex throttled to a crawl; and the settings left behind after maintenance: allocation for primaries only, a node excluded, disk watermarks every disk is past, a shard limit nearly reached. The passwords were made by the run and kept out of the evidence.
- **On Fedora**: every job directly as vigil, on both clusters, each reading checked; a wrong password failing the run and saying so; a cluster that does not answer read as `up 0`; then `service-packs.sh` through Vigil (enable, the password as a secret line on every job, every job, a wrong password, a cluster down, the password written nowhere, the metrics reaching the backend); then one node of three stopped (two left), and another (no cluster manager: `status 3`, `cluster_manager 0`): **@FD@**, and through Vigil **@FV@** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/fedora/pack-opensearch/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, `jq` 1.8.2), against both clusters through SSH tunnels: every job, **@MD@**; through Vigil, **@MV@** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/macos/pack-opensearch-macos/console.txt)).
- **On Windows**, as an account that is not an administrator, against both clusters through SSH tunnels, the demo CA checked by the scripts' own TLS: on Windows 11 under Windows PowerShell 5.1 and PowerShell 7, **@WD@** directly and **@WV@** through Vigil on each ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows/pack-opensearch-windows/console.txt)), and on Windows Server 2025 under Windows PowerShell 5.1, **@SD@** and **@SV@** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows-server-2025/pack-opensearch-windows/console.txt)). The Windows scripts printed the same lines, values apart, as the Linux ones against the same clusters.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
