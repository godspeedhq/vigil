#!/usr/bin/env bash
#
# mbeans.sh - MBeans of your own
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
# Reports MBean attributes you name, as numbers: an application's own figures,
# from any JMX bean. JVM_MBEANS lists them: <object name>/<attribute>, or
# <attribute>.<key> for a part of a composite value; ... An object name may be
# a pattern (*), for every bean it matches, up to 100. Booleans are 1 or 0;
# anything not a number is left out. Read-only: it changes nothing in the JVM,
# and nothing it does pauses one.
#
# From JMX, for each JVM given a JMX address in JVM_TARGETS (jmx=host:port, or
# jmxs=host:port for JMX over TLS, its certificate checked against JVM_CACERT
# or Java's own CAs, and against its name), as JVM_JMX_USER with the password
# in JVM_JMX_PASSWORD (a secret line, never a command line). A JVM with an
# address that does not answer reports jmx_up 0.
# JVM_TARGETS names the JVMs: name: key=value, ...; name: ... with main=<its
# main class or jar, or any text on its command line> or pid=<a pid file> to
# find it on this machine, and jmx= or jmxs= for its JMX address. Empty, it
# watches every JVM on this machine, each named by its main class. Each metric
# is tagged jvm=<name>; jvms is how many JVMs the job looked at.
#
# Metrics:
#   jvms    the JVMs the job looked at (untagged)
#   jmx_up  1 when the JVM answered at its JMX address, 0 when not (only for a
#           JVM with one)
#   value   an attribute, tagged mbean=<its object name> and attribute=<the
#           attribute>
#
# Example output:
#   metric jvms 8
#   metric value 22 jvm=j21 mbean=java.lang:type=Threading attribute=ThreadCount
#   metric value 190453104 jvm=j21 mbean=java.lang:type=Memory attribute=HeapMemoryUsage.used
#
# Reading the results (starting points: tune them to the JVM):
#   Healthy  As your application defines it.
#   Watch    As your application defines it.
#   Act      As your application defines it.
#
# Requires: bash, a JDK 11 or later (JAVA_HOME, or java on the PATH) to run
#   _client.java, beside this script
# Exit code: 0 on success, JVMs up or down; 1 if java is missing, JVM_TARGETS
#   is wrong, or a JVM refuses the JMX login or its certificate

set -u

# The client, beside this script, run by a JDK: JAVA_HOME's, else the PATH's.
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    java=$JAVA_HOME/bin/java
elif command -v java > /dev/null 2>&1; then
    java=$(command -v java)
else
    echo "jvm_mbeans: java not found: the jvm pack runs its client with a JDK 11 or later, on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-jvm.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (it would
# find itself among the JVMs it watches).
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" "$here/_client.java" jvm_mbeans
exit $?
