# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""Writes packs/jetty: Eclipse Jetty, over JMX, as tables for the probe
(tools/probe/packgen.py). Its rows are below, once. Jetty 9.4 to 11 and
Jetty 12 name some MBeans and units differently: 12's MBeans carry a
context key (its server, then a / and the part), and its request times are
in nanoseconds where 9.4 to 11's are in milliseconds, so those rows come in
pairs, one for each; an MBean a server does not have prints nothing. Run
from the repository: python tools/jetty/gen.py ."""
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[1], 'tools', 'probe'))
import packgen  # noqa: E402

SRV = 'org.eclipse.jetty.server:type=server,*'
ST = 'org.eclipse.jetty.server.handler:type=statisticshandler,*'
ST9 = 'org.eclipse.jetty.server.handler:type=statisticshandler,id=*'
ST12 = 'org.eclipse.jetty.server.handler:type=statisticshandler,context=*,id=*'
QTP = 'org.eclipse.jetty.util.thread:type=queuedthreadpool,*'
CS = 'org.eclipse.jetty.io:type=connectionstatistics,*'
CL = 'org.eclipse.jetty.server:type=connectionlimit,*'
LR = 'org.eclipse.jetty.server:type=lowresourcemonitor,*'
QOS = 'org.eclipse.jetty.server.handler:type=qoshandler,*'
WA = 'org.eclipse.jetty*:type=webappcontext,*'
SC = 'org.eclipse.jetty*:type=*sessioncache,*'
SH = 'org.eclipse.jetty*:type=sessionhandler,*'
BP = 'org.eclipse.jetty.io:type=*bytebufferpool,*'

JOBS = [
    dict(job='status', metric_name='jetty', when='run_every   = 1m', title="a Jetty's health",
         what="Reports whether each Jetty answers over JMX, its version, whether the server and each web "
              "application are started, how long since it started (9.4 to 11), and whether it is low on "
              "resources (the lowresources module), and since when.",
         rows=[('version', SRV, 'version', '@version', "always 1, tagged version=<Jetty's version, 12.1.15>"),
               ('up', SRV, 'state', '=STARTED', '1 when the server is started, else 0'),
               ('uptime_seconds', SRV, 'startupTime', 'age', 'since the server started (9.4 to 11: 12 gives it as a text)'),
               ('app_up', WA, 'state', 'context/ =STARTED', '1 when the web application is started, else 0 (FAILED, STOPPED), tagged context=<its name>. Jetty keeps an app whose start failed STARTED and answers 503, unless it throws (throwUnavailableOnStartupException): its 503s show in jetty_requests'),
               ('low_on_resources', LR, 'lowOnResources', '', '1 when the low resources monitor says so, else 0'),
               ('low_since_seconds', LR, 'lowResourcesStarted', 'age', 'how long it has been low on resources, when it is')],
         healthy="jmx_up 1; up 1 and every app_up 1; low_on_resources 0.",
         watch="uptime_seconds falling back: Jetty restarted; version older than the newest of its line.",
         act="jmx_up 0: Jetty or its JMX is down; app_up 0: that app answers 404 (and responses_5xx_count rising may be an app that failed to start, answering 503); low_on_resources 1: Jetty is "
             "closing idle connections early and may stop accepting."),
    dict(job='requests', metric_name='jetty.requests', when='run_every   = 1m', title="a Jetty's requests and responses",
         what="Reports the statistics module's figures for the whole server: requests and those active now, "
              "responses by class (1xx to 5xx), failures, the bytes in and out, and request times (the longest, "
              "the mean, the total), since Jetty started or its statistics were reset. Totals only grow: graph "
              "them as rates. Needs Jetty's statistics module (stats on 9.4 to 11).",
         rows=[('requests_count', ST, 'requests', '', 'requests'),
               ('active', ST, 'requestsActive', '', 'requests being handled now'),
               ('active_max', ST, 'requestsActiveMax', '', 'the most at once'),
               ('responses_1xx_count', ST, 'responses1xx', '', 'responses with a 1xx status'),
               ('responses_2xx_count', ST, 'responses2xx', '', 'with a 2xx status'),
               ('responses_3xx_count', ST, 'responses3xx', '', 'with a 3xx status'),
               ('responses_4xx_count', ST, 'responses4xx', '', 'with a 4xx status'),
               ('responses_5xx_count', ST, 'responses5xx', '', 'with a 5xx status (on 9.4 to 11, not those that threw: thrown_count)'),
               ('failures_count', ST12, 'failures', '', 'requests that failed (12)'),
               ('failures_count', ST9, 'errors', '', ''),
               ('handling_failures_count', ST12, 'handlingFailures', '', 'failures while handling (12)'),
               ('thrown_count', ST9, 'responsesThrown', '', 'requests that ended in an exception (9.4 to 11)'),
               ('dispatched_count', ST9, 'dispatched', '', 'dispatches to the application (9.4 to 11)'),
               ('dispatched_active', ST9, 'dispatchedActive', '', 'dispatches running now (9.4 to 11)'),
               ('handling_active', ST12, 'handleActive', '', 'requests being handled by the application now (12)'),
               ('async_count', ST9, 'asyncRequests', '', 'asynchronous requests (9.4 to 11)'),
               ('async_waiting', ST9, 'asyncRequestsWaiting', '', 'asynchronous requests waiting now (9.4 to 11)'),
               ('expired_count', ST9, 'expires', '', 'asynchronous requests that timed out (9.4 to 11)'),
               ('received_bytes', ST12, 'bytesRead', '', 'bytes of requests read (12)'),
               ('sent_bytes', ST12, 'bytesWritten', '', 'bytes of responses written'),
               ('sent_bytes', ST9, 'responsesBytesTotal', '', ''),
               ('slowest_seconds', ST12, 'requestTimeMax', '*0.000000001', 'the slowest request'),
               ('slowest_seconds', ST9, 'requestTimeMax', '*0.001', ''),
               ('mean_seconds', ST12, 'requestTimeMean', '*0.000000001', 'the mean time of a request'),
               ('mean_seconds', ST9, 'requestTimeMean', '*0.001', ''),
               ('total_seconds', ST12, 'requestTimeTotal', '*0.000000001', 'the time of every request, added up'),
               ('total_seconds', ST9, 'requestTimeTotal', '*0.001', '')],
         healthy="responses_5xx_count flat; active well below the thread pool's max; mean_seconds steady.",
         watch="responses_4xx_count rising faster than requests: clients asking for what is not there, or refused.",
         act="responses_5xx_count rising: the server or the apps are failing; active near the pool's max: "
             "requests are waiting for a thread."),
    dict(job='threads', metric_name='jetty.threads', when='run_every   = 1m', title="a Jetty's thread pool",
         what="Reports Jetty's thread pool: threads, busy, idle and ready, the most it may have, jobs waiting for "
              "a thread, how much of it is in use, whether it is low on threads, and the threads leased to "
              "Jetty's own work (acceptors and selectors) and reserved.",
         rows=[('threads', QTP, 'threads', 'id', 'threads it has, tagged id=<the pool>'),
               ('busy', QTP, 'busyThreads', 'id', 'busy threads, tagged the same'),
               ('idle', QTP, 'idleThreads', 'id', 'idle threads, tagged the same'),
               ('ready', QTP, 'readyThreads', 'id', 'threads ready for a job now, tagged the same'),
               ('utilized', QTP, 'utilizedThreads', 'id', 'threads running a job of the application, tagged the same'),
               ('max_threads', QTP, 'maxThreads', 'id', 'the most it may have, tagged the same'),
               ('min_threads', QTP, 'minThreads', 'id', 'the fewest it keeps, tagged the same'),
               ('queue', QTP, 'queueSize', 'id', 'jobs waiting for a thread, tagged the same'),
               ('utilization_pct', QTP, 'utilizationRate', 'id *100', 'how much of the pool is in use, tagged the same'),
               ('low_on_threads', QTP, 'lowOnThreads', 'id', '1 when it is low on threads, else 0, tagged the same'),
               ('leased', QTP, 'leasedThreads', 'id', "threads leased to Jetty's own work (acceptors, selectors), tagged the same"),
               ('reserved', QTP, 'availableReservedThreads', 'id', 'threads reserved and available, tagged the same'),
               ('max_available', QTP, 'maxAvailableThreads', 'id', 'the most that could run the application, tagged the same')],
         healthy="busy well below max_threads; queue 0; low_on_threads 0.",
         watch="utilization_pct above 80 for minutes; queue above 0 now and then.",
         act="queue growing and low_on_threads 1: every thread is busy and requests wait. Find what holds them "
             "(the jvm pack's threads and deadlocks)."),
    dict(job='connections', metric_name='jetty.connections', when='run_every   = 1m', title="a Jetty's connections",
         what="Reports Jetty's connections, every connector's added up (the connection statistics module): open "
              "now and at most, opened since, how long they last, the bytes and messages in and out; the "
              "connection limit (its module) and connections waiting for it; and the QoS handler's limit (12): "
              "requests suspended, refused and expired.",
         rows=[('open', CS, 'connections', 'sum', 'connections open now'),
               ('open_max', CS, 'connectionsMax', 'sum', 'the most open at once'),
               ('opened_count', CS, 'connectionsTotal', 'sum', 'connections opened'),
               ('duration_max_seconds', CS, 'connectionDurationMax', 'sum *0.001', 'the longest a connection lasted'),
               ('duration_mean_seconds', CS, 'connectionDurationMean', 'sum *0.001', 'how long a connection lasts, on average'),
               ('received_bytes', CS, 'receivedBytes', 'sum', 'bytes received'),
               ('sent_bytes', CS, 'sentBytes', 'sum', 'bytes sent'),
               ('received_messages_count', CS, 'receivedMessages', 'sum', 'messages received (requests, frames)'),
               ('sent_messages_count', CS, 'sentMessages', 'sum', 'messages sent'),
               ('limited', CL, 'connections', '', 'connections the connection limit counts'),
               ('limit', CL, 'maxConnections', '', 'its limit'),
               ('limit_pending', CL, 'pendingConnections', '', 'connections accepted but waiting for it (12)'),
               ('qos_max', QOS, 'maxRequestCount', '', "the QoS handler's limit of requests at once (12)"),
               ('qos_suspended', QOS, 'suspendedRequestCount', '', 'requests suspended for it now (12)'),
               ('qos_exceeded_count', QOS, 'totalExceededRequestCount', '', 'requests refused for it (12)'),
               ('qos_expired_count', QOS, 'totalExpiredRequestCount', '', 'requests that waited too long for it (12)')],
         healthy="open well below limit; limit_pending 0; qos_exceeded_count flat.",
         watch="open near limit; qos_suspended above 0: requests wait for the QoS handler.",
         act="limited at limit with limit_pending above 0: Jetty is not accepting more; qos_exceeded_count "
             "rising: requests refused."),
    dict(job='sessions', metric_name='jetty.sessions', when='run_every   = 1m', title="a Jetty's HTTP sessions, by app",
         what="Reports each app's session cache (sessions now, the most at once, every one created) and its "
              "session handler (sessions created, how long they live, their timeout).",
         rows=[('current', SC, 'sessionsCurrent', 'context/ top', 'sessions in the cache now, tagged context=<its app>; the most first'),
               ('most', SC, 'sessionsMax', 'context/', 'the most at once, tagged the same'),
               ('cached_count', SC, 'sessionsTotal', 'context/', 'sessions it has held, tagged the same'),
               ('created_count', SH, 'sessionsCreated', 'context/', 'sessions created, tagged the same'),
               ('alive_mean_seconds', SH, 'sessionTimeMean', 'context/', 'how long a session lives, on average, tagged the same'),
               ('alive_max_seconds', SH, 'sessionTimeMax', 'context/', 'the longest a session lived, tagged the same'),
               ('timeout_seconds', SH, 'maxInactiveInterval', 'context/', 'how long an idle session lives, tagged the same')],
         healthy="current rising and falling with traffic.",
         watch="current climbing without falling back: sessions created and never used again hold memory until "
               "they time out.",
         act="current far above what your users explain: a client or a bot making a session each request."),
    dict(job='buffers', metric_name='jetty.buffers', when='cron        = 2/5 * * * *', title="a Jetty's byte buffers",
         what="Reports the memory Jetty's own byte buffer pools hold, direct and on the heap, and how much of it "
              "is free to reuse. The heap and direct memory of the whole JVM are the jvm pack's.",
         rows=[('direct_bytes', BP, 'directMemory', 'sum', 'direct memory its pools hold'),
               ('heap_bytes', BP, 'heapMemory', 'sum', 'heap memory its pools hold'),
               ('direct_free_bytes', BP, 'availableDirectMemory', 'sum', 'of the direct, free to reuse (12)'),
               ('heap_free_bytes', BP, 'availableHeapMemory', 'sum', 'of the heap, free to reuse (12)')],
         healthy="direct_bytes and heap_bytes steady.",
         watch="direct_bytes growing without falling back.",
         act="direct_bytes near the JVM's -XX:MaxDirectMemorySize: Jetty will fail to allocate (the jvm pack's "
             "buffers job shows the limit)."),
]

PACK = dict(
    name='jetty', tag='jetty', product='Jetty', what_tuned='Jetty',
    version='1.0.0',
    name_row='jetty',
    name_doc='Each Jetty is named as JETTY_JMX names it (web1: jmxs=host:port), else by its address.',
    jmx_doc=("Reads each Jetty's JMX, at JETTY_JMX: jmx=host:port, or jmxs=host:port over TLS, separated by ; "
             "or , each with a name first if you like (web1: jmxs=host:port); with JETTY_JMX_USER and the "
             "password in JETTY_JMX_PASSWORD when JMX asks for them; a certificate is checked against "
             "JETTY_CACERT, a PEM file of CAs, or Java's own, and against the server's name. Jetty's MBeans are "
             "there with its jmx module. With no JETTY_JMX, it prints nothing. Jetty's JVM (heap, garbage "
             "collection, threads, CPU, open files) is the jvm pack's, not this one's."),
    description='Eclipse Jetty over JMX: server and apps, low resources, requests and responses by class, '
                'request times, the thread pool, connections and limits, QoS, sessions and byte buffers',
    works_with='Eclipse Jetty 9.4 to 12 (tested: 9.4, 11.0, 12.0 and 12.1), with its jmx and statistics modules',
    needs=["Jetty's jmx module, and its statistics module (stats on 9.4 to 11) for requests; each Jetty's JMX in "
           "JETTY_JMX (web1: jmxs=host:port): -Dcom.sun.management.jmxremote.port and a password and TLS in "
           "JAVA_OPTIONS (packs/README.md shows how)",
           "for JMX with a password: a secret line on the jobs: secret = JETTY_JMX_PASSWORD=secret:JETTY_JMX_PASSWORD, "
           "then vigil secret set JETTY_JMX_PASSWORD",
           "for Jetty's JVM (heap, garbage collection, threads, CPU, open files): the jvm pack, not this one: vigil "
           "pack install jvm, with each Jetty in JVM_TARGETS named as here (web1: jmxs=host:port)"],
    config_head=['jetty - Eclipse Jetty, on this machine or any it can reach, over JMX: the',
                 'server and its apps, low resources, requests and responses, request times,',
                 'the thread pool, connections and their limits, QoS, sessions and byte',
                 'buffers. Never Jetty\'s JVM: that is the jvm pack\'s. Linux, macOS and',
                 'Windows. See SPECIFICATION.md section 18.10 for this format, and',
                 'tools/probe/DESIGN.md for the probe that reads it.',
                 '',
                 'Every script runs _probe.jar, beside it, with Java 11 or later (a JDK or a',
                 'JRE), once it matches the digest the script carries, with this pack\'s',
                 '_probe.tables. Nothing of Jetty\'s is needed here: only its JMX.',
                 '',
                 'Off until enabled: vigil pack enable jetty. Then set JETTY_JMX in the jobs',
                 'vigil pack enable writes into the configuration (web1: jmxs=host:port),',
                 'JETTY_JMX_USER, and for its password a secret line (packs/README.md has',
                 'it all).'],
    jobs=JOBS,
)

if __name__ == '__main__':
    packgen.write(sys.argv[1], PACK)
