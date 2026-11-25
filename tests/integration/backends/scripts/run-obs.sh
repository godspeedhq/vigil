#!/usr/bin/env bash
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# run-obs.sh - the nine packs that watch a monitoring stack (prometheus,
# alertmanager, grafana, loki, mimir, tempo, otelcol, victoriametrics,
# victorialogs) against a real one in trouble on purpose, with its evidence
# kept like the other runs'.
#
#   scripts/run-obs.sh
#
# It starts compose.obs.yaml, whose header says what is wrong with each
# service, from a copy of configs/services/obs of its own (OBS_DIR). Once
# everything is ready and the faults have had time to show, every job of
# every pack is run and what it reads is checked. Then: a login that is
# refused, a page that is not there, and nothing answering at all. Then
# tests/integration/service-packs.sh runs the packs through Vigil. At the
# end the stack is broken further, live: Tempo stops (its own pack, and
# Prometheus', the Collector's and Grafana's, each see it from their side),
# an Alertmanager leaves its cluster, and Prometheus and Alertmanager are
# each given a configuration they refuse. Grafana's admin password and the
# read-only token are made here, into this run's own folder, and kept out
# of the evidence. VIGIL_IT_OBS_HOLD (below) keeps the stack up for other
# machines' tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: the stack runs in containers'
for p in curl jq openssl awk; do command -v "$p" > /dev/null 2>&1 || die "$p not found"; done
file=compose.obs.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-obs-it.XXXXXX") || exit 1
root=$work/none
dc() { docker compose -p vigil-obs --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }

export OBS_DIR=$work/obs
cp -R "$bk_dir/configs/services/obs" "$OBS_DIR" && chmod -R a+rX "$work" || die "cannot copy the stack's configuration"
(umask 077 && openssl rand -hex 12 > "$work/grafana.pw" && : > "$work/grafana.token")
export OBS_GRAFANA_PASSWORD
OBS_GRAFANA_PASSWORD=$(cat "$work/grafana.pw")
trap 'dc down -v > /dev/null 2>&1; evidence_save "$(cat "$work/grafana.pw")" "$(cat "$work/grafana.token")"; rm -rf "$work"' EXIT
evidence_start pack-obs "$bk_dir/$file" "$0" "$@"

packs='prometheus alertmanager grafana loki mimir tempo otelcol victoriametrics victorialogs'
port_of() {
    case $1 in
        prometheus) echo 19090 ;; alertmanager) echo 19093 ;; grafana) echo 19300 ;; loki) echo 19310 ;; mimir) echo 19009 ;;
        tempo) echo 19320 ;; otelcol) echo 18888 ;; victoriametrics) echo 18428 ;; victorialogs) echo 19428 ;;
    esac
}
var_of() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
ready_of() {
    case $1 in
        prometheus | alertmanager) echo /-/ready ;; grafana) echo /api/health ;; loki | mimir | tempo) echo /ready ;;
        otelcol) echo /metrics ;; *) echo /health ;;
    esac
}
for p in $packs; do export "$(var_of "$p")_URL=http://127.0.0.1:$(port_of "$p")"; done

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'the stack would not start'; }
for p in $packs; do
    for _ in $(seq 1 90); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$(port_of "$p")$(ready_of "$p")")" = 200 ] && break; sleep 2; done
    [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$(port_of "$p")$(ready_of "$p")")" = 200 ] || { dc logs --tail 15 "$p"; die "$p did not become ready"; }
done
printf 'stack    %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | grep -v '^gen-\|^load ' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

# Grafana: a service account that may only view, and a token for it. The
# admin password and the token go to curl on its standard input.
adm() { printf 'user = "admin:%s"\n' "$OBS_GRAFANA_PASSWORD" | curl -s -K - -H 'Content-Type: application/json' "$@"; }
sa=$(adm -X POST http://127.0.0.1:19300/api/serviceaccounts -d '{"name":"vigil","role":"Viewer"}' | jq -r '.id // empty')
[ -n "$sa" ] || die 'cannot make the Grafana service account'
(umask 077 && adm -X POST "http://127.0.0.1:19300/api/serviceaccounts/$sa/tokens" -d '{"name":"vigil"}' | jq -r '.key // empty' > "$work/grafana.token")
[ -s "$work/grafana.token" ] || die 'cannot make the Grafana token'
echo 'grafana  a service account with the Viewer role, and a token for it'
export GRAFANA_TOKEN
GRAFANA_TOKEN=$(cat "$work/grafana.token")

say() { printf '\n# %s\n' "$*"; }
os=linux
pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
# val <pack.job> <reading> [<tags>]: its value; least and most compare it;
# has says whether such a line was printed.
val() { grep -E "^metric $2 [^ ]+( .*)?${3-}" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "${3-}")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2( |$).*${3-}" "$work/$1.out" && echo yes || echo no; }
# run <pack> <job> [<label>]: the job's script, its output shown and kept;
# quiet does the same without showing it.
quiet() {
    bash "$bk_repo/packs/$1/$os/$2.sh" > "$work/$1.$2.out" 2> "$work/$1.$2.err"
    printf 'exit %s\n' "$?" >> "$work/$1.$2.err"
}
run() {
    printf '\n$ bash packs/%s/%s/%s.sh%s\n' "$1" "$os" "$2" "${3:+   ($3)}"
    quiet "$1" "$2"
    cat "$work/$1.$2.out"
    grep -v '^exit 0$' "$work/$1.$2.err"
}
# until_least <pack> <job> <reading> <tags> <n> [<tries>]: runs the job until
# the reading is at least n (a fault taking its time to show).
until_least() {
    local i=0
    while [ "$i" -lt "${6:-60}" ]; do
        quiet "$1" "$2"
        [ "$(least "$1.$2" "$3" "$4" "$5")" = yes ] && return 0
        sleep 3
        i=$((i + 1))
    done
    return 1
}
jobs_of() { sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/$1/pack.config"; }

say "The stack, in trouble on purpose: waiting for each fault to show."
until_least prometheus rules evaluation_failures_count '' 1
until_least prometheus targets targets_down '' 3
until_least prometheus remote_write samples_failed 'remote=mimir' 1
until_least alertmanager notifications notifications_failed_count '' 1
until_least grafana alerting notifications_failed_count '' 1
# Grafana counts what it holds a little after it starts.
until_least grafana status datasources '' 4 80
until_least loki ingestion discarded 'reason=line_too_long' 1
until_least loki compaction compactions_count '' 1 80
until_least mimir ingestion discarded 'reason=per_user_series_limit' 1
until_least mimir storage compactor_runs_count '' 1 80
until_least tempo ingestion discarded 'reason=trace_too_large' 1
until_least tempo storage blocks '' 1 80
until_least otelcol exporters enqueue_failed_spans_count '' 1 80
until_least victoriametrics targets targets_down '' 1
until_least victorialogs ingestion rows_dropped 'reason=too_small_timestamp' 1
echo 'every fault planted in the stack is showing'

for p in $packs; do
    say "$p: every job."
    for j in $(jobs_of "$p"); do
        run "$p" "$j"
        check "$p $j: runs, and the service answers" 'exit 0 1' "$(tail -n 1 "$work/$p.$j.err") $(val "$p.$j" up)"
    done
done

say "What each pack must have read."
check 'prometheus: ready, its configuration loaded' '1 1' "$(val prometheus.status ready) $(val prometheus.status config_reload_ok)"
check 'prometheus: three Alertmanagers found, alerts to one of them failing' '3 yes' "$(val prometheus.status alertmanagers) $(least prometheus.status notifications_errors 'alertmanager=http://alertmanager:9/' 1)"
check 'prometheus: three targets down, two in one job and one in another' '3 2 1' "$(val prometheus.targets targets_down) $(val prometheus.targets down 'job=dead') $(val prometheus.targets down 'job=notmetrics')"
check 'prometheus: the rule group that cannot be evaluated is named' yes "$(least prometheus.rules evaluation_failures 'group=.*broken' 1)"
check 'prometheus: one alert firing, three pending' '1 3 1' "$(val prometheus.rules alerts_firing) $(val prometheus.rules alerts_pending) $(val prometheus.rules firing 'alert=AlwaysFiring')"
check 'prometheus: three remotes; Mimir refuses samples; one remote never took any, and holds some' '3 yes 1 yes' "$(val prometheus.remote_write remotes) $(least prometheus.remote_write samples_failed 'remote=mimir' 1) $(val prometheus.remote_write remotes_never_sent) $(least prometheus.remote_write pending 'remote=dead' 1)"
check 'prometheus: the TSDB is ingesting, with nothing failed' 'yes 0 0' "$(least prometheus.tsdb head_series '' 100) $(val prometheus.tsdb compactions_failed_count) $(val prometheus.tsdb wal_corruptions_count)"
check 'alertmanager: ready, an alert active, two receivers' '1 yes 2' "$(val alertmanager.status ready) $(least alertmanager.status alerts_active '' 1) $(val alertmanager.status receivers)"
check 'alertmanager: notifications fail, through the webhook' 'yes yes' "$(least alertmanager.notifications failed 'integration=webhook' 1) $(least alertmanager.notifications notifications_failed_count '' 1)"
# In a cluster one member sends each notification and tells the others: the
# ones that get through are on one member or the other, not on both.
ALERTMANAGER_URL=http://127.0.0.1:19094 bash "$bk_repo/packs/alertmanager/$os/notifications.sh" > "$work/alertmanager2.notifications.out" 2> /dev/null
check 'alertmanager: and some get through, counted over both members of the cluster' yes "$(awk -v a="$(val alertmanager.notifications notifications_count)" -v b="$(val alertmanager.notifications notifications_failed_count)" -v c="$(val alertmanager2.notifications notifications_count)" -v d="$(val alertmanager2.notifications notifications_failed_count)" 'BEGIN { print (a + c > b + d) ? "yes" : "no [" a " " b " " c " " d "]" }')"
check 'alertmanager: a cluster of two, whole' '1 2 0' "$(val alertmanager.cluster cluster_enabled) $(val alertmanager.cluster members) $(val alertmanager.cluster failed_peers)"
check 'grafana: healthy; four data sources, two of one kind' '1 4 2' "$(val grafana.status healthy) $(val grafana.status datasources) $(val grafana.status datasources_by_type 'type=prometheus')"
check 'grafana: the data source that does not answer is named, the others answer' '1 4 1 0 1' "$(val grafana.datasources login_ok) $(val grafana.datasources datasources) $(val grafana.datasources datasources_failing) $(val grafana.datasources datasource_ok 'name=Dead') $(val grafana.datasources datasource_ok 'name=Prometheus')"
check 'grafana: one alert firing, one whose rule cannot be evaluated; notifications fail' '1 1 yes yes' "$(val grafana.alerting alerts_alerting) $(val grafana.alerting alerts_error) $(least grafana.alerting evaluation_failures_count '' 1) $(least grafana.alerting notifications_failed 'integration=webhook' 1)"
check 'loki: ready, one ingester; lines received' '1 1 yes' "$(val loki.status ready) $(val loki.status ingesters_active) $(least loki.ingestion lines_received_count '' 1)"
check 'loki: entries discarded, too old and too long' 'yes yes' "$(least loki.ingestion discarded 'reason=greater_than_max_sample_age' 1) $(least loki.ingestion discarded 'reason=line_too_long' 1)"
check 'loki: its compactor ran, and nothing failed' 'yes 0' "$(least loki.compaction compactions_count '' 1) $(val loki.compaction compactions_failed_count)"
check 'mimir: ready, its rings whole' '1 1 0' "$(val mimir.status ready) $(val mimir.status ingesters_active) $(val mimir.status ring_unhealthy)"
check 'mimir: at its limit of 200 series, and discarding for it' '200 yes' "$(val mimir.ingestion series) $(least mimir.ingestion discarded 'reason=per_user_series_limit' 1)"
check 'mimir: its compactor ran; the bucket answers' 'yes 0' "$(least mimir.storage compactor_runs_count '' 1) $(val mimir.storage bucket_failures_count)"
check 'tempo: ready, one ingester; spans received' '1 1 yes' "$(val tempo.status ready) $(val tempo.status ingesters_active) $(least tempo.ingestion spans_received_count '' 1)"
check 'tempo: traces too large discarded' yes "$(least tempo.ingestion discarded 'reason=trace_too_large' 1)"
check 'tempo: blocks on disk, nothing failed' 'yes 0' "$(least tempo.storage blocks '' 1) $(val tempo.storage compaction_errors_count)"
check 'otelcol: its version; spans, metric points and log records accepted' 'yes yes yes yes' "$(has otelcol.status version 'version=0\.') $(least otelcol.receivers accepted_spans_count '' 1) $(least otelcol.receivers accepted_metric_points_count '' 1) $(least otelcol.receivers accepted_log_records_count '' 1)"
check 'otelcol: the receiver that must refuse is named' yes "$(least otelcol.receivers refused_spans 'receiver=otlp/refused' 1)"
check 'otelcol: the exporter nothing answers: its queue full, spans dropped at the door, sends failed' '100 yes yes' "$(val otelcol.exporters queue_fullest_pct) $(least otelcol.exporters enqueue_failed_spans_count '' 1) $(least otelcol.exporters queue 'exporter=otlphttp/dead' 1)"
check 'otelcol: metric points sent to one place and refused by another, which is named' 'yes yes' "$(least otelcol.exporters sent_metric_points_count '' 1) $(least otelcol.exporters send_failed_metric_points 'exporter=prometheusremotewrite/mimir' 1)"
check 'victoriametrics: healthy, writable; queries that failed, by path' '1 0 yes' "$(val victoriametrics.status healthy) $(val victoriametrics.status read_only) $(least victoriametrics.status http_errors 'path=/api/v1/query' 1)"
check 'victoriametrics: rows by remote write and by scraping' 'yes yes' "$(least victoriametrics.ingestion rows_inserted 'type=promremotewrite' 1) $(least victoriametrics.ingestion rows_inserted 'type=promscrape' 1)"
check 'victoriametrics: one target up, one down, and its job named' '1 1 1' "$(val victoriametrics.targets targets_up) $(val victoriametrics.targets targets_down) $(val victoriametrics.targets down 'job=dead')"
check 'victorialogs: healthy, writable' '1 0' "$(val victorialogs.status healthy) $(val victorialogs.status read_only)"
check 'victorialogs: entries by two protocols; those older than its retention dropped' 'yes yes yes' "$(least victorialogs.ingestion rows_ingested 'type=jsonline' 1) $(least victorialogs.ingestion rows_ingested 'type=opentelemetry_protobuf' 1) $(least victorialogs.ingestion rows_dropped 'reason=too_small_timestamp' 1)"

say "A login that is refused, a page that is not there, and nothing answering."
GRAFANA_TOKEN=glsa_not_a_token bash "$bk_repo/packs/grafana/linux/datasources.sh" > "$work/wrong.out" 2> "$work/wrong.err"
check 'grafana: a token it refuses: the run succeeds, and reads login_ok 0' '0 0' "$? $(grep '^metric login_ok ' "$work/wrong.out" | awk '{ print $3 }')"
check 'and says why' yes "$(grep -q 'answered HTTP 401: this login may not read it' "$work/wrong.err" && echo yes || echo no)"
sed 's/^/        /' "$work/wrong.out" "$work/wrong.err"
(unset GRAFANA_TOKEN; bash "$bk_repo/packs/grafana/linux/datasources.sh" > "$work/none.out" 2> "$work/none.err")
check 'grafana: no token at all: login_ok 0, and it says what it needs' '0 yes' "$(grep '^metric login_ok ' "$work/none.out" | awk '{ print $3 }') $(grep -q "needs a Viewer's token" "$work/none.err" && echo yes || echo no)"
PROMETHEUS_URL=http://127.0.0.1:19090/nothing-here bash "$bk_repo/packs/prometheus/linux/status.sh" > "$work/missing.out" 2> "$work/missing.err"
check 'prometheus: an address with no metrics page: the run succeeds, up 0, and it says so' '0 0 yes' "$? $(grep '^metric up ' "$work/missing.out" | awk '{ print $3 }') $(grep -q 'no such page (HTTP 404)' "$work/missing.err" && echo yes || echo no)"
sed 's/^/        /' "$work/missing.out" "$work/missing.err"
for p in $packs; do
    j=$(jobs_of "$p" | head -n 1)
    env "$(var_of "$p")_URL=http://127.0.0.1:1" bash "$bk_repo/packs/$p/linux/$j.sh" > "$work/down.out" 2>&1
    check "$p: nothing answers: $j still runs, up 0" '0 yes' "$? $(grep -q '^metric up 0$' "$work/down.out" && echo yes || echo no)"
done

say "The packs through Vigil."
for p in $packs; do
    P=$(var_of "$p")
    export "VIGIL_IT_OBS_$P=${P}_URL=http://127.0.0.1:$(port_of "$p")" "VIGIL_IT_OBS_${P}_DOWN=${P}_URL=http://127.0.0.1:1"
done
export VIGIL_IT_OBS_GRAFANA_TOKEN=$GRAFANA_TOKEN
( for p in $packs; do unset "$(var_of "$p")_URL"; done; unset GRAFANA_TOKEN; bash "$bk_repo/tests/integration/service-packs.sh" )
rc=$?
# VIGIL_IT_OBS_HOLD=<file>: the stack stays up, the token in <file>.d/ (this
# account's alone), for the tests of other machines (macOS, Windows), until
# <file> is deleted.
if [ -n "${VIGIL_IT_OBS_HOLD-}" ]; then
    (umask 077 && mkdir -p "$VIGIL_IT_OBS_HOLD.d" && cp "$work/grafana.token" "$VIGIL_IT_OBS_HOLD.d/")
    : > "$VIGIL_IT_OBS_HOLD"
    printf 'hold     the stack stays up, on its ports of 127.0.0.1, until %s is deleted\n' "$VIGIL_IT_OBS_HOLD"
    while [ -e "$VIGIL_IT_OBS_HOLD" ]; do sleep 5; done
    rm -rf "$VIGIL_IT_OBS_HOLD.d"
fi

say "Tempo stops. Its own pack says so, and three others see it from their side."
dc stop tempo > /dev/null 2>&1
until_least prometheus targets down 'job=stack' 1 40
until_least otelcol exporters queue 'exporter=otlp/tempo' 1 40
until_least grafana datasources datasources_failing '' 2 40
run tempo status 'Tempo stopped'
check 'tempo: its status job still runs, and reads up 0' 'exit 0 0' "$(tail -n 1 "$work/tempo.status.err") $(val tempo.status up)"
run prometheus targets 'Tempo stopped'
check 'prometheus: one more target down, in the job Tempo is in' '4 1' "$(val prometheus.targets targets_down) $(val prometheus.targets down 'job=stack')"
run otelcol exporters 'Tempo stopped'
check "otelcol: the exporter to Tempo is holding what it cannot send" yes "$(least otelcol.exporters queue 'exporter=otlp/tempo' 1)"
run grafana datasources 'Tempo stopped'
check 'grafana: its Tempo data source no longer answers: two failing now' '2 0' "$(val grafana.datasources datasources_failing) $(val grafana.datasources datasource_ok 'name=Tempo')"
dc start tempo > /dev/null 2>&1
for _ in $(seq 1 60); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:19320/ready)" = 200 ] && break; sleep 2; done
until_least tempo status ready '' 1 40
check 'tempo: back, and ready' '1 1' "$(val tempo.status up) $(val tempo.status ready)"

say "An Alertmanager leaves the cluster: alertmanager2 stops."
dc stop alertmanager2 > /dev/null 2>&1
until_least alertmanager cluster failed_peers '' 1 40
run alertmanager cluster 'alertmanager2 stopped'
check 'alertmanager: it sees one member, and one peer lost' '1 1' "$(val alertmanager.cluster members) $(val alertmanager.cluster failed_peers)"
dc start alertmanager2 > /dev/null 2>&1
for _ in $(seq 1 40); do quiet alertmanager cluster; [ "$(val alertmanager.cluster members)" = 2 ] && [ "$(val alertmanager.cluster failed_peers)" = 0 ] && break; sleep 3; done
check 'alertmanager: back to two members, none lost' '2 0' "$(val alertmanager.cluster members) $(val alertmanager.cluster failed_peers)"

say "A configuration they refuse: Prometheus, then Alertmanager."
# Written into the file in place: the containers have that very file.
printf '\nthis is: [not a configuration\n' >> "$OBS_DIR/prometheus.yml"
printf '$ curl -X POST http://127.0.0.1:19090/-/reload   -> HTTP %s\n' "$(curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST http://127.0.0.1:19090/-/reload)"
run prometheus status 'an edit Prometheus refused'
check 'prometheus: still up and ready, on the configuration it had; the reload is said to have failed' '1 1 0' "$(val prometheus.status up) $(val prometheus.status ready) $(val prometheus.status config_reload_ok)"
cat "$bk_dir/configs/services/obs/prometheus.yml" > "$OBS_DIR/prometheus.yml"
curl -s -o /dev/null -m 20 -X POST http://127.0.0.1:19090/-/reload
quiet prometheus status
check 'prometheus: the file mended and reloaded: config_reload_ok 1' 1 "$(val prometheus.status config_reload_ok)"
printf '\nthis is: [not a configuration\n' >> "$OBS_DIR/alertmanager.yml"
printf '$ curl -X POST http://127.0.0.1:19093/-/reload   -> HTTP %s\n' "$(curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST http://127.0.0.1:19093/-/reload)"
run alertmanager status 'an edit Alertmanager refused'
check 'alertmanager: still up and ready; the reload is said to have failed' '1 1 0' "$(val alertmanager.status up) $(val alertmanager.status ready) $(val alertmanager.status config_reload_ok)"
cat "$bk_dir/configs/services/obs/alertmanager.yml" > "$OBS_DIR/alertmanager.yml"
curl -s -o /dev/null -m 20 -X POST http://127.0.0.1:19093/-/reload
quiet alertmanager status
check 'alertmanager: the file mended and reloaded: config_reload_ok 1' 1 "$(val alertmanager.status config_reload_ok)"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
