#!/usr/bin/env bash
#
# requests.sh - how each Kafka broker serves requests
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
# Reports how each broker serves requests: the time produce, consumer fetch
# and follower fetch requests take (99th percentile, as the broker measures it
# over its recent requests), the time they queue and wait on others, how many
# it has served, the request and response queues, requests waiting in
# purgatory, and how idle its request handler and network threads are.
# Read-only: it changes nothing in the cluster.
#
# Reads each broker's JMX, at KAFKA_JMX: host:port, comma-separated, one per
# broker, through Kafka's own JmxTool (KAFKA_HOME, when its tools are not on
# the PATH). JMX without a password, as Kafka's start scripts set it up with
# JMX_PORT: JmxTool takes a password only on its command line, where this pack
# never puts one. Each broker is named by its id. With no KAFKA_JMX, it prints
# nothing.
#
# Metrics:
#   jmx_up            1 when a broker's JMX answers, tagged broker=<id, or its
#                     JMX host:port>
#   total_ms_p99      the time a request takes, in ms, tagged broker=<id> and
#                     request=<Produce, FetchConsumer or FetchFollower>
#   queue_ms_p99      of that, the time it waits in the queue, tagged the same
#   remote_ms_p99     of that, the time it waits on other brokers (acks=all)
#                     or for data (fetch), tagged the same
#   requests_count    requests served, a running total, tagged the same
#   request_queue     requests waiting for a handler thread, tagged
#                     broker=<id>
#   response_queue    responses waiting to be sent, tagged the same
#   purgatory         requests waiting in purgatory, tagged broker=<id> and
#                     operation=<produce or fetch>
#   handler_idle_pct  how idle the request handler threads are, as a percent,
#                     tagged broker=<id>
#   network_idle_pct  how idle the network threads are, as a percent, tagged
#                     the same
#
# Example output (the rest are in the same form):
#   metric total_ms_p99 502 broker=1 request=FetchConsumer
#   metric queue_ms_p99 3 broker=1 request=Produce
#   metric remote_ms_p99 43.23 broker=1 request=Produce
#   metric request_queue 0 broker=1
#   metric response_queue 0 broker=1
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  handler_idle_pct and network_idle_pct above 30; request_queue
#            near 0; Produce total_ms_p99 steady.
#   Watch    handler_idle_pct below 30: the broker is busy; queue_ms_p99
#            rising: requests wait for threads.
#   Act      handler_idle_pct or network_idle_pct below 10: the broker is
#            saturated; Produce total_ms_p99 climbing with remote_ms_p99:
#            followers are slow to replicate.
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
    echo "requests: $1.sh not found: install Kafka's command-line tools (the Kafka download), and set KAFKA_HOME to the folder that holds bin/" >&2
    exit 1
}
if [ -z "${JAVA_HOME-}" ] && ! command -v java > /dev/null 2>&1; then
    echo "requests: java not found: Kafka's tools need Java 17 or later, on the PATH or in JAVA_HOME" >&2
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
                    *) echo "requests: KAFKA_SASL_MECHANISM is '$mech': set it to SCRAM-SHA-512, SCRAM-SHA-256 or PLAIN (or give KAFKA_CLIENT_CONFIG)" >&2; exit 1 ;;
                esac
                [ -n "${KAFKA_PASSWORD-}" ] || { echo "requests: no password: KAFKA_SECURITY is $security, and KAFKA_PASSWORD is empty (vigil secret set KAFKA_MONITOR_PASSWORD)" >&2; exit 1; }
                # In the JAAS line, a quote or a backslash is escaped.
                u=${KAFKA_USER:-vigil_monitor}
                u=${u//\\/\\\\} u=${u//\"/\\\"}
                p=${KAFKA_PASSWORD//\\/\\\\} p=${p//\"/\\\"}
                printf 'sasl.mechanism=%s\n' "$mech"
                printf 'sasl.jaas.config=%s required username="%s" password="%s";\n' "$module" "$u" "$p"
                ;;
            PLAINTEXT | SSL) ;;
            *) echo "requests: KAFKA_SECURITY is '$security': set it to PLAINTEXT, SSL, SASL_PLAINTEXT or SASL_SSL" >&2; exit 1 ;;
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
        echo "requests: the cluster refused the login or its certificate: $(why)" >&2
        exit 1
    fi
    if grep -qE 'AuthorizationException|[Nn]ot authorized|Authorization failed' "$work/err"; then
        echo "requests: a permission is missing (packs/README.md lists the ACLs): $(why)" >&2
        exit 1
    fi
    if grep -qE 'TimeoutException|Timed out waiting|could not be established|Connection refused|UnknownHostException|No resolvable bootstrap urls|Broker may not be available|disconnected' "$work/err"; then
        return 2
    fi
    [ -n "${soft-}" ] && return 1
    echo "requests: $(kt_name "$t") failed (exit $rc): $(why)" >&2
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
    echo "requests: no topics are visible: the cluster has none, or this user may not describe them (packs/README.md lists the ACLs)" >&2
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

# How each broker serves requests, from JMX: the time produce, consumer
# fetch and follower fetch requests take (99th percentile, in ms, as the
# broker measures it over its recent requests) and how many it has served;
# how long they queue; the request and response queues; requests parked in
# purgatory; and how idle its request handler and network threads are.
report() {
    printf '%s\n' "$out" | awk -F '\t' -v b="$broker" "$AWKFMT"'
        function out(name, v, tags) { if ((v = fmt(v)) != "") printf "metric %s %s broker=%s%s\n", name, v, b, tags }
        /RequestMetrics,name=TotalTimeMs,request=/ {
            r = $1; sub(/.*request=/, "", r); a = r; sub(/^[^:]*:/, "", a); sub(/:.*/, "", r)
            if (a == "99thPercentile") out("total_ms_p99", $2, " request=" r)
            else if (a == "Count") out("requests_count", $2, " request=" r)
            next
        }
        /RequestMetrics,name=RequestQueueTimeMs,request=.*:99thPercentile/ { r = $1; sub(/.*request=/, "", r); sub(/:.*/, "", r); out("queue_ms_p99", $2, " request=" r); next }
        /RequestMetrics,name=RemoteTimeMs,request=.*:99thPercentile/ { r = $1; sub(/.*request=/, "", r); sub(/:.*/, "", r); out("remote_ms_p99", $2, " request=" r); next }
        /RequestChannel,name=RequestQueueSize:Value/ { out("request_queue", $2, ""); next }
        /RequestChannel,name=ResponseQueueSize:Value/ { out("response_queue", $2, ""); next }
        /PurgatorySize,delayedOperation=/ { o = $1; sub(/.*delayedOperation=/, "", o); sub(/:.*/, "", o); out("purgatory", $2, " operation=" tolower(o)); next }
        # The idle shares are fractions, 0 to 1: as percents.
        /RequestHandlerAvgIdlePercent:OneMinuteRate/ { if ((v = fmt($2)) != "") out("handler_idle_pct", v * 100, ""); next }
        /NetworkProcessorAvgIdlePercent:Value/ { if ((v = fmt($2)) != "") out("network_idle_pct", v * 100, "") }'
}
objs=()
for r in Produce FetchConsumer FetchFollower; do
    objs+=(--object-name "kafka.network:type=RequestMetrics,name=TotalTimeMs,request=$r"
        --object-name "kafka.network:type=RequestMetrics,name=RequestQueueTimeMs,request=$r"
        --object-name "kafka.network:type=RequestMetrics,name=RemoteTimeMs,request=$r")
done
jmx_each report "${objs[@]}" \
    --object-name 'kafka.network:type=RequestChannel,name=RequestQueueSize' \
    --object-name 'kafka.network:type=RequestChannel,name=ResponseQueueSize' \
    --object-name 'kafka.server:type=DelayedOperationPurgatory,name=PurgatorySize,delayedOperation=Produce' \
    --object-name 'kafka.server:type=DelayedOperationPurgatory,name=PurgatorySize,delayedOperation=Fetch' \
    --object-name 'kafka.server:type=KafkaRequestHandlerPool,name=RequestHandlerAvgIdlePercent' \
    --object-name 'kafka.network:type=SocketServer,name=NetworkProcessorAvgIdlePercent' \
    --attributes Version,Value,Count,99thPercentile,OneMinuteRate
exit 0
