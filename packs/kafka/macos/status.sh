#!/usr/bin/env bash
#
# status.sh - a Kafka cluster's health
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
# Reports whether the cluster answers, its id, whether it runs on KRaft or
# ZooKeeper, its brokers and how many are fenced, and which node is the active
# controller. Read-only: it changes nothing in the cluster.
#
# Connects to KAFKA_BOOTSTRAP (host:port, comma-separated) with Kafka's own
# command-line tools, as KAFKA_USER with the password in KAFKA_PASSWORD, set
# by the job; never on a command line: it goes in a client configuration of
# the run's own, in a folder only this account can read, deleted at the end.
# KAFKA_SECURITY is PLAINTEXT, SSL, SASL_PLAINTEXT or SASL_SSL;
# KAFKA_SASL_MECHANISM SCRAM-SHA-512, SCRAM-SHA-256 or PLAIN. With TLS, the
# brokers' certificates are checked against KAFKA_CACERT, a PEM file of CAs,
# or Java's own, and against their names; KAFKA_CERT and KAFKA_KEY give a
# client certificate. KAFKA_CLIENT_CONFIG, a client properties file of your
# own, replaces all of these, for a login this pack does not build (Kerberos,
# OAuth). KAFKA_HOME is where Kafka is unpacked, when its tools are not on the
# PATH.
#
# Metrics:
#   up              1 when the cluster answers, else 0
#   info            always 1, tagged cluster_id=<its id> and kraft=<yes or no>
#   brokers         brokers the cluster lists
#   brokers_fenced  of those, brokers fenced: registered, but not serving
#   controller_id   the node that is the active controller (KRaft)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric info 1 cluster_id=MkU3OEVBNTcwNTJENDM2Qg kraft=yes
#   metric brokers 3
#   metric brokers_fenced 0
#   metric controller_id 2
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  up 1; brokers steady at as many as you run; brokers_fenced 0.
#   Watch    controller_id changing often: the controllers keep electing a new
#            leader.
#   Act      up 0; brokers below what you run: a broker is down;
#            brokers_fenced above 0 for minutes.
#
# Requires: bash, Kafka's command-line tools (any from 3.9, the Kafka
#   download), Java 17 or later, and a user with the ACLs packs/README.md
#   lists
# Exit code: 0 on success, cluster up or down; 1 if the tools are missing, or
#   the cluster refuses the login, its certificate or a request

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
    echo "status: $1.sh not found: install Kafka's command-line tools (the Kafka download), and set KAFKA_HOME to the folder that holds bin/" >&2
    exit 1
}
if [ -z "${JAVA_HOME-}" ] && ! command -v java > /dev/null 2>&1; then
    echo "status: java not found: Kafka's tools need Java 17 or later, on the PATH or in JAVA_HOME" >&2
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
                    *) echo "status: KAFKA_SASL_MECHANISM is '$mech': set it to SCRAM-SHA-512, SCRAM-SHA-256 or PLAIN (or give KAFKA_CLIENT_CONFIG)" >&2; exit 1 ;;
                esac
                [ -n "${KAFKA_PASSWORD-}" ] || { echo "status: no password: KAFKA_SECURITY is $security, and KAFKA_PASSWORD is empty (vigil secret set KAFKA_MONITOR_PASSWORD)" >&2; exit 1; }
                # In the JAAS line, a quote or a backslash is escaped.
                u=${KAFKA_USER:-vigil_monitor}
                u=${u//\\/\\\\} u=${u//\"/\\\"}
                p=${KAFKA_PASSWORD//\\/\\\\} p=${p//\"/\\\"}
                printf 'sasl.mechanism=%s\n' "$mech"
                printf 'sasl.jaas.config=%s required username="%s" password="%s";\n' "$module" "$u" "$p"
                ;;
            PLAINTEXT | SSL) ;;
            *) echo "status: KAFKA_SECURITY is '$security': set it to PLAINTEXT, SSL, SASL_PLAINTEXT or SASL_SSL" >&2; exit 1 ;;
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

# bounded <command...>: runs it, its output in $work/out and its errors in
# $work/err, and stops it if it has not finished in 45 seconds, saying so in
# $work/err. The client settings above bound each request, but a tool can
# still hang: Kafka 3.9's kafka-broker-api-versions logs a failed TLS
# handshake, then waits forever.
bounded() {
    local pid dog rc
    "$@" > "$work/out" 2> "$work/err" &
    pid=$!
    # The watchdog ends its own sleep when it is ended, so none is left.
    (
        trap 'kill "$s" 2> /dev/null; exit 0' TERM
        sleep 45 &
        s=$!
        wait "$s"
        kill "$pid" 2> /dev/null && echo 'Timed out: no answer in 45 seconds, stopped' >> "$work/err"
    ) > /dev/null 2>&1 &
    dog=$!
    wait "$pid" 2> /dev/null
    rc=$?
    # bash says "Terminated" of a job it reaps, on the stderr of its wait.
    kill "$dog" 2> /dev/null
    wait "$dog" 2> /dev/null
    return "$rc"
}

# run <tool> <args...>: the tool's output in $out. On failure: a cluster that
# cannot be reached returns 2 (the caller reports it, or nothing); anything
# else, a login or certificate refused, a permission missing, says why and
# exits 1. A tool that hangs is stopped (bounded), and judged by what it
# said before it was.
run() {
    local t rc
    t=$(kt "$1") || need "$1"
    shift
    bounded "$t" "$@"
    rc=$?
    out=$(cat "$work/out")
    [ "$rc" -eq 0 ] && return 0
    # lenient: any failure but an unreachable cluster returns 1, for a
    # caller with another way to go on.
    if [ -n "${lenient-}" ]; then
        grep -qE 'TimeoutException|Timed out waiting|could not be established|Connection refused|UnknownHostException|No resolvable bootstrap urls' "$work/err" && return 2
        return 1
    fi
    if grep -qE 'SaslAuthenticationException|Authentication failed|SslAuthenticationException|SSL handshake failed|PKIX path|certificate' "$work/err"; then
        echo "status: the cluster refused the login or its certificate: $(why)" >&2
        exit 1
    fi
    if grep -qE 'AuthorizationException|[Nn]ot authorized|Authorization failed' "$work/err"; then
        echo "status: a permission is missing (packs/README.md lists the ACLs): $(why)" >&2
        exit 1
    fi
    if grep -qE 'TimeoutException|Timed out waiting|could not be established|Connection refused|UnknownHostException|No resolvable bootstrap urls|Broker may not be available|disconnected' "$work/err"; then
        return 2
    fi
    [ -n "${soft-}" ] && return 1
    if grep -q '^Timed out: no answer in 45 seconds' "$work/err"; then
        echo "status: $(kt_name "$t") did not finish in 45 seconds, and was stopped: $(why)" >&2
        exit 1
    fi
    echo "status: $(kt_name "$t") failed (exit $rc): $(why)" >&2
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
    echo "status: no topics are visible: the cluster has none, or this user may not describe them (packs/README.md lists the ACLs)" >&2
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
    local fn=$1 t ep rc
    shift
    [ -n "${KAFKA_JMX-}" ] || return 0
    t=$(kt kafka-run-class) || need kafka-run-class
    for ep in ${KAFKA_JMX//,/ }; do
        bounded "$t" org.apache.kafka.tools.JmxTool --jmx-url "service:jmx:rmi:///jndi/rmi://$ep/jmxrmi" \
            --object-name 'kafka.server:type=app-info,id=*' "$@" \
            --one-time true --report-format tsv
        rc=$?
        out=$(cat "$work/out")
        if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -q 'app-info'; then
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

# The brokers, as the cluster lists them.
brokers_list
rc=$?
if [ "$rc" = 2 ]; then echo 'metric up 0'; exit 0; fi
brokers=$out

# KRaft: the quorum names the cluster and its active controller. A cluster
# on ZooKeeper (Kafka 3) has no quorum to ask: its id comes from
# kafka-cluster.
kraft=yes cluster='' controller=''
if try kafka-metadata-quorum "${conn[@]}" describe --status; then
    cluster=$(printf '%s\n' "$out" | sed -n 's/^ClusterId: *//p')
    controller=$(printf '%s\n' "$out" | sed -n 's/^LeaderId: *//p')
else
    [ "$?" = 2 ] && { echo 'metric up 0'; exit 0; }
fi
if [ -z "$cluster" ]; then
    kraft=no
    run kafka-cluster cluster-id "${conn[@]}" || { echo 'metric up 0'; exit 0; }
    cluster=$(printf '%s\n' "$out" | sed -n 's/^Cluster ID: *//p')
fi

echo 'metric up 1'
echo "metric info 1 cluster_id=$(tagv "$cluster") kraft=$kraft"
printf '%s\n' "$brokers" | awk '
    / \(id: [0-9]+ rack: / { n++; if ($0 ~ /isFenced: true/) f++ }
    END { printf "metric brokers %d\nmetric brokers_fenced %d\n", n, f }'
[ -n "$controller" ] && [ "$controller" != -1 ] && echo "metric controller_id $controller"
exit 0
