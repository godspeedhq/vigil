#!/usr/bin/env bash
#
# tls.sh - the Kafka brokers' TLS certificates
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
# Reports, for each broker, the certificate it presents on the listener this
# pack connects to: how many days until it expires, and whether it is trusted
# (by KAFKA_CACERT, or the system's CAs) and names the broker. The brokers are
# those the cluster lists, as it tells clients to reach them; or
# KAFKA_TLS_ENDPOINTS, host:port, comma-separated. Without TLS, it reports tls
# 0. Read-only: it changes nothing in the cluster.
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
#   tls           1 when the listener uses TLS, else 0
#   endpoints     brokers checked
#   reachable     1 when a broker gave its certificate, tagged
#                 endpoint=<host:port>
#   expires_days  days until it expires, below 0 once it has, tagged the same
#   trusted       1 when it is trusted and names the broker, tagged the same
#
# Example output (the rest are in the same form):
#   metric tls 1
#   metric reachable 1 endpoint=localhost:19091
#   metric expires_days 1 endpoint=localhost:19091
#   metric trusted 1 endpoint=localhost:19091
#   metric endpoints 3
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  expires_days above 30 everywhere; trusted 1.
#   Watch    expires_days below 30: renew it.
#   Act      expires_days below 7, or trusted 0: clients that check
#            certificates will refuse the broker.
#
# Requires: bash, Kafka's command-line tools (any from 3.9, the Kafka
#   download), Java 17 or later, openssl, and a user with the ACLs
#   packs/README.md lists
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
    echo "tls: $1.sh not found: install Kafka's command-line tools (the Kafka download), and set KAFKA_HOME to the folder that holds bin/" >&2
    exit 1
}
if [ -z "${JAVA_HOME-}" ] && ! command -v java > /dev/null 2>&1; then
    echo "tls: java not found: Kafka's tools need Java 17 or later, on the PATH or in JAVA_HOME" >&2
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
                    *) echo "tls: KAFKA_SASL_MECHANISM is '$mech': set it to SCRAM-SHA-512, SCRAM-SHA-256 or PLAIN (or give KAFKA_CLIENT_CONFIG)" >&2; exit 1 ;;
                esac
                [ -n "${KAFKA_PASSWORD-}" ] || { echo "tls: no password: KAFKA_SECURITY is $security, and KAFKA_PASSWORD is empty (vigil secret set KAFKA_MONITOR_PASSWORD)" >&2; exit 1; }
                # In the JAAS line, a quote or a backslash is escaped.
                u=${KAFKA_USER:-vigil_monitor}
                u=${u//\\/\\\\} u=${u//\"/\\\"}
                p=${KAFKA_PASSWORD//\\/\\\\} p=${p//\"/\\\"}
                printf 'sasl.mechanism=%s\n' "$mech"
                printf 'sasl.jaas.config=%s required username="%s" password="%s";\n' "$module" "$u" "$p"
                ;;
            PLAINTEXT | SSL) ;;
            *) echo "tls: KAFKA_SECURITY is '$security': set it to PLAINTEXT, SSL, SASL_PLAINTEXT or SASL_SSL" >&2; exit 1 ;;
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
        echo "tls: the cluster refused the login or its certificate: $(why)" >&2
        exit 1
    fi
    if grep -qE 'AuthorizationException|[Nn]ot authorized|Authorization failed' "$work/err"; then
        echo "tls: a permission is missing (packs/README.md lists the ACLs): $(why)" >&2
        exit 1
    fi
    if grep -qE 'TimeoutException|Timed out waiting|could not be established|Connection refused|UnknownHostException|No resolvable bootstrap urls|Broker may not be available|disconnected' "$work/err"; then
        return 2
    fi
    [ -n "${soft-}" ] && return 1
    echo "tls: $(kt_name "$t") failed (exit $rc): $(why)" >&2
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
    echo "tls: no topics are visible: the cluster has none, or this user may not describe them (packs/README.md lists the ACLs)" >&2
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

# The certificate each broker presents on the listener this pack connects
# to: how many days until it expires, and whether it is trusted (by
# KAFKA_CACERT, or the system's CAs) and names the broker. The brokers are
# those the cluster lists, as it tells clients to reach them; or
# KAFKA_TLS_ENDPOINTS, host:port, comma-separated. Without TLS: tls 0.
case $security in SSL | SASL_SSL) ;; *) [ -n "${KAFKA_TLS_ENDPOINTS-}" ] || { echo 'metric tls 0'; exit 0; } ;; esac
command -v openssl > /dev/null 2>&1 || { echo "tls: openssl not found: install it to read the brokers' certificates" >&2; exit 1; }
if [ -n "${KAFKA_TLS_ENDPOINTS-}" ]; then
    eps=${KAFKA_TLS_ENDPOINTS//,/ }
else
    # The brokers as the cluster lists them; when it cannot be asked (a
    # certificate it does not trust is what this job is for), the bootstrap
    # list.
    lenient=1 brokers_list
    case $? in
        0) eps=$(printf '%s\n' "$out" | sed -n 's/^\([^ ]*:[0-9][0-9]*\) (id: .*/\1/p' | sort -u) ;;
        2) exit 0 ;;
        *) eps=${bootstrap//,/ } ;;
    esac
fi
echo 'metric tls 1'
now=$(date +%s)
hostcheck=''
openssl s_client -help 2>&1 | grep -q -- '-verify_hostname' && hostcheck=yes
n=0
for ep in $eps; do
    host=${ep%:*}
    opts=(-connect "$ep")
    case $host in
        *[!0-9.]*) opts+=(-servername "$host"); [ -n "$hostcheck" ] && opts+=(-verify_hostname "$host") ;;
        *) [ -n "$hostcheck" ] && opts+=(-verify_ip "$host") ;;
    esac
    [ -n "${KAFKA_CACERT-}" ] && opts+=(-CAfile "$KAFKA_CACERT")
    # A handshake that never ends is ended after 15 seconds.
    openssl s_client "${opts[@]}" < /dev/null > "$work/tls" 2>&1 &
    pid=$!
    ( sleep 15; kill "$pid" 2> /dev/null ) > /dev/null 2>&1 &
    dog=$!
    wait "$pid" 2> /dev/null
    # The watchdog, no longer needed, ended and waited for: bash says
    # "Terminated" of a job it reaps, on the stderr of its wait.
    kill "$dog" 2> /dev/null
    wait "$dog" 2> /dev/null
    n=$((n + 1))
    tag="endpoint=$(tagv "$ep")"
    end=$(openssl x509 -noout -enddate < "$work/tls" 2> /dev/null | sed 's/^notAfter=//')
    if [ -z "$end" ]; then
        echo "metric reachable 0 $tag"
        continue
    fi
    echo "metric reachable 1 $tag"
    end=$(printf '%s' "$end" | tr -s ' ')
    t=$(date -u -d "$end" +%s 2> /dev/null || date -u -j -f '%b %d %T %Y %Z' "$end" +%s 2> /dev/null)
    if [ -n "$t" ]; then
        echo "metric expires_days $(( (t - now) / 86400 )) $tag"
    fi
    if grep -q 'Verify return code: 0 ' "$work/tls"; then
        echo "metric trusted 1 $tag"
    else
        echo "metric trusted 0 $tag"
    fi
done
echo "metric endpoints $n"
exit 0
