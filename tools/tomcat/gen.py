# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""Writes packs/tomcat: Apache Tomcat, over JMX, as tables for the probe
(tools/probe/packgen.py). Its rows are below, once. Run from the
repository: python tools/tomcat/gen.py ."""
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[1], 'tools', 'probe'))
import packgen  # noqa: E402

S = 'Catalina:type=Server'
GRP = 'Catalina:type=GlobalRequestProcessor,*'
TP = 'Catalina:type=ThreadPool,*'
EX = 'Catalina:type=Executor,*'
WM = 'Catalina:j2eeType=WebModule,*'
MG = 'Catalina:type=Manager,*'
SV = 'Catalina:j2eeType=Servlet,*'
DS = 'Catalina:type=DataSource,*'
HK = 'com.zaxxer.hikari:type=Pool?(*'
RC = 'Catalina:type=WebResourceRoot,name=Cache,*'
JSP = 'Catalina:type=JspMonitor,*'
NOKIDS = '-connectionpool=*'

JOBS = [
    dict(job='status', metric_name='tomcat', when='run_every   = 1m', title="a Tomcat's health",
         what="Reports whether each Tomcat answers over JMX, its version, and whether the server, its engine, "
              "each host and each connector are started.",
         rows=[('version', S, 'serverNumber', '@version', "always 1, tagged version=<Tomcat's version, 11.0.29.0>"),
               ('up', S, 'stateName', '=STARTED', '1 when the server is started, else 0'),
               ('engine_up', 'Catalina:type=Engine', 'stateName', '=STARTED', '1 when the engine is started, else 0'),
               ('host_up', 'Catalina:type=Host,*', 'stateName', 'host =STARTED', '1 when the host is started, else 0, tagged host=<its name>'),
               ('connector_up', 'Catalina:type=Connector,*', 'stateName', 'port =STARTED',
                '1 when the connector is started, else 0 (stopped, or its port taken), tagged port=<its port>')],
         healthy="jmx_up 1; up, engine_up, host_up and every connector_up 1.",
         watch="version older than the newest of its line: Tomcat fixes security issues in most releases.",
         act="jmx_up 0: Tomcat is down, or its JMX is; connector_up 0: that port takes no requests."),
    dict(job='requests', metric_name='tomcat.requests', when='run_every   = 1m', title="a Tomcat's requests, by connector",
         what="Reports each connector's requests since Tomcat started: how many, how many failed (a status of "
              "400 or more), the bytes in and out, the time spent, and the slowest. Totals only grow: graph them "
              "as rates.",
         rows=[('requests_count', GRP, 'requestCount', 'name', 'requests, tagged name=<the connector: http-nio-8080>'),
               ('errors_count', GRP, 'errorCount', 'name', 'of those, answered with a status of 400 or more, tagged the same'),
               ('sent_bytes', GRP, 'bytesSent', 'name', 'bytes sent, tagged the same'),
               ('received_bytes', GRP, 'bytesReceived', 'name', 'bytes received, tagged the same'),
               ('processing_seconds', GRP, 'processingTime', 'name *0.001', 'time spent on requests, tagged the same'),
               ('slowest_seconds', GRP, 'maxTime', 'name *0.001', 'the slowest request since Tomcat started, tagged the same')],
         healthy="errors_count rising far slower than requests_count; processing_seconds rising in step with requests.",
         watch="errors_count rising faster than usual: clients or the apps are failing (404s count too).",
         act="requests_count flat where there should be traffic; the share of errors climbing; processing_seconds "
             "per request climbing: the apps or what they call are slow."),
    dict(job='threads', metric_name='tomcat.threads', when='run_every   = 1m', title="a Tomcat's request threads and connections",
         what="Reports each connector's threads and connections (busy against the most it may have, connections "
              "open and kept alive, whether it is paused), and each shared Executor's threads and queue. When "
              "every thread is busy, requests wait; when the queue and the connections are full too, Tomcat turns "
              "them away.",
         rows=[('busy', TP, 'currentThreadsBusy', 'name >=0', 'threads handling a request now, tagged name=<the connector> (none for a connector on an Executor)'),
               ('threads', TP, 'currentThreadCount', 'name >=0', 'threads it has, tagged the same'),
               ('max_threads', TP, 'maxThreads', 'name >=0', 'the most it may have, tagged the same'),
               ('connections', TP, 'connectionCount', 'name >=0', 'connections open, tagged the same'),
               ('max_connections', TP, 'maxConnections', 'name >=0', 'the most it accepts, then they wait in the backlog, tagged the same'),
               ('keep_alive', TP, 'keepAliveCount', 'name >=0', 'connections kept alive between requests, tagged the same'),
               ('backlog_max', TP, 'acceptCount', 'name >=0', 'the backlog of connections waiting to be accepted, its size, tagged the same'),
               ('paused', TP, 'paused', 'name', '1 when the connector is paused (takes no requests), tagged the same'),
               ('executor_busy', EX, 'activeCount', 'name', "an Executor's threads handling a request now, tagged name=<the Executor>"),
               ('executor_threads', EX, 'poolSize', 'name', 'threads it has, tagged the same'),
               ('executor_max_threads', EX, 'maxThreads', 'name', 'the most it may have, tagged the same'),
               ('executor_largest', EX, 'largestPoolSize', 'name', 'the most it has had at once, tagged the same'),
               ('executor_queue', EX, 'queueSize', 'name', 'requests waiting for a thread, tagged the same'),
               ('executor_max_queue', EX, 'maxQueueSize', 'name', 'the most that may wait, then they are refused, tagged the same'),
               ('executor_done_count', EX, 'completedTaskCount', 'name', 'requests it has handled, tagged the same')],
         healthy="busy, or executor_busy, well below max_threads; executor_queue 0; connections well below max_connections.",
         watch="busy near max_threads for minutes; executor_queue above 0: requests are waiting for a thread.",
         act="busy at max_threads with executor_queue near executor_max_queue, or connections at max_connections: "
             "Tomcat is turning requests away. Find what holds the threads (tomcat_inflight, the jvm pack's "
             "threads and deadlocks)."),
    dict(job='inflight', metric_name='tomcat.inflight', when='run_every   = 1m', title="a Tomcat's requests running now, and stuck threads",
         what="Reports the requests running now, each with how long it has run so far, the longest first; and, "
              "where the StuckThreadDetectionValve is on, the threads it calls stuck (past its threshold) and "
              "those it has interrupted.",
         rows=[('running_seconds', 'Catalina:type=RequestProcessor,*', 'requestProcessingTime', 'worker name top >=1 *0.001',
                'how long a request running now has run, tagged worker=<the connector> and name=<its processor>; the longest first'),
               ('stuck_threads', 'Catalina:type=Valve,name=StuckThreadDetectionValve,*', 'stuckThreadCount', 'host',
                "threads on a request longer than the valve's threshold, tagged host=<its host>"),
               ('stuck_threshold_seconds', 'Catalina:type=Valve,name=StuckThreadDetectionValve,*', 'threshold', 'host',
                "the valve's threshold, tagged the same"),
               ('interrupted_count', 'Catalina:type=Valve,name=StuckThreadDetectionValve,*', 'interruptedThreadsCount', 'host',
                'stuck threads the valve has interrupted (with interruptThreadThreshold), tagged the same')],
         healthy="running_seconds of a second or less; stuck_threads 0.",
         watch="running_seconds in tens of seconds for some requests; stuck_threads above 0 now and then.",
         act="stuck_threads staying above 0, or rising: requests that never end hold threads until none are left. "
             "A thread dump shows where they wait (a database, a lock, another service)."),
    dict(job='apps', metric_name='tomcat.app', when='run_every   = 2m', title="each web application in a Tomcat",
         what="Reports each web application: whether it is started (an app that failed to start is FAILED), how "
              "long since it started and how long starting took, and its requests, errors (an exception), time "
              "and slowest request since then. The apps with the most errors first.",
         rows=[('up', WM, 'stateName', 'name =STARTED', '1 when the app is started, else 0 (FAILED, STOPPED), tagged name=<//host/path>'),
               ('uptime_seconds', WM, 'startTime', 'name age', 'since the app started, tagged the same'),
               ('startup_seconds', WM, 'startupTime', 'name *0.001', 'how long it took to start, tagged the same'),
               ('errors_count', WM, 'errorCount', 'name top', 'requests that ended in an exception, tagged the same; the most first'),
               ('requests_count', WM, 'requestCount', 'name', 'requests, tagged the same'),
               ('processing_seconds', WM, 'processingTime', 'name *0.001', 'time spent on requests, tagged the same'),
               ('slowest_seconds', WM, 'maxTime', 'name *0.001', 'the slowest request, tagged the same')],
         healthy="up 1 for every app; uptime_seconds only growing; errors_count flat or rising slowly.",
         watch="uptime_seconds falling back: the app was restarted or redeployed; errors_count rising.",
         act="up 0: the app failed to start or was stopped, and answers 404 (Tomcat's log says why)."),
    dict(job='sessions', metric_name='tomcat.sessions', when='run_every   = 1m', title="a Tomcat's HTTP sessions, by app",
         what="Reports each app's HTTP sessions: active now, the most at once, the limit if one is set and how "
              "many were refused for it, created and expired since the app started, the rates of both, and how "
              "long sessions live. The apps with the most sessions first.",
         rows=[('active', MG, 'activeSessions', 'host context top', 'sessions active now, tagged host=<its host> and context=<its path>; the most first'),
               ('most', MG, 'maxActive', 'host context', 'the most active at once since the app started, tagged the same'),
               ('limit', MG, 'maxActiveSessions', 'host context >=0', 'the most it allows (maxActiveSessions), when one is set, tagged the same'),
               ('rejected_count', MG, 'rejectedSessions', 'host context', 'sessions refused for the limit, tagged the same'),
               ('created_count', MG, 'sessionCounter', 'host context', 'sessions created, tagged the same'),
               ('expired_count', MG, 'expiredSessions', 'host context', 'sessions expired, tagged the same'),
               ('created_per_minute', MG, 'sessionCreateRate', 'host context', 'sessions created a minute, over the last 100, tagged the same'),
               ('expired_per_minute', MG, 'sessionExpireRate', 'host context', 'sessions expired a minute, over the last 100, tagged the same'),
               ('average_alive_seconds', MG, 'sessionAverageAliveTime', 'host context', 'how long the last 100 expired sessions lived, on average, tagged the same'),
               ('longest_alive_seconds', MG, 'sessionMaxAliveTime', 'host context', 'the longest any expired session lived, tagged the same')],
         healthy="active rising and falling with traffic; rejected_count 0.",
         watch="active climbing without falling back: sessions created and never used again (bots, a client "
               "that keeps no cookie) hold memory until they expire.",
         act="rejected_count rising: users are refused a session at the limit; active near limit."),
    dict(job='servlets', metric_name='tomcat.servlet', when='cron        = 3/5 * * * *', max_runtime='2m',
         title="the servlets of a Tomcat's apps",
         what="Reports each servlet (JSPs, as Tomcat's jsp servlet): its requests, errors, time and slowest request "
              "since its app started. The servlets that took the most time first: where the time goes.",
         rows=[('processing_seconds', SV, 'processingTime', 'WebModule name top *0.001',
                'time spent in the servlet, tagged WebModule=<//host/path> and name=<the servlet>; the most first'),
               ('requests_count', SV, 'requestCount', 'WebModule name', 'requests, tagged the same'),
               ('errors_count', SV, 'errorCount', 'WebModule name', 'requests that ended in an exception, tagged the same'),
               ('slowest_seconds', SV, 'maxTime', 'WebModule name *0.001', 'the slowest request, tagged the same')],
         healthy="processing_seconds rising in step with requests_count; errors_count flat.",
         watch="one servlet's share of the time growing.",
         act="a servlet's errors_count rising: it is failing; its processing_seconds per request climbing: it is slow."),
    dict(job='jdbc', metric_name='tomcat.jdbc', when='run_every   = 1m', title="a Tomcat's database connection pools",
         what="Reports each connection pool Tomcat makes from a Resource (DBCP, Tomcat's default, and Tomcat's "
              "JDBC pool) and HikariCP's when it registers its MBeans: connections in use, idle and at most; for "
              "Tomcat's JDBC pool, threads waiting for one and the connections borrowed, returned, created, "
              "released and abandoned. A pool at its most makes requests wait.",
         rows=[('active', DS, 'numActive', 'context name ' + NOKIDS, 'connections in use, tagged context=<the app, or none for a global one> and name=<its JNDI name>'),
               ('idle', DS, 'numIdle', 'context name ' + NOKIDS, 'connections idle in the pool, tagged the same'),
               ('max', DS, 'maxTotal', 'context name ' + NOKIDS, 'the most it may open (DBCP maxTotal, the JDBC pool maxActive), tagged the same'),
               ('max', DS, 'maxActive', 'context name ' + NOKIDS, ''),
               ('max_idle', DS, 'maxIdle', 'context name ' + NOKIDS, 'the most it keeps idle, tagged the same'),
               ('min_idle', DS, 'minIdle', 'context name ' + NOKIDS, 'the fewest it keeps idle, tagged the same'),
               ('max_wait_seconds', DS, 'maxWaitMillis', 'context name *0.001 >=0 ' + NOKIDS, 'how long a request waits for a connection before it fails, tagged the same'),
               ('max_wait_seconds', DS, 'maxWait', 'context name *0.001 >=0 ' + NOKIDS, ''),
               ('size', DS, 'size', 'context name ' + NOKIDS, 'connections open, in use or idle (the JDBC pool), tagged the same'),
               ('waiting', DS, 'waitCount', 'context name ' + NOKIDS, 'threads waiting for a connection now (the JDBC pool), tagged the same'),
               ('borrowed_count', DS, 'borrowedCount', 'context name ' + NOKIDS, 'connections taken from it (the JDBC pool), tagged the same'),
               ('returned_count', DS, 'returnedCount', 'context name ' + NOKIDS, 'connections given back (the JDBC pool), tagged the same'),
               ('created_count', DS, 'createdCount', 'context name ' + NOKIDS, 'connections opened (the JDBC pool), tagged the same'),
               ('released_count', DS, 'releasedCount', 'context name ' + NOKIDS, 'connections closed (the JDBC pool), tagged the same'),
               ('abandoned_count', DS, 'removeAbandonedCount', 'context name ' + NOKIDS, 'connections taken back from code that never returned them (the JDBC pool, removeAbandoned), tagged the same'),
               ('reconnected_count', DS, 'reconnectedCount', 'context name ' + NOKIDS, 'connections reopened (the JDBC pool), tagged the same'),
               ('hikari_active', HK, 'ActiveConnections', 'type', "a HikariCP pool's connections in use, tagged type=<Pool (its name)>"),
               ('hikari_idle', HK, 'IdleConnections', 'type', 'its connections idle, tagged the same'),
               ('hikari_total', HK, 'TotalConnections', 'type', 'its connections open, tagged the same'),
               ('hikari_waiting', HK, 'ThreadsAwaitingConnection', 'type', 'threads waiting for one of its connections, tagged the same')],
         healthy="active well below max; waiting and hikari_waiting 0; abandoned_count flat.",
         watch="active at max now and then; waiting above 0: requests queue for a connection.",
         act="active at max and waiting above 0 for minutes: requests fail after max_wait_seconds. Either the "
             "database is slow or code keeps connections (abandoned_count rising says code leaks them)."),
    dict(job='cache', metric_name='tomcat.cache', when='cron        = 4/5 * * * *', title="a Tomcat's resource cache and JSPs",
         what="Reports each app's static resource cache (lookups and hits, its size against its most), and its "
              "JSPs: how many are loaded, reloaded and unloaded, and the JSPs waiting to be unloaded.",
         rows=[('lookups_count', RC, 'lookupCount', 'host context', "lookups in the app's resource cache, tagged host=<its host> and context=<its path>"),
               ('hits_count', RC, 'hitCount', 'host context', 'of those, found in the cache, tagged the same'),
               ('size_bytes', RC, 'size', 'host context *1024', 'what the cache holds, tagged the same'),
               ('max_bytes', RC, 'maxSize', 'host context *1024', 'the most it may hold, tagged the same'),
               ('jsps', JSP, 'jspCount', 'WebModule', 'JSPs loaded, tagged WebModule=<//host/path>'),
               ('jsp_reloads_count', JSP, 'jspReloadCount', 'WebModule', 'JSPs reloaded after a change, tagged the same'),
               ('jsp_unloads_count', JSP, 'jspUnloadCount', 'WebModule', 'JSPs unloaded (maxLoadedJsps), tagged the same'),
               ('jsp_queue', JSP, 'jspQueueLength', 'WebModule >=0', 'JSPs waiting to be unloaded, when there is a limit, tagged the same')],
         healthy="hits_count close to lookups_count; size_bytes below max_bytes; jsp_reloads_count flat in production.",
         watch="size_bytes at max_bytes with hits falling behind lookups: the cache is too small (Tomcat warns).",
         act="jsp_reloads_count rising in production: JSPs are being changed under a running Tomcat."),
]

PACK = dict(
    name='tomcat', tag='tomcat', product='Tomcat', what_tuned='Tomcat',
    version='1.0.0',
    name_row='tomcat',
    name_doc='Each Tomcat is named as TOMCAT_JMX names it (web1: jmxs=host:port), else by its address.',
    jmx_doc=("Reads each Tomcat's JMX, at TOMCAT_JMX: jmx=host:port, or jmxs=host:port over TLS, separated by ; "
             "or , each with a name first if you like (web1: jmxs=host:port); with TOMCAT_JMX_USER and the "
             "password in TOMCAT_JMX_PASSWORD when JMX asks for them; a certificate is checked against "
             "TOMCAT_CACERT, a PEM file of CAs, or Java's own, and against the server's name. With no TOMCAT_JMX, "
             "it prints nothing. Tomcat's JVM (heap, garbage collection, threads, CPU, open files) is the jvm "
             "pack's, not this one's."),
    description='Apache Tomcat over JMX: server, connectors, requests, threads and executors, requests running '
                'and stuck, apps, sessions, servlets, JDBC pools (DBCP, Tomcat JDBC, HikariCP), resource cache and JSPs',
    works_with='Apache Tomcat 9, 10.1 and 11 (tested: 9.0, 10.1 and 11.0), with JMX on',
    needs=["each Tomcat's JMX in TOMCAT_JMX (web1: jmxs=host:port): -Dcom.sun.management.jmxremote.port and a "
           "password and TLS in CATALINA_OPTS (packs/README.md shows how)",
           "for JMX with a password: a secret line on the jobs: secret = TOMCAT_JMX_PASSWORD=secret:TOMCAT_JMX_PASSWORD, "
           "then vigil secret set TOMCAT_JMX_PASSWORD",
           "for stuck requests: Tomcat's StuckThreadDetectionValve on the Host or the app (packs/README.md shows how)",
           "for Tomcat's JVM (heap, garbage collection, threads, CPU, open files): the jvm pack, not this one: vigil "
           "pack install jvm, with each Tomcat in JVM_TARGETS named as here (web1: jmxs=host:port)"],
    config_head=['tomcat - Apache Tomcat, on this machine or any it can reach, over JMX: the',
                 'server and its connectors, requests and errors, threads and executors,',
                 'requests running now and stuck, each app, its sessions and servlets, the',
                 'JDBC pools, the resource cache and JSPs. Never Tomcat\'s JVM: that is the',
                 'jvm pack\'s. Linux, macOS and Windows. See SPECIFICATION.md section 18.10',
                 'for this format, and tools/probe/DESIGN.md for the probe that reads it.',
                 '',
                 'Every script runs _probe.jar, beside it, with Java 11 or later (a JDK or a',
                 'JRE), once it matches the digest the script carries, with this pack\'s',
                 '_probe.tables. Nothing of Tomcat\'s is needed here: only its JMX.',
                 '',
                 'Off until enabled: vigil pack enable tomcat. Then set TOMCAT_JMX in the',
                 'jobs vigil pack enable writes into the configuration (web1:',
                 'jmxs=host:port; web2: jmxs=host:port), TOMCAT_JMX_USER, and for its',
                 'password a secret line (packs/README.md has it all).'],
    jobs=JOBS,
)

if __name__ == '__main__':
    packgen.write(sys.argv[1], PACK)
