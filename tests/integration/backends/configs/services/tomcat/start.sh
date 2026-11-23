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
# start.sh - one Tomcat of compose.tomcat.yaml: workloads/tomcat's
# server.xml and apps, the libraries in /vigil/lib, and JMX on JMX_PORT:
# user monitor (readonly), password JMX_PASSWORD, TLS with /tls/server.p12
# (password KS_PASSWORD) on the registry and the connector both.

set -e
mkdir -p /tmp/jmx
# JMX insists its password file be its owner's alone.
printf 'monitor %s\n' "$JMX_PASSWORD" > /tmp/jmx/password
printf 'monitor readonly\n' > /tmp/jmx/access
chmod 600 /tmp/jmx/password /tmp/jmx/access
cp /vigil/workload/server.xml "$CATALINA_HOME/conf/server.xml"
rm -rf "$CATALINA_HOME/webapps"/*
cp -R /vigil/workload/shop /vigil/workload/broken "$CATALINA_HOME/webapps/"
cp /vigil/lib/*.jar "$CATALINA_HOME/lib/"
CATALINA_OPTS="-Xmx192m -Dtomcat.port=8080 -Dtomcat.port2=8081 -Dtomcat.address=0.0.0.0"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.port=$JMX_PORT -Dcom.sun.management.jmxremote.rmi.port=$JMX_PORT"
CATALINA_OPTS="$CATALINA_OPTS -Djava.rmi.server.hostname=localhost -Dcom.sun.management.jmxremote.authenticate=true"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.password.file=/tmp/jmx/password -Dcom.sun.management.jmxremote.access.file=/tmp/jmx/access"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.ssl=true -Dcom.sun.management.jmxremote.registry.ssl=true"
CATALINA_OPTS="$CATALINA_OPTS -Djavax.net.ssl.keyStore=/tls/server.p12 -Djavax.net.ssl.keyStoreType=PKCS12 -Djavax.net.ssl.keyStorePassword=$KS_PASSWORD"
export CATALINA_OPTS
exec catalina.sh run
