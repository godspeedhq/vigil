#!/usr/bin/env bash
#
# jvm.sh - each Kafka broker's JVM and logs
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
# Reports each broker's JVM: heap used against the most it may use, garbage
# collection, open files against the limit, CPU, threads and uptime; and its
# logs: how long a flush to disk takes, the log cleaner (compaction), and log
# directories offline. Read-only: it changes nothing in the cluster.
#
# Reads each broker's JMX, at KAFKA_JMX: host:port, comma-separated, one per
# broker, through Kafka's own JmxTool (KAFKA_HOME, when its tools are not on
# the PATH). JMX without a password, as Kafka's start scripts set it up with
# JMX_PORT: JmxTool takes a password only on its command line, where this pack
# never puts one. Each broker is named by its id. With no KAFKA_JMX, it prints
# nothing.
#
# Metrics:
#   jmx_up                     1 when a broker's JMX answers, tagged
#                              broker=<id, or its JMX host:port>
#   heap_used_bytes            heap in use, tagged broker=<id>
#   heap_max_bytes             the most heap it may use, tagged the same
#   gc_count                   garbage collections, a running total, tagged
#                              broker=<id> and gc=<the collector>
#   gc_ms_count                time spent collecting, in ms, a running total,
#                              tagged the same
#   open_files                 files and sockets open, tagged broker=<id>
#   max_files                  the most it may open, tagged the same
#   cpu_pct                    the broker's CPU, as a percent of the machine,
#                              tagged the same
#   threads                    its threads, tagged the same
#   uptime_seconds             how long it has run, tagged the same
#   flush_ms_p99               the time a log flush takes, in ms, 99th
#                              percentile, tagged the same
#   flushes_count              log flushes, a running total, tagged the same
#   cleaner_max_dirty_pct      the most of a compacted log not yet compacted,
#                              as a percent, tagged the same
#   cleaner_idle_seconds       since the log cleaner last ran, tagged the same
#   cleaner_dead_threads       log cleaner threads that died, tagged the same
#   cleaner_max_clean_seconds  the longest a clean took, tagged the same
#   offline_log_dirs           log directories offline, tagged the same
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  heap_used_bytes well under heap_max_bytes after collections;
#            open_files well under max_files; cleaner_dead_threads 0.
#   Watch    gc_ms_count rising fast: the broker pauses to collect;
#            flush_ms_p99 rising: the disk is slow; uptime_seconds back near
#            0: it restarted.
#   Act      open_files near max_files: it will fail to open a file or a
#            connection; cleaner_dead_threads above 0: compacted topics grow
#            without bound; offline_log_dirs above 0.
#
# Requires: bash, Kafka's command-line tools (any from 3.9, the Kafka
#   download), Java 17 or later
# Exit code: 0 on success, or when the cluster does not answer; 1 if the tools
#   are missing, or the cluster refuses the login, its certificate or a
#   request

set -u

# Kafka's own command-line tools: under KAFKA_HOME/bin, else on the PATH
# (with or without .sh, as packages name them), else where Kafka is often
# unpacked. kt <tool> prints the path, or says what to install and exits.
kt() {
    local d
    for d in "${KAFKA_HOME:+$KAFKA_HOME/bin}" /opt/kafka/bin /usr/local/kafka/bin; do
        [ -n "$d" ] && [ -x "$d/$1.sh" ] && { printf '%s\n' "$d/$1.sh"; return 0; }
    done
    command -v "$1.sh" 2> /dev/null && return 0
    command -v "$1" 2> /dev/null && return 0
    return 1
}
need() {
    kt "$1" > /dev/null && return 0
    echo "jvm: $1.sh not found: install Kafka's command-line tools (the Kafka download), and set KAFKA_HOME to the folder that holds bin/" >&2
    exit 1
}
if [ -z "${JAVA_HOME-}" ] && ! command -v java > /dev/null 2>&1; then
    echo "jvm: java not found: Kafka's tools need Java 17 or later, on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A folder of this run's own, readable by this account only, for the client
# configuration (which holds the password) and the tools' output.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-kafka.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
cfg=$work/client.properties
bootstrap=${KAFKA_BOOTSTRAP:-localhost:9092}
security=${KAFKA_SECURITY:-PLAINTEXT}

# The client configuration: KAFKA_CLIENT_CONFIG, a file of your own (for a
# login this pack does not build, such as Kerberos or OAuth), or one built
# from KAFKA_SECURITY and the settings beside it. Either way with timeouts,
# so an unreachable cluster is told apart from one that refuses.
(
    umask 077
    if [ -n "${KAFKA_CLIENT_CONFIG-}" ]; then
        cat "$KAFKA_CLIENT_CONFIG" || exit 1
        printf '\n'
    else
        printf 'security.protocol=%s\n' "$security"
        case $security in
            SASL_PLAINTEXT | SASL_SSL)
                mech=${KAFKA_SASL_MECHANISM:-SCRAM-SHA-512}
                case $mech in
                    PLAIN) module=org.apache.kafka.common.security.plain.PlainLoginModule ;;
                    SCRAM-SHA-256 | SCRAM-SHA-512) module=org.apache.kafka.common.security.scram.ScramLoginModule ;;
                    *) echo "jvm: KAFKA_SASL_MECHANISM is '$mech': set it to SCRAM-SHA-512, SCRAM-SHA-256 or PLAIN (or give KAFKA_CLIENT_CONFIG)" >&2; exit 1 ;;
                esac
                [ -n "${KAFKA_PASSWORD-}" ] || { echo "jvm: no password: KAFKA_SECURITY is $security, and KAFKA_PASSWORD is empty (vigil secret set KAFKA_MONITOR_PASSWORD)" >&2; exit 1; }
                # In the JAAS line, a quote or a backslash is escaped.
                u=${KAFKA_USER:-vigil_monitor}
                u=${u//\\/\\\\} u=${u//\"/\\\"}
                p=${KAFKA_PASSWORD//\\/\\\\} p=${p//\"/\\\"}
                printf 'sasl.mechanism=%s\n' "$mech"
                printf 'sasl.jaas.config=%s required username="%s" password="%s";\n' "$module" "$u" "$p"
                ;;
            PLAINTEXT | SSL) ;;
            *) echo "jvm: KAFKA_SECURITY is '$security': set it to PLAINTEXT, SSL, SASL_PLAINTEXT or SASL_SSL" >&2; exit 1 ;;
        esac
        case $security in
            SSL | SASL_SSL)
                if [ -n "${KAFKA_CACERT-}" ]; then
                    printf 'ssl.truststore.type=PEM\nssl.truststore.location=%s\n' "$KAFKA_CACERT"
                fi
                if [ -n "${KAFKA_CERT-}" ]; then
                    # A client certificate: its key and the certificate, in one
                    # PEM file of this run's own, as Kafka reads them.
                    cat "${KAFKA_KEY-}" "$KAFKA_CERT" > "$work/client.pem" || exit 1
                    printf 'ssl.keystore.type=PEM\nssl.keystore.location=%s\n' "$work/client.pem"
                fi
                ;;
        esac
    fi
    printf 'request.timeout.ms=10000\ndefault.api.timeout.ms=15000\nsocket.connection.setup.timeout.max.ms=10000\n'
) > "$cfg" || exit 1
# The tools' JVM: small, as they are.
export KAFKA_HEAP_OPTS=${KAFKA_HEAP_OPTS:--Xmx256m}

# run <tool> <args...>: the tool's output in $out. On failure: a cluster that
# cannot be reached returns 2 (the caller reports it, or nothing); anything
# else, a login or certificate refused, a permission missing, says why and
# exits 1.
run() {
    local t rc
    t=$(kt "$1") || need "$1"
    shift
    out=$("$t" "$@" 2> "$work/err") && return 0
    rc=$?
    # lenient: any failure but an unreachable cluster returns 1, for a
    # caller with another way to go on.
    if [ -n "${lenient-}" ]; then
        grep -qE 'TimeoutException|Timed out waiting|could not be established|Connection refused|UnknownHostException|No resolvable bootstrap urls' "$work/err" && return 2
        return 1
    fi
    if grep -qE 'SaslAuthenticationException|Authentication failed|SslAuthenticationException|SSL handshake failed|PKIX path|certificate' "$work/err"; then
        echo "jvm: the cluster refused the login or its certificate: $(why)" >&2
        exit 1
    fi
    if grep -qE 'AuthorizationException|[Nn]ot authorized|Authorization failed' "$work/err"; then
        echo "jvm: a permission is missing (packs/README.md lists the ACLs): $(why)" >&2
        exit 1
    fi
    if grep -qE 'TimeoutException|Timed out waiting|could not be established|Connection refused|UnknownHostException|No resolvable bootstrap urls|Broker may not be available|disconnected' "$work/err"; then
        return 2
    fi
    [ -n "${soft-}" ] && return 1
    echo "jvm: $(kt_name "$t") failed (exit $rc): $(why)" >&2
    exit 1
}
# try: run, but a failure that is neither a login, a permission nor an
# unreachable cluster returns 1, for the caller to read $work/err.
try() { local soft=1; run "$@"; }
kt_name() { local n=${1##*/}; printf '%s' "${n%.sh}"; }
# The most telling line of the tool's error output.
why() {
    local l
    l=$(grep -E 'Exception|[Ee]rror' "$work/err" | grep -v '^\s*at ' | tail -n 1)
    [ -n "$l" ] || l=$(grep -v '^\s*$' "$work/err" | tail -n 1)
    l=${l#*\] }
    printf '%s' "${l:-no message}" | cut -c1-300
}
# The options every admin tool takes, in the order most take them.
conn=(--bootstrap-server "$bootstrap" --command-config "$cfg")

# The brokers, as the cluster lists them, in $out: kafka-broker-api-versions,
# or kafka-cluster api-versions where it has gone (Kafka 5).
brokers_list() {
    if kt kafka-broker-api-versions > /dev/null; then
        run kafka-broker-api-versions "${conn[@]}"
    elif kt kafka-cluster > /dev/null; then
        run kafka-cluster api-versions "${conn[@]}"
    else
        need kafka-broker-api-versions
    fi
}
# Kafka hides from a user the topics it may not describe: none at all may
# mean an empty cluster, or missing ACLs. Said on stderr, for the job log.
no_topics() {
    echo "jvm: no topics are visible: the cluster has none, or this user may not describe them (packs/README.md lists the ACLs)" >&2
}

# A tag's value: no spaces or control characters, never empty.
tagv() {
    local v=${1//[[:space:][:cntrl:]]/_}
    printf '%s' "${v:-none}"
}

# JMX, for the jobs that read the brokers' own metrics: KAFKA_JMX lists each
# broker's JMX host:port, comma-separated. jmx_each <function> <JmxTool
# options...> asks each broker for the objects named, as name<TAB>value
# lines, and calls the function with them in $out, the broker's id (from
# Kafka's app-info, else the endpoint) in $broker. Each job's --attributes
# includes Version, app-info's, which names the broker. A broker whose JMX
# does not answer is reported as jmx_up 0; with no KAFKA_JMX, nothing is.
jmx_each() {
    local fn=$1 t ep
    shift
    [ -n "${KAFKA_JMX-}" ] || return 0
    t=$(kt kafka-run-class) || need kafka-run-class
    for ep in ${KAFKA_JMX//,/ }; do
        if ! out=$("$t" org.apache.kafka.tools.JmxTool --jmx-url "service:jmx:rmi:///jndi/rmi://$ep/jmxrmi" \
            --object-name 'kafka.server:type=app-info,id=*' "$@" \
            --one-time true --report-format tsv 2> "$work/err") || ! printf '%s\n' "$out" | grep -q 'app-info'; then
            echo "metric jmx_up 0 broker=$(tagv "$ep")"
            continue
        fi
        broker=$(printf '%s\n' "$out" | sed -n 's/^kafka\.server:type=app-info,id=\([0-9]*\):Version.*/\1/p' | head -n 1)
        [ -n "$broker" ] || broker=$(tagv "$ep")
        echo "metric jmx_up 1 broker=$broker"
        "$fn"
    done
}
# A JMX value as a metric value: no exponent, at most 4 decimals, whole
# numbers without any. Prints nothing for a value that is not a number.
num() {
    awk -v v="$1" 'BEGIN {
        if (v !~ /^-?[0-9]+(\.[0-9]+)?([Ee][-+]?[0-9]+)?$/) exit
        x = v + 0
        if (x == int(x) && (x < 1e15 && x > -1e15)) printf "%d\n", x
        else { s = sprintf("%.4f", x); sub(/0+$/, "", s); sub(/\.$/, "", s); print s }
    }'
}
# The same, as an awk function for the jobs that print many: fmt(v) returns
# "" for a value that is not a number.
AWKFMT='function fmt(v,  x, s) {
    if (v !~ /^-?[0-9]+(\.[0-9]+)?([Ee][-+]?[0-9]+)?$/) return ""
    x = v + 0
    if (x == int(x) && x < 1e15 && x > -1e15) return sprintf("%d", x)
    s = sprintf("%.4f", x); sub(/0+$/, "", s); sub(/\.$/, "", s); return s
}'

# Each broker's JVM and its logs, from JMX: heap used against the most it
# may use, garbage collection (a running total of collections and of the
# time they took, per collector), open files against the limit, CPU,
# threads, how long it has run; how long flushing the log to disk takes,
# the log cleaner (compaction), and log directories offline.
now=$(date +%s)
report() {
    printf '%s\n' "$out" | awk -F '\t' -v b="$broker" -v now="$now" "$AWKFMT"'
        function out(name, v, tags) { if ((v = fmt(v)) != "") printf "metric %s %s broker=%s%s\n", name, v, b, tags }
        /:HeapMemoryUsage/ {
            if (match($2, /used=[0-9]+/)) out("heap_used_bytes", substr($2, RSTART + 5, RLENGTH - 5), "")
            if (match($2, /max=[0-9]+/)) out("heap_max_bytes", substr($2, RSTART + 4, RLENGTH - 4), "")
            next
        }
        /type=GarbageCollector/ {
            g = $1; sub(/.*name=/, "", g); sub(/,type=.*/, "", g); gsub(/[^A-Za-z0-9_.-]/, "_", g)
            if ($1 ~ /:CollectionCount$/) out("gc_count", $2, " gc=" g)
            else if ($1 ~ /:CollectionTime$/) out("gc_ms_count", $2, " gc=" g)
            next
        }
        /:OpenFileDescriptorCount/ { out("open_files", $2, ""); next }
        /:MaxFileDescriptorCount/ { out("max_files", $2, ""); next }
        /:ProcessCpuLoad/ { if ((v = fmt($2)) != "" && v >= 0) out("cpu_pct", v * 100, ""); next }
        /:ThreadCount/ { out("threads", $2, ""); next }
        /app-info,id=[0-9]+:StartTimeMs/ { if ((v = fmt($2)) != "") out("uptime_seconds", now - int(v / 1000), ""); next }
        /LogFlushRateAndTimeMs:99thPercentile/ { out("flush_ms_p99", $2, ""); next }
        /LogFlushRateAndTimeMs:Count/ { out("flushes_count", $2, ""); next }
        /name=max-dirty-percent:Value/ { out("cleaner_max_dirty_pct", $2, ""); next }
        /name=time-since-last-run-ms:Value/ { out("cleaner_idle_seconds", int($2 / 1000), ""); next }
        /name=DeadThreadCount:Value/ { out("cleaner_dead_threads", $2, ""); next }
        # Before the cleaner first runs this holds nonsense, below 0.
        /name=max-clean-time-secs:Value/ { if ($2 + 0 >= 0) out("cleaner_max_clean_seconds", $2, ""); next }
        /OfflineLogDirectoryCount:Value/ { out("offline_log_dirs", $2, "") }'
}
jmx_each report \
    --object-name 'java.lang:type=Memory' \
    --object-name 'java.lang:type=GarbageCollector,name=*' \
    --object-name 'java.lang:type=OperatingSystem' \
    --object-name 'java.lang:type=Threading' \
    --object-name 'kafka.log:type=LogFlushStats,name=LogFlushRateAndTimeMs' \
    --object-name 'kafka.log:type=LogCleanerManager,name=*' \
    --object-name 'kafka.log:type=LogCleaner,name=*' \
    --object-name 'kafka.log:type=LogManager,name=OfflineLogDirectoryCount' \
    --attributes Version,StartTimeMs,HeapMemoryUsage,CollectionCount,CollectionTime,OpenFileDescriptorCount,MaxFileDescriptorCount,ProcessCpuLoad,ThreadCount,Value,99thPercentile,Count
exit 0
