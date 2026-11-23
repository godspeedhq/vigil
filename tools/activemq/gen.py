# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""Writes packs/activemq: Apache ActiveMQ Classic (5.x and 6.x), over JMX,
as tables for the probe (tools/probe/packgen.py). ActiveMQ Artemis is the
artemis pack's: its MBeans are another tree. Run from the repository:
python tools/activemq/gen.py ."""
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[1], 'tools', 'probe'))
import packgen  # noqa: E402

B = 'org.apache.activemq:type=Broker,brokerName=*'
HEALTH = 'org.apache.activemq:type=Broker,brokerName=*,service=Health'
STORE = 'org.apache.activemq:type=Broker,brokerName=*,service=PersistenceAdapter,*'
TC = 'org.apache.activemq:type=Broker,brokerName=*,connector=clientConnectors,connectorName=*'
NB = 'org.apache.activemq:type=Broker,brokerName=*,connector=networkConnectors,networkConnectorName=*,networkBridge=*'
CONN = 'org.apache.activemq:type=Broker,brokerName=*,connector=clientConnectors,connectorName=*,connectionViewType=clientId,connectionName=*'
Q = 'org.apache.activemq:type=Broker,brokerName=*,destinationType=Queue,destinationName=*'
DLQ = 'org.apache.activemq:type=Broker,brokerName=*,destinationType=Queue,destinationName=*DLQ*'
T = 'org.apache.activemq:type=Broker,brokerName=*,destinationType=Topic,destinationName=*'
NOADV = '-destinationName=ActiveMQ.Advisory.*'
SUB = 'org.apache.activemq:type=Broker,brokerName=*,destinationType=*,destinationName=*,endpoint=Consumer,*'
PROD = 'org.apache.activemq:type=Broker,brokerName=*,destinationType=*,destinationName=*,endpoint=Producer,*'


def qrows(p, words, tagdoc):
    w = 'destinationName ' + words
    return [
        ('size', p, 'QueueSize', w + ' top', 'messages waiting, tagged destinationName=<the queue>; the deepest first'),
        ('enqueued_count', p, 'EnqueueCount', w, 'messages sent to it, tagged the same'),
        ('dequeued_count', p, 'DequeueCount', w, 'messages consumed and acknowledged, tagged the same'),
        ('dispatched_count', p, 'DispatchCount', w, 'messages handed to consumers, tagged the same'),
        ('expired_count', p, 'ExpiredCount', w, 'messages that expired, tagged the same'),
        ('in_flight', p, 'InFlightCount', w, 'messages handed to consumers and not yet acknowledged, tagged the same'),
        ('consumers', p, 'ConsumerCount', w, 'consumers, tagged the same'),
        ('producers', p, 'ProducerCount', w, 'producers, tagged the same'),
        ('memory_pct', p, 'MemoryPercentUsage', w, 'of its memory limit, in use, tagged the same'),
        ('memory_bytes', p, 'MemoryUsageByteCount', w, 'memory its messages hold, tagged the same'),
        ('cursor_pct', p, 'CursorPercentUsage', w, "of its cursor's memory, in use, tagged the same"),
        ('blocked_sends_count', p, 'BlockedSends', w, 'sends held back by flow control, tagged the same'),
        ('blocked_seconds', p, 'TotalBlockedTime', w + ' *0.001', 'time sends were held back, added up, tagged the same'),
        ('enqueue_mean_seconds', p, 'AverageEnqueueTime', w + ' *0.001', 'how long a message waits in it, on average, tagged the same'),
        ('enqueue_max_seconds', p, 'MaxEnqueueTime', w + ' *0.001', 'the longest a message waited, tagged the same'),
        ('message_mean_bytes', p, 'AverageMessageSize', w, 'the mean size of a message, tagged the same'),
        ('paused', p, 'Paused', w, '1 when it is paused (no dispatch), tagged the same'),
        ('forwarded_count', p, 'ForwardCount', w, 'messages forwarded to another broker, tagged the same'),
        ('store_bytes', p, 'StoreMessageSize', w, 'the size of its messages in the store (6.x), tagged the same'),
        ('temp_pct', p, 'TempUsagePercentUsage', w, 'of its temp limit (non-persistent messages on disk), in use, tagged the same'),
        ('cursor_full', p, 'CursorFull', w, '1 when its cursor is full: no more messages paged in to dispatch, tagged the same'),
        ('blocked_mean_seconds', p, 'AverageBlockedTime', w + ' *0.001', 'how long a held-back send waited, on average, tagged the same'),
        ('network_enqueued_count', p, 'NetworkEnqueues', w, 'messages that came from another broker, tagged the same'),
        ('network_dequeued_count', p, 'NetworkDequeues', w, 'messages that went on to another broker, tagged the same'),
        ('message_max_bytes', p, 'MaxMessageSize', w, 'the largest message, tagged the same'),
        ('duplicates_count', p, 'DuplicateFromStoreCount', w, 'duplicates found in the store, tagged the same'),
        ('uncommitted_exceeded_count', p, 'MaxUncommittedExceededCount', w, 'transactions refused for holding too many messages, tagged the same'),
    ]


JOBS = [
    dict(job='status', metric_name='activemq', when='run_every   = 1m', title="an ActiveMQ broker's health",
         what="Reports whether each broker answers over JMX, its name and version, how long it has been up, "
              "its health check (Good, or what is wrong), whether it is a slave (master/slave), and each "
              "transport connector: started, and connections refused for its maximumConnections.",
         rows=[('version', B, 'BrokerVersion', '@version', "always 1, tagged version=<ActiveMQ's version, 6.2.0>"),
               ('broker', B, 'BrokerName', '@broker_name', "always 1, tagged broker_name=<the broker's own name>"),
               ('uptime_seconds', B, 'UptimeMillis', '*0.001', 'since the broker started'),
               ('healthy', HEALTH, 'CurrentStatus', '=Good', "1 when the broker's health check says Good, else 0"),
               ('slave', B, 'Slave', '', '1 when it is a slave, waiting for the master (the store lock), else 0'),
               ('connector_up', TC, 'Started', 'connectorName', '1 when the transport connector is started, tagged connectorName=<openwire, amqp...>'),
               ('connections_refused_count', TC, 'MaxConnectionExceededCount', 'connectorName', 'connections refused for its maximumConnections, tagged the same')],
         healthy="jmx_up 1; healthy 1; every connector_up 1; connections_refused_count flat.",
         watch="uptime_seconds falling back: the broker restarted; version older than the newest of its line.",
         act="jmx_up 0 or healthy 0: the broker is down or unwell (its log, and the health MBean, say why); "
             "connections_refused_count rising: clients are turned away; slave 1 on the broker that should be "
             "master."),
    dict(job='broker', metric_name='activemq.broker', when='run_every   = 1m', title="an ActiveMQ broker's limits and totals",
         what="Reports the broker's memory, store, temp and scheduler store, each in use against its limit (past "
              "100 percent, producer flow control holds senders back), its store's size, its connections, "
              "producers and consumers now, its messages, destinations and totals, and message sizes.",
         rows=[('memory_pct', B, 'MemoryPercentUsage', '', 'of the memory limit (systemUsage memoryUsage), in use'),
               ('memory_limit_bytes', B, 'MemoryLimit', '', 'the memory limit'),
               ('store_pct', B, 'StorePercentUsage', '', 'of the store limit (storeUsage), in use'),
               ('store_limit_bytes', B, 'StoreLimit', '', 'the store limit'),
               ('temp_pct', B, 'TempPercentUsage', '', 'of the temp limit (tempUsage: non-persistent messages on disk), in use'),
               ('temp_limit_bytes', B, 'TempLimit', '', 'the temp limit'),
               ('scheduler_pct', B, 'JobSchedulerStorePercentUsage', '', 'of the scheduler store limit, in use'),
               ('scheduler_limit_bytes', B, 'JobSchedulerStoreLimit', '', 'the scheduler store limit'),
               ('store_bytes', STORE, 'Size', 'sum', "the persistence adapter's size (KahaDB, JDBC...)"),
               ('connections', B, 'CurrentConnectionsCount', '', 'client connections now'),
               ('connections_count', B, 'TotalConnectionsCount', '', 'client connections since it started'),
               ('producers', B, 'TotalProducerCount', '', 'producers now'),
               ('consumers', B, 'TotalConsumerCount', '', 'consumers now'),
               ('messages', B, 'TotalMessageCount', '', 'messages waiting, every destination'),
               ('enqueued_count', B, 'TotalEnqueueCount', '', 'messages sent to it'),
               ('dequeued_count', B, 'TotalDequeueCount', '', 'messages consumed'),
               ('queues', B, 'TotalQueuesCount', '', 'queues'),
               ('topics', B, 'TotalTopicsCount', '', 'topics, advisory ones too'),
               ('temp_queues', B, 'TotalTemporaryQueuesCount', '', 'temporary queues'),
               ('temp_topics', B, 'TotalTemporaryTopicsCount', '', 'temporary topics'),
               ('message_mean_bytes', B, 'AverageMessageSize', '', 'the mean size of a message'),
               ('message_max_bytes', B, 'MaxMessageSize', '', 'the largest message')],
         healthy="memory_pct, store_pct and temp_pct well below 100; messages rising and falling with traffic.",
         watch="store_pct above 70: messages piling up on disk; messages growing without falling back.",
         act="memory_pct, store_pct or temp_pct at 100: producer flow control blocks senders (or they fail, "
             "with sendFailIfNoSpace). Find the queue that keeps them (activemq_queues)."),
    dict(job='queues', metric_name='activemq.queue', when='run_every   = 1m', max_runtime='2m', title="an ActiveMQ broker's queues",
         what="Reports each queue: messages waiting, sent, consumed, dispatched, expired and in flight, its "
              "consumers and producers, its memory and cursor in use, sends held back by flow control, how long "
              "messages wait, message sizes and whether it is paused. The deepest 100 queues, the rest counted.",
         rows=qrows(Q, '', ''),
         healthy="size rising and falling; consumers above 0 on every queue that should be read; blocked_sends_count flat.",
         watch="size growing on one queue; enqueue_mean_seconds growing: consumers are falling behind.",
         act="size growing with consumers 0: nothing reads it; blocked_sends_count rising: flow control holds "
             "producers back (its memory_pct at 100)."),
    dict(job='topics', metric_name='activemq.topic', when='run_every   = 1m', max_runtime='2m', title="an ActiveMQ broker's topics",
         what="Reports each topic (advisory topics left out): messages sent, delivered, expired and pending "
              "for slow or offline subscribers, its consumers and producers, memory in use and sends held back. "
              "The 100 with the most pending, the rest counted.",
         rows=[('pending', T, 'QueueSize', 'destinationName top ' + NOADV, 'messages pending for its subscribers, tagged destinationName=<the topic>; the most first'),
               ('enqueued_count', T, 'EnqueueCount', 'destinationName ' + NOADV, 'messages sent to it, tagged the same'),
               ('dequeued_count', T, 'DequeueCount', 'destinationName ' + NOADV, 'messages delivered and acknowledged, tagged the same'),
               ('dispatched_count', T, 'DispatchCount', 'destinationName ' + NOADV, 'messages handed to subscribers, tagged the same'),
               ('expired_count', T, 'ExpiredCount', 'destinationName ' + NOADV, 'messages that expired, tagged the same'),
               ('consumers', T, 'ConsumerCount', 'destinationName ' + NOADV, 'subscribers, tagged the same'),
               ('producers', T, 'ProducerCount', 'destinationName ' + NOADV, 'producers, tagged the same'),
               ('memory_pct', T, 'MemoryPercentUsage', 'destinationName ' + NOADV, 'of its memory limit, in use, tagged the same'),
               ('blocked_sends_count', T, 'BlockedSends', 'destinationName ' + NOADV, 'sends held back by flow control, tagged the same')],
         healthy="pending near 0.",
         watch="pending growing on one topic: a subscriber is slow, or a durable one offline.",
         act="pending growing for hours: an offline durable subscriber keeps every message on disk "
             "(activemq_subscribers names it); store_pct rises with it."),
    dict(job='dlq', metric_name='activemq.dlq', when='run_every   = 1m', title="an ActiveMQ broker's dead letter queues",
         what="Reports each dead letter queue (a queue whose name has DLQ in it: ActiveMQ.DLQ, or a DLQ of "
              "each destination): messages in it and sent to it. A message lands there when it expires or "
              "fails delivery too many times.",
         rows=[('size', DLQ, 'QueueSize', 'destinationName top', 'messages in it, tagged destinationName=<the queue>; the most first'),
               ('enqueued_count', DLQ, 'EnqueueCount', 'destinationName', 'messages sent to it, tagged the same')],
         healthy="size 0, or flat.",
         watch="enqueued_count rising: messages are expiring or failing delivery.",
         act="size growing: messages nobody handled are piling up (and taking store); read or purge them once "
             "the cause is fixed."),
    dict(job='subscribers', metric_name='activemq.subscriber', when='run_every   = 2m', max_runtime='2m', title="an ActiveMQ broker's consumers and durable subscribers",
         what="Reports each consumer and durable subscription: messages pending for it and dispatched to it and "
              "not acknowledged, delivered and acknowledged, whether it is active (a durable subscriber "
              "offline is not) and whether the broker calls it slow. The 100 with the most pending first.",
         rows=[('pending', SUB, 'PendingQueueSize', 'destinationName clientId top', 'messages waiting for it, tagged destinationName=<its destination> and clientId=<its client>; the most first'),
               ('dispatched', SUB, 'DispatchedQueueSize', 'destinationName clientId', 'messages handed to it, not yet acknowledged, tagged the same'),
               ('enqueued_count', SUB, 'EnqueueCounter', 'destinationName clientId', 'messages for it, tagged the same'),
               ('dequeued_count', SUB, 'DequeueCounter', 'destinationName clientId', 'messages it acknowledged, tagged the same'),
               ('active', SUB, 'Active', 'destinationName clientId', '1 when it is connected, 0 for a durable subscriber offline, tagged the same'),
               ('slow', SUB, 'SlowConsumer', 'destinationName clientId', '1 when the broker calls it slow, tagged the same')],
         healthy="pending near 0 for every subscriber; active 1.",
         watch="slow 1; pending growing on one.",
         act="active 0 with pending growing: an offline durable subscriber keeps every message for it. Bring "
             "it back, or remove the subscription."),
    dict(job='producers', metric_name='activemq.producer', when='run_every   = 2m', max_runtime='2m', title="an ActiveMQ broker's producers, and those held back",
         what="Reports each producer: whether flow control holds it back now, how long it has been held back "
              "and its share of the time, and the messages it sent. The 100 held back longest first.",
         rows=[('blocked_seconds', PROD, 'TotalTimeBlocked', 'destinationName clientId top *0.001', 'how long it has been held back by flow control, added up, tagged destinationName=<its destination> and clientId=<its client>; the longest first'),
               ('blocked', PROD, 'ProducerBlocked', 'destinationName clientId', '1 when flow control holds it back now, tagged the same'),
               ('blocked_pct', PROD, 'PercentageBlocked', 'destinationName clientId', 'of its time, held back, tagged the same'),
               ('sent_count', PROD, 'SentCount', 'destinationName clientId', 'messages it sent, tagged the same')],
         healthy="blocked 0 for every producer.",
         watch="blocked_pct climbing on one producer.",
         act="blocked 1 for minutes: its destination is at its memory limit (activemq_queues memory_pct), and the "
             "producer waits; nothing reads what it sends."),
    dict(job='connections', metric_name='activemq.connection', when='run_every   = 2m', max_runtime='2m', title="an ActiveMQ broker's client connections and network bridges",
         what="Reports each client connection (the 100 with the most waiting to be dispatched): messages "
              "waiting to go to it, whether it is blocked or slow, its open transactions and the oldest's age; "
              "and each network bridge to another broker, with the messages it forwarded.",
         rows=[('dispatch_queue', CONN, 'DispatchQueueSize', 'connectorName connectionName top', 'messages waiting to be sent to it, tagged connectorName=<its connector> and connectionName=<its client>; the most first'),
               ('blocked', CONN, 'Blocked', 'connectorName connectionName', '1 when it is blocked (flow control), tagged the same'),
               ('slow', CONN, 'Slow', 'connectorName connectionName', '1 when it is slow, tagged the same'),
               ('transactions', CONN, 'ActiveTransactionCount', 'connectorName connectionName', 'transactions open on it, tagged the same'),
               ('oldest_transaction_seconds', CONN, 'OldestActiveTransactionDuration', 'connectorName connectionName *0.001 >=0', 'how long its oldest open transaction has been open, tagged the same'),
               ('bridge', NB, 'RemoteBrokerName', 'networkConnectorName @remote', 'always 1 for a network bridge up, tagged networkConnectorName=<its connector> and remote=<the broker it reaches>'),
               ('bridge_enqueued_count', NB, 'EnqueueCounter', 'networkConnectorName networkBridge', 'messages it took from this broker, tagged networkConnectorName and networkBridge=<the bridge>'),
               ('bridge_dequeued_count', NB, 'DequeueCounter', 'networkConnectorName networkBridge', 'messages it forwarded, tagged the same')],
         healthy="dispatch_queue small; blocked 0; transactions few and short; a bridge for every network connector.",
         watch="slow 1 on a connection; oldest_transaction_seconds in minutes.",
         act="blocked 1: the client is held back by flow control; a bridge line gone: the brokers no longer "
             "forward to each other."),
]

PACK = dict(
    name='activemq', tag='broker', product='ActiveMQ', what_tuned='brokers',
    version='1.0.0',
    name_row='broker',
    name_doc='Each broker is named as ACTIVEMQ_JMX names it (amq1: jmxs=host:port), else by its address; its own name is in activemq_status.',
    jmx_doc=("Reads each ActiveMQ Classic broker's JMX, at ACTIVEMQ_JMX: jmx=host:port, or jmxs=host:port over "
             "TLS, separated by ; or , each with a name first if you like (amq1: jmxs=host:port); with "
             "ACTIVEMQ_JMX_USER and the password in ACTIVEMQ_JMX_PASSWORD when JMX asks for them; a certificate "
             "is checked against ACTIVEMQ_CACERT, a PEM file of CAs, or Java's own, and against the server's "
             "name. With no ACTIVEMQ_JMX, it prints nothing. ActiveMQ Artemis is the artemis pack's; the broker's "
             "JVM (heap, garbage collection, threads, CPU, open files) is the jvm pack's, not this one's."),
    description='Apache ActiveMQ Classic over JMX: health, memory, store and temp limits, queues (the deepest first), '
                'topics, dead letter queues, durable subscribers, connections and network bridges',
    works_with='Apache ActiveMQ Classic 5.18 to 6.x (tested: 5.18, 5.19 and 6.2), with JMX on; Artemis is the artemis pack\'s',
    needs=["each broker's JMX in ACTIVEMQ_JMX (amq1: jmxs=host:port): -Dcom.sun.management.jmxremote.port and a "
           "password and TLS in ACTIVEMQ_SUNJMX_START (packs/README.md shows how)",
           "for JMX with a password: a secret line on the jobs: secret = ACTIVEMQ_JMX_PASSWORD=secret:ACTIVEMQ_JMX_PASSWORD, "
           "then vigil secret set ACTIVEMQ_JMX_PASSWORD",
           "for the broker's JVM (heap, garbage collection, threads, CPU, open files): the jvm pack, not this one: "
           "vigil pack install jvm, with each broker in JVM_TARGETS named as here (amq1: jmxs=host:port)"],
    config_head=['activemq - Apache ActiveMQ Classic, on this machine or any it can reach,',
                 'over JMX: its health, its memory, store and temp against their limits,',
                 'queues (the deepest first), topics, dead letter queues, consumers and',
                 'durable subscribers, connections and network bridges. ActiveMQ Artemis is',
                 'the artemis pack\'s; the broker\'s JVM is the jvm pack\'s. Linux, macOS and',
                 'Windows. See SPECIFICATION.md section 18.10 for this format, and',
                 'tools/probe/DESIGN.md for the probe that reads it.',
                 '',
                 'Every script runs _probe.jar, beside it, with Java 11 or later (a JDK or a',
                 'JRE), once it matches the digest the script carries, with this pack\'s',
                 '_probe.tables. Nothing of ActiveMQ\'s is needed here: only its JMX.',
                 '',
                 'Off until enabled: vigil pack enable activemq. Then set ACTIVEMQ_JMX in the',
                 'jobs vigil pack enable writes into the configuration (amq1:',
                 'jmxs=host:port), ACTIVEMQ_JMX_USER, and for its password a secret line',
                 '(packs/README.md has it all).'],
    jobs=JOBS,
)

if __name__ == '__main__':
    packgen.write(sys.argv[1], PACK)
