#!/bin/bash
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# start.sh - one node of compose.kafka.yaml: writes its configuration,
# formats its storage the first time, and starts it, a broker and a
# controller, with JMX on a port of its own. NODE_ID (1 to 3) says which.
# Every port is the same inside and out, so each listener, and JMX's RMI,
# can name the port the host reaches.

set -eu
n=$NODE_ID
cfg=/tmp/server.properties
cat > "$cfg" <<EOF
process.roles=broker,controller
node.id=$n
controller.quorum.voters=1@kafka1:9093,2@kafka2:9093,3@kafka3:9093
listeners=CONTROLLER://:9093,INTERNAL://:9094,SECURE://:1909$n,PLAIN://:2909$n
advertised.listeners=INTERNAL://kafka$n:9094,SECURE://localhost:1909$n,PLAIN://127.0.0.1:2909$n
listener.security.protocol.map=CONTROLLER:PLAINTEXT,INTERNAL:PLAINTEXT,SECURE:SASL_SSL,PLAIN:PLAINTEXT
controller.listener.names=CONTROLLER
inter.broker.listener.name=INTERNAL
sasl.enabled.mechanisms=SCRAM-SHA-512
listener.name.secure.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required;
ssl.keystore.type=PEM
ssl.keystore.location=/tls/server.pem
authorizer.class.name=org.apache.kafka.metadata.authorizer.StandardAuthorizer
super.users=User:ANONYMOUS
allow.everyone.if.no.acl.found=false
log.dirs=/var/lib/kafka/data
num.partitions=3
default.replication.factor=3
min.insync.replicas=2
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
group.initial.rebalance.delay.ms=0
EOF
/opt/kafka/bin/kafka-storage.sh format -t "${CLUSTER_ID:-MkU3OEVBNTcwNTJENDM2Qg}" -c "$cfg" --ignore-formatted
# JMX as the pack asks for it: a user that may only read (monitor), its
# password JMX_PASSWORD, and TLS with /tls/server.p12 (KS_PASSWORD) on the
# registry and the connector both. JMX insists the files be its own.
mkdir -p /tmp/jmx
printf 'monitor %s\n' "$JMX_PASSWORD" > /tmp/jmx/password
printf 'monitor readonly\n' > /tmp/jmx/access
chmod 600 /tmp/jmx/password /tmp/jmx/access
export JMX_PORT=1999$n
export KAFKA_JMX_OPTS="-Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.rmi.port=1999$n -Djava.rmi.server.hostname=127.0.0.1 -Dcom.sun.management.jmxremote.authenticate=true -Dcom.sun.management.jmxremote.password.file=/tmp/jmx/password -Dcom.sun.management.jmxremote.access.file=/tmp/jmx/access -Dcom.sun.management.jmxremote.ssl=true -Dcom.sun.management.jmxremote.registry.ssl=true -Djavax.net.ssl.keyStore=/tls/server.p12 -Djavax.net.ssl.keyStoreType=PKCS12 -Djavax.net.ssl.keyStorePassword=$KS_PASSWORD"
exec /opt/kafka/bin/kafka-server-start.sh "$cfg"
