#!/usr/bin/env bash
#
# config.sh - risky Kafka settings
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
# Reports the brokers' settings that matter most for safety, from the first
# broker, how many of them differ between brokers, and the topics whose own
# settings put their data at risk. Read-only: it changes nothing in the
# cluster.
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
#   unclean_leader_election          1 when an out-of-sync replica may become
#                                    leader, losing data
#   auto_create_topics               1 when a client creates a topic just by
#                                    naming it
#   auto_leader_rebalance            1 when leadership moves back to preferred
#                                    leaders by itself
#   authorizer                       1 when ACLs are checked
#   min_insync_replicas              the default min.insync.replicas
#   default_replication_factor       the replication factor of a topic created
#                                    without one
#   offsets_replication_factor       the consumer offsets topic's
#   transactions_replication_factor  the transaction state topic's
#   message_max_bytes                the largest batch a broker takes
#   retention_hours                  how long messages are kept by default; -1
#                                    forever
#   plaintext_listeners              listeners without TLS or a login, the
#                                    controllers' left out
#   settings_differ                  settings with different values on
#                                    different brokers
#   topics_unclean_election          topics that allow unclean leader election
#   topics_min_isr_ge_rf             topics with more replicas than one whose
#                                    min.insync.replicas is at least their
#                                    replication factor: one replica down and
#                                    writes with acks=all fail
#   topics_min_isr_1                 topics with 3 or more replicas but
#                                    min.insync.replicas 1: acks=all keeps
#                                    only one copy
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  unclean_leader_election 0; min_insync_replicas 2 with a
#            replication factor of 3; settings_differ 0.
#   Watch    auto_create_topics 1 in production: a typo makes a topic;
#            plaintext_listeners above 0.
#   Act      unclean_leader_election 1, or topics_unclean_election above 0,
#            where data must not be lost; topics_min_isr_ge_rf above 0.
#
# Requires: bash, Kafka's command-line tools (any from 3.9, the Kafka
#   download), Java 17 or later, and a user with the ACLs packs/README.md
#   lists
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
    echo "config: $1.sh not found: install Kafka's command-line tools (the Kafka download), and set KAFKA_HOME to the folder that holds bin/" >&2
    exit 1
}
if [ -z "${JAVA_HOME-}" ] && ! command -v java > /dev/null 2>&1; then
    echo "config: java not found: Kafka's tools need Java 17 or later, on the PATH or in JAVA_HOME" >&2
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
                    *) echo "config: KAFKA_SASL_MECHANISM is '$mech': set it to SCRAM-SHA-512, SCRAM-SHA-256 or PLAIN (or give KAFKA_CLIENT_CONFIG)" >&2; exit 1 ;;
                esac
                [ -n "${KAFKA_PASSWORD-}" ] || { echo "config: no password: KAFKA_SECURITY is $security, and KAFKA_PASSWORD is empty (vigil secret set KAFKA_MONITOR_PASSWORD)" >&2; exit 1; }
                # In the JAAS line, a quote or a backslash is escaped.
                u=${KAFKA_USER:-vigil_monitor}
                u=${u//\\/\\\\} u=${u//\"/\\\"}
                p=${KAFKA_PASSWORD//\\/\\\\} p=${p//\"/\\\"}
                printf 'sasl.mechanism=%s\n' "$mech"
                printf 'sasl.jaas.config=%s required username="%s" password="%s";\n' "$module" "$u" "$p"
                ;;
            PLAINTEXT | SSL) ;;
            *) echo "config: KAFKA_SECURITY is '$security': set it to PLAINTEXT, SSL, SASL_PLAINTEXT or SASL_SSL" >&2; exit 1 ;;
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
        echo "config: the cluster refused the login or its certificate: $(why)" >&2
        exit 1
    fi
    if grep -qE 'AuthorizationException|[Nn]ot authorized|Authorization failed' "$work/err"; then
        echo "config: a permission is missing (packs/README.md lists the ACLs): $(why)" >&2
        exit 1
    fi
    if grep -qE 'TimeoutException|Timed out waiting|could not be established|Connection refused|UnknownHostException|No resolvable bootstrap urls|Broker may not be available|disconnected' "$work/err"; then
        return 2
    fi
    [ -n "${soft-}" ] && return 1
    echo "config: $(kt_name "$t") failed (exit $rc): $(why)" >&2
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
    echo "config: no topics are visible: the cluster has none, or this user may not describe them (packs/README.md lists the ACLs)" >&2
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

# The settings that matter most for safety, from every broker:
#   All configs for broker 1 are:
#     unclean.leader.election.enable=false sensitive=false synonyms={...}
# reported from the first, with a count of those that differ between
# brokers; then the topics whose own settings put their data at risk.
run kafka-configs "${conn[@]}" --describe --entity-type brokers --all || exit 0
brokers=$out
run kafka-topics "${conn[@]}" --describe || exit 0
{
    printf '%s\n' "$brokers" | awk '
        /^All configs for broker / { b = $5; next }
        /^  [a-z.]+=/ { line = substr($0, 3); k = line; sub(/=.*/, "", k); v = line; sub(/^[^=]*=/, "", v); sub(/ sensitive=(true|false) synonyms=.*/, "", v); print "B", b, k, v }'
    printf '%s\n' "$out" | grep '^Topic: ' | awk -F '\t' '
        function val(f,  i) { i = index(f, ": "); return i ? substr(f, i + 2) : "" }
        { t = val($1); rf = 0; mi = 1; u = 0
          for (i = 1; i <= NF; i++) {
              if ($i ~ /^ReplicationFactor: /) rf = val($i)
              else if ($i ~ /^Configs: /) {
                  if (match($i, /(^|[ ,])min\.insync\.replicas=[0-9]+/)) { v = substr($i, RSTART, RLENGTH); sub(/.*=/, "", v); mi = v + 0 }
                  if ($i ~ /(^|[ ,])unclean\.leader\.election\.enable=true/) u = 1
              }
          }
          print "T", t, rf, mi, u }'
} | awk '
    function bool(v) { return v == "true" ? 1 : 0 }
    $1 == "B" {
        b = $2; k = $3; v = $4; for (i = 5; i <= NF; i++) v = v " " $i
        if (first == "") first = b
        if (k in seen && seen[k] != v && k !~ /^(listeners|advertised\.listeners|broker\.id|node\.id|broker\.rack)$/) diff[k] = 1
        seen[k] = v
        if (b == first) cfg[k] = v
        next
    }
    $1 == "T" {
        if ($5) unclean++
        if ($3 > 1 && $4 >= $3) strict++
        if ($3 >= 3 && $4 <= 1) weak++
    }
    END {
        printf "metric unclean_leader_election %d\n", bool(cfg["unclean.leader.election.enable"])
        printf "metric auto_create_topics %d\n", bool(cfg["auto.create.topics.enable"])
        printf "metric auto_leader_rebalance %d\n", bool(cfg["auto.leader.rebalance.enable"])
        printf "metric authorizer %d\n", (cfg["authorizer.class.name"] != "" && cfg["authorizer.class.name"] != "null") ? 1 : 0
        if (cfg["min.insync.replicas"] ~ /^[0-9]+$/) printf "metric min_insync_replicas %d\n", cfg["min.insync.replicas"]
        if (cfg["default.replication.factor"] ~ /^[0-9]+$/) printf "metric default_replication_factor %d\n", cfg["default.replication.factor"]
        if (cfg["offsets.topic.replication.factor"] ~ /^[0-9]+$/) printf "metric offsets_replication_factor %d\n", cfg["offsets.topic.replication.factor"]
        if (cfg["transaction.state.log.replication.factor"] ~ /^[0-9]+$/) printf "metric transactions_replication_factor %d\n", cfg["transaction.state.log.replication.factor"]
        if (cfg["message.max.bytes"] ~ /^[0-9]+$/) printf "metric message_max_bytes %d\n", cfg["message.max.bytes"]
        # Retention: log.retention.ms, else .minutes, else .hours; -1 is forever.
        h = ""
        if (cfg["log.retention.ms"] ~ /^-?[0-9]+$/) h = (cfg["log.retention.ms"] < 0) ? -1 : cfg["log.retention.ms"] / 3600000
        else if (cfg["log.retention.minutes"] ~ /^-?[0-9]+$/) h = (cfg["log.retention.minutes"] < 0) ? -1 : cfg["log.retention.minutes"] / 60
        else if (cfg["log.retention.hours"] ~ /^-?[0-9]+$/) h = cfg["log.retention.hours"] + 0
        if (h != "") { s = sprintf("%.2f", h); sub(/0+$/, "", s); sub(/\.$/, "", s); printf "metric retention_hours %s\n", s }
        # Listeners without TLS or a login, but for the controllers.
        split(cfg["listener.security.protocol.map"], pm, ",")
        for (i in pm) { split(pm[i], kv, ":"); proto[kv[1]] = kv[2] }
        split(cfg["controller.listener.names"], cn, ","); for (i in cn) ctl[cn[i]] = 1
        n = split(cfg["listeners"], ls, ",")
        for (i = 1; i <= n; i++) { name = ls[i]; sub(/:\/\/.*/, "", name); if (!(name in ctl) && proto[name] == "PLAINTEXT") plain++ }
        printf "metric plaintext_listeners %d\n", plain
        for (k in diff) differ++
        printf "metric settings_differ %d\n", differ
        printf "metric topics_unclean_election %d\nmetric topics_min_isr_ge_rf %d\nmetric topics_min_isr_1 %d\n", unclean, strict, weak
    }'
exit 0
