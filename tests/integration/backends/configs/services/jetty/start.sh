#!/bin/sh
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# start.sh - one Jetty of compose.jetty.yaml: a base of its own in /tmp,
# with the modules the jetty pack reads (jmx, statistics, the thread pool,
# the connection limit, the low resources monitor; QoS on 12), small on
# purpose so trouble comes quickly: 24 threads, 40 connections. The apps
# are workloads/jetty's. JMX on JMX_PORT: user monitor (readonly), password
# JMX_PASSWORD, TLS with /tls/server.p12 (password KS_PASSWORD).

set -e
mkdir -p /tmp/jmx /tmp/base/webapps
printf 'monitor %s\n' "$JMX_PASSWORD" > /tmp/jmx/password
printf 'monitor readonly\n' > /tmp/jmx/access
chmod 600 /tmp/jmx/password /tmp/jmx/access
cp -R /vigil/workload/shop /vigil/workload/broken /tmp/base/webapps/
cd /tmp/base
case $JETTY_LINE in
    12) mods=http,jmx,statistics,ee10-deploy,ee10-jsp,threadpool,connectionlimit,lowresources,qos ;;
    *) mods=http,jmx,stats,deploy,jsp,threadpool,connectionlimit,lowresources ;;
esac
java -jar "$JETTY_HOME/start.jar" --add-module="$mods" > /tmp/base/modules.log 2>&1 ||
    java -jar "$JETTY_HOME/start.jar" --add-to-start="$mods" >> /tmp/base/modules.log 2>&1
opts="-Xmx192m -Dcom.sun.management.jmxremote.port=$JMX_PORT -Dcom.sun.management.jmxremote.rmi.port=$JMX_PORT"
opts="$opts -Djava.rmi.server.hostname=localhost -Dcom.sun.management.jmxremote.authenticate=true"
opts="$opts -Dcom.sun.management.jmxremote.password.file=/tmp/jmx/password -Dcom.sun.management.jmxremote.access.file=/tmp/jmx/access"
opts="$opts -Dcom.sun.management.jmxremote.ssl=true -Dcom.sun.management.jmxremote.registry.ssl=true"
opts="$opts -Djavax.net.ssl.keyStore=/tls/server.p12 -Djavax.net.ssl.keyStoreType=PKCS12 -Djavax.net.ssl.keyStorePassword=$KS_PASSWORD"
# shellcheck disable=SC2086
exec java $opts -jar "$JETTY_HOME/start.jar" jetty.http.port=8080 \
    jetty.threadPool.minThreads=4 jetty.threadPool.maxThreads=24 \
    jetty.connectionlimit.maxConnections=40 \
    jetty.lowresources.period=1000 jetty.lowresources.monitorThreads=true jetty.lowresources.maxLowResourcesTime=600000 \
    jetty.qos.maxRequestCount=16
