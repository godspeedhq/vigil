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
# start.sh - one broker of compose.activemq.yaml: workloads/activemq's
# activemq.xml, named BROKER, with a network connector to NETWORK_TO when it
# is set, and JMX on JMX_PORT: user monitor (readonly), password
# JMX_PASSWORD, TLS with /tls/server.p12 (password KS_PASSWORD).

set -e
mkdir -p /tmp/jmx /tmp/amq-data
printf 'monitor %s\n' "$JMX_PASSWORD" > /tmp/jmx/password
printf 'monitor readonly\n' > /tmp/jmx/access
chmod 600 /tmp/jmx/password /tmp/jmx/access
net=''
if [ -n "${NETWORK_TO-}" ]; then
    net="<networkConnectors><networkConnector name=\"to-$NETWORK_TO\" uri=\"static:(tcp://$NETWORK_TO:61616)\"/></networkConnectors>"
fi
sed -e "s|@BROKER@|$BROKER|" -e "s|@NETWORK@|$net|" /vigil/workload/activemq.xml > "$ACTIVEMQ_CONF/activemq.xml"
ACTIVEMQ_OPTS="${ACTIVEMQ_OPTS-} -Xmx256m -Dcom.sun.management.jmxremote.port=$JMX_PORT -Dcom.sun.management.jmxremote.rmi.port=$JMX_PORT"
ACTIVEMQ_OPTS="$ACTIVEMQ_OPTS -Djava.rmi.server.hostname=localhost -Dcom.sun.management.jmxremote.authenticate=true"
ACTIVEMQ_OPTS="$ACTIVEMQ_OPTS -Dcom.sun.management.jmxremote.password.file=/tmp/jmx/password -Dcom.sun.management.jmxremote.access.file=/tmp/jmx/access"
ACTIVEMQ_OPTS="$ACTIVEMQ_OPTS -Dcom.sun.management.jmxremote.ssl=true -Dcom.sun.management.jmxremote.registry.ssl=true"
ACTIVEMQ_OPTS="$ACTIVEMQ_OPTS -Djavax.net.ssl.keyStore=/tls/server.p12 -Djavax.net.ssl.keyStoreType=PKCS12 -Djavax.net.ssl.keyStorePassword=$KS_PASSWORD"
export ACTIVEMQ_OPTS ACTIVEMQ_SUNJMX_START=''
exec activemq console
