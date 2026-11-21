# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""Writes packs/kafka: pack.config, and each job's script for Linux and macOS
(bash) and Windows (PowerShell), from the job bodies in tools/kafka/sh and
tools/kafka/ps, each after its platform's _head, and the documentation
below. Run from the repository: python tools/kafka/gen.py ."""
import os
import sys
import textwrap

repo = sys.argv[1]
src = os.path.join(repo, 'tools', 'kafka')
out = os.path.join(repo, 'packs', 'kafka')

NOTICE = [
    'Copyright (c) Bankole Ogundero and the Vigil contributors',
    'SPDX-License-Identifier: Apache-2.0',
    '',
    'Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or',
    'implied. Run it at your own risk: review it first, and test it before you',
    'rely on it. In no event shall the authors or copyright holders be liable',
    'for any claim, damages or other liability arising from its use. See the',
    'LICENSE file for the full terms.',
]

ADMIN = (
    "Connects to KAFKA_BOOTSTRAP (host:port, comma-separated) with Kafka's own "
    "command-line tools, as KAFKA_USER with the password in KAFKA_PASSWORD, "
    "set by the job; never on a command line: it goes in a client "
    "configuration of the run's own, in a folder only this account can read, "
    "deleted at the end. KAFKA_SECURITY is PLAINTEXT, SSL, SASL_PLAINTEXT or "
    "SASL_SSL; KAFKA_SASL_MECHANISM SCRAM-SHA-512, SCRAM-SHA-256 or PLAIN. "
    "With TLS, the brokers' certificates are checked against KAFKA_CACERT, a "
    "PEM file of CAs, or Java's own, and against their names; KAFKA_CERT and "
    "KAFKA_KEY give a client certificate. KAFKA_CLIENT_CONFIG, a client "
    "properties file of your own, replaces all of these, for a login this "
    "pack does not build (Kerberos, OAuth). KAFKA_HOME is where Kafka is "
    "unpacked, when its tools are not on the PATH.")
JMX = (
    "Reads each broker's JMX, at KAFKA_JMX: host:port, comma-separated, one "
    "per broker, through Kafka's own JmxTool (KAFKA_HOME, when its tools are "
    "not on the PATH). JMX without a password, as Kafka's start scripts set it "
    "up with JMX_PORT: JmxTool takes a password only on its command line, "
    "where this pack never puts one. Each broker is named by its id. With no "
    "KAFKA_JMX, it prints nothing.")
READONLY = "Read-only: it changes nothing in the cluster."

M = lambda *pairs: list(pairs)

# job, metric_name, schedule, kind (admin, jmx or both), title, what,
# metrics, example, healthy, watch, act
JOBS = [
    dict(job='status', metric_name='kafka', when='run_every   = 1m', kind='admin', title="a Kafka cluster's health",
         what="Reports whether the cluster answers, its id, whether it runs on KRaft or ZooKeeper, its brokers "
              "and how many are fenced, and which node is the active controller.",
         metrics=M(('up', '1 when the cluster answers, else 0'),
                   ('info', 'always 1, tagged cluster_id=<its id> and kraft=<yes or no>'),
                   ('brokers', 'brokers the cluster lists'),
                   ('brokers_fenced', 'of those, brokers fenced: registered, but not serving'),
                   ('controller_id', 'the node that is the active controller (KRaft)')),
         healthy="up 1; brokers steady at as many as you run; brokers_fenced 0.",
         watch="controller_id changing often: the controllers keep electing a new leader.",
         act="up 0; brokers below what you run: a broker is down; brokers_fenced above 0 for minutes."),
    dict(job='quorum', metric_name='kafka.quorum', when='cron        = 1/2 * * * *', kind='admin', title="a KRaft cluster's controller quorum",
         what="Reports the KRaft quorum that keeps the cluster's metadata: its leader and epoch, its high "
              "watermark, how far the followers lag, the voters and observers, and for each node how far "
              "behind it is and how long since it last fetched and last caught up. A cluster on ZooKeeper "
              "reports kraft 0 and nothing else.",
         metrics=M(('kraft', '1 when the cluster runs on KRaft, else 0'),
                   ('leader_id', "the quorum's leader, the active controller"),
                   ('leader_epoch', 'its epoch: it rises with each new leader'),
                   ('high_watermark', "the metadata log's committed end"),
                   ('max_follower_lag', 'the most any follower is behind, in records'),
                   ('max_follower_lag_ms', 'the same, in milliseconds'),
                   ('voters', 'controllers that vote'),
                   ('observers', 'nodes that only follow (brokers)'),
                   ('node_lag', 'how many records a node is behind, tagged node=<id> and role=<leader, follower or observer>'),
                   ('node_fetch_age_seconds', 'since the node last fetched, tagged the same'),
                   ('node_caught_up_age_seconds', 'since the node was last caught up, tagged the same')),
         healthy="kraft 1; max_follower_lag near 0; every node's node_caught_up_age_seconds a few seconds.",
         watch="leader_epoch rising often: the controllers keep losing their leader; node_lag growing for one node.",
         act="voters fewer than you run, or a voter's node_caught_up_age_seconds in minutes: a controller is gone "
             "or stuck. Lose a majority of voters and the cluster can change nothing."),
    dict(job='brokers', metric_name='kafka.broker', when='cron        = 1/5 * * * *', kind='admin', title="each Kafka broker's share",
         what="Reports each broker: whether it is listed and fenced, its rack, and what it holds: partitions it "
              "leads, replicas, replicas it has let fall out of sync, and partitions that prefer it as leader. A "
              "broker that holds replicas but is not listed is down, and is shown so.",
         metrics=M(('online', '1 when the broker is listed, 0 when it holds replicas but is not, tagged broker=<id> and rack=<its rack, or none>'),
                   ('fenced', '1 when it is fenced, tagged broker=<id>'),
                   ('leaders', 'partitions it leads, tagged the same'),
                   ('replicas', 'replicas it holds, tagged the same'),
                   ('out_of_sync_replicas', 'of those, replicas not in sync, tagged the same'),
                   ('preferred_leaders', 'partitions whose preferred leader it is, tagged the same'),
                   ('brokers_not_shown', 'brokers past the first 150, left out')),
         healthy="online 1 for every broker; out_of_sync_replicas 0; leaders close to preferred_leaders.",
         watch="leaders far from preferred_leaders on one broker: leadership is unbalanced (kafka-leader-election "
               "puts it back).",
         act="online 0; out_of_sync_replicas above 0 on one broker: it cannot keep up (disk, network, CPU)."),
    dict(job='replication', metric_name='kafka.replication', when='run_every   = 1m', kind='admin', title="a Kafka cluster's replication",
         what="Reports every partition's replication: partitions with fewer replicas in sync than they have, with "
              "no leader (offline), with fewer in sync than min.insync.replicas (writes with acks=all fail), "
              "exactly at it (one more lost and they fail), led by a broker other than the preferred one, with "
              "eligible leader replicas, and being moved; and by name, the topics that have such partitions.",
         metrics=M(('topics', 'topics'),
                   ('partitions', 'partitions'),
                   ('under_replicated', 'partitions with fewer replicas in sync than they have'),
                   ('offline', 'partitions with no leader: no one can read or write them'),
                   ('under_min_isr', 'partitions with fewer in sync than min.insync.replicas: writes with acks=all fail'),
                   ('at_min_isr', 'partitions exactly at min.insync.replicas, with replicas to spare'),
                   ('not_preferred_leader', 'partitions not led by their preferred leader'),
                   ('with_eligible_leaders', 'partitions with eligible leader replicas (Kafka 4)'),
                   ('reassigning', 'partitions being moved between brokers'),
                   ('topic_under_replicated', 'under-replicated partitions of a topic, tagged topic=<name> (at most 100 topics)'),
                   ('topic_offline', 'offline partitions of a topic, tagged the same'),
                   ('topic_under_min_isr', 'partitions of a topic under min.insync.replicas, tagged the same')),
         healthy="under_replicated, offline and under_min_isr 0.",
         watch="at_min_isr above 0: one more replica lost and writes fail; not_preferred_leader growing.",
         act="offline above 0: data unreachable; under_min_isr above 0: producers with acks=all fail; "
             "under_replicated above 0 for minutes when no broker is restarting."),
    dict(job='reassignment', metric_name='kafka.reassignment', when='cron        = 2/5 * * * *', kind='admin', title="partition moves in a Kafka cluster",
         what="Reports the partition moves in progress: partitions, the replicas being added and removed, the "
              "topics, and each topic's partitions on the move.",
         metrics=M(('partitions', 'partitions being moved'),
                   ('adding_replicas', 'replicas being added'),
                   ('removing_replicas', 'replicas being removed'),
                   ('topics', 'topics with a partition being moved'),
                   ('topic_partitions', "a topic's partitions being moved, tagged topic=<name> (at most 100)")),
         healthy="partitions 0, except while you move partitions.",
         watch="partitions above 0 for hours: a move held back by a throttle, or by a broker that cannot catch up.",
         act="partitions not falling during a move you started: check the throttle and the brokers it moves to."),
    dict(job='consumers', metric_name='kafka.consumer', when='run_every   = 1m', kind='admin', title="consumer group lag",
         what="Reports each consumer group's lag: how far its committed offsets are behind the end of each "
              "partition, summed and the worst partition, per group and topic; partitions with no committed "
              "offset; and each group's total.",
         metrics=M(('groups', 'groups with committed offsets'),
                   ('total_lag', 'all groups\' lag, in messages'),
                   ('lag', "a group's lag on a topic, in messages, tagged group=<name> and topic=<name> (at most 150 pairs)"),
                   ('lag_max', 'its worst partition, tagged the same'),
                   ('no_offset_partitions', 'partitions the group has no committed offset for, tagged the same; left out when none'),
                   ('pairs_not_shown', 'group and topic pairs past the first 150, left out'),
                   ('group_lag', "a group's lag on all its topics, tagged group=<name> (at most 150)")),
         healthy="lag steady or falling: consumers keep up.",
         watch="lag rising for minutes: consumers fall behind; lag_max far above lag divided by partitions: one "
               "partition is stuck, or one consumer is slow.",
         act="lag rising with the group empty (kafka_groups): nothing consumes; lag near what retention keeps: "
             "consumers are about to lose messages they never read."),
    dict(job='groups', metric_name='kafka.group', when='cron        = 3/5 * * * *', kind='admin', title='Kafka groups by state',
         what="Reports every group by type and state, and each group's members: consumer groups, classic or "
              "new protocol, and with Kafka 4's tools, share groups and Streams groups. A tool this Kafka does not "
              "have, or a group type the cluster has not turned on, is left out.",
         metrics=M(('all_groups', 'groups'),
                   ('all_members', "all groups' members"),
                   ('rebalancing', 'groups rebalancing now'),
                   ('empty', 'groups with no members'),
                   ('dead', 'groups that are dead (being removed)'),
                   ('groups', 'groups of a type in a state, tagged type=<classic, consumer, share or streams> and state=<stable, empty, ...>'),
                   ('members', "a group's members, tagged group=<name> and type=<its type> (at most 150)"),
                   ('groups_not_shown', 'groups past the first 150, left out')),
         healthy="rebalancing 0 most of the time; each group's members steady.",
         watch="rebalancing often above 0: consumers join and leave, or time out (max.poll.interval.ms).",
         act="a group you expect to consume shows empty, or its members fall to 0: its consumers stopped."),
    dict(job='topics', metric_name='kafka.topic', when='cron        = 4/5 * * * *', kind='admin', title='Kafka topics and their messages',
         what="Reports the topics: how many, internal, with a single replica, compacted; and each topic's "
              "partitions, replication factor, every message ever written to it (a running total, from the end "
              "of each partition), and the messages it still holds (from its start).",
         metrics=M(('topics', 'topics'),
                   ('internal_topics', "Kafka's own topics (their names start with __)"),
                   ('rf1_topics', 'topics of your own with a single replica: a broker lost is data lost'),
                   ('compacted_topics', 'topics compacted (cleanup.policy compact)'),
                   ('partitions', "a topic's partitions, tagged topic=<name> (at most 100 topics)"),
                   ('replication_factor', 'its replication factor, tagged the same'),
                   ('messages_count', 'messages ever written to it, a running total, tagged the same'),
                   ('retained_messages', 'messages it still holds, tagged the same'),
                   ('topics_not_shown', 'topics past the first 100, left out')),
         healthy="rf1_topics 0, unless on purpose; messages_count rising on every topic you write to.",
         watch="messages_count flat on a topic that should be written to: its producers stopped.",
         act="rf1_topics above 0 for data you cannot lose."),
    dict(job='logdirs', metric_name='kafka.logdir', when='cron        = 0/5 * * * *', kind='both', title="Kafka's data on disk",
         what="Reports every broker's log directories: their size, partitions, errors (an offline directory) and "
              "replicas being moved between directories; each broker's and each topic's size, every replica "
              "counted; and, with tiered storage and KAFKA_JMX, what each broker has copied to remote storage "
              "and still has to.",
         metrics=M(('size_bytes', 'a directory\'s size, tagged broker=<id> and dir=<its path>'),
                   ('partitions', 'its partitions, tagged the same'),
                   ('offline', '1 when the broker reports an error for it, tagged the same'),
                   ('future_replicas', 'replicas being moved into it, tagged the same'),
                   ('dirs', 'directories'),
                   ('dirs_offline', 'of those, offline'),
                   ('broker_size_bytes', "a broker's data, tagged broker=<id>"),
                   ('topic_size_bytes', "a topic's data, every replica counted, tagged topic=<name> (at most 100)"),
                   ('topics_not_shown', 'topics past the first 100, left out'),
                   ('jmx_up', "with KAFKA_JMX: 1 when a broker's JMX answers, tagged broker=<id, or its JMX host:port>"),
                   ('remote_size_bytes', "a broker's data in remote storage (tiered storage), tagged broker=<id>"),
                   ('remote_copy_lag_bytes', 'data it has yet to copy there, tagged the same')),
         healthy="dirs_offline 0; sizes growing and shrinking with retention.",
         watch="a broker's broker_size_bytes far above the others': partitions are unbalanced; remote_copy_lag_bytes "
               "growing.",
         act="offline 1: a disk failed, and its partitions moved away or went offline."),
    dict(job='transactions', metric_name='kafka.transaction', when='cron        = 1/5 * * * *', kind='admin', title='Kafka transactions',
         what="Reports the cluster's transactions by state, those ongoing, and those open longer than "
              "KAFKA_TXN_LONG seconds (default 300). Counts only: a transactional id names an application.",
         metrics=M(('all_transactions', 'transactional producers the cluster knows'),
                   ('transactions', 'of those, in a state, tagged state=<ongoing, completecommit, empty, ...>'),
                   ('ongoing', 'transactions open now'),
                   ('long_running', 'transactions open longer than KAFKA_TXN_LONG')),
         healthy="long_running 0.",
         watch="ongoing growing without falling back.",
         act="long_running above 0: a transaction left open holds up consumers that read committed messages "
             "(isolation.level read_committed) on its partitions."),
    dict(job='config', metric_name='kafka.config', when='cron        = 6/15 * * * *', kind='admin', title="risky Kafka settings",
         what="Reports the brokers' settings that matter most for safety, from the first broker, how many of "
              "them differ between brokers, and the topics whose own settings put their data at risk.",
         metrics=M(('unclean_leader_election', '1 when an out-of-sync replica may become leader, losing data'),
                   ('auto_create_topics', '1 when a client creates a topic just by naming it'),
                   ('auto_leader_rebalance', '1 when leadership moves back to preferred leaders by itself'),
                   ('authorizer', '1 when ACLs are checked'),
                   ('min_insync_replicas', 'the default min.insync.replicas'),
                   ('default_replication_factor', 'the replication factor of a topic created without one'),
                   ('offsets_replication_factor', "the consumer offsets topic's"),
                   ('transactions_replication_factor', "the transaction state topic's"),
                   ('message_max_bytes', 'the largest batch a broker takes'),
                   ('retention_hours', 'how long messages are kept by default; -1 forever'),
                   ('plaintext_listeners', 'listeners without TLS or a login, the controllers\' left out'),
                   ('settings_differ', 'settings with different values on different brokers'),
                   ('topics_unclean_election', 'topics that allow unclean leader election'),
                   ('topics_min_isr_ge_rf', 'topics with more replicas than one whose min.insync.replicas is at least their replication factor: one replica down and writes with acks=all fail'),
                   ('topics_min_isr_1', 'topics with 3 or more replicas but min.insync.replicas 1: acks=all keeps only one copy')),
         healthy="unclean_leader_election 0; min_insync_replicas 2 with a replication factor of 3; settings_differ 0.",
         watch="auto_create_topics 1 in production: a typo makes a topic; plaintext_listeners above 0.",
         act="unclean_leader_election 1, or topics_unclean_election above 0, where data must not be lost; "
             "topics_min_isr_ge_rf above 0."),
    dict(job='security', metric_name='kafka.security', when='cron        = 8/15 * * * *', kind='admin', title="a Kafka cluster's ACLs, users and quotas",
         what="Reports the ACLs by resource and permission, the ACLs that grant to every principal or every "
              "operation, the users with SCRAM credentials, and the quotas set. Counts only: never a "
              "principal's or a client's name.",
         metrics=M(('authorizer', '1 when the cluster checks ACLs, 0 when it has no authorizer'),
                   ('all_acls', 'ACLs'),
                   ('any_principal_acls', 'ACLs for every principal (User:*)'),
                   ('all_operations_acls', 'ACLs for every operation (ALL)'),
                   ('acls', 'ACLs, tagged resource=<topic, group, cluster, ...> and permission=<allow or deny>'),
                   ('scram_users', 'users with SCRAM credentials'),
                   ('quotas', 'quotas set, tagged entity=<user or client>')),
         healthy="authorizer 1; all_acls and scram_users changing only when you change them.",
         watch="any_principal_acls or all_operations_acls above 0: check they are meant.",
         act="authorizer 0 on a cluster that should check ACLs; all_acls or scram_users changing when no one "
             "changed them."),
    dict(job='features', metric_name='kafka.feature', when='cron        = 10/15 * * * *', kind='admin', title="a Kafka cluster's finalized features",
         what="Reports the cluster's finalized features against the most its brokers support: metadata.version "
              "by name, the others by level. A feature behind is an upgrade not finalized yet (kafka-features "
              "upgrade).",
         metrics=M(('metadata_version', 'always 1, tagged version=<finalized> and supported=<the most supported>'),
                   ('level', "a feature's finalized level, tagged feature=<name>"),
                   ('supported_level', 'the most the brokers support, tagged the same'),
                   ('behind', '1 when the feature is below that, tagged the same'),
                   ('features', 'features'),
                   ('features_behind', 'of those, behind')),
         healthy="features_behind 0, after an upgrade is finished.",
         watch="features_behind above 0 for long after an upgrade: it was never finalized, and the cluster "
               "does not use what the new version brings.",
         act="metadata_version far behind supported: finalize it once every broker runs the new version."),
    dict(job='throughput', metric_name='kafka.throughput', when='run_every   = 2m', kind='jmx', title="each Kafka broker's traffic",
         what="Reports each broker's traffic, all topics together: messages and bytes in and out, replication "
              "between brokers, produce and fetch requests and those that failed, bytes rejected, format "
              "conversions, and records rejected as invalid. Running totals: graph them as a rate.",
         metrics=M(('jmx_up', "1 when a broker's JMX answers, tagged broker=<id, or its JMX host:port>"),
                   ('messages_in_count', 'messages written to it, tagged broker=<id>'),
                   ('bytes_in_count', 'bytes written to it by clients, tagged the same'),
                   ('bytes_out_count', 'bytes read from it by clients, tagged the same'),
                   ('bytes_rejected_count', 'bytes rejected, too large, tagged the same'),
                   ('replication_bytes_in_count', 'bytes copied to it from other brokers, tagged the same'),
                   ('replication_bytes_out_count', 'bytes copied from it to other brokers, tagged the same'),
                   ('produce_requests_count', 'produce requests, tagged the same'),
                   ('fetch_requests_count', 'fetch requests, tagged the same'),
                   ('failed_produce_requests_count', 'produce requests that failed, tagged the same'),
                   ('failed_fetch_requests_count', 'fetch requests that failed, tagged the same'),
                   ('produce_conversions_count', 'messages converted to another format on produce, tagged the same'),
                   ('fetch_conversions_count', 'messages converted on fetch, tagged the same'),
                   ('invalid_crc_records_count', 'records rejected for a bad checksum, tagged the same'),
                   ('invalid_sequence_records_count', 'records rejected for an offset or sequence out of order, tagged the same')),
         healthy="jmx_up 1; traffic spread evenly between brokers; the failed counts flat.",
         watch="one broker's bytes far above the others': partitions are unbalanced; the conversion counts "
               "rising: old clients make the broker do extra work.",
         act="failed_produce_requests_count rising: producers' writes fail; bytes_rejected_count rising: "
             "messages too large for message.max.bytes."),
    dict(job='requests', metric_name='kafka.request', when='cron        = 1/2 * * * *', kind='jmx', title="how each Kafka broker serves requests",
         what="Reports how each broker serves requests: the time produce, consumer fetch and follower fetch "
              "requests take (99th percentile, as the broker measures it over its recent requests), the time "
              "they queue and wait on others, how many it has served, the request and response queues, "
              "requests waiting in purgatory, and how idle its request handler and network threads are.",
         metrics=M(('jmx_up', "1 when a broker's JMX answers, tagged broker=<id, or its JMX host:port>"),
                   ('total_ms_p99', 'the time a request takes, in ms, tagged broker=<id> and request=<Produce, FetchConsumer or FetchFollower>'),
                   ('queue_ms_p99', 'of that, the time it waits in the queue, tagged the same'),
                   ('remote_ms_p99', 'of that, the time it waits on other brokers (acks=all) or for data (fetch), tagged the same'),
                   ('requests_count', 'requests served, a running total, tagged the same'),
                   ('request_queue', 'requests waiting for a handler thread, tagged broker=<id>'),
                   ('response_queue', 'responses waiting to be sent, tagged the same'),
                   ('purgatory', 'requests waiting in purgatory, tagged broker=<id> and operation=<produce or fetch>'),
                   ('handler_idle_pct', 'how idle the request handler threads are, as a percent, tagged broker=<id>'),
                   ('network_idle_pct', 'how idle the network threads are, as a percent, tagged the same')),
         healthy="handler_idle_pct and network_idle_pct above 30; request_queue near 0; Produce total_ms_p99 "
                 "steady.",
         watch="handler_idle_pct below 30: the broker is busy; queue_ms_p99 rising: requests wait for threads.",
         act="handler_idle_pct or network_idle_pct below 10: the broker is saturated; Produce total_ms_p99 "
             "climbing with remote_ms_p99: followers are slow to replicate."),
    dict(job='jvm', metric_name='kafka.jvm', when='cron        = 2/5 * * * *', kind='jmx', title="each Kafka broker's JVM and logs",
         what="Reports each broker's JVM: heap used against the most it may use, garbage collection, open files "
              "against the limit, CPU, threads and uptime; and its logs: how long a flush to disk takes, the log "
              "cleaner (compaction), and log directories offline.",
         metrics=M(('jmx_up', "1 when a broker's JMX answers, tagged broker=<id, or its JMX host:port>"),
                   ('heap_used_bytes', 'heap in use, tagged broker=<id>'),
                   ('heap_max_bytes', 'the most heap it may use, tagged the same'),
                   ('gc_count', 'garbage collections, a running total, tagged broker=<id> and gc=<the collector>'),
                   ('gc_ms_count', 'time spent collecting, in ms, a running total, tagged the same'),
                   ('open_files', 'files and sockets open, tagged broker=<id>'),
                   ('max_files', 'the most it may open, tagged the same'),
                   ('cpu_pct', "the broker's CPU, as a percent of the machine, tagged the same"),
                   ('threads', 'its threads, tagged the same'),
                   ('uptime_seconds', 'how long it has run, tagged the same'),
                   ('flush_ms_p99', 'the time a log flush takes, in ms, 99th percentile, tagged the same'),
                   ('flushes_count', 'log flushes, a running total, tagged the same'),
                   ('cleaner_max_dirty_pct', 'the most of a compacted log not yet compacted, as a percent, tagged the same'),
                   ('cleaner_idle_seconds', 'since the log cleaner last ran, tagged the same'),
                   ('cleaner_dead_threads', 'log cleaner threads that died, tagged the same'),
                   ('cleaner_max_clean_seconds', 'the longest a clean took, tagged the same'),
                   ('offline_log_dirs', 'log directories offline, tagged the same')),
         healthy="heap_used_bytes well under heap_max_bytes after collections; open_files well under max_files; "
                 "cleaner_dead_threads 0.",
         watch="gc_ms_count rising fast: the broker pauses to collect; flush_ms_p99 rising: the disk is slow; "
               "uptime_seconds back near 0: it restarted.",
         act="open_files near max_files: it will fail to open a file or a connection; cleaner_dead_threads above "
             "0: compacted topics grow without bound; offline_log_dirs above 0."),
    dict(job='controller', metric_name='kafka.controller', when='run_every   = 2m', kind='jmx', title="the Kafka controller's view",
         what="Reports which node is the active controller, and from it the cluster as it sees it: brokers active "
              "and fenced, topics and partitions, offline partitions, leaders not where they prefer, metadata "
              "errors and lag, heartbeats that timed out, leader elections (unclean ones too), and its event "
              "queue. The other nodes report active_controller 0 and nothing else.",
         metrics=M(('jmx_up', "1 when a node's JMX answers, tagged broker=<id, or its JMX host:port>"),
                   ('active_controller', '1 on the active controller, else 0, tagged broker=<id>'),
                   ('brokers', 'brokers active, tagged the same'),
                   ('fenced_brokers', 'brokers fenced, tagged the same'),
                   ('topics', 'topics, tagged the same'),
                   ('partitions', 'partitions, tagged the same'),
                   ('offline_partitions', 'partitions with no leader, tagged the same'),
                   ('preferred_imbalance', 'partitions not led by their preferred leader, tagged the same'),
                   ('metadata_errors', 'errors applying metadata, tagged the same'),
                   ('metadata_lag_ms', 'how far behind its metadata is, in ms, tagged the same'),
                   ('timed_out_heartbeats', 'broker heartbeats that timed out, tagged the same'),
                   ('controller_changes', 'times a new controller became active, tagged the same'),
                   ('elections_count', 'leader elections, a running total, tagged the same'),
                   ('unclean_elections_count', 'unclean leader elections (data lost), a running total, tagged the same'),
                   ('eligible_leader_elections_count', 'leaders elected from eligible leader replicas (Kafka 4), a running total, tagged the same'),
                   ('event_queue', "events waiting in the controller's queue, tagged the same"),
                   ('event_queue_ms_p99', 'the time an event waits there, in ms, tagged the same')),
         healthy="one node with active_controller 1; offline_partitions 0; metadata_errors 0.",
         watch="elections_count rising fast: leaders keep changing; timed_out_heartbeats rising.",
         act="no node with active_controller 1; offline_partitions above 0; unclean_elections_count rising: "
             "data was lost."),
    dict(job='connections', metric_name='kafka.connection', when='cron        = 3/5 * * * *', kind='jmx', title="connections and logins on each Kafka broker",
         what="Reports each broker's connections per listener: open now, and running totals of those made and "
              "of logins that succeeded, failed, and failed again on re-authentication.",
         metrics=M(('jmx_up', "1 when a broker's JMX answers, tagged broker=<id, or its JMX host:port>"),
                   ('connections', 'connections open, tagged broker=<id> and listener=<name>'),
                   ('created_count', 'connections made, a running total, tagged the same'),
                   ('logins_count', 'logins that succeeded, a running total, tagged the same'),
                   ('failed_logins_count', 'logins that failed, a running total, tagged the same'),
                   ('failed_relogins_count', 're-authentications that failed, a running total, tagged the same')),
         healthy="failed_logins_count flat; connections steady.",
         watch="created_count rising fast while connections stays flat: clients connect and drop.",
         act="failed_logins_count rising: a client with a wrong password or certificate, or someone guessing."),
    dict(job='tls', metric_name='kafka.tls', when='cron        = 12 * * * *', kind='admin', title="the Kafka brokers' TLS certificates",
         what="Reports, for each broker, the certificate it presents on the listener this pack connects to: how "
              "many days until it expires, and whether it is trusted (by KAFKA_CACERT, or the system's CAs) and "
              "names the broker. The brokers are those the cluster lists, as it tells clients to reach them; or "
              "KAFKA_TLS_ENDPOINTS, host:port, comma-separated. Without TLS, it reports tls 0.",
         metrics=M(('tls', '1 when the listener uses TLS, else 0'),
                   ('endpoints', 'brokers checked'),
                   ('reachable', '1 when a broker gave its certificate, tagged endpoint=<host:port>'),
                   ('expires_days', 'days until it expires, below 0 once it has, tagged the same'),
                   ('trusted', '1 when it is trusted and names the broker, tagged the same')),
         healthy="expires_days above 30 everywhere; trusted 1.",
         watch="expires_days below 30: renew it.",
         act="expires_days below 7, or trusted 0: clients that check certificates will refuse the broker."),
]


def wrap(text, width, first='', rest=''):
    return textwrap.wrap(text, width, initial_indent=first, subsequent_indent=rest, break_on_hyphens=False) or [first]


def metrics_doc(metrics):
    w = max(len(n) for n, _ in metrics) + 2
    lines = []
    for n, d in metrics:
        lines += wrap(d, 76, first=('  ' + n).ljust(2 + w), rest=' ' * (2 + w))
    return lines


def examples():
    """Each job's example output: tools/kafka/examples.txt, '== job' then lines."""
    ex, cur = {}, None
    path = os.path.join(src, 'examples.txt')
    if not os.path.exists(path):
        return ex
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if line.startswith('== '):
            cur = line[3:].strip()
            ex[cur] = []
        elif cur and line:
            ex[cur].append(line)
    return ex


EXAMPLES = examples()


def doc(j, ps):
    c = []
    c += wrap(j['what'] + ' ' + READONLY, 76)
    c += ['']
    if j['kind'] in ('admin', 'both'):
        c += wrap(ADMIN, 76)
    if j['kind'] == 'both':
        c += ['']
    if j['kind'] in ('jmx', 'both'):
        c += wrap(JMX, 76)
    c += ['', 'Metrics:']
    c += metrics_doc(j['metrics'])
    ex = EXAMPLES.get(j['job'])
    if not ex:
        # KAFKA_GEN_DRAFT=1: scripts to run, before their real output is in.
        if os.environ.get('KAFKA_GEN_DRAFT') != '1':
            sys.exit('no example output for %s in tools/kafka/examples.txt' % j['job'])
        ex = ['(draft: no example yet)']
    c += ['', 'Example output (the rest are in the same form):']
    c += ['  ' + e for e in ex]
    c += ['', 'Reading the results (starting points: tune them to the cluster):']
    c += wrap(j['healthy'], 76, first='  Healthy  ', rest=' ' * 11)
    c += wrap(j['watch'], 76, first='  Watch    ', rest=' ' * 11)
    c += wrap(j['act'], 76, first='  Act      ', rest=' ' * 11)
    c += ['']
    tools = ("Kafka's command-line tools (any from 3.9, the Kafka download), Java 17 or later" +
             (", openssl" if j['job'] == 'tls' and not ps else ''))
    if j['kind'] != 'jmx':
        tools += ', and a user with the ACLs packs/README.md lists'
    c += wrap(('Requires: Windows PowerShell 5.1 or PowerShell 7, ' if ps else 'Requires: bash, ') + tools, 76, rest='  ')
    if j['job'] == 'status':
        c += wrap('Exit code: 0 on success, cluster up or down; 1 if the tools are missing, or the cluster '
                  'refuses the login, its certificate or a request', 76, rest='  ')
    else:
        c += wrap('Exit code: 0 on success, or when the cluster does not answer; 1 if the tools are missing, or '
                  'the cluster refuses the login, its certificate or a request', 76, rest='  ')
    return c


def body(lang, job):
    d = 'ps' if lang == 'ps1' else lang
    head = open(os.path.join(src, d, '_head.' + lang), encoding='utf-8').read()
    b = open(os.path.join(src, d, job + '.' + lang), encoding='utf-8').read()
    s = head.rstrip('\n') + '\n\n' + b.rstrip('\n') + '\n'
    if lang == 'ps1':
        # The head opens a try: its folder goes, however the run ends.
        s += '}\nfinally {\n    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue\n}\nexit 0\n'
    return s.replace('@JOB@', job)


def sh_script(j):
    head = ['#!/usr/bin/env bash', '#', '# %s.sh - %s' % (j['job'], j['title']), '#']
    head += [('# ' + n).rstrip() for n in NOTICE] + ['#']
    head += [('# ' + l).rstrip() for l in doc(j, False)]
    return '\n'.join(head) + '\n\n' + body('sh', j['job'])


def ps_script(j):
    head = ['#Requires -Version 5.1', '', '<#', '.SYNOPSIS', '    %s.ps1 - %s, on Windows' % (j['job'], j['title']), '.NOTES']
    head += [('    ' + n).rstrip() for n in NOTICE]
    head += ['.DESCRIPTION']
    head += [('    ' + l).rstrip() for l in doc(j, True)]
    head += ['#>']
    return '\n'.join(head) + '\n\n' + body('ps1', j['job'])


ACLS = ("kafka-acls --add --allow-principal User:vigil_monitor --operation Describe --operation DescribeConfigs "
        "--cluster --topic '*'; kafka-acls --add --allow-principal User:vigil_monitor --operation Describe "
        "--group '*' --transactional-id '*'")


def pack_config():
    p = ['# kafka - Apache Kafka 3.9 and 4.x, KRaft or ZooKeeper, on this machine or',
         '# any it can reach, through Kafka\'s own command-line tools: its brokers and',
         '# controller quorum, replication, partition moves, consumer lag, groups,',
         '# topics, data on disk, transactions, risky settings, ACLs, features and',
         '# certificates; and from the brokers\' JMX, their traffic, requests, JVM,',
         '# controller and connections. Linux, macOS and Windows. See',
         '# SPECIFICATION.md section 18.10 for this format.',
         '#',
         '# The jobs that run every 5 or 15 minutes, or each hour, have minutes of',
         '# their own (cron, local time), so few runs start together. Each tool a',
         '# job runs starts Java with Kafka\'s libraries: about 4 seconds on Linux,',
         '# 10 or more on Windows. So only status, replication and consumers run',
         '# every minute; the rest every 2, 5 or 15 minutes, or each hour.',
         '#',
         '# Off until enabled: vigil pack enable kafka. It logs in as a user that may',
         '# only describe; create one once, as an administrator (packs/README.md has',
         '# it all), with SCRAM:',
         "#   kafka-configs --alter --entity-type users --entity-name vigil_monitor \\",
         "#     --add-config 'SCRAM-SHA-512=[password=...]'",
         '#   kafka-acls --add --allow-principal User:vigil_monitor \\',
         "#     --operation Describe --operation DescribeConfigs --cluster --topic '*'",
         '#   kafka-acls --add --allow-principal User:vigil_monitor \\',
         "#     --operation Describe --group '*' --transactional-id '*'",
         '# and give Vigil its password:',
         '#   vigil secret set KAFKA_MONITOR_PASSWORD',
         '# For another cluster, or another login, edit the env lines of the jobs',
         '# vigil pack enable writes into the configuration; for JMX, KAFKA_JMX.',
         '#']
    p += [('# ' + n).rstrip() for n in NOTICE]
    p += ['',
          '[pack]',
          'version     = 1.0.0',
          '# vigil: the oldest Vigil this pack runs on. vigil pack update refuses the',
          '# pack on an older one.',
          'vigil       = 0.3.0',
          'description = Apache Kafka: brokers, KRaft quorum, replication, consumer lag, groups, topics, disk, transactions, settings, ACLs, features, certificates; traffic, requests, JVM, controller and connections from JMX',
          '# What vigil pack info shows besides: the servers it is meant for, the',
          '# programs its scripts need on each platform, and where it is explained.',
          'works_with  = Apache Kafka 3.9 and 4.x, KRaft or ZooKeeper, and the clusters built on it',
          "programs_linux = Kafka's command-line tools (3.9 or later), Java 17 or later, openssl",
          "programs_macos = Kafka's command-line tools (3.9 or later), Java 17 or later, openssl",
          "programs_windows = Kafka's command-line tools (3.9 or later), Java 17 or later",
          'docs        = https://github.com/godspeedhq/vigil/blob/main/packs/README.md#kafka',
          "needs       = a user that may only describe, as an administrator: kafka-configs --alter --entity-type users --entity-name vigil_monitor --add-config 'SCRAM-SHA-512=[password=...]'",
          'needs       = its ACLs: ' + ACLS,
          "needs       = for the JMX jobs (throughput, requests, jvm, controller, connections): each broker's JMX port, without a password, in KAFKA_JMX",
          '']
    admin_env = ['env         = KAFKA_BOOTSTRAP=localhost:9092',
                 'env         = KAFKA_SECURITY=SASL_SSL',
                 'env         = KAFKA_SASL_MECHANISM=SCRAM-SHA-512',
                 'env         = KAFKA_USER=vigil_monitor',
                 'env         = KAFKA_CACERT=',
                 'env         = KAFKA_HOME=',
                 'secret      = KAFKA_PASSWORD=secret:KAFKA_MONITOR_PASSWORD']
    for j in JOBS:
        names = [n for n, _ in j['metrics']]
        p += ['[job.%s]' % j['job'],
              'metric_name = %s' % j['metric_name'],
              'metrics     = %s' % ', '.join(names),
              j['when'],
              'max_runtime = %s' % ('3m' if j['job'] in ('tls', 'groups', 'topics', 'security') else '2m')]
        if j['kind'] == 'jmx':
            p += ['env         = KAFKA_JMX=localhost:9999', 'env         = KAFKA_HOME=']
        else:
            p += admin_env
            if j['kind'] == 'both':
                p.insert(len(p) - 1, 'env         = KAFKA_JMX=')
            if j['job'] == 'transactions':
                p.insert(len(p) - 1, 'env         = KAFKA_TXN_LONG=300')
        p += ['']
    return '\n'.join(p).rstrip('\n') + '\n'


for d in ('linux', 'macos', 'windows'):
    os.makedirs(os.path.join(out, d), exist_ok=True)
open(os.path.join(out, 'pack.config'), 'w', encoding='utf-8', newline='\n').write(pack_config())
for j in JOBS:
    s = sh_script(j)
    for d in ('linux', 'macos'):
        open(os.path.join(out, d, j['job'] + '.sh'), 'w', encoding='utf-8', newline='\n').write(s)
    if os.path.exists(os.path.join(src, 'ps', j['job'] + '.ps1')):
        open(os.path.join(out, 'windows', j['job'] + '.ps1'), 'w', encoding='utf-8', newline='\n').write(ps_script(j))
print('wrote', len(JOBS), 'jobs')
