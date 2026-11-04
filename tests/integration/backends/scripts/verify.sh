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
# verify.sh - asks a backend, through its own query interface, whether one
# run's telemetry was stored. An HTTP 2xx from the backend when Vigil sent
# is not proof; finding the data is.
#
#   scripts/verify.sh <target> <run tag>      run-vigil.sh calls it
#
# Checks, for each signal the target takes:
#   metrics  the probe metric (42) with this run's tag. Which job label it
#            kept goes in the evidence: Prometheus, for one, replaces the
#            job Vigil sends with job="vigil", from the service name.
#   logs     a line carrying this run's tag
# Prints PASS, FAIL or NOT APPLICABLE for each, and saves the answers as
# evidence in reports/evidence/<target>-<tag>.txt for the compatibility
# report. Retries for up to two minutes, since backends index in the
# background. Exit code: 0 when every applicable check passed.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

[ "$#" -eq 2 ] || die 'usage: verify.sh <target> <run tag>'
target=$1 tag=$2
endpoints "$target"
mkdir -p "$bk_dir/reports/evidence"
evidence=$bk_dir/reports/evidence/$target-$tag.txt
fail=0

# PromQL for the probe: Prometheus-style names turn dots into underscores,
# others keep them, so both are accepted.
probe="{__name__=~\"bk_metrics[._]vigil_backend_probe\",run=\"$tag\"}"

# URL-encodes $1.
enc() {
    local s=$1 out='' c i
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case $c in [A-Za-z0-9._~-]) out+=$c ;; *) out+=$(printf '%%%02X' "'$c") ;; esac
    done
    printf '%s' "$out"
}

# Runs check function $2 for signal $1 until it passes or two minutes go by.
check() {
    local signal=$1 fn=$2 i=0 answer
    while :; do
        answer=$("$fn" 2>&1)
        if [ $? -eq 0 ]; then
            printf '  PASS  %s\n' "$signal"
            printf '== %s: PASS\n%s\n\n' "$signal" "$answer" >> "$evidence"
            return
        fi
        i=$((i + 1))
        [ "$i" -ge 24 ] && break
        sleep 5
    done
    printf '  FAIL  %s\n' "$signal"
    printf '== %s: FAIL\n%s\n\n' "$signal" "$answer" >> "$evidence"
    fail=1
}

# A PromQL answer holding the value 42.
promql() {
    local out
    out=$(curl -fsS "$@") || return 1
    printf '%s\n' "$out"
    case $out in *'"42"'*) return 0 ;; esac
    return 1
}

# Grafana's data source proxy, for lgtm's Prometheus and Loki.
grafana_ds() {
    curl -fsS -u admin:admin http://127.0.0.1:3000/api/datasources |
        tr '{' '\n' | grep "\"type\":\"$1\"" | sed -n 's/.*"uid":"\([^"]*\)".*/\1/p' | head -n 1
}

# A Loki answer with at least one line.
loki() {
    local out
    out=$(curl -fsS -G "$1" --data-urlencode "query={service_name=\"vigil\"} |= \"$tag\"" --data-urlencode "since=1h") || return 1
    printf '%s\n' "$out"
    case $out in *'"values":[['*) return 0 ;; esac
    return 1
}

# Splunk search, through the management API (the container's own
# certificate: -k, for this local test container only).
splunk_search() {
    local out
    out=$(printf 'user = "admin:%s"\n' "$SPLUNK_PASSWORD" |
        curl -sk -K - https://127.0.0.1:8089/services/search/jobs/export \
            --data-urlencode "search=$1" -d output_mode=csv -d earliest_time=-1h) || return 1
    printf '%s\n' "$out"
    [ "$(printf '%s\n' "$out" | sed 1d | grep -c .)" -gt 0 ]
}

metrics_lgtm() { promql -G "http://127.0.0.1:3000/api/datasources/proxy/uid/$(grafana_ds prometheus)/api/v1/query" -u admin:admin --data-urlencode "query=$probe"; }
logs_lgtm() { loki "http://127.0.0.1:3000/api/datasources/proxy/uid/$(grafana_ds loki)/loki/api/v1/query_range" -u admin:admin; }
metrics_prometheus() { promql -G http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$probe"; }
metrics_mimir() { promql -G http://127.0.0.1:9009/prometheus/api/v1/query --data-urlencode "query=$probe"; }
logs_loki() { loki http://127.0.0.1:3100/loki/api/v1/query_range; }
metrics_otel_collector() { metrics_mimir; }
logs_otel_collector() { logs_loki; }
metrics_alloy() { metrics_prometheus; }
logs_alloy() { logs_loki; }
metrics_splunk() { splunk_search "| mstats latest(_value) AS v WHERE index=vigil_metrics AND metric_name=\"bk_metrics.vigil_backend_probe\" AND run=\"$tag\" BY job | where v=42"; }
logs_splunk() { splunk_search "search index=vigil_logs \"$tag\" | head 5"; }
metrics_victoriametrics() { promql -G http://127.0.0.1:8428/api/v1/query --data-urlencode "query=$probe"; }
logs_victorialogs() {
    local out
    out=$(curl -fsS http://127.0.0.1:9428/select/logsql/query --data-urlencode "query=\"$tag\"") || return 1
    printf '%s\n' "$out"
    [ -n "$out" ]
}
# Elasticsearch and OpenSearch: any document carrying the tag. User and
# password $1 go to curl on its standard input, never its command line.
es_hits() {
    local out user=$1
    shift
    out=$(printf 'user = "%s"\n' "$user" | curl -fsS -K - "$@") || return 1
    printf '%s\n' "$out"
    case $out in *'"hits":{"total":{"value":0'*) return 1 ;; *'"hits":{"total":{"value":'*) return 0 ;; esac
    return 1
}
metrics_elastic() { es_hits "elastic:$ELASTIC_PASSWORD" "http://127.0.0.1:9200/metrics-*/_search?q=$(enc "\"$tag\"")"; }
logs_elastic() { es_hits "elastic:$ELASTIC_PASSWORD" "http://127.0.0.1:9200/logs-*/_search?q=$(enc "\"$tag\"")"; }
# OpenSearch's demo certificate, verified against its root CA (ca.sh).
logs_opensearch() { es_hits "admin:$OPENSEARCH_ADMIN_PASSWORD" --cacert "$bk_dir/.secrets/opensearch/root-ca.pem" "https://127.0.0.1:9201/*/_search?q=$(enc "\"$tag\"")"; }
metrics_influxdb() {
    local out
    # The token on curl's standard input, never its command line.
    out=$(printf 'header = "Authorization: Token %s"\n' "$INFLUXDB_TOKEN" |
        curl -fsS -K - http://127.0.0.1:8086/api/v2/query?org=vigil \
        -H 'Content-Type: application/vnd.flux' -H 'Accept: application/csv' \
        --data "from(bucket: \"vigil\") |> range(start: -1h) |> filter(fn: (r) => r.run == \"$tag\")") || return 1
    printf '%s\n' "$out"
    printf '%s\n' "$out" | grep -q ',42'
}
clickhouse_count() {
    local out
    out=$(printf 'user = "vigil:%s"\n' "$CLICKHOUSE_PASSWORD" |
        curl -fsS -K - http://127.0.0.1:18123/ --data-binary "$1") || return 1
    printf '%s\n' "$out"
    [ "${out:-0}" -gt 0 ]
}
metrics_clickhouse() { clickhouse_count "SELECT count() FROM vigil.otel_metrics_gauge WHERE Attributes['run'] = '$tag' AND Value = 42"; }
logs_clickhouse() { clickhouse_count "SELECT count() FROM vigil.otel_logs WHERE position(Body, '$tag') > 0"; }
# SigNoz's query API needs a signed-in session: checked in its UI for now.
metrics_signoz() { printf 'SigNoz: open http://127.0.0.1:8080 and look for bk_metrics.vigil_backend_probe with run=%s\n' "$tag"; return 1; }
logs_signoz() { printf 'SigNoz: open http://127.0.0.1:8080 and search the logs for %s\n' "$tag"; return 1; }

{
    printf 'target   %s\nrun tag  %s\ndate     %s\n' "$target" "$tag" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'images\n'
    compose ps --format '  {{.Service}} {{.Image}}' 2> /dev/null
    printf '\n'
} > "$evidence"

printf '\n%s, run %s\n' "$target" "$tag"
fn=${target//-/_}
if [ -n "$bk_metrics" ]; then check metrics "metrics_$fn"; else printf '  NOT APPLICABLE  metrics\n'; fi
if [ -n "$bk_logs" ]; then check logs "logs_$fn"; else printf '  NOT APPLICABLE  logs\n'; fi
printf '  NOT APPLICABLE  traces (Vigil sends none)\n'
printf 'evidence: %s\n' "$evidence"
exit "$fail"
