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
# start.sh - one broker of compose.artemis.yaml: the JVM's JMX on JMX_PORT,
# user monitor (readonly), password JMX_PASSWORD, TLS with /tls/server.p12
# (password KS_PASSWORD) on the registry and the connector both; then the
# image's own start, which makes the broker on its first run.

set -e
mkdir -p /tmp/jmx
# JMX insists its password file be its owner's alone.
printf 'monitor %s\n' "$JMX_PASSWORD" > /tmp/jmx/password
printf 'monitor readonly\n' > /tmp/jmx/access
chmod 600 /tmp/jmx/password /tmp/jmx/access
JAVA_ARGS_APPEND="-Xms128m -Xmx320m -Dcom.sun.management.jmxremote.port=$JMX_PORT -Dcom.sun.management.jmxremote.rmi.port=$JMX_PORT"
JAVA_ARGS_APPEND="$JAVA_ARGS_APPEND -Djava.rmi.server.hostname=localhost -Dcom.sun.management.jmxremote.authenticate=true"
JAVA_ARGS_APPEND="$JAVA_ARGS_APPEND -Dcom.sun.management.jmxremote.password.file=/tmp/jmx/password -Dcom.sun.management.jmxremote.access.file=/tmp/jmx/access"
JAVA_ARGS_APPEND="$JAVA_ARGS_APPEND -Dcom.sun.management.jmxremote.ssl=true -Dcom.sun.management.jmxremote.registry.ssl=true"
JAVA_ARGS_APPEND="$JAVA_ARGS_APPEND -Djavax.net.ssl.keyStore=/tls/server.p12 -Djavax.net.ssl.keyStoreType=PKCS12 -Djavax.net.ssl.keyStorePassword=$KS_PASSWORD"
export JAVA_ARGS_APPEND
exec /docker-run.sh run
