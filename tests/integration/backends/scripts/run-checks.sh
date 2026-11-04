#!/usr/bin/env bash
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
# run-checks.sh - the delivery checks of section 5 beyond what run-vigil.sh
# shows, against one running target, on the Docker host: it stops and
# starts the target's containers.
#
#   scripts/start.sh prometheus
#   scripts/run-checks.sh prometheus
#
# One Vigil, with the target and a local file backend, runs a job every 5
# seconds that writes down its own run (a ledger outside Vigil), reports the
# second it ran as a metric, and prints it as a log line. Then, in turn:
#   - the target is stopped for 70 seconds, and started again
#   - the target is restarted
#   - Vigil's supervisor is stopped for 10 seconds, and started again
#   - the spool is cut to 1 MB, a job floods it, and the target is stopped
# The backend's own query interface is then asked what it holds, and each
# run in the ledger is looked for. Checks, numbered as in section 5:
#    4 job identifiers and labels   10 recovery from the spool
#    5 host metadata                11 a backend restart
#    6 timestamps preserved         12 duplicate delivery
#    7 authentication rejected      13 dropped telemetry reported
#    8 the backend unavailable      14 several destinations
#    9 retry and backoff            15 a healthy destination unaffected
#                                   16 a supervisor restart
# Needs curl and jq. Linux. Exit code: 0 when nothing failed.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

[ "$#" -eq 1 ] || die 'usage: run-checks.sh <target>'
target=$1
endpoints "$target"
[ -z "$bk_why" ] || die "$target: not applicable to Vigil: $bk_why"
command -v jq > /dev/null 2>&1 || die 'run-checks.sh needs jq'
services=$(services_of "$target")
[ -n "$services" ] || die "no containers for $target"

# Where to ask: a Prometheus-style API for metrics, and for logs a Loki
# (loki) or VictoriaLogs (vlogs) one at $logs, Elasticsearch (es) for both,
# OpenSearch (os) for logs, or ClickHouse (ch) for both.
prom='' logs_api='' logs=''
case $target in
    prometheus | alloy) prom=http://127.0.0.1:9090/api/v1 ;;
    mimir | otel-collector) prom=http://127.0.0.1:9009/prometheus/api/v1 ;;
    victoriametrics) prom=http://127.0.0.1:8428/api/v1 ;;
    # Not PromQL: documents searched in Elasticsearch (es() below), and
    # Flux on InfluxDB (ifq()), and SQL on ClickHouse (chq()).
    elastic) prom=es ;;
    influxdb) prom=influx ;;
    clickhouse) prom=ch ;;
    splunk) prom=splunk ;;
esac
case $target in
    loki | otel-collector | alloy) logs_api=loki logs=http://127.0.0.1:3100/loki/api/v1 ;;
    victorialogs) logs_api=vlogs logs=http://127.0.0.1:9428/select/logsql ;;
    elastic) logs_api=es ;;
    opensearch) logs_api=os ;;
    clickhouse) logs_api=ch ;;
    splunk) logs_api=splunk ;;
esac

tag="ck$(date -u '+%Y%m%d%H%M%S')$$"
# A well-formed HEC token Splunk never issued: check 7's backend sends it.
BK_BAD_TOKEN=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/')
export BK_BAD_TOKEN
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-ck.XXXXXX") || exit 1
root=$work/root
ledger=$work/ledger
sup=''
pass=0 fail=0 skip=0
cleanup() {
    # The supervisor this script started, and nothing else.
    [ -n "$sup" ] && kill "$sup" 2> /dev/null
    end_workers
    # The target is left running, as start.sh left it.
    [ -n "${down-}" ] && start_target > /dev/null
    evidence_save "${VIGIL_SPLUNK_METRICS_TOKEN-}" "${VIGIL_SPLUNK_LOGS_TOKEN-}" "${ELASTIC_PASSWORD-}" "${OPENSEARCH_ADMIN_PASSWORD-}" "${INFLUXDB_TOKEN-}" "${CLICKHOUSE_PASSWORD-}" "${SPLUNK_PASSWORD-}" "$BK_BAD_TOKEN"
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' TERM INT HUP

mkdir -p "$root/scripts" "$root/config" && cp -R "$bk_repo/app" "$root/" || exit 1
: > "$ledger"
evidence_start "checks-$target" "$bk_dir/compose*.yaml" "$0" "$@"

result() {
    local word=$1
    shift
    case $word in
        PASS) pass=$((pass + 1)) ;;
        FAIL) fail=$((fail + 1)) ;;
        *) skip=$((skip + 1)) ;;
    esac
    printf '  %s  %s\n' "$word" "$*"
}
say() { printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
vigil() { bash "$root/app/vigil" --root "$root" "$@" < /dev/null; }
# Not through vigil(): a function run in the background is a subshell, and
# $! would be that subshell, so stopping it would leave the supervisor up.
start_sup() {
    bash "$root/app/vigil" --root "$root" supervise < /dev/null >> "$work/supervise.out" 2>&1 &
    sup=$!
}
stop_target() { compose --profile "$target" stop $services > /dev/null 2>&1; down=1; }
start_target() { bash "$here/start.sh" "$target" > "$work/start.out" 2>&1 && down=''; }

# The job: writes its run in the ledger, then reports it as a metric and a
# line. Its metric is bk_check.seq, whose value is the second it ran.
cat > "$root/scripts/check.sh" << 'EOF'
s=$(date +%s)
echo "$s" >> "$BK_LEDGER"
echo "metric seq $s run=$BK_RUN"
echo "line $BK_RUN $s"
EOF
# Many series in one run, to fill a small spool: 1000, the most Vigil takes
# from a run (14.3).
cat > "$root/scripts/flood.sh" << 'EOF'
i=0
while [ "$i" -lt 1000 ]; do echo "metric flood_$i 1 run=$BK_RUN"; i=$((i + 1)); done
EOF

config() {
    printf '[vigil]\ninstance = backend-check\n\n[scheduler]\ntick = 2s\n\n'
    printf '[runner.sh]\ncommand = /bin/bash\n\n[runners]\n.sh = sh\n\n'
    [ -n "${1-}" ] && printf '[spool]\nmax_mb = 1\n\n'
    if [ -n "$bk_metrics" ]; then
        printf '[backend.target]\ntype     = %s\nendpoint = %s\n' "${bk_metrics%% *}" "${bk_metrics#* }"
        [ "$target" = splunk ] && printf 'token    = env:VIGIL_SPLUNK_METRICS_TOKEN\n'
        printf '\n'
    fi
    # 7: a credential the target must refuse, beside the right one.
    if [ "$target" = splunk ]; then
        printf '[backend.badtoken]\ntype     = splunk\nendpoint = %s\ntoken    = env:BK_BAD_TOKEN\n\n' "${bk_metrics#* }"
    fi
    # The second destination, healthy throughout.
    printf '[backend.local]\ntype = file\npath = metrics/local.prom\n\n'
    if [ -n "$bk_logs" ]; then
        printf '[log_forward]\ndestination = target\ninclude     = run, stdout, stderr\ncheck_every = 5s\n\n'
        printf '[log_destination.target]\ntype     = %s\nendpoint = %s\n' "${bk_logs%% *}" "${bk_logs#* }"
        [ "$target" = splunk ] && printf 'token    = env:VIGIL_SPLUNK_LOGS_TOKEN\n'
        printf '\n'
    fi
    printf '[job.bk_check]\nfile = scripts/check.sh\nrun_every = 5s\nenv = BK_RUN=%s\nenv = BK_LEDGER=%s\n\n' "$tag" "$ledger"
    # To the target only: the file backend merges about 430 events a second
    # (backlog 29), and would hold up the sender for the flood.
    [ -n "${1-}" ] && printf '[job.bk_flood]\nfile = scripts/flood.sh\nrun_every = 2s\nbackends = target\nenv = BK_RUN=%s\n' "$tag"
    return 0
}
config > "$root/config/vigil.config"

# PromQL $1, as JSON.
pq() { curl -fsS -m 30 -G "$prom/query" --data-urlencode "query=$1"; }
# An Elasticsearch search of index pattern $1 with body $2, as JSON. The
# password goes to curl on its standard input, never its command line.
es() {
    printf 'user = "elastic:%s"\n' "$ELASTIC_PASSWORD" |
        curl -fsS -m 30 -K - -H 'Content-Type: application/json' "http://127.0.0.1:9200/$1/_search" -d "$2"
}
# Flux $1 on InfluxDB, as CSV with a header, one row a line. The token goes
# to curl on its standard input, never its command line.
ifq() {
    printf 'header = "Authorization: Token %s"\n' "$INFLUXDB_TOKEN" |
        curl -fsS -m 30 -K - 'http://127.0.0.1:8086/api/v2/query?org=vigil' \
            -H 'Content-Type: application/vnd.flux' -H 'Accept: application/csv' --data "$1" | tr -d '\r'
}
# A Splunk search $1, from time $2 (default an hour ago), through the
# management API, as JSON results one a line. The password goes to curl on
# its standard input; the certificate is the test CA's, verified.
spl() {
    printf 'user = "admin:%s"\n' "$SPLUNK_PASSWORD" |
        curl -fsS -m 60 -K - --cacert "$bk_dir/.secrets/tls/ca.pem" https://127.0.0.1:8089/services/search/jobs/export \
            --data-urlencode "search=$1" -d output_mode=json -d "earliest_time=${2:--1h}" |
        jq -c '.result // empty'
}
# SQL $1 on ClickHouse, as tab-separated rows. The password goes to curl on
# its standard input, never its command line.
chq() {
    printf 'user = "vigil:%s"\n' "$CLICKHOUSE_PASSWORD" |
        curl -fsS -m 30 -K - http://127.0.0.1:18123/ --data-binary "$1 FORMAT TSV"
}
# Columns $2... of CSV $1 (a header line, then rows), space-separated.
csv_cols() {
    printf '%s\n' "$1" | awk -F, -v want="${*:2}" '
        NR == 1 { n = split(want, w, " "); for (i = 1; i <= NF; i++) col[$i] = i; next }
        NF > 1 { line = ""; for (j = 1; j <= n; j++) line = line (j > 1 ? " " : "") $(col[w[j]]); print line }'
}
# The same for OpenSearch, its demo certificate verified against the root CA
# configs/platforms/opensearch/ca.sh copied out.
osq() {
    printf 'user = "admin:%s"\n' "$OPENSEARCH_ADMIN_PASSWORD" |
        curl -fsS -m 30 -K - --cacert "$bk_dir/.secrets/opensearch/root-ca.pem" -H 'Content-Type: application/json' \
            "https://127.0.0.1:9201/$1/_search" -d "$2"
}
# bk_check.seq for this run, under the name each backend gives it:
# Prometheus-style names turn the dot into an underscore, others keep it.
seq_sel="{__name__=~\"bk_check[._]seq\",run=\"$tag\"}"
es_seq="{\"size\":5000,\"query\":{\"bool\":{\"filter\":[{\"match\":{\"attributes.run\":\"$tag\"}},{\"exists\":{\"field\":\"metrics.bk_check.seq\"}}]}},\"sort\":[{\"@timestamp\":\"asc\"}]}"
flux_seq="from(bucket: \"vigil\") |> range(start: -1h) |> filter(fn: (r) => r._measurement == \"bk_check.seq\" and r._field == \"gauge\" and r.run == \"$tag\")"
# Every stored sample of it, as "<timestamp> <value>".
samples() {
    case $prom in
        es) es 'metrics-*' "$es_seq" | jq -r '.hits.hits[]._source | "\((.["@timestamp"] | tonumber) / 1000 | floor) \(.metrics["bk_check.seq"] | floor)"' ;;
        influx) csv_cols "$(ifq "$flux_seq |> map(fn: (r) => ({t: int(v: r._time) / 1000000000, v: int(v: r._value)}))")" t v ;;
        splunk)
            # Per second, how many samples and their value: two in one second
            # are a duplicate, and are listed twice.
            spl "| mstats count(_value) AS n latest(_value) AS v WHERE index=vigil_metrics AND metric_name=\"bk_check.seq\" AND run=\"$tag\" span=1s | where n > 0 | eval t=_time" |
                jq -r '. as $r | range($r.n | tonumber) | "\($r.t | tonumber | floor) \($r.v | tonumber | floor)"'
            ;;
        ch) chq "SELECT toUnixTimestamp(TimeUnix), toInt64(Value) FROM vigil.otel_metrics_gauge WHERE MetricName = 'bk_check.seq' AND Attributes['run'] = '$tag' ORDER BY TimeUnix" | tr '\t' ' ' ;;
        *) pq "$seq_sel[1h]" | jq -r '.data.result[0].values[]? | "\(.[0]) \(.[1])"' ;;
    esac
}
# The labels of its latest sample, one "key=value" a line.
labels() {
    case $prom in
        es) es 'metrics-*' "$es_seq" | jq -r '.hits.hits[-1]._source | (.attributes + .resource.attributes) | to_entries[] | "\(.key)=\(.value)"' ;;
        splunk)
            spl "| mstats latest(_value) AS v WHERE index=vigil_metrics AND metric_name=\"bk_check.seq\" AND run=\"$tag\" BY host os instance job run" |
                head -n 1 | jq -r 'to_entries[] | select(.key != "v") | "\(.key)=\(.value)"'
            ;;
        ch)
            chq "SELECT concat(k, '=', v) FROM (SELECT Attributes AS m FROM vigil.otel_metrics_gauge WHERE MetricName = 'bk_check.seq' AND Attributes['run'] = '$tag' ORDER BY TimeUnix DESC LIMIT 1) ARRAY JOIN mapKeys(m) AS k, mapValues(m) AS v"
            ;;
        influx)
            # The tags of the last row: every column but Flux's own.
            ifq "$flux_seq |> last()" | awk -F, 'NR == 1 { for (i = 1; i <= NF; i++) h[i] = $i; next }
                NF > 1 { for (i = 1; i <= NF; i++) if (h[i] != "" && h[i] !~ /^_/ && h[i] != "result" && h[i] != "table") print h[i] "=" $i; exit }'
            ;;
        *) pq "last_over_time($seq_sel[1h])" | jq -r '.data.result[0].metric | to_entries[] | "\(.key)=\(.value)"' ;;
    esac
}
# The drops of the target's events that the target itself holds, as
# "<reason>=<value>" a line, or nothing. Prometheus adds _total to a
# counter's name; Mimir, by default, does not; others keep the dots.
drops() {
    case $prom in
        es)
            # Only this run's: Vigil's own metrics carry no run tag, and a
            # search, unlike PromQL, finds a series however old it is.
            es 'metrics-*' "{\"size\":1,\"query\":{\"bool\":{\"filter\":[{\"match\":{\"attributes.backend\":\"target\"}},{\"match\":{\"attributes.instance\":\"backend-check\"}},{\"exists\":{\"field\":\"metrics.vigil.spool.dropped\"}},{\"range\":{\"@timestamp\":{\"gte\":$((t_start * 1000))}}}]}},\"sort\":[{\"@timestamp\":\"desc\"}]}" |
                jq -r '.hits.hits[]._source | "\(.attributes.reason)=\(.metrics["vigil.spool.dropped"])"'
            ;;
        splunk)
            spl "| mstats latest(_value) AS v WHERE index=vigil_metrics AND metric_name=\"vigil.spool.dropped\" AND backend=\"target\" AND instance=\"backend-check\" BY reason" "$t_start" |
                jq -r '"\(.reason)=\(.v)"'
            ;;
        ch)
            chq "SELECT concat(Attributes['reason'], '=', toString(Value)) FROM vigil.otel_metrics_sum WHERE MetricName = 'vigil.spool.dropped' AND Attributes['backend'] = 'target' AND Attributes['instance'] = 'backend-check' AND TimeUnix >= toDateTime($t_start) ORDER BY TimeUnix DESC LIMIT 1"
            ;;
        influx)
            csv_cols "$(ifq "from(bucket: \"vigil\") |> range(start: $(date -u -d "@$t_start" +%FT%TZ)) |> filter(fn: (r) => r._measurement == \"vigil.spool.dropped\" and r._field == \"counter\" and r.backend == \"target\" and r.instance == \"backend-check\") |> last()")" reason _value |
                tr ' ' '='
            ;;
        *)
            pq "{__name__=~\"vigil[._]spool[._]dropped(_total)?\",backend=\"target\",instance=\"backend-check\"}" |
                jq -r '.data.result[] | "\(.metric.reason)=\(.value[1])"'
            ;;
    esac
}
# Stored lines for this run, as "<nanoseconds> <line>", at most $1.
lines() {
    case $logs_api in
        loki)
            curl -fsS -m 30 -G "$logs/query_range" --data-urlencode "query={service_name=\"vigil\"} |= \"line $tag \"" \
                --data-urlencode "since=1h" --data-urlencode "limit=${1:-5000}" --data-urlencode 'direction=forward' |
                jq -r '.data.result[].values[] | "\(.[0]) \(.[1])"'
            ;;
        vlogs)
            # One JSON object a line; _time to the second is enough here.
            curl -fsS -m 30 "$logs/query" --data-urlencode "query=_time:1h \"line $tag \"" --data-urlencode "limit=${1:-5000}" |
                jq -r '"\((._time | sub("\\.[0-9]+"; "") | fromdateiso8601) * 1000000000) \(._msg)"'
            ;;
        es)
            # @timestamp in milliseconds.
            es 'logs-*' "{\"size\":${1:-5000},\"query\":{\"match_phrase\":{\"body.text\":\"line $tag \"}},\"sort\":[{\"@timestamp\":\"asc\"}]}" |
                jq -r '.hits.hits[]._source | "\((.["@timestamp"] | tonumber) / 1000 | floor | . * 1000000000) \(.body.text)"'
            ;;
        splunk)
            spl "search index=vigil_logs \"line $tag\" | spath message | eval t=_time | table t message | head ${1:-5000}" |
                jq -r '"\(.t | tonumber | floor | . * 1000000000) \(.message)"'
            ;;
        ch)
            chq "SELECT toUnixTimestamp(Timestamp) * 1000000000, Body FROM vigil.otel_logs WHERE position(Body, 'line $tag ') > 0 ORDER BY Timestamp LIMIT ${1:-5000}" | tr '\t' ' '
            ;;
        os)
            # @timestamp as an ISO time, to the second.
            osq 'ss4o_logs-*' "{\"size\":${1:-5000},\"query\":{\"match_phrase\":{\"body\":\"line $tag \"}},\"sort\":[{\"@timestamp\":\"asc\"}]}" |
                jq -r '.hits.hits[]._source | "\((.["@timestamp"] | sub("\\.[0-9]+"; "") | fromdateiso8601) * 1000000000) \(.body)"'
            ;;
    esac
}
# The labels or fields one stored line came with, as "key=value ...".
line_labels() {
    case $logs_api in
        loki)
            curl -fsS -m 30 -G "$logs/query_range" --data-urlencode "query={service_name=\"vigil\"} |= \"line $tag \"" \
                --data-urlencode "since=1h" --data-urlencode 'limit=1' | jq -r '.data.result[0].stream | to_entries[] | "\(.key)=\(.value)"'
            ;;
        vlogs)
            curl -fsS -m 30 "$logs/query" --data-urlencode "query=_time:1h \"line $tag \"" --data-urlencode 'limit=1' |
                jq -r 'to_entries[] | select(.key | startswith("_") | not) | "\(.key)=\(.value)"'
            ;;
        es)
            es 'logs-*' "{\"size\":1,\"query\":{\"match_phrase\":{\"body.text\":\"line $tag \"}}}" |
                jq -r '.hits.hits[0]._source | (.attributes + .resource.attributes) | to_entries[] | "\(.key)=\(.value)"'
            ;;
        splunk)
            # The event's own fields, and the indexed ones HEC set.
            spl "search index=vigil_logs \"line $tag\" | head 1 | spath | fields - _* index splunk_server linecount punct timestartpos timeendpos date_* eventtype tag* | table *" |
                head -n 1 | jq -r 'to_entries[] | select(.value | type == "string") | "\(.key)=\(.value)"'
            ;;
        ch)
            chq "SELECT concat(k, '=', v) FROM (SELECT mapUpdate(ResourceAttributes, LogAttributes) AS m FROM vigil.otel_logs WHERE position(Body, 'line $tag ') > 0 LIMIT 1) ARRAY JOIN mapKeys(m) AS k, mapValues(m) AS v"
            ;;
        os)
            osq 'ss4o_logs-*' "{\"size\":1,\"query\":{\"match_phrase\":{\"body\":\"line $tag \"}}}" |
                jq -r '.hits.hits[0]._source | (.attributes + .resource) | to_entries[] | select(.value | type == "string") | "\(.key)=\(.value)"'
            ;;
    esac | tr '\n' ' '
}
# The value of the first series in the local file backend whose line starts
# with $1 (its labels are sorted by key), or nothing.
local_value() { awk -v p="$1" 'index($0, p) == 1 { print $NF; exit }' "$root/metrics/local.prom" 2> /dev/null; }
# The ledger's runs from second $1 up to, not including, second $2.
ledger_between() { awk -v a="$1" -v b="$2" '$1 >= a && $1 < b' "$ledger"; }

say "$target, run $tag: services $services"
[ -n "$prom" ] || [ -z "$bk_metrics" ] || say "no query helper for $target's metrics yet: those checks are NOT RUN"
[ -n "$logs_api" ] || [ -z "$bk_logs" ] || say "no query helper for $target's logs yet: those checks are NOT RUN"
vigil precheck > "$work/precheck.out" 2>&1 || { cat "$work/precheck.out"; die 'precheck failed'; }
# Up at the start, whatever state it was left in.
start_target || { cat "$work/start.out"; die "$target did not start"; }

t_start=$(date +%s)
start_sup
say 'baseline: 40 seconds'
sleep 40

# 8, 9, 15: the target stopped.
say "stopping $target"
t_down=$(date +%s)
stop_target
fresh=yes
for _ in $(seq 1 14); do
    sleep 5
    # The file backend's copy keeps up: the job's latest run is there.
    v=$(local_value 'bk_check_seq{')
    [ -n "$v" ] && [ $(($(date +%s) - v)) -le 20 ] || fresh="no (latest $v at $(date +%s))"
done
fwd=$(sed -n 's/^failures = //p' "$root/state/logs/forwarder.state" 2> /dev/null)
queued=$(find "$root/spool/backends/target" -name '*.events' 2> /dev/null | wc -l)
say "starting $target"
t_up=$(date +%s)
start_target || say "$target did not come back: $(tail -1 "$work/start.out")"
say 'recovery: 40 seconds'
sleep 40

# 11: a restart.
say "restarting $target"
t_restart=$(date +%s)
compose --profile "$target" restart $services > /dev/null 2>&1
start_target
sleep 30

# 16: the supervisor stopped and started again.
say 'stopping the supervisor for 10 seconds'
t_sup=$(date +%s)
kill "$sup" 2> /dev/null
wait "$sup" 2> /dev/null
sleep 10
start_sup
sleep 30
t_main=$(date +%s)
say 'letting delivery catch up: 30 seconds'
sleep 30

# What the target holds for the runs before t_main.
want=$(ledger_between 0 "$t_main" | sort -n)
nwant=$(printf '%s\n' "$want" | grep -c .)
if [ -n "$prom" ]; then
    samples > "$work/samples.txt" 2> "$work/samples.err"
    labels > "$work/labels.txt" 2>&1
    got=$(awk '{ print $2 }' "$work/samples.txt" | sort -n | awk -v m="$t_main" '$1 < m')
fi
if [ -n "$logs_api" ]; then
    lines > "$work/lines.txt" 2> "$work/lines.err"
    gotl=$(awk '{ print $4 }' "$work/lines.txt" | sort -n | awk -v m="$t_main" '$1 < m')
fi
# Missing and duplicated seconds, as counts, from a list on stdin.
missing() { comm -23 <(printf '%s\n' "$want" | sort -u) <(sort -u) | grep -c .; }
dups() { sort | uniq -d | grep -c .; }

# 13: a spool too small for an outage. Only metrics go through the spool.
if [ -n "$bk_metrics" ]; then
    # The target first: while it is backing off, the flood only queues. The
    # bash sender encodes a large batch slowly (backlog 29), and a flood sent
    # to a live target would measure that instead.
    say 'the target stopped, the spool cut to 1 MB, and a flood job'
    stop_target
    config small > "$root/config/vigil.config.tmp" && mv -f "$root/config/vigil.config.tmp" "$root/config/vigil.config"
    i=0
    until [ -n "$(local_value 'vigil_spool_dropped_total{backend="target"')" ] || [ "$i" -ge 40 ]; do sleep 3; i=$((i + 1)); done
    dropped_local=$(grep -h '^vigil_spool_dropped_total{' "$root/metrics/local.prom" 2> /dev/null | grep 'backend="target"')
    config > "$root/config/vigil.config.tmp" && mv -f "$root/config/vigil.config.tmp" "$root/config/vigil.config"
    start_target
    say 'recovery: up to 3 minutes, for the count to reach the target'
    i=0
    while [ -n "$prom" ] && [ "$i" -lt 36 ]; do
        drops > "$work/dropped.txt" 2> /dev/null
        [ -s "$work/dropped.txt" ] && break
        sleep 5
        i=$((i + 1))
    done
fi
kill "$sup" 2> /dev/null
wait "$sup" 2> /dev/null
sup=''

printf '\n%s, run %s: %s runs before %s\n' "$target" "$tag" "$nwant" "$(date -u -d "@$t_main" '+%H:%M:%SZ')"
printf '  outage %s to %s, restart %s, supervisor down %s to %s\n' \
    "$(date -u -d "@$t_down" +%T)" "$(date -u -d "@$t_up" +%T)" "$(date -u -d "@$t_restart" +%T)" \
    "$(date -u -d "@$t_sup" +%T)" "$(date -u -d "@$((t_sup + 10))" +%T)"

# 4, 5: what the backend kept of Vigil's tags, against the file backend's.
if [ -n "$prom" ]; then
    printf '  stored labels: %s\n' "$(tr '\n' ' ' < "$work/labels.txt")"
    sent=$(grep -h '^bk_check_seq{' "$root/metrics/local.prom" | head -n 1 | sed 's/^[^{]*{//; s/}.*//' | tr ',' '\n' | tr -d '"')
    printf '  sent labels:   %s\n' "$(printf '%s\n' "$sent" | tr '\n' ' ')"
    job=$(sed -n 's/^job=//p' "$work/labels.txt")
    if [ "$job" = bk_check ]; then
        result PASS '4 job identifiers and labels: job="bk_check" kept'
    elif grep -q '^__name__=bk_check[._]' "$work/labels.txt"; then
        result PASS "4 job identifiers and labels: the job is in the metric name ($(sed -n 's/^__name__=//p' "$work/labels.txt")); its job label became job=\"$job\""
    else
        result FAIL '4 job identifiers and labels: the job is in neither the name nor a label'
    fi
    lost=''
    for kv in $(printf '%s\n' "$sent" | grep -E '^(host|os|instance|run)='); do
        grep -qx "$kv" "$work/labels.txt" || lost="$lost $kv"
    done
    if [ -z "$lost" ]; then result PASS '5 host metadata: host, os and instance kept'; else result FAIL "5 host metadata: lost$lost"; fi
elif [ -n "$bk_metrics" ]; then
    result 'NOT RUN' "4, 5 labels: no query helper for $target"
fi
if [ -n "$logs_api" ]; then
    stream=$(line_labels)
    printf '  stored log labels: %s\n' "$stream"
    case " $stream " in
        *" job=bk_check "*) result PASS '4 logs: job="bk_check" kept as a label' ;;
        *) result FAIL "4 logs: no job=bk_check in $stream" ;;
    esac
    case " $stream " in
        *" host="*" os="* | *" os="*" host="*) result PASS '5 logs: host and os kept as labels' ;;
        *) result FAIL "5 logs: host or os missing from $stream" ;;
    esac
fi

# 6: a delayed sample keeps the time it was made, not the time it arrived.
if [ -n "$prom" ]; then
    off=$(awk '{ d = int($1) - $2; if (d < 0 || d > 10) bad++; if (d > max) max = d } END { printf "%d %d", bad, max }' "$work/samples.txt")
    late=$(awk -v a="$t_down" -v b="$t_up" '$2 >= a && $2 < b' "$work/samples.txt" | grep -c .)
    if [ "${off% *}" -eq 0 ] && [ "$late" -gt 0 ]; then
        result PASS "6 timestamps: every sample within ${off#* }s of its run, the $late delivered late after the outage too"
    else
        result FAIL "6 timestamps: ${off% *} samples more than 10s from their run (largest ${off#* }s); $late from the outage"
    fi
fi
if [ -n "$logs_api" ]; then
    off=$(awk '{ d = int($1 / 1000000000) - $4; if (d < 0 || d > 10) bad++; if (d > max) max = d } END { printf "%d %d", bad, max }' "$work/lines.txt")
    if [ "${off% *}" -eq 0 ] && [ -s "$work/lines.txt" ]; then
        result PASS "6 timestamps (logs): every line within ${off#* }s of its run"
    else
        result FAIL "6 timestamps (logs): ${off% *} lines more than 10s from their run (largest ${off#* }s)"
    fi
fi

# 7: a wrong credential refused. Only Splunk takes one from Vigil here.
if [ "$target" = splunk ]; then
    refused=$(grep -h 'delivery failed: .*badtoken (permission denied (HTTP 40[13]' "$root"/logs/jobs/vigil_sender/*.log 2> /dev/null | head -n 1)
    badn=$(local_value 'vigil_backend_failures_total{backend="badtoken"')
    if [ -n "$refused" ] && [ "${badn:-0}" -gt 0 ]; then
        result PASS "7 authentication rejected: a wrong HEC token refused ($(printf '%s' "$refused" | grep -o 'HTTP 40[13][^)]*' | head -n 1)), $badn failures counted, the right token delivering all along"
    else
        result FAIL "7 authentication rejected: refused [${refused:-nothing}], failures counted [${badn:-none}]"
    fi
else
    result 'NOT APPLICABLE' "7 authentication rejected: $target takes OTLP without authentication in this environment, so there is nothing to refuse"
fi

# 8, 9: the outage, as Vigil recorded it.
if [ -n "$bk_metrics" ]; then
    failures=$(local_value 'vigil_backend_failures_total{backend="target"')
    if [ "${failures:-0}" -gt 0 ] && [ "$queued" -gt 0 ]; then
        result PASS "8 the backend unavailable: $failures failures counted, $queued event files held in its queue, jobs ran on"
    else
        result FAIL "8 the backend unavailable: failures ${failures:-none}, queued $queued"
    fi
    # The sender's failed runs in the outage, from its own log: each began
    # 5, 10, 20, 40... seconds after the one before. A run id has the
    # second the worker started, and the backoff counts from when the
    # sender read the clock, a second or two in: 2 seconds of slack below,
    # and a tick and a sender run above.
    starts=$(grep -h 'run end failed (delivery failed: target' "$root"/logs/jobs/vigil_sender/*.log |
        awk '{ print $2 }' | sed 's/^\([0-9]\{8\}\)T\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)Z.*/\1 \2:\3:\4/' |
        while read -r d t; do date -u -d "$d $t" +%s; done | awk -v a="$t_down" -v b="$t_up" '$1 >= a && $1 < b')
    gaps=$(printf '%s\n' "$starts" | awk 'NR > 1 { printf "%s ", $1 - p } { p = $1 }')
    ok=$(printf '%s\n' "$gaps" | awk '{ e = 5; for (i = 1; i <= NF; i++) { if ($i < e - 2 || $i > e + 15) { print "no"; exit } e = (e * 2 > 300) ? 300 : e * 2 } print "yes" }')
    if [ "$ok" = yes ] && [ "$(printf '%s\n' $gaps | grep -c .)" -ge 2 ]; then
        result PASS "9 retry and backoff: the sender's failed runs ${gaps}seconds apart"
    else
        result FAIL "9 retry and backoff: failed runs ${gaps:-none }seconds apart, not 5, 10, 20... (plus slack)"
    fi
fi
if [ -n "$bk_logs" ]; then
    if [ "${fwd:-0}" -gt 0 ]; then result PASS "8, 9 logs: the forwarder failed $fwd times and backed off"; else result FAIL "8, 9 logs: no forwarder failure recorded"; fi
fi

# 10, 11, 12, 16: every run before t_main, once.
if [ -n "$prom" ]; then
    m=$(printf '%s\n' "$got" | missing) d=$(printf '%s\n' "$got" | dups)
    out=$(ledger_between "$t_down" "$t_up" | grep -c .)
    if [ "$m" -eq 0 ]; then
        result PASS "10 recovery from the spool: all $out runs of the outage arrived afterwards"
        result PASS "11 a backend restart: nothing lost across it"
        result PASS "16 a supervisor restart: nothing lost across it, the same spool carried on"
    else
        result FAIL "10, 11, 16: $m of $nwant runs never arrived: $(comm -23 <(printf '%s\n' "$want" | sort -u) <(printf '%s\n' "$got" | sort -u) | tr '\n' ' ')"
    fi
    if [ "$d" -eq 0 ]; then result PASS "12 duplicate delivery: none, $nwant runs, $nwant samples"; else result FAIL "12 duplicate delivery: $d runs stored twice"; fi
fi
if [ -n "$logs_api" ]; then
    m=$(printf '%s\n' "$gotl" | missing) d=$(printf '%s\n' "$gotl" | dups)
    if [ "$m" -eq 0 ]; then
        result PASS "10, 11, 16 logs: every run's line arrived, through the outage, the restart and the supervisor restart"
    else
        result FAIL "10, 11, 16 logs: $m of $nwant lines never arrived"
    fi
    if [ "$d" -eq 0 ]; then result PASS "12 duplicate delivery (logs): none"; else result FAIL "12 duplicate delivery (logs): $d lines stored twice"; fi
fi

# 13: drops counted, and reported to the backend itself once it is back.
if [ -n "$bk_metrics" ]; then
    printf '  dropped, in the file backend: %s\n' "${dropped_local:-none}"
    if [ -z "$dropped_local" ]; then
        result FAIL '13 dropped telemetry: nothing counted'
    elif [ -n "$prom" ] && [ -s "$work/dropped.txt" ]; then
        result PASS "13 dropped telemetry: counted, and reported to $target once it was back ($(tr '\n' ' ' < "$work/dropped.txt"))"
    else
        result FAIL "13 dropped telemetry: counted in the file backend, but $target never got the count"
    fi
else
    result 'NOT APPLICABLE' "13 dropped telemetry: $target takes logs, and the forwarder reads Vigil's own files, which are never dropped for an outage"
fi

# 14, 15: the file backend alongside.
if [ -n "$bk_metrics" ] && [ -n "$(local_value "bk_check_seq{")" ]; then
    result PASS '14 several destinations: the same runs in the file backend and the target'
elif [ -n "$bk_metrics" ]; then
    result FAIL '14 several destinations: nothing in the file backend'
fi
if [ -n "$bk_metrics" ]; then
    if [ "$fresh" = yes ]; then result PASS '15 a healthy destination unaffected: the file backend stayed current all through the outage'; else result FAIL "15 a healthy destination unaffected: $fresh"; fi
fi

printf '%d passed, %d failed, %d not run or not applicable\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
