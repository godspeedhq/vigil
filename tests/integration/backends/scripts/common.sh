# shellcheck shell=bash
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
# common.sh - what start.sh, stop.sh, reset.sh, verify.sh and run-vigil.sh
# share: where things are, and what each target is.
#
# A target is a Compose profile (lgtm, prometheus, splunk, victoria, ...)
# or one of the official deployments start.sh fetches (signoz, uptrace,
# graylog). README.md lists them all.

set -u

bk_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bk_repo=$(cd "$bk_dir/../../.." && pwd)

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

# Credentials from .env, when there is one: never from anywhere committed.
if [ -f "$bk_dir/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$bk_dir/.env"
    set +a
fi

# The Compose command for this environment.
compose() {
    local env=()
    [ -f "$bk_dir/.env" ] && env=(--env-file "$bk_dir/.env")
    docker compose --project-directory "$bk_dir" -f "$bk_dir/compose.yaml" ${env[@]+"${env[@]}"} "$@"
}

# The services of profile $1, one per line. lgtm has no profile, so it is
# what runs with none; every other profile is started by naming its
# services, which keeps lgtm out unless it was asked for.
services_of() {
    case $1 in
        lgtm) echo lgtm ;;
        *) compose --profile "$1" config --services 2> /dev/null | grep -vx lgtm ;;
    esac
}

is_upstream() {
    case $1 in signoz | uptrace | graylog) return 0 ;; esac
    return 1
}

# Every target, for usage messages.
bk_targets='lgtm prometheus grafana loki tempo mimir pyroscope otel-collector alloy grafana-stack
splunk victoriametrics victorialogs victoriatraces victoria elastic opensearch influxdb
jaeger zipkin tracing clickhouse signoz uptrace graylog openbao vault aws azure'

# How Vigil reaches target $1. Sets bk_metrics and bk_logs to "<type>
# <endpoint>" (type otel or splunk), each empty when Vigil cannot send that
# signal there, and bk_why to the reason for a target Vigil cannot reach.
endpoints() {
    bk_metrics='' bk_logs='' bk_why=''
    case $1 in
        lgtm)
            bk_metrics='otel http://127.0.0.1:4318/v1/metrics'
            bk_logs='otel http://127.0.0.1:4318/v1/logs' ;;
        prometheus) bk_metrics='otel http://127.0.0.1:9090/api/v1/otlp/v1/metrics' ;;
        mimir) bk_metrics='otel http://127.0.0.1:9009/otlp/v1/metrics' ;;
        loki) bk_logs='otel http://127.0.0.1:3100/otlp/v1/logs' ;;
        otel-collector)
            bk_metrics='otel http://127.0.0.1:24318/v1/metrics'
            bk_logs='otel http://127.0.0.1:24318/v1/logs' ;;
        alloy)
            bk_metrics='otel http://127.0.0.1:34318/v1/metrics'
            bk_logs='otel http://127.0.0.1:34318/v1/logs' ;;
        splunk)
            bk_metrics='splunk http://127.0.0.1:8088'
            bk_logs='splunk http://127.0.0.1:8088' ;;
        victoriametrics) bk_metrics='otel http://127.0.0.1:8428/opentelemetry/v1/metrics' ;;
        victorialogs) bk_logs='otel http://127.0.0.1:9428/insert/opentelemetry/v1/logs' ;;
        elastic)
            bk_metrics='otel http://127.0.0.1:4418/v1/metrics'
            bk_logs='otel http://127.0.0.1:4418/v1/logs' ;;
        opensearch) bk_logs='otel http://127.0.0.1:4428/v1/logs' ;;
        influxdb) bk_metrics='otel http://127.0.0.1:4438/v1/metrics' ;;
        clickhouse)
            bk_metrics='otel http://127.0.0.1:4448/v1/metrics'
            bk_logs='otel http://127.0.0.1:4448/v1/logs' ;;
        signoz)
            bk_metrics='otel http://127.0.0.1:4318/v1/metrics'
            bk_logs='otel http://127.0.0.1:4318/v1/logs' ;;
        grafana) bk_why='Grafana stores nothing: it is the interface to the others' ;;
        tempo | jaeger | zipkin | victoriatraces | tracing) bk_why='Vigil sends no traces' ;;
        pyroscope) bk_why='Vigil sends no profiles' ;;
        uptrace) bk_why='Uptrace wants its DSN in an uptrace-dsn header, which Vigil can send for logs but not metrics: to be worked out at first run' ;;
        graylog) bk_why='Graylog takes OTLP over gRPC, and Vigil sends OTLP over HTTP: needs a collector in between, to be worked out at first run' ;;
        openbao | vault | aws | azure) bk_why="$1 is a secret store, not somewhere Vigil sends: test it with scripts/run-store.sh $1" ;;
        *) die "unknown target: $1 (one of: $(echo $bk_targets))" ;;
    esac
}
