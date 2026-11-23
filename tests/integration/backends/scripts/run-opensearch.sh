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
# run-opensearch.sh - the opensearch pack against two real clusters in
# trouble on purpose, with its evidence kept like the other runs'.
#
#   scripts/run-opensearch.sh
#
# It starts compose.opensearch-cluster.yaml's clusters (3.10.0, three
# nodes; 2.19.7, two nodes; both over https with the security plugin's demo
# certificates) and, in each, as admin: a user that may only monitor
# (vigil, a role of the security plugin); Index State Management that fails
# (a rollover with no alias) and snapshot management to a repository and
# to a read-only one, given time to act first (snapshot management skips
# every run while a cluster is red); an ingest pipeline that fails half its
# documents; an index red, one yellow, one closed, one blocked for writes;
# the request breaker tripped; writes refused (one write thread, a queue of
# ten); a reindex crawling; then settings left behind after maintenance:
# allocation for primaries only, a node excluded, disk watermarks the disks
# are past, and a shard limit nearly reached. Every job of the pack is run
# as vigil and what it reads is checked; then a wrong password and a
# cluster that is down; then tests/integration/service-packs.sh runs the
# pack through Vigil. At the end, nodes of 3.10.0 are stopped: one (two
# are left), then another (one, with no cluster manager). The passwords
# are made here, into this run's own folder, and kept out of the evidence.
# VIGIL_IT_OS_HOLD (below) keeps the clusters up for other machines' tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: OpenSearch runs in containers'
for p in curl jq openssl; do command -v "$p" > /dev/null 2>&1 || die "$p not found"; done
file=compose.opensearch-cluster.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-os-it.XXXXXX") || exit 1
root=$work/none
dc() { docker compose -p vigil-os --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
# OpenSearch wants a strong admin password: upper and lower case, a digit
# and a sign.
(umask 077 && printf 'Vg1!%s' "$(openssl rand -hex 12)" > "$work/admin.pw" && printf 'Vr1!%s' "$(openssl rand -hex 12)" > "$work/vigil.pw")
export OS_IT_PASSWORD; OS_IT_PASSWORD=$(cat "$work/admin.pw")
(umask 077 && printf 'user = "admin:%s"\n' "$OS_IT_PASSWORD" > "$work/admin.curl")
trap 'dc down -v > /dev/null 2>&1; evidence_save "$(cat "$work/admin.pw")" "$(cat "$work/vigil.pw")"; rm -rf "$work"' EXIT
evidence_start pack-opensearch "$bk_dir/$file" "$0" "$@"
pack=$bk_repo/packs/opensearch/linux

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'OpenSearch would not start'; }
for _ in $(seq 1 60); do docker cp vigil-os-os310a-1:/usr/share/opensearch/config/root-ca.pem "$work/ca.pem" > /dev/null 2>&1 && break; sleep 2; done
# os <base> <method> <path> [curl args]: as admin.
os() {
    local b=$1 m=$2 p=$3
    shift 3
    curl -s -K "$work/admin.curl" --cacert "$work/ca.pem" -H 'Content-Type: application/json' -X "$m" "$b/$p" "$@"
}
# osbulk <base> <file>: a bulk request into logs-ok, as newline-delimited JSON.
osbulk() { curl -s -K "$work/admin.curl" --cacert "$work/ca.pem" -H 'Content-Type: application/x-ndjson' -X POST "$1/logs-ok/_bulk" --data-binary "@$2" "${@:3}"; }
for c in https://127.0.0.1:19210:3 https://127.0.0.1:19211:2; do
    b=${c%:*} n=${c##*:}
    for _ in $(seq 1 150); do
        [ "$(os "$b" GET '_cat/nodes?h=name' 2> /dev/null | grep -c '^os')" -ge "$n" ] && break
        sleep 3
    done
    [ "$(os "$b" GET '_cat/nodes?h=name' 2> /dev/null | grep -c '^os')" -ge "$n" ] || { dc logs --tail 20; die "$b did not form a cluster of $n"; }
done
printf 'opensearch  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say() { printf '\n# %s\n' "$*"; }
# lifecycles <base>: ISM and snapshot management, first: snapshot
# management skips every run while a cluster is red.
lifecycles() {
    local b=$1
    os "$b" PUT _plugins/_security/api/roles/vigil_monitor -d '{"cluster_permissions":["cluster_monitor","cluster:admin/repository/get","cluster:admin/snapshot/get","cluster:admin/snapshot/status","cluster:admin/opendistro/ism/managedindex/explain","cluster:admin/opensearch/snapshot_management/policy/get","cluster:admin/opensearch/snapshot_management/policy/search","cluster:admin/opensearch/snapshot_management/policy/explain"],"index_permissions":[{"index_patterns":["*"],"allowed_actions":["indices_monitor","indices:admin/get","indices:monitor/settings/get"]}]}' > /dev/null
    printf '{"password":"%s","backend_roles":[]}' "$(cat "$work/vigil.pw")" | os "$b" PUT _plugins/_security/api/internalusers/vigil -d @- > /dev/null
    os "$b" PUT _plugins/_security/api/rolesmapping/vigil_monitor -d '{"users":["vigil"]}' > /dev/null
    os "$b" PUT _cluster/settings -d '{"persistent":{"plugins.index_state_management.job_interval":1}}' > /dev/null
    os "$b" PUT _plugins/_ism/policies/rollover-broken -d '{"policy":{"description":"a rollover with no alias","default_state":"hot","states":[{"name":"hot","actions":[{"retry":{"count":1,"delay":"10s"},"rollover":{"min_doc_count":1}}],"transitions":[]}]}}' > /dev/null
    os "$b" PUT ism-broken -d '{"settings":{"number_of_shards":1,"number_of_replicas":0}}' > /dev/null
    os "$b" POST ism-broken/_doc -d '{"a":1}' > /dev/null
    os "$b" POST _plugins/_ism/add/ism-broken -d '{"policy_id":"rollover-broken"}' > /dev/null
    os "$b" PUT logs-ok -d '{"settings":{"number_of_shards":2,"number_of_replicas":1}}' > /dev/null
    os "$b" POST logs-ok/_doc -d '{"msg":"first","n":0,"tag":"t0"}' > /dev/null
    os "$b" PUT _snapshot/backups -d '{"type":"fs","settings":{"location":"/snapshots/backups"}}' > /dev/null
    os "$b" PUT _snapshot/ro-repo -d '{"type":"fs","settings":{"location":"/snapshots/backups","readonly":true}}' > /dev/null
    os "$b" POST _plugins/_sm/policies/nightly-ok -d '{"description":"every minute","creation":{"schedule":{"cron":{"expression":"* * * * *","timezone":"UTC"}}},"snapshot_config":{"repository":"backups","indices":"logs-ok"}}' > /dev/null
    os "$b" POST _plugins/_sm/policies/nightly-ro -d '{"description":"to a read-only repository","creation":{"schedule":{"cron":{"expression":"* * * * *","timezone":"UTC"}}},"snapshot_config":{"repository":"ro-repo","indices":"logs-ok"}}' > /dev/null
}
# trouble <base>: the rest, as admin.
trouble() {
    local b=$1 i k
    for k in $(seq 1 500); do printf '{"index":{}}\n{"msg":"line %s","n":%s,"tag":"t%s"}\n' "$k" "$k" "$((k % 7))"; done > "$work/bulk"
    for i in $(seq 1 20); do osbulk "$b" "$work/bulk" -o /dev/null; done
    os "$b" PUT _index_template/app-logs -d '{"index_patterns":["app-logs*"],"data_stream":{},"template":{"settings":{"number_of_replicas":1}}}' > /dev/null
    os "$b" POST app-logs/_doc -d '{"@timestamp":"2026-11-23T20:00:00Z","message":"hello"}' > /dev/null
    os "$b" PUT _ingest/pipeline/parse -d '{"processors":[{"fail":{"if":"ctx.n % 2 == 0","message":"even"}}]}' > /dev/null
    for k in 1 2 3 4 5 6; do os "$b" POST 'logs-ok/_doc?pipeline=parse' -d "{\"n\":$k}" -o /dev/null; done
    os "$b" PUT orders -d '{"settings":{"number_of_shards":1,"number_of_replicas":3}}' > /dev/null
    os "$b" PUT 'archive-red?wait_for_active_shards=0' -d '{"settings":{"number_of_shards":1,"number_of_replicas":0,"index.routing.allocation.require._name":"nowhere"}}' > /dev/null
    os "$b" PUT old-2024 -d '{"settings":{"number_of_shards":1,"number_of_replicas":0}}' > /dev/null
    os "$b" POST old-2024/_close > /dev/null
    os "$b" PUT blocked -d '{"settings":{"number_of_shards":1,"number_of_replicas":0,"index.blocks.write":true}}' > /dev/null
    for i in $(seq 1 10); do os "$b" POST 'logs-ok/_search?request_cache=true' -d '{"size":0,"aggs":{"t":{"terms":{"field":"tag.keyword"}}}}' -o /dev/null; done
    os "$b" PUT _cluster/settings -d '{"transient":{"indices.breaker.request.limit":"1kb"}}' > /dev/null
    for i in 1 2 3; do os "$b" POST logs-ok/_search -d '{"size":0,"aggs":{"t":{"terms":{"field":"tag.keyword","size":1000}}}}' -o /dev/null; done
    os "$b" PUT _cluster/settings -d '{"transient":{"indices.breaker.request.limit":null}}' > /dev/null
    for i in $(seq 1 200); do osbulk "$b" "$work/bulk" -o /dev/null & done
    wait
    os "$b" PUT logs-slow -d '{"settings":{"number_of_shards":1,"number_of_replicas":1}}' > /dev/null
    os "$b" POST '_reindex?wait_for_completion=false&requests_per_second=0.2' -d '{"source":{"index":"logs-ok","size":10},"dest":{"index":"logs-slow"}}' > /dev/null
    os "$b" PUT _cluster/settings -d '{"persistent":{"cluster.routing.allocation.enable":"primaries","cluster.routing.allocation.exclude._name":"decommissioned-1","cluster.routing.allocation.disk.watermark.low":"100tb","cluster.routing.allocation.disk.watermark.high":"50tb","cluster.routing.allocation.disk.watermark.flood_stage":"1gb","cluster.max_shards_per_node":12}}' > /dev/null
}
for b in https://127.0.0.1:19210 https://127.0.0.1:19211; do lifecycles "$b"; done
# ISM fails, and snapshot management takes a snapshot and fails one: on
# their own schedules, a few minutes.
for b in https://127.0.0.1:19210 https://127.0.0.1:19211; do
    for _ in $(seq 1 100); do
        os "$b" GET '_plugins/_ism/explain/ism-broken' | grep -q '"failed":true' &&
            [ "$(os "$b" GET '_plugins/_sm/policies/*/_explain' | jq '[.policies[]?.creation.latest_execution.status // empty | select(. == "SUCCESS" or . == "FAILED")] | length')" -ge 2 ] && break
        sleep 6
    done
done
for b in https://127.0.0.1:19210 https://127.0.0.1:19211; do trouble "$b"; done
sleep 10

pass=0 fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+( .*)?$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2( |$).*$3" "$work/$1.out" && echo yes || echo no; }

jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/opensearch/pack.config")
export OPENSEARCH_USER=vigil OPENSEARCH_CACERT=$work/ca.pem
export OPENSEARCH_PASSWORD; OPENSEARCH_PASSWORD=$(cat "$work/vigil.pw")
for s in os310:19210:3.10.0:3 os219:19211:2.19.7:2; do
    name=${s%%:*} rest=${s#*:} nodes=${s##*:}
    rest=${rest%:*} version=${rest##*:} port=${rest%:*}
    export OPENSEARCH_URL=https://127.0.0.1:$port
    say "OpenSearch $version ($nodes nodes): every job, as the pack's scripts print it, as vigil (it may only monitor)."
    for j in $jobs; do
        printf '\n$ bash packs/opensearch/linux/%s.sh\n' "$j"
        bash "$pack/$j.sh" > "$work/$j.out" 2> "$work/$j.err"
        printf 'exit %s\n' "$?" >> "$work/$j.err"
        cat "$work/$j.out"
        grep -v '^exit 0$' "$work/$j.err"
    done

    say "OpenSearch $version: what they read."
    for j in $jobs; do check "$name: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
    check "$name: answers" 1 "$(val status up '')"
    check "$name: OpenSearch $version" yes "$(has status version "version=${version//./\\.} ")"
    check "$name: red" 2 "$(val status status '')"
    check "$name: $nodes nodes" "$nodes" "$(val status nodes '')"
    check "$name: a cluster manager elected" yes "$(has status cluster_manager '1 node=os')"
    check "$name: every node seen, one version" "$nodes 1" "$(val nodes nodes '') $(val nodes versions '')"
    check "$name: writes refused" yes "$(least thread_pools rejected_total '' 1)"
    check "$name: the request breaker tripped" yes "$(least breakers tripped_total '' 1)"
    check "$name: search backpressure, monitoring" yes "$(has backpressure search_mode '1 node=os.* mode=monitor_only')"
    check "$name: a red index, a closed one" '1 1' "$(val indices red '') $(val indices closed '')"
    check "$name: a yellow index" yes "$(least indices yellow '' 1)"
    check "$name: an index blocked for writes, and which" yes "$(has indices block 'index=blocked block=write')"
    check "$name: the unassigned primary, and since when" yes "$(has shards unassigned_seconds 'index=archive-red shard=0 prirep=p reason=INDEX_CREATED')"
    check "$name: and why, in OpenSearch's words" yes "$(has shards explained 'index=archive-red .*can_allocate=no decider=filter why=node_does_not_match_index_setting')"
    check "$name: every node past the high watermark" "$nodes" "$(val allocation nodes_over_high '')"
    check "$name: allocation left at primaries" yes "$(has allocation allocation_enabled '0 setting=primaries')"
    check "$name: a node left excluded" yes "$(has allocation exclusion '1 attribute=_name value=decommissioned-1')"
    check "$name: the shard limit" 12 "$(val allocation max_shards_per_node '')"
    check "$name: work done, per node" yes "$(least operations index_total 'node=' 1)"
    check "$name: the pipeline failing half" '3 50' "$(val ingest pipeline_failed 'pipeline=parse') $(val ingest pipeline_failed_pct 'pipeline=parse')"
    check "$name: the reindex running, and what it does" yes "$(has tasks running_seconds 'action=indices:data/write/reindex .*what=reindex_from__logs-ok__to__logs-slow_')"
    check "$name: ISM failing, in OpenSearch's words" yes "$(has lifecycle ism_failure '1 index=ism-broken policy=rollover-broken action=rollover reason=Missing_rollover_alias')"
    check "$name: snapshot management failing, and why" yes "$(has lifecycle sm_failing '1 policy=nightly-ro reason=')"
    check "$name: and the other's snapshot taken" yes "$(has lifecycle sm_last_status '0 policy=nightly-ok status=SUCCESS')"
    check "$name: snapshots in the repository" '0' "$(val snapshots last_status 'repository=backups')"
    check "$name: the cluster, its plugins" yes "$(least cluster plugins '' 10)"

    OPENSEARCH_PASSWORD=not-the-password bash "$pack/status.sh" > "$work/wrong.out" 2>&1
    check "$name: a wrong password fails the run" 1 "$?"
    check "$name: and says so" yes "$(grep -q 'OpenSearch refused the login (HTTP 401)' "$work/wrong.out" && echo yes || echo no)"
done
OPENSEARCH_URL=http://127.0.0.1:1 bash "$pack/status.sh" > "$work/down.out" 2>&1
check 'a cluster that does not answer still runs' 0 "$?"
check 'and reads as up 0' yes "$(grep -q '^metric up 0$' "$work/down.out" && echo yes || echo no)"

say "The pack through Vigil."
export VIGIL_IT_OS_URL=https://127.0.0.1:19210 VIGIL_IT_OS_USER=vigil VIGIL_IT_OS_CACERT=$work/ca.pem
export VIGIL_IT_OS_PASSWORD; VIGIL_IT_OS_PASSWORD=$(cat "$work/vigil.pw")
unset OPENSEARCH_URL OPENSEARCH_USER OPENSEARCH_PASSWORD OPENSEARCH_CACERT
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
# VIGIL_IT_OS_HOLD=<file>: the clusters stay up, the CA and vigil's
# password in <file>.d/ (this account's alone), for the tests of other
# machines (macOS, Windows), until <file> is deleted.
if [ -n "${VIGIL_IT_OS_HOLD-}" ]; then
    (umask 077 && mkdir -p "$VIGIL_IT_OS_HOLD.d" && cp "$work/ca.pem" "$work/vigil.pw" "$VIGIL_IT_OS_HOLD.d/")
    : > "$VIGIL_IT_OS_HOLD"
    printf 'hold     the clusters stay up, on 19210 and 19211, until %s is deleted\n' "$VIGIL_IT_OS_HOLD"
    while [ -e "$VIGIL_IT_OS_HOLD" ]; do sleep 5; done
    rm -rf "$VIGIL_IT_OS_HOLD.d"
fi

say "Nodes leave 3.10.0: os310c stops (two of three are left), then os310b (one: no cluster manager)."
export OPENSEARCH_URL=https://127.0.0.1:19210 OPENSEARCH_USER=vigil OPENSEARCH_CACERT=$work/ca.pem
export OPENSEARCH_PASSWORD; OPENSEARCH_PASSWORD=$(cat "$work/vigil.pw")
dc stop os310c > /dev/null 2>&1
for _ in $(seq 1 40); do [ "$(os https://127.0.0.1:19210 GET '_cat/nodes?h=name' | grep -c '^os')" -eq 2 ] && break; sleep 3; done
for j in status nodes; do
    printf '\n$ bash packs/opensearch/linux/%s.sh   (os310c gone)\n' "$j"
    bash "$pack/$j.sh" > "$work/$j.out" 2>&1
    check "os310c gone: $j still runs" 0 "$?"
    grep -v -E ' (load_|transport_|http_|indexing_pressure|open_fds|max_fds|fds_pct)' "$work/$j.out"
done
check 'os310c gone: two nodes left' '2 2' "$(val status nodes '') $(val nodes nodes '')"
dc stop os310b > /dev/null 2>&1
sleep 5
printf '\n$ bash packs/opensearch/linux/status.sh   (os310b gone too: one node of three, no cluster manager)\n'
bash "$pack/status.sh" > "$work/status.out" 2>&1
check 'no cluster manager: still runs' 0 "$?"
cat "$work/status.out"
check 'no cluster manager: read as such' '1 3 0' "$(val status up '') $(val status status '') $(val status cluster_manager '')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
