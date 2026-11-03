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

# Evidence: what a run printed, and Vigil's own record of it, kept in
# reports/runs/<date>/<host>/<name>/ for the compatibility reports:
#   console.txt  a header (when, where, which Vigil, which tools and
#                images), then everything the run printed
#   *.out        what Vigil printed
#   root/        Vigil's config, logs, state and metrics, as the run left them
# VIGIL_EVIDENCE_HOST names the host (default: its hostname).
# evidence_start <name> <compose files (a pattern)> <command>: once $work
# and $root are set.
evidence_start() {
    local host
    host=${VIGIL_EVIDENCE_HOST:-$(hostname -s 2> /dev/null || hostname)}
    ev_dir=$bk_dir/reports/runs/$(date -u '+%Y-%m-%d')/$host/$1
    rm -rf "$ev_dir" && mkdir -p "$ev_dir" || die "cannot make $ev_dir"
    exec > >(tee "$ev_dir/console.txt") 2>&1
    evidence_header "$@"
}
evidence_header() {
    local name=$1 file=$2 os rev
    shift 2
    if command -v sw_vers > /dev/null 2>&1; then
        os="macOS $(sw_vers -productVersion)"
    else
        os=$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release 2> /dev/null)
    fi
    # VIGIL_EVIDENCE_COMMIT, when a copy of a commit was put here.
    if [ -n "${VIGIL_EVIDENCE_COMMIT-}" ]; then
        rev="$VIGIL_EVIDENCE_COMMIT (deployed copy)"
    else
        rev=$(git -C "$bk_repo" rev-parse HEAD 2> /dev/null) || rev='unknown: not a Git checkout'
        [ -n "$(git -C "$bk_repo" status --porcelain -- app tests 2> /dev/null)" ] && rev="$rev, with local changes"
    fi
    printf '== %s\n' "$name"
    printf 'date     %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'host     %s\n' "$(hostname)"
    printf 'os       %s (%s)\n' "${os:-unknown}" "$(uname -srm)"
    printf 'vigil    %s\n' "$rev"
    printf 'command  %s\n' "$*"
    printf 'bash     %s\n' "$BASH_VERSION"
    printf 'git      %s\n' "$(git --version 2> /dev/null || echo none)"
    printf 'curl     %s\n' "$(curl --version 2> /dev/null | head -1 || echo none)"
    printf 'openssl  %s\n' "$(openssl version 2> /dev/null || echo none)"
    printf 'ssh      %s\n' "$(ssh -V 2>&1 | head -1)"
    printf 'images   (as %s pins them)\n' "${file##*/}"
    sed -n 's/^ *image: *//p' $file | sort -u | sed 's/^/         /'
    printf '\n'
}
# evidence_save <value>...: from the EXIT trap, before $work goes. A file
# holding any of the values (the run's secrets and credentials) is left
# out, and said so: the run has failed its leak check already.
evidence_save() {
    local d f v
    [ -n "${ev_dir-}" ] && [ -d "$ev_dir" ] || return 0
    mkdir -p "$ev_dir/root"
    for d in config logs state metrics; do [ -d "$root/$d" ] && cp -R "$root/$d" "$ev_dir/root/"; done
    rm -rf "$ev_dir/root/state/locks"
    for f in "$work"/*.out; do [ -f "$f" ] && cp "$f" "$ev_dir/"; done
    for v in "$@"; do
        [ -n "$v" ] || continue
        for f in $(grep -rlF -- "$v" "$ev_dir" 2> /dev/null); do
            case $f in
                */console.txt) printf 'evidence: console.txt holds a credential: do not publish it\n' ;;
                *) rm -f "$f" && printf 'evidence: %s held a credential and was left out\n' "${f#"$ev_dir"/}" ;;
            esac
        done
    done
    printf 'evidence: %s\n' "${ev_dir#"$bk_dir"/}"
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
jaeger zipkin tracing clickhouse signoz uptrace graylog openbao vault aws azure gcp azure-alt gcp-alt
git-gitea https-nginx sftp-openssh'

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
        openbao | vault | aws | azure | gcp | azure-alt | gcp-alt) bk_why="$1 is a secret store, not somewhere Vigil sends: test it with scripts/run-store.sh $1" ;;
        git-* | https-* | sftp-*) bk_why="$1 is a source Vigil fetches from, not somewhere it sends: test it with scripts/run-source.sh $1" ;;
        *) die "unknown target: $1 (one of: $(echo $bk_targets))" ;;
    esac
}
