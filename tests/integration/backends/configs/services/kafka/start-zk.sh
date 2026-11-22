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
# start-zk.sh - the broker of compose.kafka-zk.yaml: a Kafka 3 broker on
# ZooKeeper, with the same listeners as start.sh's first node, and JMX.

set -eu
cfg=/tmp/server.properties
cat > "$cfg" <<EOF
broker.id=1
zookeeper.connect=zookeeper:2181
listeners=INTERNAL://:9094,SECURE://:19091,PLAIN://:29091
advertised.listeners=INTERNAL://kafka1:9094,SECURE://localhost:19091,PLAIN://127.0.0.1:29091
listener.security.protocol.map=INTERNAL:PLAINTEXT,SECURE:SASL_SSL,PLAIN:PLAINTEXT
inter.broker.listener.name=INTERNAL
sasl.enabled.mechanisms=SCRAM-SHA-512
listener.name.secure.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required;
ssl.keystore.type=PEM
ssl.keystore.location=/tls/server.pem
authorizer.class.name=kafka.security.authorizer.AclAuthorizer
super.users=User:ANONYMOUS
allow.everyone.if.no.acl.found=false
log.dirs=/var/lib/kafka/data
num.partitions=3
default.replication.factor=1
min.insync.replicas=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
group.initial.rebalance.delay.ms=0
EOF
# JMX as the pack asks for it: a user that may only read (monitor), its
# password JMX_PASSWORD, and TLS with /tls/server.p12 (KS_PASSWORD) on the
# registry and the connector both. JMX insists the files be its own.
mkdir -p /tmp/jmx
printf 'monitor %s\n' "$JMX_PASSWORD" > /tmp/jmx/password
printf 'monitor readonly\n' > /tmp/jmx/access
chmod 600 /tmp/jmx/password /tmp/jmx/access
export JMX_PORT=19991
export KAFKA_JMX_OPTS="-Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.rmi.port=19991 -Djava.rmi.server.hostname=127.0.0.1 -Dcom.sun.management.jmxremote.authenticate=true -Dcom.sun.management.jmxremote.password.file=/tmp/jmx/password -Dcom.sun.management.jmxremote.access.file=/tmp/jmx/access -Dcom.sun.management.jmxremote.ssl=true -Dcom.sun.management.jmxremote.registry.ssl=true -Djavax.net.ssl.keyStore=/tls/server.p12 -Djavax.net.ssl.keyStoreType=PKCS12 -Djavax.net.ssl.keyStorePassword=$KS_PASSWORD"
# A Kafka download mounted at /opt/kafka-dist (2.8), else the image's own.
K=/opt/kafka
[ -x /opt/kafka-dist/bin/kafka-server-start.sh ] && K=/opt/kafka-dist
exec "$K/bin/kafka-server-start.sh" "$cfg"
