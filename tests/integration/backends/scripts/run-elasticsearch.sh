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
# run-elasticsearch.sh - the elasticsearch pack against two real clusters in
# trouble on purpose, with its evidence kept like the other runs'.
#
#   scripts/run-elasticsearch.sh
#
# It starts compose.elasticsearch-cluster.yaml's clusters (9.5.5, three
# nodes, over https; 8.19.25, two nodes) and, in each, as the elastic user:
# a user that may only monitor (vigil); an index lifecycle that fails (a
# rollover with no alias); snapshot policies, one to a read-only repository;
# a transform that fails (a runtime field reading a field no document has);
# an ingest pipeline that fails half its documents;
# an index red (a primary no node may take), one yellow (more replicas than
# nodes), one closed, one blocked for writes; the request breaker tripped;
# writes refused (one write thread, a queue of ten); a reindex crawling;
# then settings left behind after maintenance: allocation for primaries
# only, a node excluded, disk watermarks the disks are past, and a shard
# limit nearly reached. Every job of the pack is run as vigil and what it
# reads is checked; then a wrong password and a cluster that is down; then
# tests/integration/service-packs.sh runs the pack through Vigil. At the
# end, nodes of 9.5.5 are stopped: one (two are left), then another (one
# is left, with no master). The passwords are made here, into this run's own
# folder, and kept out of the evidence. VIGIL_IT_ES_HOLD (below) keeps the
# clusters up for other machines' tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: Elasticsearch runs in containers'
for p in curl jq openssl; do command -v "$p" > /dev/null 2>&1 || die "$p not found"; done
file=compose.elasticsearch-cluster.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-es-it.XXXXXX") || exit 1
root=$work/none
dc() { docker compose -p vigil-es --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
(umask 077 && openssl rand -hex 16 > "$work/elastic.pw" && openssl rand -hex 16 > "$work/vigil.pw")
export ES_IT_PASSWORD; ES_IT_PASSWORD=$(cat "$work/elastic.pw")
(umask 077 && printf 'user = "elastic:%s"\n' "$ES_IT_PASSWORD" > "$work/elastic.curl")
# shellcheck disable=SC2046
trap 'dc down -v > /dev/null 2>&1; evidence_save "$(cat "$work/elastic.pw")" "$(cat "$work/vigil.pw")"; rm -rf "$work"' EXIT
evidence_start pack-elasticsearch "$bk_dir/$file" "$0" "$@"
pack=$bk_repo/packs/elasticsearch/linux

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'Elasticsearch would not start'; }
docker cp vigil-es-es95a-1:/usr/share/elasticsearch/config/certs/ca/ca.crt "$work/ca.crt" > /dev/null 2>&1 ||
    { sleep 5; docker cp vigil-es-es95a-1:/usr/share/elasticsearch/config/certs/ca/ca.crt "$work/ca.crt" > /dev/null; }
# es <base> <method> <path> [curl args]: as elastic.
es() {
    local b=$1 m=$2 p=$3
    shift 3
    curl -s -K "$work/elastic.curl" --cacert "$work/ca.crt" -H 'Content-Type: application/json' -X "$m" "$b/$p" "$@"
}
# esbulk <base> <file>: a bulk request into logs-ok, as newline-delimited JSON.
esbulk() { curl -s -K "$work/elastic.curl" --cacert "$work/ca.crt" -H 'Content-Type: application/x-ndjson' -X POST "$1/logs-ok/_bulk" --data-binary "@$2" "${@:3}"; }
for c in https://127.0.0.1:19200:3 http://127.0.0.1:19201:2; do
    b=${c%:*} n=${c##*:}
    for _ in $(seq 1 120); do
        [ "$(es "$b" GET '_cat/nodes?h=name' 2> /dev/null | grep -c .)" -ge "$n" ] && break
        sleep 3
    done
    [ "$(es "$b" GET '_cat/nodes?h=name' 2> /dev/null | grep -c .)" -ge "$n" ] || { dc logs --tail 20; die "$b did not form a cluster of $n"; }
done
printf 'elasticsearch  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say() { printf '\n# %s\n' "$*"; }
# trouble <base>: the cluster in trouble on purpose, as elastic.
trouble() {
    local b=$1 i k
    es "$b" PUT _security/role/vigil_monitor -d '{"cluster":["monitor","read_ilm","read_slm","monitor_snapshot"],"indices":[{"names":["*"],"privileges":["monitor","view_index_metadata"]}]}' > /dev/null
    printf '{"password":"%s","roles":["vigil_monitor"]}' "$(cat "$work/vigil.pw")" | es "$b" PUT _security/user/vigil -d @- > /dev/null
    es "$b" PUT _cluster/settings -d '{"persistent":{"indices.lifecycle.poll_interval":"5s"}}' > /dev/null
    # Index lifecycle: a rollover with no alias fails.
    es "$b" PUT _ilm/policy/rollover-broken -d '{"policy":{"phases":{"hot":{"actions":{"rollover":{"max_docs":1}}}}}}' > /dev/null
    es "$b" PUT ilm-broken -d '{"settings":{"number_of_shards":1,"number_of_replicas":0,"index.lifecycle.name":"rollover-broken"}}' > /dev/null
    es "$b" POST ilm-broken/_doc -d '{"a":1}' > /dev/null
    # A data stream (logs-*-*, Elasticsearch's own template).
    es "$b" POST logs-app-default/_doc -d '{"@timestamp":"2026-11-23T20:00:00Z","message":"hello"}' > /dev/null
    # Documents.
    es "$b" PUT logs-ok -d '{"settings":{"number_of_shards":2,"number_of_replicas":1}}' > /dev/null
    for k in $(seq 1 500); do printf '{"index":{}}\n{"msg":"line %s","n":%s,"tag":"t%s"}\n' "$k" "$k" "$((k % 7))"; done > "$work/bulk"
    for i in $(seq 1 20); do esbulk "$b" "$work/bulk" -o /dev/null; done
    # Snapshots: a repository, and a read-only one; a policy to each.
    es "$b" PUT _snapshot/backups -d '{"type":"fs","settings":{"location":"/snapshots/backups"}}' > /dev/null
    es "$b" PUT _snapshot/ro-repo -d '{"type":"fs","settings":{"location":"/snapshots/backups","readonly":true}}' > /dev/null
    es "$b" PUT _slm/policy/nightly-ok -d '{"schedule":"0 30 1 * * ?","name":"<ok-{now/d}>","repository":"backups","config":{"indices":["logs-ok"]}}' > /dev/null
    es "$b" PUT _slm/policy/nightly-ro -d '{"schedule":"0 30 2 * * ?","name":"<ro-{now/d}>","repository":"ro-repo","config":{"indices":["logs-ok"]}}' > /dev/null
    es "$b" POST _slm/policy/nightly-ok/_execute > /dev/null
    es "$b" POST _slm/policy/nightly-ro/_execute > /dev/null
    # A transform grouping by a runtime field that reads a field no
    # document has: its first search fails, and so does it.
    es "$b" PUT '_transform/broken?defer_validation=true' -d '{"source":{"index":"logs-ok","runtime_mappings":{"bad":{"type":"keyword","script":"emit(doc[\"nope\"].value)"}}},"dest":{"index":"t-dest"},"pivot":{"group_by":{"bad":{"terms":{"field":"bad"}}},"aggregations":{"c":{"value_count":{"field":"n"}}}},"settings":{"num_failure_retries":0}}' > /dev/null
    es "$b" POST _transform/broken/_start > /dev/null
    for i in $(seq 1 30); do es "$b" GET _transform/broken/_stats | grep -q '"state":"failed"' && break; sleep 1; done
    # Ingest: half the documents fail.
    es "$b" PUT _ingest/pipeline/parse -d '{"processors":[{"fail":{"if":"ctx.n % 2 == 0","message":"even"}}]}' > /dev/null
    for k in 1 2 3 4 5 6; do es "$b" POST 'logs-ok/_doc?pipeline=parse' -d "{\"n\":$k}" -o /dev/null; done
    # Yellow, red, closed and blocked.
    es "$b" PUT orders -d '{"settings":{"number_of_shards":1,"number_of_replicas":3}}' > /dev/null
    es "$b" PUT 'archive-red?wait_for_active_shards=0' -d '{"settings":{"number_of_shards":1,"number_of_replicas":0,"index.routing.allocation.require._name":"nowhere"}}' > /dev/null
    es "$b" PUT old-2024 -d '{"settings":{"number_of_shards":1,"number_of_replicas":0}}' > /dev/null
    es "$b" POST old-2024/_close > /dev/null
    es "$b" PUT blocked -d '{"settings":{"number_of_shards":1,"number_of_replicas":0,"index.blocks.write":true}}' > /dev/null
    # Searches, then the request breaker tripped.
    for i in $(seq 1 10); do es "$b" POST 'logs-ok/_search?request_cache=true' -d '{"size":0,"aggs":{"t":{"terms":{"field":"tag.keyword"}}}}' -o /dev/null; done
    es "$b" PUT _cluster/settings -d '{"transient":{"indices.breaker.request.limit":"1kb"}}' > /dev/null
    for i in 1 2 3; do es "$b" POST logs-ok/_search -d '{"size":0,"aggs":{"t":{"terms":{"field":"tag.keyword","size":1000}}}}' -o /dev/null; done
    es "$b" PUT _cluster/settings -d '{"transient":{"indices.breaker.request.limit":null}}' > /dev/null
    # Writes refused: a burst, at one write thread and a queue of ten.
    for i in $(seq 1 200); do esbulk "$b" "$work/bulk" -o /dev/null & done
    wait
    # A reindex, throttled to a crawl.
    es "$b" PUT logs-slow -d '{"settings":{"number_of_shards":1,"number_of_replicas":1}}' > /dev/null
    es "$b" POST '_reindex?wait_for_completion=false&requests_per_second=0.2' -d '{"source":{"index":"logs-ok","size":10},"dest":{"index":"logs-slow"}}' > /dev/null
    # Left behind after maintenance: allocation for primaries only, a node
    # excluded, disk watermarks every disk is past (but not the flood
    # stage), and a shard limit nearly reached.
    es "$b" PUT _cluster/settings -d '{"persistent":{"cluster.routing.allocation.enable":"primaries","cluster.routing.allocation.exclude._name":"decommissioned-1","cluster.routing.allocation.disk.watermark.low":"100tb","cluster.routing.allocation.disk.watermark.high":"50tb","cluster.routing.allocation.disk.watermark.flood_stage":"1gb","cluster.max_shards_per_node":12}}' > /dev/null
}
for b in https://127.0.0.1:19200 http://127.0.0.1:19201; do trouble "$b"; done
# Index lifecycle fails its step; give it time to say so, then put its poll
# back to the default (10 minutes): polled every 5 seconds, it retries the
# step so often that the index is seldom seen in ERROR.
for b in https://127.0.0.1:19200 http://127.0.0.1:19201; do
    for _ in $(seq 1 40); do es "$b" GET 'ilm-broken/_ilm/explain' | grep -q '"step":"ERROR"' && break; sleep 3; done
    es "$b" PUT _cluster/settings -d '{"persistent":{"indices.lifecycle.poll_interval":null}}' > /dev/null
done
sleep 10

pass=0 fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+( .*)?$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2( |$).*$3" "$work/$1.out" && echo yes || echo no; }

jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/elasticsearch/pack.config")
for s in es95:https://127.0.0.1:19200:9.5.5:3 es819:http://127.0.0.1:19201:8.19.25:2; do
    name=${s%%:*} rest=${s#*:} nodes=${s##*:}
    rest=${rest%:*} version=${rest##*:} url=${rest%:*}
    say "Elasticsearch $version ($nodes nodes): every job, as the pack's scripts print it, as vigil (it may only monitor)."
    export ELASTICSEARCH_URL=$url ELASTICSEARCH_USER=vigil ELASTICSEARCH_CACERT=$work/ca.crt
    export ELASTICSEARCH_PASSWORD; ELASTICSEARCH_PASSWORD=$(cat "$work/vigil.pw")
    for j in $jobs; do
        printf '\n$ bash packs/elasticsearch/linux/%s.sh\n' "$j"
        bash "$pack/$j.sh" > "$work/$j.out" 2> "$work/$j.err"
        printf 'exit %s\n' "$?" >> "$work/$j.err"
        cat "$work/$j.out"
        grep -v '^exit 0$' "$work/$j.err"
    done

    say "Elasticsearch $version: what they read."
    for j in $jobs; do check "$name: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
    check "$name: answers" 1 "$(val status up '')"
    check "$name: Elasticsearch $version" yes "$(has status version "version=${version//./\\.} ")"
    check "$name: red" 2 "$(val status status '')"
    check "$name: $nodes nodes" "$nodes" "$(val status nodes '')"
    check "$name: a primary unassigned" yes "$(least status unassigned_primary_shards '' 1)"
    check "$name: a master elected" yes "$(has status master 'node=es')"
    check "$name: its health report, red" '1 2' "$(val health served '') $(val health status '')"
    check "$name: shard availability red" 2 "$(val health indicator 'indicator=shards_availability ')"
    check "$name: the disks past a watermark" yes "$(least health indicator 'indicator=disk ' 1)"
    check "$name: the shard limit near" yes "$(least health indicator 'indicator=shards_capacity ' 1)"
    check "$name: every node seen, one version" "$nodes 1" "$(val nodes nodes '') $(val nodes versions '')"
    check "$name: writes refused" yes "$(least thread_pools rejected_total '' 1)"
    check "$name: the request breaker tripped" yes "$(least breakers tripped_total '' 1)"
    check "$name: a red index, a closed one" '1 1' "$(val indices red '') $(val indices closed '')"
    check "$name: a yellow index" yes "$(least indices yellow '' 1)"
    check "$name: an index blocked for writes" yes "$(least indices write_blocked '' 1)"
    check "$name: and which" yes "$(has indices block 'index=blocked block=write')"
    check "$name: the unassigned primary, and since when" yes "$(has shards unassigned_seconds 'index=archive-red shard=0 prirep=p reason=INDEX_CREATED')"
    check "$name: and why, in Elasticsearch's words" yes "$(has shards explained 'index=archive-red .*can_allocate=no decider=filter why=node_does_not_match_index_setting')"
    check "$name: every node past the high watermark" "$nodes" "$(val allocation nodes_over_high '')"
    check "$name: allocation left at primaries" yes "$(has allocation allocation_enabled '0 setting=primaries')"
    check "$name: a node left excluded" yes "$(has allocation exclusion '1 attribute=_name value=decommissioned-1')"
    check "$name: the shard limit" 12 "$(val allocation max_shards_per_node '')"
    check "$name: work done, per node" yes "$(least operations index_total 'node=' 1)"
    check "$name: the pipeline failing half" '3 50' "$(val ingest pipeline_failed 'pipeline=parse') $(val ingest pipeline_failed_pct 'pipeline=parse')"
    check "$name: the reindex running, and what it does" yes "$(has tasks running_seconds 'action=indices:data/write/reindex .*what=reindex_from__logs-ok__to__logs-slow_')"
    check "$name: the lifecycle error, in Elasticsearch's words" yes "$(has lifecycle ilm_error 'index=ilm-broken policy=rollover-broken step=check-rollover-ready reason=setting__index.lifecycle.rollover_alias')"
    check "$name: the snapshot policy failing, and why" yes "$(has lifecycle slm_failing '1 policy=nightly-ro reason=.*readonly_repository')"
    check "$name: the other's last success" yes "$(has lifecycle slm_last_success_age_seconds 'policy=nightly-ok')"
    check "$name: snapshots in the repository" '0' "$(val snapshots last_status 'repository=backups')"
    check "$name: the cluster's license" yes "$(has cluster license 'type=basic status=active')"
    check "$name: the failed transform, and why" yes "$(has features transform_failed '1 transform=broken reason=')"

    ELASTICSEARCH_PASSWORD=not-the-password bash "$pack/status.sh" > "$work/wrong.out" 2>&1
    check "$name: a wrong password fails the run" 1 "$?"
    check "$name: and says so" yes "$(grep -q 'Elasticsearch refused the login (HTTP 401)' "$work/wrong.out" && echo yes || echo no)"
done
ELASTICSEARCH_URL=http://127.0.0.1:1 bash "$pack/status.sh" > "$work/down.out" 2>&1
check 'a cluster that does not answer still runs' 0 "$?"
check 'and reads as up 0' yes "$(grep -q '^metric up 0$' "$work/down.out" && echo yes || echo no)"

say "The pack through Vigil."
export VIGIL_IT_ES_URL=https://127.0.0.1:19200 VIGIL_IT_ES_USER=vigil VIGIL_IT_ES_CACERT=$work/ca.crt
export VIGIL_IT_ES_PASSWORD; VIGIL_IT_ES_PASSWORD=$(cat "$work/vigil.pw")
unset ELASTICSEARCH_URL ELASTICSEARCH_USER ELASTICSEARCH_PASSWORD ELASTICSEARCH_CACERT
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
# VIGIL_IT_ES_HOLD=<file>: the clusters stay up, the CA and vigil's
# password in <file>.d/ (this account's alone), for the tests of other
# machines (macOS, Windows), until <file> is deleted.
if [ -n "${VIGIL_IT_ES_HOLD-}" ]; then
    (umask 077 && mkdir -p "$VIGIL_IT_ES_HOLD.d" && cp "$work/ca.crt" "$work/vigil.pw" "$VIGIL_IT_ES_HOLD.d/")
    : > "$VIGIL_IT_ES_HOLD"
    printf 'hold     the clusters stay up, on 19200 and 19201, until %s is deleted\n' "$VIGIL_IT_ES_HOLD"
    while [ -e "$VIGIL_IT_ES_HOLD" ]; do sleep 5; done
    rm -rf "$VIGIL_IT_ES_HOLD.d"
fi

say "Nodes leave 9.5.5: es95c stops (two of three are left), then es95b (one: no master)."
export ELASTICSEARCH_URL=https://127.0.0.1:19200 ELASTICSEARCH_USER=vigil ELASTICSEARCH_CACERT=$work/ca.crt
export ELASTICSEARCH_PASSWORD; ELASTICSEARCH_PASSWORD=$(cat "$work/vigil.pw")
dc stop es95c > /dev/null 2>&1
for _ in $(seq 1 40); do [ "$(es https://127.0.0.1:19200 GET '_cat/nodes?h=name' | grep -c .)" -eq 2 ] && break; sleep 3; done
for j in status nodes; do
    printf '\n$ bash packs/elasticsearch/linux/%s.sh   (es95c gone)\n' "$j"
    bash "$pack/$j.sh" > "$work/$j.out" 2>&1
    check "es95c gone: $j still runs" 0 "$?"
    grep -v -E ' (load_|transport_|http_|indexing_pressure|open_fds|max_fds|fds_pct)' "$work/$j.out"
done
check 'es95c gone: two nodes left' '2 2' "$(val status nodes '') $(val nodes nodes '')"
check 'es95c gone: its shards wait for it, on purpose' yes "$(least status delayed_unassigned_shards '' 1)"
dc stop es95b > /dev/null 2>&1
sleep 5
printf '\n$ bash packs/elasticsearch/linux/status.sh   (es95b gone too: one node of three, no master)\n'
bash "$pack/status.sh" > "$work/status.out" 2>&1
check 'no master: still runs' 0 "$?"
cat "$work/status.out"
check 'no master: read as such' '1 3 0' "$(val status up '') $(val status status '') $(val status master '')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
