# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""Writes packs/cassandra: Apache Cassandra, over JMX, as tables for the
probe (tools/probe/packgen.py). Its rows are below, once. Run from the
repository: python tools/cassandra/gen.py ."""
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[1], 'tools', 'probe'))
import packgen  # noqa: E402

SS = 'org.apache.cassandra.db:type=StorageService'
FD = 'org.apache.cassandra.net:type=FailureDetector'
M = 'org.apache.cassandra.metrics:'
CR = M + 'type=ClientRequest,scope=*,name='
TP = M + 'type=ThreadPools,path=*,scope=*,name='
TB = M + 'type=Table,keyspace=*,scope=*,name='
# The application's tables: Cassandra's own keyspaces left out.
APP = 'keyspace scope -keyspace=system* top'

JOBS = [
    dict(job='status', metric_name='cassandra', when='run_every   = 1m', title="a Cassandra node's health",
         what="Reports whether each node answers over JMX, its version and mode (normal, or joining, leaving, "
              "draining, drained, decommissioned), whether gossip and the native protocol (CQL) are running, the "
              "nodes it sees up and down, the data it holds, exceptions, hints kept for nodes that were away, "
              "clients connected, and the commit log.",
         rows=[('version', SS, 'ReleaseVersion', '@version', "always 1, tagged version=<Cassandra's version, 5.0.9>"),
               ('mode', SS, 'OperationMode', '@mode', 'always 1, tagged mode=<NORMAL, JOINING, LEAVING, DRAINING, DRAINED, DECOMMISSIONED>'),
               ('normal', SS, 'OperationMode', '=NORMAL', '1 when the node is in normal operation, else 0'),
               ('gossip_up', SS, 'GossipRunning', '=true', '1 when gossip is running, else 0 (the node is cut off from the ring)'),
               ('native_up', SS, 'NativeTransportRunning', '=true', '1 when the native protocol (CQL) takes clients, else 0'),
               ('nodes_up', FD, 'UpEndpointCount', '', 'nodes this one sees up, itself included'),
               ('nodes_down', FD, 'DownEndpointCount', '', 'nodes this one sees down'),
               ('load_bytes', M + 'type=Storage,name=Load', 'Count', '', 'the data this node holds on disk'),
               ('exceptions_count', M + 'type=Storage,name=Exceptions', 'Count', '', 'errors Cassandra caught (a running total)'),
               ('hints_count', M + 'type=Storage,name=TotalHints', 'Count', '', 'hints written for nodes that were down (a running total)'),
               ('hints_in_progress', M + 'type=Storage,name=TotalHintsInProgress', 'Count', '', 'hints being sent now'),
               ('clients', M + 'type=Client,name=connectedNativeClients', 'Value', '', 'CQL clients connected'),
               ('commitlog_pending', M + 'type=CommitLog,name=PendingTasks', 'Value', '', 'commit log writes waiting'),
               ('commitlog_bytes', M + 'type=CommitLog,name=TotalCommitLogSize', 'Value', '', 'the commit log on disk')],
         healthy="normal 1, gossip_up and native_up 1; nodes_down 0; hints_in_progress 0; exceptions_count flat.",
         watch="hints_count rising (a node was away: it is catching up); commitlog_pending above 0 for several runs.",
         act="the node down over JMX; normal 0 (draining, leaving, decommissioned); gossip_up or native_up 0; "
             "nodes_down above 0: a node is down, and with it, requests at QUORUM may fail."),
    dict(job='requests', metric_name='cassandra.requests', when='run_every   = 1m', title="a Cassandra node's requests as a coordinator",
         what="Reports the requests each node coordinates, by kind (Read, Write, RangeSlice, CASRead, CASWrite and "
              "the rest): how many, their latency (the 99th percentile and the mean), and those that timed out, "
              "found too few replicas up (unavailable), or failed.",
         rows=[('requests_count', CR + 'Latency', 'Count', 'scope -scope=*-*', 'requests coordinated (a running total), tagged scope=<Read, Write, RangeSlice, ...> (the counts Cassandra keeps per consistency level, Write-ALL and the like, left out)'),
               ('latency_p99_ms', CR + 'Latency', '99thPercentile', 'scope -scope=*-* *0.001', 'the 99th percentile of their latency, tagged the same'),
               ('latency_mean_ms', CR + 'Latency', 'Mean', 'scope -scope=*-* *0.001', 'their mean latency, tagged the same'),
               ('timeouts_count', CR + 'Timeouts', 'Count', 'scope -scope=*-*', 'requests that timed out waiting for replicas (a running total), tagged the same'),
               ('unavailables_count', CR + 'Unavailables', 'Count', 'scope -scope=*-*', 'requests refused at once: too few replicas up for their consistency level (a running total), tagged the same'),
               ('failures_count', CR + 'Failures', 'Count', 'scope -scope=*-*', 'requests a replica failed (a running total), tagged the same')],
         healthy="latency_p99_ms steady; timeouts_count, unavailables_count and failures_count flat.",
         watch="latency_p99_ms rising run after run; timeouts_count rising now and then.",
         act="unavailables_count rising: replicas are down for the consistency level asked; timeouts_count or "
             "failures_count rising fast."),
    dict(job='threads', metric_name='cassandra.threads', when='run_every   = 1m', title="a Cassandra node's thread pools and dropped messages",
         what="Reports each of the node's thread pools (reads, writes, compaction, gossip and the rest): tasks "
              "waiting, at work, and blocked; and the messages it dropped, by kind, because they waited past "
              "their timeout.",
         rows=[('pending', TP + 'PendingTasks', 'Value', 'scope', "tasks waiting in a pool, tagged scope=<ReadStage, MutationStage, CompactionExecutor, ...>"),
               ('active', TP + 'ActiveTasks', 'Value', 'scope', 'tasks at work, tagged the same'),
               ('blocked', TP + 'CurrentlyBlockedTasks', 'Count', 'scope', 'tasks blocked now (the pool is full), tagged the same'),
               ('blocked_count', TP + 'TotalBlockedTasks', 'Count', 'scope', 'tasks that were blocked (a running total), tagged the same'),
               ('dropped_total_count', M + 'type=DroppedMessage,scope=*,name=Dropped', 'Count', 'sum', 'messages dropped, past their timeout, of every kind (a running total)'),
               ('dropped_count', M + 'type=DroppedMessage,scope=*,name=Dropped', 'Count', 'scope >=1', 'of those, each kind that dropped any, tagged scope=<MUTATION, READ, ...> (some 90 kinds: those at 0 are left out)')],
         healthy="pending near 0; blocked 0; dropped_total_count flat.",
         watch="pending rising in ReadStage or MutationStage; CompactionExecutor pending growing.",
         act="blocked above 0; dropped_total_count rising, dropped_count for MUTATION or READ above all: the node is overloaded, and writes are "
             "being lost to hints or reads to timeouts."),
    dict(job='tables', metric_name='cassandra.tables', when='cron        = 3/5 * * * *', title="a Cassandra node's compactions and tables",
         what="Reports the node's compactions (pending, done, bytes compacted) and its key cache; and for the "
              "application's tables (Cassandra's own keyspaces left out), the worst first: SSTables, compactions "
              "pending, SSTables read by a read, tombstones scanned by a read, the space on disk, and the largest "
              "partition.",
         rows=[('compactions_pending', M + 'type=Compaction,name=PendingTasks', 'Value', '', 'compactions waiting'),
               ('compactions_done_count', M + 'type=Compaction,name=CompletedTasks', 'Value', '', 'compactions done (a running total)'),
               ('compacted_bytes_count', M + 'type=Compaction,name=BytesCompacted', 'Count', '', 'bytes compacted (a running total)'),
               ('key_cache_hit_pct', M + 'type=Cache,scope=KeyCache,name=HitRate', 'Value', '*100', 'reads that found their key in the key cache, of all'),
               ('sstables', TB + 'LiveSSTableCount', 'Value', APP, 'a table\'s SSTables, tagged keyspace=<its keyspace> and scope=<the table>'),
               ('table_compactions_pending', TB + 'PendingCompactions', 'Value', APP, 'its compactions waiting, tagged the same'),
               ('sstables_per_read_p99', TB + 'SSTablesPerReadHistogram', '99thPercentile', APP, 'SSTables a read had to look in, the 99th percentile, tagged the same'),
               ('tombstones_per_read_p99', TB + 'TombstoneScannedHistogram', '99thPercentile', APP, 'tombstones a read scanned, the 99th percentile, tagged the same'),
               ('disk_bytes', TB + 'LiveDiskSpaceUsed', 'Count', APP, 'its live data on disk, tagged the same'),
               ('partition_max_bytes', TB + 'MaxPartitionSize', 'Value', APP, 'its largest partition, tagged the same')],
         healthy="compactions_pending near 0; sstables_per_read_p99 a few; tombstones_per_read_p99 low.",
         watch="compactions_pending rising run after run; sstables in the dozens for a table; "
               "tombstones_per_read_p99 past 1,000 (Cassandra warns); partition_max_bytes past 100 MB.",
         act="compactions_pending in the hundreds and growing; tombstones_per_read_p99 near 100,000 (Cassandra "
             "fails the read); partition_max_bytes past 1 GB."),
]

PACK = dict(
    name='cassandra', tag='node', product='Cassandra', what_tuned='Cassandra',
    version='1.0.0',
    name_row='node',
    name_doc='Each node is named as CASSANDRA_JMX names it (db1: jmx=host:port), else by its address.',
    jmx_doc=("Reads each Cassandra node's JMX, at CASSANDRA_JMX: jmx=host:port, or jmxs=host:port over TLS, "
             "separated by ; or , each with a name first if you like (db1: jmx=host:7199); with "
             "CASSANDRA_JMX_USER and the password in CASSANDRA_JMX_PASSWORD when JMX asks for them; a "
             "certificate is checked against CASSANDRA_CACERT, a PEM file of CAs, or Java's own. With no "
             "CASSANDRA_JMX, it prints nothing. Cassandra's JVM (heap, garbage collection, threads) is the jvm "
             "pack's, not this one's."),
    description='Apache Cassandra over JMX: each node up and normal, gossip and CQL, nodes down, hints; requests '
                'and their latency, timeouts and unavailables; thread pools, blocked tasks, dropped messages; '
                'compactions, SSTables and tombstones per table',
    works_with='Apache Cassandra 4.1 and 5.0 (tested: a 5.0.9 cluster of three, and 4.1.12), with JMX reachable',
    needs=["each node's JMX in CASSANDRA_JMX (db1: jmx=host:7199). Cassandra listens on JMX on localhost only "
           "(LOCAL_JMX=yes in cassandra-env.sh): run the pack on each node, pointed at localhost:7199, or open "
           "JMX with a password (LOCAL_JMX=no) to read it from elsewhere (packs/cassandra/README.md shows how)",
           "for JMX with a password: CASSANDRA_JMX_USER, and a secret line on the jobs: "
           "secret = CASSANDRA_JMX_PASSWORD=secret:CASSANDRA_JMX_PASSWORD, then vigil secret set CASSANDRA_JMX_PASSWORD",
           "for Cassandra's JVM (heap, garbage collection, threads): the jvm pack, not this one: vigil pack "
           "install jvm, with each node in JVM_TARGETS named as here"],
    config_head=['cassandra - Apache Cassandra, on this machine or any it can reach, over JMX:',
                 'each node up and in normal operation, gossip and CQL, the nodes it sees',
                 'down, hints; the requests it coordinates, their latency, timeouts and',
                 'unavailables; its thread pools, blocked tasks and dropped messages; its',
                 'compactions, and the application\'s tables. Never Cassandra\'s JVM: that is',
                 'the jvm pack\'s. Linux, macOS and Windows. See SPECIFICATION.md section',
                 '18.10 for this format, and tools/probe/DESIGN.md for the probe that reads',
                 'it.',
                 '',
                 'Every script runs _probe.jar, beside it, with Java 11 or later (a JDK or a',
                 'JRE), once it matches the digest the script carries, with this pack\'s',
                 '_probe.tables. Nothing of Cassandra\'s is needed here: only its JMX.',
                 '',
                 'Off until enabled: vigil pack enable cassandra. Then set CASSANDRA_JMX in',
                 'the jobs vigil pack enable writes into the configuration (db1:',
                 'jmx=localhost:7199), and with a password, CASSANDRA_JMX_USER and a secret',
                 'line (packs/cassandra/README.md has it all).'],
    jobs=JOBS,
)

if __name__ == '__main__':
    packgen.write(sys.argv[1], PACK)
