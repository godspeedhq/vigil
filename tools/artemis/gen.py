# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""Writes packs/artemis: Apache ActiveMQ Artemis, over JMX, as tables for
the probe (tools/probe/packgen.py). ActiveMQ Classic is the activemq pack's.
Run from the repository: python tools/artemis/gen.py ."""
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[1], 'tools', 'probe'))
import packgen  # noqa: E402

D = 'org.apache.activemq.artemis'
B = D + ':broker=*'
ACC = D + ':broker=*,component=acceptors,name=*'
CC = D + ':broker=*,component=cluster-connections,name=*'
BR = D + ':broker=*,component=bridges,name=*'
BC = D + ':broker=*,component=broker-connections,name=*'
A = D + ':broker=*,component=addresses,address=*'
Q = D + ':broker=*,component=addresses,address=*,subcomponent=queues,routing-type=*,queue=*'
DLQ = D + ':broker=*,component=addresses,address=*,subcomponent=queues,routing-type=*,queue=*DLQ*'
EXP = D + ':broker=*,component=addresses,address=*,subcomponent=queues,routing-type=*,queue=*Expiry*'
NOSYS = '-address=$sys.* -address=activemq.notifications -address=activemq.management*'


def qrow(metric, attr, words, what):
    return (metric, Q, attr, 'address queue ' + words + (' ' if words else '') + NOSYS, what)


JOBS = [
    dict(job='status', metric_name='artemis', when='run_every   = 1m', title="an Artemis broker's health",
         what="Reports whether each broker answers over JMX, its name and version, how long it has been up, "
              "whether it is started and active, its high availability policy and role (a backup, and whether a "
              "backup's replica is in sync), and each acceptor: started.",
         rows=[('version', B, 'Version', '@version', "always 1, tagged version=<Artemis's version, 2.44.0>"),
               ('broker', B, 'Name', '@broker_name', "always 1, tagged broker_name=<the broker's own name>"),
               ('ha_policy', B, 'HAPolicy', '@policy', 'always 1, tagged policy=<its high availability policy, Primary Only...>'),
               ('uptime_seconds', B, 'UptimeMillis', '*0.001', 'since the broker started'),
               ('started', B, 'Started', '', '1 when the broker is started, else 0'),
               ('active', B, 'Active', '', '1 when it is active (serving clients), else 0: a backup waiting'),
               ('backup', B, 'Backup', '', '1 when it is a backup, else 0'),
               ('replica_sync', B, 'ReplicaSync', '', '1 when its replica is in sync (replication), else 0'),
               ('acceptor_up', ACC, 'Started', 'name', '1 when the acceptor is started, tagged name=<the acceptor>')],
         healthy="jmx_up 1; started 1; active 1 on the primary and 0 on a backup; every acceptor_up 1; replica_sync 1 under replication.",
         watch="uptime_seconds falling back: the broker restarted; version older than the newest of its line.",
         act="jmx_up 0 or started 0: the broker is down; active 1 on a backup: it has taken over (failover); "
             "replica_sync 0 for minutes: the backup is not in sync, and a failover now loses messages."),
    dict(job='broker', metric_name='artemis.broker', when='run_every   = 1m', title="an Artemis broker's memory, disk and totals",
         what="Reports the broker's address memory against global-max-size (past it, addresses page, block or "
              "drop, as each says), its disk use against max-disk-usage (past it, it blocks producers), its "
              "connections, sessions and consumers now and since it started, its messages and totals, its "
              "addresses and queues, and the logins and authorizations it has refused.",
         rows=[('address_memory_bytes', B, 'AddressMemoryUsage', '', 'memory the addresses hold'),
               ('address_memory_pct', B, 'AddressMemoryUsagePercentage', '', 'of global-max-size, in use'),
               ('global_max_bytes', B, 'GlobalMaxSize', '', 'global-max-size'),
               ('disk_pct', B, 'DiskStoreUsage', '*100', 'of the disk the journal is on, in use'),
               ('disk_max_pct', B, 'MaxDiskUsage', '', 'max-disk-usage: past it, producers are blocked'),
               ('connections', B, 'ConnectionCount', '', 'client connections now'),
               ('connections_count', B, 'TotalConnectionCount', '', 'client connections since it started'),
               ('sessions', B, 'SessionCount', '', 'sessions now'),
               ('sessions_count', B, 'TotalSessionCount', '', 'sessions since it started'),
               ('consumers', B, 'TotalConsumerCount', '', 'consumers now'),
               ('messages', B, 'TotalMessageCount', '', 'messages waiting, every queue'),
               ('added_count', B, 'TotalMessagesAdded', '', 'messages added to queues'),
               ('acknowledged_count', B, 'TotalMessagesAcknowledged', '', 'messages acknowledged'),
               ('addresses', B, 'AddressCount', '', 'addresses'),
               ('queues', B, 'QueueCount', '', 'queues'),
               ('login_failed_count', B, 'AuthenticationFailureCount', '', 'logins refused'),
               ('login_count', B, 'AuthenticationSuccessCount', '', 'logins'),
               ('authorization_failed_count', B, 'AuthorizationFailureCount', '', 'actions refused for a role'),
               ('mirror_pending', B, 'PendingMirrorAcks', '', 'acknowledgements a mirror owes (AMQP mirroring)')],
         healthy="address_memory_pct and disk_pct well below their limits; login_failed_count flat.",
         watch="address_memory_pct above 70: addresses near paging; disk_pct nearing disk_max_pct.",
         act="disk_pct at disk_max_pct: producers are blocked; address_memory_pct at 100: addresses page to "
             "disk, block or drop (artemis_addresses says which are paging); login_failed_count rising: a client "
             "with a wrong password, or someone guessing."),
    dict(job='addresses', metric_name='artemis.address', when='run_every   = 1m', max_runtime='2m', title="an Artemis broker's addresses and paging",
         what="Reports each address (Artemis's own left out): its size in memory and against its limit, its "
              "messages, whether it is paging and how many pages are on disk, the messages routed to its queues "
              "and those routed nowhere, its queues, and whether it is paused. The 100 largest first.",
         rows=[('size_bytes', A, 'AddressSize', 'address top ' + NOSYS, 'memory its messages hold, tagged address=<the address>; the largest first'),
               ('limit_pct', A, 'AddressLimitPercent', 'address ' + NOSYS, 'of its max-size-bytes, in use, tagged the same'),
               ('messages', A, 'NumberOfMessages', 'address ' + NOSYS, 'messages in its queues, tagged the same'),
               ('paging', A, 'Paging', 'address ' + NOSYS, '1 when it is paging to disk, tagged the same'),
               ('pages', A, 'NumberOfPages', 'address ' + NOSYS, 'pages on disk, tagged the same'),
               ('routed_count', A, 'RoutedMessageCount', 'address ' + NOSYS, 'messages routed to its queues, tagged the same'),
               ('unrouted_count', A, 'UnRoutedMessageCount', 'address ' + NOSYS, 'messages sent to it and routed nowhere (no queue), tagged the same'),
               ('queues', A, 'QueueCount', 'address ' + NOSYS, 'its queues, tagged the same'),
               ('paused', A, 'Paused', 'address ' + NOSYS, '1 when it is paused, tagged the same')],
         healthy="paging 0; limit_pct well below 100; unrouted_count flat.",
         watch="paging 1: the address holds more than memory allows, on disk now; pages growing.",
         act="limit_pct at 100 on an address with BLOCK or FAIL: producers are blocked or refused; "
             "unrouted_count rising: messages sent where no queue reads them are lost."),
    dict(job='queues', metric_name='artemis.queue', when='run_every   = 1m', max_runtime='2m', title="an Artemis broker's queues",
         what="Reports each queue (Artemis's own left out): messages waiting and the age of the oldest, those "
              "being delivered and scheduled, added, acknowledged, expired and killed (sent to the dead letter "
              "address), its consumers, its size on disk, groups and prepared transactions, and whether it is "
              "paused. The deepest 100 queues first.",
         rows=[qrow('messages', 'MessageCount', 'top', 'messages waiting, tagged address=<its address> and queue=<the queue>; the deepest first'),
               qrow('oldest_seconds', 'FirstMessageAge', '*0.001', 'the age of its oldest message, tagged the same'),
               qrow('delivering', 'DeliveringCount', '', 'messages being delivered, not yet acknowledged, tagged the same'),
               qrow('scheduled', 'ScheduledCount', '', 'messages scheduled for later, tagged the same'),
               qrow('added_count', 'MessagesAdded', '', 'messages added, tagged the same'),
               qrow('acknowledged_count', 'MessagesAcknowledged', '', 'messages acknowledged, tagged the same'),
               qrow('expired_count', 'MessagesExpired', '', 'messages that expired, tagged the same'),
               qrow('killed_count', 'MessagesKilled', '', 'messages sent to the dead letter address (too many deliveries), tagged the same'),
               qrow('consumers', 'ConsumerCount', '', 'consumers, tagged the same'),
               qrow('persistent_bytes', 'PersistentSize', '', 'the size of its messages, tagged the same'),
               qrow('groups', 'GroupCount', '', 'message groups, tagged the same'),
               qrow('prepared', 'PreparedTransactionMessageCount', '', 'messages in prepared (XA) transactions, tagged the same'),
               qrow('paused', 'Paused', '', '1 when it is paused, tagged the same')],
         healthy="messages rising and falling; oldest_seconds small; consumers above 0 on every queue that should be read.",
         watch="oldest_seconds growing: consumers are falling behind; killed_count rising.",
         act="messages growing with consumers 0: nothing reads it; oldest_seconds in hours; prepared above 0 for "
             "long: an XA transaction left in doubt."),
    dict(job='dlq', metric_name='artemis.dlq', when='run_every   = 1m', title="an Artemis broker's dead letter and expiry queues",
         what="Reports each dead letter queue (DLQ in its name) and expiry queue (Expiry in its name): messages "
              "in it, the age of the oldest, and those added. A message lands there when it fails delivery too "
              "many times, or expires.",
         rows=[('dead', DLQ, 'MessageCount', 'address queue top', 'messages in a dead letter queue, tagged address and queue; the most first'),
               ('dead_oldest_seconds', DLQ, 'FirstMessageAge', 'address queue *0.001', 'the age of its oldest, tagged the same'),
               ('dead_added_count', DLQ, 'MessagesAdded', 'address queue', 'messages added to it, tagged the same'),
               ('expired', EXP, 'MessageCount', 'address queue top', 'messages in an expiry queue, tagged the same; the most first'),
               ('expired_added_count', EXP, 'MessagesAdded', 'address queue', 'messages added to it, tagged the same')],
         healthy="dead and expired 0, or flat.",
         watch="dead_added_count rising: messages are failing delivery.",
         act="dead growing: messages nobody handled are piling up; read or purge them once the cause is fixed."),
    dict(job='cluster', metric_name='artemis.cluster', when='run_every   = 2m', title="an Artemis broker's cluster connections and bridges",
         what="Reports each cluster connection, core bridge and broker connection (AMQP, mirroring): started, "
              "and for the cluster and bridges, the messages sent and not yet acknowledged by the other side.",
         rows=[('cluster_up', CC, 'Started', 'name', '1 when the cluster connection is started, tagged name=<it>'),
               ('cluster_pending', CC, 'MessagesPendingAcknowledgement', 'name', 'messages sent to other nodes, not yet acknowledged, tagged the same'),
               ('cluster_acknowledged_count', CC, 'MessagesAcknowledged', 'name', 'messages the other nodes acknowledged, tagged the same'),
               ('bridge_up', BR, 'Started', 'name', '1 when the bridge is started, tagged name=<it>'),
               ('bridge_pending', BR, 'MessagesPendingAcknowledgement', 'name', 'messages it sent, not yet acknowledged, tagged the same'),
               ('bridge_acknowledged_count', BR, 'MessagesAcknowledged', 'name', 'messages acknowledged by the other side, tagged the same'),
               ('connection_up', BC, 'Open', 'name', '1 when the broker connection is open, tagged name=<it>')],
         healthy="every cluster_up, bridge_up and connection_up 1; pending small.",
         watch="pending growing: the other side is slow, or the network is.",
         act="cluster_up, bridge_up or connection_up 0: messages for the other brokers wait here."),
]

PACK = dict(
    name='artemis', tag='broker', product='Artemis', what_tuned='brokers',
    version='1.0.0',
    name_row='broker',
    name_doc='Each broker is named as ARTEMIS_JMX names it (art1: jmxs=host:port), else by its address; its own name is in artemis_status.',
    jmx_doc=("Reads each ActiveMQ Artemis broker's JMX, at ARTEMIS_JMX: jmx=host:port, or jmxs=host:port over TLS, "
             "separated by ; or , each with a name first if you like (art1: jmxs=host:port); with ARTEMIS_JMX_USER "
             "(a broker user of a role management.xml lets read: get*, is*) and the password in "
             "ARTEMIS_JMX_PASSWORD; a certificate is checked against ARTEMIS_CACERT, a PEM file of CAs, or "
             "Java's own, and against the server's name. With no ARTEMIS_JMX, it prints nothing. ActiveMQ Classic "
             "is the activemq pack's; the broker's JVM (heap, garbage collection, threads, CPU, open files) is "
             "the jvm pack's, not this one's."),
    description='Apache ActiveMQ Artemis over JMX: health and HA, address memory and disk against their limits, '
                'addresses and paging, queues (the deepest first, the oldest message), dead letter and expiry '
                'queues, logins refused, cluster connections and bridges',
    works_with="Apache ActiveMQ Artemis 2.x (tested: 2.33, 2.40 and 2.44), with management.xml's JMX connector on; Classic is the activemq pack's",
    needs=["each broker's JMX in ARTEMIS_JMX (art1: jmxs=host:port): the connector in its management.xml, with TLS "
           "(packs/README.md shows how)",
           "a broker user for it, of a role management.xml lets read (get*, is* and list*), in ARTEMIS_JMX_USER, "
           "and its password a secret line on the jobs: secret = ARTEMIS_JMX_PASSWORD=secret:ARTEMIS_JMX_PASSWORD, "
           "then vigil secret set ARTEMIS_JMX_PASSWORD",
           "for the broker's JVM (heap, garbage collection, threads, CPU, open files): the jvm pack, not this one: "
           "vigil pack install jvm, with each broker in JVM_TARGETS named as here (art1: jmxs=host:port)"],
    config_head=['artemis - Apache ActiveMQ Artemis, on this machine or any it can reach,',
                 'over JMX: its health and high availability, address memory and disk',
                 'against their limits, addresses and paging, queues (the deepest first,',
                 'and the age of the oldest message), dead letter and expiry queues,',
                 'refused logins, cluster connections and bridges. ActiveMQ Classic is the',
                 'activemq pack\'s; the broker\'s JVM is the jvm pack\'s. Linux, macOS and',
                 'Windows. See SPECIFICATION.md section 18.10 for this format, and',
                 'tools/probe/DESIGN.md for the probe that reads it.',
                 '',
                 'Every script runs _probe.jar, beside it, with Java 11 or later (a JDK or a',
                 'JRE), once it matches the digest the script carries, with this pack\'s',
                 '_probe.tables. Nothing of Artemis\'s is needed here: only its JMX.',
                 '',
                 'Off until enabled: vigil pack enable artemis. Then set ARTEMIS_JMX in the',
                 'jobs vigil pack enable writes into the configuration (art1:',
                 'jmxs=host:port), ARTEMIS_JMX_USER, and for its password a secret line',
                 '(packs/README.md has it all).'],
    jobs=JOBS,
)

if __name__ == '__main__':
    packgen.write(sys.argv[1], PACK)
