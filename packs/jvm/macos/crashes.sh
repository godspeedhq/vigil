#!/usr/bin/env bash
#
# crashes.sh - a JVM's crashes
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
# Reports crash reports (hs_err_pid*.log), compiler replay files and core
# dumps, where the JVM writes them: -XX:ErrorFile's folder, its working folder
# (Linux), and JVM_DUMP_DIRS. A crash report is the JVM itself failing: what
# is in it says why. Read-only: it changes nothing in the JVM, and nothing it
# does pauses one.
#
# From the operating system: the JVM's process, which needs nothing set up.
# JVM_TARGETS names the JVMs: name: key=value, ...; name: ... with main=<its
# main class or jar, or any text on its command line> or pid=<a pid file> to
# find it on this machine, and jmx= or jmxs= for its JMX address. Empty, it
# watches every JVM on this machine, each named by its main class. Each metric
# is tagged jvm=<name>; jvms is how many JVMs the job looked at.
#
# Metrics:
#   jvms                                the JVMs the job looked at (untagged)
#   jmx_up                              1 when the JVM answered at its JMX
#                                       address, 0 when not (only for a JVM
#                                       with one)
#   crash_reports_day                   crash reports written in the last day
#   crash_reports                       crash reports there
#   crash_reports_bytes                 their size
#   newest_crash_report_age_seconds     since the newest was written
#   compiler_replays_day                compiler replay files in the last day
#   compiler_replays                    compiler replay files there
#   compiler_replays_bytes              their size
#   newest_compiler_replay_age_seconds  since the newest
#   core_dumps_day                      core dumps in the last day
#   core_dumps                          core dumps there
#   core_dumps_bytes                    their size
#   newest_core_dump_age_seconds        since the newest
#
# Example output:
#   metric jvms 8
#   metric crash_reports_day 1 jvm=j17
#   metric crash_reports 1 jvm=j17
#   metric crash_reports_bytes 45402 jvm=j17
#   metric newest_crash_report_age_seconds 1262 jvm=j17
#   metric compiler_replays_day 0 jvm=j17
#   metric compiler_replays 0 jvm=j17
#   metric compiler_replays_bytes 0 jvm=j17
#   metric core_dumps_day 0 jvm=j17
#   metric core_dumps 0 jvm=j17
#
# Reading the results (starting points: tune them to the JVM):
#   Healthy  crash_reports_day 0.
#   Watch    core_dumps_bytes large: they fill the disk.
#   Act      crash_reports_day above 0: the JVM crashed; read the report, it
#            names the frame that failed.
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
    echo "jvm_crashes: java not found: the jvm pack runs its client with a JDK 11 or later, on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-jvm.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (it would
# find itself among the JVMs it watches).
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" "$here/_client.java" jvm_crashes
exit $?
