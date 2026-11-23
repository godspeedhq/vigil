# The elasticsearch pack

An Elasticsearch cluster, from its REST API. The pack reads the cluster's health and Elasticsearch's own health report, every node (its CPU, memory, open files, disk, connections and indexing pressure), the thread pools and the work they refuse, the circuit breakers and how often they trip, every index (its health, size, deleted documents and blocks), every shard and, for an unassigned one, Elasticsearch's own explanation of why, each node's disk against the watermarks and the settings that stop shards moving, the work each node does (indexing, searches, merges, refreshes, caches), the ingest pipelines and their failures, the tasks running and the cluster tasks waiting, index and snapshot lifecycles (ILM, SLM, the data stream lifecycle), the snapshots in each repository, the cluster as a whole with its license, and its transforms, Watcher and enrich. Never its JVM: heap and garbage collection are the [jvm pack](../jvm/README.md)'s. Linux, macOS and Windows.

**It only reads.** Every request is a GET, as a user (or an API key) that may only monitor. Nothing the pack asks for changes the cluster.

**curl and jq, or PowerShell alone.** On Linux and macOS each job reads the API with `curl` and `jq`; on Windows, with PowerShell alone: it speaks HTTP itself, over .NET's own TCP and TLS, so there is nothing to install, on Windows PowerShell 5.1 and PowerShell 7 alike.

1. **A role that may only monitor, and a user with it**, as an administrator (Kibana's Dev Tools, or curl):

   ```json
   PUT _security/role/vigil_monitor
   {
     "cluster": ["monitor", "read_ilm", "read_slm", "monitor_snapshot"],
     "indices": [{ "names": ["*"], "privileges": ["monitor", "view_index_metadata"] }]
   }

   PUT _security/user/vigil
   { "password": "...", "roles": ["vigil_monitor"] }
   ```

   Or an API key with the same privileges, instead of a user: `POST _security/api_key` with `"role_descriptors": { "vigil_monitor": { ...the role above... } }`, and keep the `encoded` value it gives.

2. `vigil pack enable elasticsearch`, then in `vigil.config` set the jobs' `ELASTICSEARCH_URL` (`https://es.example.com:9200`), `ELASTICSEARCH_USER` (`vigil`), and for https with a private CA, `ELASTICSEARCH_CACERT` (the CA's PEM file; on Windows too). Add a secret line to each job, under its `env` lines, and the password:

   ```ini
   secret = ELASTICSEARCH_PASSWORD=secret:ELASTICSEARCH_PASSWORD
   ```

   ```sh
   vigil secret set ELASTICSEARCH_PASSWORD
   ```

   With an API key instead: `secret = ELASTICSEARCH_API_KEY=secret:ELASTICSEARCH_API_KEY`, then `vigil secret set ELASTICSEARCH_API_KEY`, and no `ELASTICSEARCH_USER`.

   The login reaches `curl` on its standard input (its config, `-K -`), and PowerShell in a header made in memory: never on a command line.

**Point it at any node.** Every job reads the whole cluster through the node at `ELASTICSEARCH_URL`; one set of jobs a cluster is enough. A coordinating-only node, or a load balancer in front of the cluster, is a good address.

**A wrong password fails the run, saying so** (HTTP 401). A cluster that does not answer is a reading, `up 0`, and the run succeeds; a cluster with no elected master is a reading too (`status 3`, `master 0`). An address that answers but is not Elasticsearch fails the run, and says when it is OpenSearch (the [opensearch pack](../opensearch/README.md) reads that).

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `jq` | `curl`, `jq` (Homebrew; macOS 15 has it) | Nothing: PowerShell 5.1 or 7 |
| Elasticsearch | 8.x or 9.x, with security on or off | | |
| A user | the `vigil_monitor` role above: cluster `monitor`, `read_ilm`, `read_slm`, `monitor_snapshot`; index `monitor`, `view_index_metadata` on `*` | | |
| A secret | `ELASTICSEARCH_PASSWORD`, or `ELASTICSEARCH_API_KEY` | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `elasticsearch_status` | Whether it answers, its version, the cluster's health (green, yellow, red), its nodes and data nodes, shards active, relocating, initializing and unassigned (primaries apart), the cluster tasks waiting, and the elected master | minute |
| `elasticsearch_health` | Elasticsearch's own health report (8.7 and later): its status, and each indicator's (master, shard availability, disk, shard capacity, repositories, ILM, SLM, data stream lifecycle...) with Elasticsearch's own words for what is wrong | minute |
| `elasticsearch_nodes` | The nodes by role and version, and each node: version and roles, master or not, CPU and load, memory, open files against the limit, its data disk, HTTP and transport connections and traffic, indexing pressure and the writes it refused | minute |
| `elasticsearch_thread_pools` | Each node's thread pools (write, search, get always; others when busy): threads busy, work queued against the queue's size, work refused (HTTP 429), done, threads | minute |
| `elasticsearch_breakers` | Each node's circuit breakers (parent, request, field data, in flight...): what each holds against its limit, and its trips | minute |
| `elasticsearch_indices` | Every index, hidden and data streams' too: how many, open and closed, green, yellow, red, documents, size, those blocked; then each, the worst first: health, documents, deleted share, size, shards, replicas, age, blocks | 5 minutes |
| `elasticsearch_shards` | Every shard by state, the largest (by size and documents, against Elasticsearch's advice), each node's share, each unassigned shard with why and since when, Elasticsearch's own explanation for the first, and the recoveries in progress | minute |
| `elasticsearch_allocation` | Each data node's disk as Elasticsearch weighs it: shards, bytes, used and free, and the watermark it is past; the watermarks themselves; allocation and rebalancing turned off, nodes excluded, and the shard limit against the shards there are | minute |
| `elasticsearch_operations` | Each node's work, as counters: indexing and deletes, searches and fetches, gets, merges, refreshes, flushes, the query, request and field data caches, segments, the translog | minute |
| `elasticsearch_ingest` | The ingest pipelines: documents, failures and time, and each pipeline that has run, the failing first | minute |
| `elasticsearch_tasks` | The tasks running (searches, bulk writes, reindexing, by-query work, snapshots...): how many, the longest, those past a minute, those cancelled but running, each kind; the 20 longest; the cluster tasks waiting | minute |
| `elasticsearch_lifecycle` | ILM: running or not, indices by phase, those whose step failed (with the reason) or stuck on one step; SLM: each policy's last success and failure, failing or not, and why; the data stream lifecycle's errors | 5 minutes |
| `elasticsearch_snapshots` | Each repository (the first 20): its snapshots, failed and partial, the last one's state, age, length and failed shards, the last success; the snapshots being taken | 15 minutes |
| `elasticsearch_cluster` | The cluster as a whole: indices, shards and replication, documents, size, segments, mapped fields, caches, nodes by role, versions, processors, disks, pipelines, plugins; its license and when it expires | 5 minutes |
| `elasticsearch_features` | Transforms (started, failed and why, health), Watcher (where it runs, its watches, those queued), enrich (lookups queued and in flight, policies executing) | 5 minutes |

Past a limit of anything (100 nodes, indices, unassigned shards and pipelines; 200 thread pools; 20 tasks and repositories), the worst first, and the rest counted in a `_not_shown` line. Tasks never show a search's query: only, for reindexing and by-query work, what it reads and writes.


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `elasticsearch.up`.

```text
+--------------------------------------------------------------------------------------------------+
| elasticsearch_status   elasticsearch.<metric>   every 1m                                         |
+---------------------------+----------------------------------------------------------------------+
| up                        | 1 when Elasticsearch answers, else 0                                 |
| version                   | always 1, tagged version=<its version> and cluster=<its name>        |
| status                    | the cluster's health: 0 green, 1 yellow (a replica unassigned), 2    |
|                           | red (a primary unassigned: data missing), 3 when there is no elected |
|                           | master; tagged status=<it>                                           |
| timed_out                 | 1 when the health check timed out                                    |
| nodes                     | nodes in the cluster                                                 |
| data_nodes                | of those, nodes that hold data                                       |
| active_primary_shards     | primary shards active                                                |
| active_shards             | shards active, primaries and replicas                                |
| active_shards_pct         | shards active, as a percentage of all                                |
| relocating_shards         | shards moving between nodes                                          |
| initializing_shards       | shards being created or recovered                                    |
| unassigned_shards         | shards on no node                                                    |
| unassigned_primary_shards | of those, primaries (when Elasticsearch says)                        |
| delayed_unassigned_shards | unassigned shards whose allocation waits, on purpose, for a node to  |
|                           | come back                                                            |
| pending_tasks             | cluster tasks waiting for the master                                 |
| task_max_wait_ms          | how long the oldest of those has waited                              |
| in_flight_fetch           | shard information being fetched from the nodes                       |
| master                    | 1 when a node is the elected master, tagged node=<its name>; 0 when  |
|                           | none is                                                              |
+---------------------------+----------------------------------------------------------------------+
| GOOD  up 1; status 0; unassigned_shards 0; pending_tasks 0.                                      |
| WATCH status 1 for long: replicas unassigned, one node from losing data; relocating_shards or    |
|       initializing_shards for long; task_max_wait_ms in seconds.                                 |
| BAD   up 0; status 2: primaries unassigned, data unreachable (the shards job says which, and     |
|       why); master 0 or status 3: no elected master, the cluster changes nothing.                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| elasticsearch_health   elasticsearch.health.<metric>   every 1m                                  |
+-------------------+------------------------------------------------------------------------------+
| up                | 1 when Elasticsearch answers, else 0                                         |
| served            | 1 when this Elasticsearch has a health report (8.7 and later), else 0        |
| status            | the overall status: 0 green, 1 yellow, 2 red, 3 unknown; tagged status=<it>  |
| indicators_red    | indicators red                                                               |
| indicators_yellow | indicators yellow                                                            |
| indicator         | each indicator's status, the same codes, tagged indicator=<its name> and     |
|                   | symptom=<what Elasticsearch says>                                            |
+-------------------+------------------------------------------------------------------------------+
| GOOD  status 0; every indicator 0.                                                               |
| WATCH An indicator at 1: its symptom says what (disk filling, shards near the limit, a lifecycle |
|       stalled).                                                                                  |
| BAD   status 2: an indicator red; its symptom says what, and Elasticsearch's own health report   |
|       (GET _health_report/<indicator>) says what to do.                                          |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| elasticsearch_nodes   elasticsearch.nodes.<metric>   every 1m                                    |
+-------------------------------+------------------------------------------------------------------+
| up                            | 1 when Elasticsearch answers, else 0                             |
| nodes                         | nodes in the cluster                                             |
| master_eligible               | of those, nodes that may be elected master                       |
| data_nodes                    | nodes that hold data                                             |
| ingest_nodes                  | nodes that run ingest pipelines                                  |
| coordinating_only             | nodes with no role: they only route requests                     |
| versions                      | Elasticsearch versions among the nodes: more than 1 during an    |
|                               | upgrade, or one left behind                                      |
| info                          | always 1, tagged node=<its name>, version=<its version> and      |
|                               | roles=<its roles, as _cat/nodes abbreviates them>                |
| master                        | 1 when the node is the elected master, tagged node=<its name>    |
| cpu_pct                       | the CPU in use on the node's machine (or container), tagged the  |
|                               | same                                                             |
| load_1m                       | its load average over a minute, tagged the same (not on Windows) |
| load_5m                       | over 5 minutes                                                   |
| load_15m                      | over 15 minutes                                                  |
| mem_used_pct                  | the machine's (or container's) memory in use                     |
| process_cpu_pct               | the CPU Elasticsearch's process uses                             |
| open_fds                      | files it has open                                                |
| max_fds                       | files it may have open                                           |
| fds_pct                       | open_fds, as a percentage of max_fds                             |
| disk_total_bytes              | the size of the node's data disks                                |
| disk_free_bytes               | of that, free for Elasticsearch                                  |
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
| elasticsearch_thread_pools   elasticsearch.thread_pools.<metric>   every 1m                      |
+----------------+---------------------------------------------------------------------------------+
| up             | 1 when Elasticsearch answers, else 0                                            |
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
| elasticsearch_breakers   elasticsearch.breakers.<metric>   every 1m                              |
+-----------------+--------------------------------------------------------------------------------+
| up              | 1 when Elasticsearch answers, else 0                                           |
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
| elasticsearch_indices   elasticsearch.indices.<metric>   cron 1/5 * * * *                        |
+---------------------------+----------------------------------------------------------------------+
| up                        | 1 when Elasticsearch answers, else 0                                 |
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
| elasticsearch_shards   elasticsearch.shards.<metric>   every 1m                                  |
+-----------------------+--------------------------------------------------------------------------+
| up                    | 1 when Elasticsearch answers, else 0                                     |
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
| shards_over_50gb      | shards larger than 50 GB, the most Elasticsearch advises                 |
| shards_over_200m_docs | shards of more than 200 million documents, the most Elasticsearch        |
|                       | advises                                                                  |
| node_shards           | shards on a node, tagged node=<its name>                                 |
| unassigned_seconds    | how long a shard has been unassigned, tagged index=<it>, shard=<its      |
|                       | number>, prirep=<p or r> and reason=<why Elasticsearch unassigned it>    |
| explained             | always 1, for the first unassigned shard: Elasticsearch's explanation,   |
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
| elasticsearch_allocation   elasticsearch.allocation.<metric>   every 1m                          |
+------------------------+-------------------------------------------------------------------------+
| up                     | 1 when Elasticsearch answers, else 0                                    |
| shards                 | a node's shards, tagged node=<its name>                                 |
| undesired_shards       | of those, shards the balancer wants elsewhere (Elasticsearch 8.6 and    |
|                        | later)                                                                  |
| disk_indices_bytes     | the bytes its indices take                                              |
| disk_used_bytes        | its disk used, by anything                                              |
| disk_free_bytes        | its disk free                                                           |
| disk_total_bytes       | its disk size                                                           |
| disk_used_pct          | its disk used, as Elasticsearch counts it                               |
| watermark              | the disk watermark it is past: 0 none, 1 low, 2 high, 3 flood stage;    |
|                        | tagged the same                                                         |
| nodes_over_low         | nodes past the low watermark: no new shards come to them                |
| nodes_over_high        | past the high watermark: shards move off them                           |
| nodes_over_flood       | past the flood stage: their indices take no more writes                 |
| watermark_pct          | a watermark set as a percentage of the disk used, tagged level=<low,    |
|                        | high or flood_stage>                                                    |
| watermark_free_bytes   | a watermark set as free space, tagged the same                          |
| disk_threshold_enabled | 1 when Elasticsearch weighs disks at all (the default)                  |
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
| elasticsearch_operations   elasticsearch.operations.<metric>   every 1m                          |
+----------------------------+---------------------------------------------------------------------+
| up                         | 1 when Elasticsearch answers, else 0                                |
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
| elasticsearch_ingest   elasticsearch.ingest.<metric>   every 1m                                  |
+---------------------+----------------------------------------------------------------------------+
| up                  | 1 when Elasticsearch answers, else 0                                       |
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
| elasticsearch_tasks   elasticsearch.tasks.<metric>   every 1m                                    |
+-------------------+------------------------------------------------------------------------------+
| up                | 1 when Elasticsearch answers, else 0                                         |
| tasks             | tasks running                                                                |
| longest_seconds   | how long the longest has run                                                 |
| over_60s          | tasks running for more than a minute                                         |
| cancellable       | tasks that may be cancelled                                                  |
| cancelled         | tasks cancelled but still running                                            |
| searches          | searches running                                                             |
| action_tasks      | tasks of a kind, tagged action=<it> (the 10 most)                            |
| running_seconds   | how long a task has run, tagged action=<it>, node=<where it runs> and        |
|                   | what=<for reindexing and by-query work, what it reads and writes; else none> |
| pending           | cluster tasks waiting for the master                                         |
| pending_oldest_ms | how long the oldest has waited                                               |
| pending_ms        | how long one has waited, tagged priority=<it> and source=<what asked for it> |
|                   | (the 20 oldest)                                                              |
| ..._not_shown     | past 100 of a list (tasks), how many were left out                           |
+-------------------+------------------------------------------------------------------------------+
| GOOD  over_60s 0, but for reindexing, snapshots and force merges you started; pending 0.         |
| WATCH searches running for minutes: an expensive query (searches, and the running_seconds of     |
|       indices:data/read/search); cancelled above 0 for long.                                     |
| BAD   pending above 0 and pending_oldest_ms in seconds: the master falls behind, and mappings,   |
|       settings and shard moves wait; a search running for many minutes, holding memory and       |
|       threads.                                                                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| elasticsearch_snapshots   elasticsearch.snapshots.<metric>   cron 7/15 * * * *                   |
+--------------------------+-----------------------------------------------------------------------+
| up                       | 1 when Elasticsearch answers, else 0                                  |
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
| elasticsearch_cluster   elasticsearch.cluster.<metric>   cron 3/5 * * * *                        |
+----------------------+---------------------------------------------------------------------------+
| up                   | 1 when Elasticsearch answers, else 0                                      |
| indices              | indices                                                                   |
| shards               | shards, primaries and replicas                                            |
| primary_shards       | primaries                                                                 |
| replication          | replicas a primary, on average                                            |
| docs                 | documents, primaries only                                                 |
| deleted_docs         | documents deleted, not yet merged away                                    |
| store_bytes          | the size of every shard                                                   |
| segments             | Lucene segments                                                           |
| fields               | fields every mapping defines, together                                    |
| fielddata_bytes      | memory field data holds                                                   |
| query_cache_bytes    | memory the query cache holds                                              |
| nodes                | nodes                                                                     |
| role_nodes           | nodes with a role, tagged role=<it>                                       |
| versions             | versions the nodes run                                                    |
| version_info         | always 1, for each version, tagged version=<it>                           |
| processors           | processors Elasticsearch uses, every node together                        |
| fs_total_bytes       | data disks, every node together                                           |
| fs_free_bytes        | of those, free                                                            |
| fs_used_pct          | of those, used                                                            |
| pipelines            | ingest pipelines defined                                                  |
| plugins              | plugins installed                                                         |
| license              | always 1, tagged type=<basic, trial, platinum, enterprise...> and         |
|                      | status=<active, expired...>                                               |
| license_expires_days | days until the license expires, when it does                              |
+----------------------+---------------------------------------------------------------------------+
| GOOD  versions 1; fields steady.                                                                 |
| WATCH fields climbing fast: a mapping explosion (dynamic fields from data); replication below 1  |
|       on a cluster of more than one node.                                                        |
| BAD   versions above 1 when no upgrade runs: a node left behind. license_expires_days below 30:  |
|       renew it.                                                                                  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| elasticsearch_lifecycle   elasticsearch.lifecycle.<metric>   cron 2/5 * * * *                    |
+------------------------------+-------------------------------------------------------------------+
| up                           | 1 when Elasticsearch answers, else 0                              |
| ilm_running                  | 1 when ILM runs, tagged mode=<RUNNING, STOPPING or STOPPED>       |
| ilm_managed                  | indices ILM manages                                               |
| ilm_errors                   | of those, with a failed step                                      |
| ilm_stuck                    | on one step (not the wait for a rollover) for more than a day     |
| ilm_in_phase                 | indices in a phase, tagged phase=<hot, warm, cold, frozen or      |
|                              | delete>                                                           |
| ilm_error                    | always 1, for each index whose step failed, tagged index, policy, |
|                              | step=<the step that failed> and reason=<Elasticsearch's reason>   |
|                              | (the first 100)                                                   |
| ilm_error_retries            | times its step was retried, tagged index                          |
| ilm_step_age_seconds         | how long a stuck index has been on its step, tagged index and     |
|                              | step (the 20 longest)                                             |
| slm_running                  | 1 when SLM runs, tagged mode=<it>                                 |
| slm_policies                 | SLM policies                                                      |
| slm_failing                  | 1 when a policy's last run failed, tagged policy=<its name> and   |
|                              | reason=<why>                                                      |
| slm_last_success_age_seconds | since its last snapshot that succeeded, tagged policy             |
| slm_last_failure_age_seconds | since its last failure, tagged policy                             |
| slm_taken                    | snapshots it has taken (a counter), tagged policy                 |
| slm_failed                   | snapshots it failed to take (a counter), tagged policy            |
| slm_next_seconds             | until its next run, tagged policy                                 |
| dlm_data_streams             | data streams the data stream lifecycle manages (8.11 and later)   |
| dlm_backing_indices          | their backing indices                                             |
| dlm_errors                   | of those, in error                                                |
| dlm_error                    | a data stream's backing indices in error, tagged data_stream=<its |
|                              | name>                                                             |
+------------------------------+-------------------------------------------------------------------+
| GOOD  ilm_running and slm_running 1; ilm_errors 0; slm_failing 0 everywhere; dlm_errors 0.       |
| WATCH ilm_stuck above 0: an index waits on a step (a shrink with no node to go to, a replica     |
|       that will not allocate); slm_last_success_age_seconds past the policy's schedule.          |
| BAD   ilm_errors above 0: indices not rolled over, not deleted (disks fill); slm_failing 1: no   |
|       new snapshots (the reason says why); ilm_running 0 left after maintenance.                 |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| elasticsearch_features   elasticsearch.features.<metric>   cron 4/5 * * * *                      |
+--------------------+-----------------------------------------------------------------------------+
| up                 | 1 when Elasticsearch answers, else 0                                        |
| transforms         | transforms                                                                  |
| transforms_started | of those, started or indexing                                               |
| transforms_failed  | failed                                                                      |
| transform_failed   | always 1, for each failed transform, tagged transform=<its id> and          |
|                    | reason=<why>                                                                |
| transform_health   | a transform's health: 0 green, 1 yellow, 2 red, 3 unknown; tagged transform |
| watcher_nodes      | nodes Watcher runs on                                                       |
| watcher_started    | of those, nodes where it is started                                         |
| watches            | watches                                                                     |
| watches_queued     | watch runs waiting for a thread                                             |
| enrich_queued      | enrich lookups queued on the coordinators                                   |
| enrich_in_flight   | enrich lookups in flight                                                    |
| enrich_executing   | enrich policies being executed                                              |
| ..._not_shown      | past 100 of a list (transforms), how many were left out                     |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  transforms_failed 0; watcher_started equal to watcher_nodes; watches_queued near 0.        |
| WATCH transform_health 1; enrich_queued rising: ingest waits for enrich lookups.                 |
| BAD   transforms_failed above 0: the transform stopped (the reason says why); watcher_started 0: |
|       no watch runs, and no alert of Watcher's fires.                                            |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what two clusters in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `elasticsearch.up` | 1 | | 0: the cluster does not answer; a wrong password fails the run instead, saying so | 0 for an address where nothing listened |
| `elasticsearch.status`, `master` | 0; 1 | 1 for long: a replica unassigned | 2: a primary unassigned, data unreachable; 3 or `master` 0: no elected master | 2 on both clusters; 3 and `master 0` with two of three nodes stopped |
| `elasticsearch.health.indicator` | 0 for every indicator | 1: its `symptom` says what | 2: its `symptom` says what; `GET _health_report/<indicator>` says what to do | `shards_availability` 2, `shards_capacity` 2, `disk` 1, each in Elasticsearch's words |
| `elasticsearch.nodes.nodes`, `versions` | As many as you run; 1 | | Fewer: a node left; `versions` above 1 with no upgrade running | 3, then 2 when a node stopped, its shards `delayed_unassigned_shards` |
| `elasticsearch.thread_pools.rejected` | Flat | `queue_pct` above 50 on write or search | Rising: clients get HTTP 429 | 285 refused on 9.5.5's write pools (166 and 119 on two nodes), 203 on 8.19.25's: one write thread, a queue of ten, 200 bulk requests at once |
| `elasticsearch.breakers.tripped`, `used_pct` | Flat; parent below 85 | Parent above 85 | Rising: requests refused (`circuit_breaking_exception`) | `request` tripped on every node, with its limit set to 1 KB |
| `elasticsearch.indices.red`, `write_blocked` | 0; 0 | `yellow` above 0 for long | Above 0: data unreachable; writes fail (often after the flood stage) | `red` 1, `yellow` 1, `write_blocked` 1 (`blocked`) |
| `elasticsearch.shards.unassigned_primaries`, `explained` | 0 | `unassigned_replicas` above 0 for minutes | Above 0: `explained` gives Elasticsearch's reason | `decider=filter why=node does not match index setting [index.routing.allocation.require] filters [_name:"nowhere"]` |
| `elasticsearch.allocation.watermark`, `allocation_enabled`, `exclusions` | 0; 1; 0 | 1 (low): no new shards come; exclusions left after maintenance | 2 (high): shards move off; 3: writes fail; `allocation_enabled` 0 left after a restart | `watermark` 2 on every node; `allocation_enabled 0 setting=primaries`; one exclusion; `shards_capacity_pct` 83.33 on 9.5.5, and 125 on 8.19.25: past its limit, so no index can be created |
| `elasticsearch.ingest.pipeline_failed` | Flat | | Rising: documents refused or indexed with errors | 3 of 6 through `parse` (50%) |
| `elasticsearch.tasks.over_60s`, `pending` | 0, but for work you started; 0 | A search running for minutes | `pending_oldest_ms` in seconds: the master falls behind | A reindex throttled to a crawl, named by what it reads and writes |
| `elasticsearch.lifecycle.ilm_errors`, `slm_failing` | 0; 0 | `ilm_stuck` above 0 | Above 0: indices not rolled over or deleted; no new snapshots | `ilm_error` for a rollover with no alias; `slm_failing` for a read-only repository, both in Elasticsearch's words |
| `elasticsearch.snapshots.last_success_age_seconds` | Within your schedule | | Past it, or absent: no good backup | A snapshot that succeeded, seconds old |
| `elasticsearch.features.transforms_failed` | 0 | | Above 0: a transform stopped | 1, in Elasticsearch's words: a runtime field dividing by zero, for a document that came later |
| `elasticsearch.cluster.license_expires_days` | Far | Below 30 | Below 7 | A basic license: no expiry |

## How it was tested

**Tested** on 2026-11-23 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-elasticsearch.sh`, against `compose.elasticsearch-cluster.yaml`: **Elasticsearch 9.5.5, three nodes, over https** with a CA of its own (so `ELASTICSEARCH_CACERT` is tested), and **Elasticsearch 8.19.25, two nodes**, both with security on, put in trouble on purpose as the elastic user: a role and user that may only monitor (vigil); an index lifecycle that fails (a rollover with no alias); snapshot policies, one to a read-only repository; a transform that fails (a runtime field dividing by zero, for a document that came later); an ingest pipeline that fails half its documents; an index red (a primary no node may take), one yellow, one closed, one blocked for writes; the request breaker tripped; writes refused (one write thread, a queue of ten, 200 bulk requests at once); a reindex throttled to a crawl; and the settings left behind after maintenance: allocation for primaries only, a node excluded, disk watermarks every disk is past, a shard limit nearly reached. The passwords were made by the run and kept out of the evidence.
- **On Fedora**: every job directly as vigil, on both clusters, each reading checked; a wrong password failing the run and saying so; a cluster that does not answer read as `up 0`; then `service-packs.sh` through Vigil (enable, the password as a secret line on every job, every job, a wrong password, a cluster down, the password written nowhere, the metrics reaching the backend); then one node of three stopped (two left, its shards waiting for it), and another (no master: `status 3`, `master 0`): **106 passed, 0 failed**, and through Vigil **21 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/fedora/pack-elasticsearch/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, `jq` 1.8.2), against both clusters through SSH tunnels: every job, **62 passed, 0 failed**; through Vigil, **21 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/macos/pack-elasticsearch-macos/console.txt)).
- **On Windows**, as an account that is not an administrator, against both clusters through SSH tunnels, the CA checked by the scripts' own TLS: on Windows 11 under Windows PowerShell 5.1 and PowerShell 7, **124 passed, 0 failed** directly and **20 passed, 0 failed** through Vigil on each ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows/pack-elasticsearch-windows/console.txt)), and on Windows Server 2025 under Windows PowerShell 5.1, **62 passed, 0 failed** and **20 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows-server-2025/pack-elasticsearch-windows/console.txt)). The Windows scripts printed the same lines, values apart, as the Linux ones against the same clusters.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
