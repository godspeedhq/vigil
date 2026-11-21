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
# start.sh - one JVM of compose.jvm.yaml: compiles Trouble.java, then runs it
# in MODES, with JAVA_OPTS, and with JMX on JMX_PORT when it is set: users
# monitor (readonly) and operator (readwrite), password JMX_PASSWORD, and
# with JMX_TLS=yes, TLS with /tls/server.p12 (password KS_PASSWORD) on the
# registry and the connector both.

set -e
mkdir -p /tmp/trouble /tmp/jmx
javac -nowarn -d /tmp/trouble /vigil/Trouble.java
opts=$JAVA_OPTS
if [ -n "${JMX_PORT-}" ]; then
    # JMX insists its password file be its owner's alone.
    printf 'monitor %s\noperator %s\n' "$JMX_PASSWORD" "$JMX_PASSWORD" > /tmp/jmx/password
    printf 'monitor readonly\noperator readwrite\n' > /tmp/jmx/access
    chmod 600 /tmp/jmx/password /tmp/jmx/access
    opts="$opts -Dcom.sun.management.jmxremote.port=$JMX_PORT -Dcom.sun.management.jmxremote.rmi.port=$JMX_PORT"
    opts="$opts -Djava.rmi.server.hostname=localhost -Dcom.sun.management.jmxremote.authenticate=true"
    opts="$opts -Dcom.sun.management.jmxremote.password.file=/tmp/jmx/password -Dcom.sun.management.jmxremote.access.file=/tmp/jmx/access"
    if [ "${JMX_TLS-}" = yes ]; then
        opts="$opts -Dcom.sun.management.jmxremote.ssl=true -Dcom.sun.management.jmxremote.registry.ssl=true"
        opts="$opts -Djavax.net.ssl.keyStore=/tls/server.p12 -Djavax.net.ssl.keyStoreType=PKCS12 -Djavax.net.ssl.keyStorePassword=$KS_PASSWORD"
    else
        opts="$opts -Dcom.sun.management.jmxremote.ssl=false"
    fi
fi
# shellcheck disable=SC2086
exec java $opts -cp /tmp/trouble Trouble $MODES
