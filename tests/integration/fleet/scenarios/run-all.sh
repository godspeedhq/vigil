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
# run-all.sh <backend address> <out dir> <first wave> - every round of the
# fleet test, one after another, on the backend host, each recorded in
# <out dir>: NN-<round>.txt (what was done and what the fleet did, from the
# backend's own data) and NN-<round>.png (the dashboard over the round).
#
#   good       a valid change: time until every instance runs it
#   job        one job broken: the file is taken, that job set aside
#   section    an unknown section: the file is refused everywhere
#   windows    only the Windows file invalid: Windows keeps its own
#   good       back to one wave
#   force      history rewritten (a force-push): the fleet follows
#   gitea      Gitea stopped for HOLD seconds, then a change once it is back
#   backend    the LGTM backend stopped for HOLD seconds: spools fill, drain
#   partition  one container cut from the network while a change lands
#
# FLEET_PARTITION_HOST (ssh target with Docker, default
# vigil-test@192.168.4.85) and FLEET_PARTITION_NODE (default fedora-c2)
# choose the container cut off; FLEET_SSH_KEY its key. HOLD defaults to 240.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ "$#" -eq 3 ] || { sed -n '10,27p' "$0"; exit 64; }
addr=$1 out=$2 wave=$3
hold=${HOLD:-240}
phost=${FLEET_PARTITION_HOST:-vigil-test@192.168.4.85}
pnode=${FLEET_PARTITION_NODE:-fedora-c2}
key=${FLEET_SSH_KEY:-$HOME/.ssh/vigil_fedora}
mkdir -p "$out"
n=0
prom() { curl -s -m 20 'http://127.0.0.1:9090/api/v1/query' --data-urlencode "query=$1" | jq -r "${2:-.data.result[0].value[1] // \"0\"}"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fleet_size() { prom 'count(max by (host) (vigil_config_info) and on (host) (time() - max by (host) (timestamp(vigil_config_info)) < 180))'; }
at_wave() { prom "count(max by (host) (vigil_config_info{wave=\"$1\"}) and on (host) (time() - max by (host) (timestamp(vigil_config_info{wave=\"$1\"})) < 180))"; }
latest() {
    prom 'topk by (host) (1, timestamp(vigil_config_info))' '.data.result[] | [.metric.kind, .metric.host, "wave " + .metric.wave, .metric.revision] | @tsv' \
        | sort | mask | column -t
}
mask() {
    local m=$here/../backend/out/mask.txt sedargs=() n l
    [ -f "$m" ] || { cat; return; }
    while IFS='=' read -r n l; do [ -n "$n" ] && sedargs+=(-e "s/$n/$l/g"); done < "$m"
    sed "${sedargs[@]}"
}
# wait_for <wave> <want> <limit s>: until <want> instances run <wave>.
wait_for() {
    local t0 c
    t0=$(date +%s)
    while :; do
        c=$(at_wave "$1"); [ "${c:-0}" -ge "$2" ] && break
        [ $(( $(date +%s) - t0 )) -ge "$3" ] && { echo "  after $3s: $c of $2 run wave $1 (limit reached)"; return 0; }
        sleep 5
    done
    echo "  $c of $2 instances run wave $1, $(( $(date +%s) - t0 ))s after the push (seen in Prometheus)"
}
# round <name> <description>: opens NN-<name>.txt; finish writes its evidence.
round() {
    n=$((n + 1)); name=$(printf '%02d-%s' "$n" "$1"); file=$out/$name.txt
    rstart=$(now)
    : > "$file"
    { echo "== Round $n: $2"; echo "started $rstart, fleet size $(fleet_size) instances"; echo; } | both
}
log() { echo "$*" | both; }
# both: standard input to the console, and masked into the round's file.
both() { local l; while IFS= read -r l; do printf '%s\n' "$l"; printf '%s\n' "$l" | mask >> "$file"; done; }
finish() {
    local pushed_at=$1 w=$2 span=$3
    {
        echo
        [ -n "$w" ] && bash "$here/evidence.sh" "$w" "$pushed_at" "$span"
        echo
        echo "-- each instance's latest configuration at $(now) (Prometheus)"
        latest
    } 2>&1 | mask >> "$file"
    sleep 1
    bash "$here/screenshot.sh" "$addr" "$(date -u -d "$rstart - 60 sec" +%Y-%m-%dT%H:%M:%SZ)" "$(now)" "$out/$name.png" > /dev/null \
        || echo "  (no screenshot)"
    echo "  -> $name.txt, $name.png"
}
push() { bash "$here/push.sh" "$addr" "$1" "$2" | tail -1; }
gitf() {
    local o=$here/../backend/out
    GIT_ASKPASS=$o/askpass.sh GIT_TERMINAL_PROMPT=0 git -C "$o/config-repo" -c credential.helper= \
        -c http.sslCAInfo="$here/../tls/out/ca.crt" -c http.sslBackend=openssl -c core.autocrlf=false "$@"
}

size=$(fleet_size)
echo "fleet: $size instances reporting at $(now)"
kinds() { prom 'count by (kind) (max by (host, kind) (vigil_config_info) and on (host) (time() - max by (host) (timestamp(vigil_config_info)) < 180))' '.data.result[] | "\(.metric.kind)=\(.value[1])"' | tr '\n' ' '; }
echo "by kind: $(kinds)"
nwin=$(prom 'count(max by (host) (vigil_config_info{kind="windows-bare"}) and on (host) (time() - max by (host) (timestamp(vigil_config_info)) < 180))')

round good "a valid change (wave $wave)"
p=$(push "$wave" good); log "$p"; at=${p%% *}
wait_for "$wave" "$size" 300 | both
finish "$at" "$wave" 300

w1=$((wave + 1))
round job "one job broken: run_every = banana (wave $w1)"
p=$(push "$w1" broken); log "$p"; at=${p%% *}
log "expected: every instance takes the file, sets fleet_broken aside as INVALID, runs the rest"
wait_for "$w1" "$size" 300 | both
log "  instances reporting fleet_broken as invalid: $(prom 'count(max by (host) (fleet_broken_invalid_config) == 1)')"
finish "$at" "$w1" 300

w2=$((wave + 2))
round section "an unknown section in every file (wave $w2)"
p=$(push "$w2" unknown); log "$p"; at=${p%% *}
log "expected: every instance refuses the file and keeps wave $w1"
sleep 150
log "  after 150s: $(at_wave "$w2") instances run wave $w2; $(at_wave "$w1") still run wave $w1"
log "  instances refusing a configuration (reason invalid) in the last 2m: $(prom 'count(increase(vigil_source_failures_total{reason="invalid"}[2m]) > 0)')"
log "  instances unable to reach the source in the last 2m: $(prom 'count(increase(vigil_source_failures_total{reason!="invalid"}[2m]) > 0)')"
finish "$at" "$w2" 150

w3=$((wave + 3))
round windows "only the Windows file invalid (wave $w3)"
p=$(push "$w3" windows); log "$p"; at=${p%% *}
log "expected: $((size - nwin)) instances move to wave $w3; the $nwin Windows instances refuse it and keep wave $w1"
wait_for "$w3" "$((size - nwin))" 300 | both
sleep 60
log "  Windows instances on wave $w3: $(prom "count(max by (host) (vigil_config_info{kind=\"windows-bare\",wave=\"$w3\"})) or vector(0)")"
finish "$at" "$w3" 300

w4=$((wave + 4))
round good "back to one valid wave (wave $w4)"
p=$(push "$w4" good); log "$p"; at=${p%% *}
wait_for "$w4" "$size" 300 | both
finish "$at" "$w4" 300

w5=$((wave + 5))
round force "history rewritten: a force-push (wave $w5)"
gitf pull -q --ff-only origin main
log "  main before: $(gitf log --oneline -3 | tr '\n' ';')"
gitf reset -q --hard HEAD~2
bash "$here/../config/make-configs.sh" "$addr" "$here/../backend/out/config-repo" "$w5" > /dev/null
gitf add -A && gitf commit -q -m "Wave $w5: force-push, history rewritten"
gitf push -q --force origin main
at=$(now); line="$at pushed wave $w5 (force) $(gitf rev-parse --short HEAD)"
echo "$line" >> "$here/out/push.log"; log "$line"
log "  main after:  $(gitf log --oneline -3 | tr '\n' ';')"
wait_for "$w5" "$size" 300 | both
finish "$at" "$w5" 300

w6=$((wave + 6))
round gitea "Gitea stopped for ${hold}s, then a change (wave $w6)"
docker stop vigil-fleet-gitea-1 > /dev/null; down=$(now); log "  $down Gitea stopped"
sleep "$hold"
log "  instances unable to reach the source in the last 2m: $(prom 'count(increase(vigil_source_failures_total{reason!="invalid"}[2m]) > 0)')"
log "  instances refusing a configuration (reason invalid) in the last 2m: $(prom 'count(increase(vigil_source_failures_total{reason="invalid"}[2m]) > 0)')"
log "  instances still sending metrics (cpu in the last 2m): $(prom 'count(max by (host) (max_over_time(system_cpu_used_pct[2m])))')"
log "  instances still on wave $w5: $(at_wave "$w5")"
docker start vigil-fleet-gitea-1 > /dev/null
until curl -sk -m 5 -o /dev/null "https://$addr:8443/api/v1/version"; do sleep 2; done
log "  $(now) Gitea back"
p=$(push "$w6" good); log "$p"; at=${p%% *}
wait_for "$w6" "$size" 300 | both
finish "$down" "$w6" $(( $(date +%s) - $(date -d "$down" +%s) ))

round backend "the LGTM backend stopped for ${hold}s"
log "  spool bytes before, fleet total: $(prom 'sum(vigil_spool_bytes)')"
docker stop vigil-fleet-lgtm-1 > /dev/null; down=$(now); log "  $down LGTM stopped"
sleep "$hold"
docker start vigil-fleet-lgtm-1 > /dev/null; up=$(now); log "  $up LGTM started"
until curl -s -m 5 -o /dev/null http://127.0.0.1:9090/-/ready && [ "$(prom 'count(vigil_spool_bytes)')" != 0 ]; do sleep 5; done
log "  $(now) Prometheus answers"
for t in 60 120 180; do
    sleep 60
    log "  +${t}s: spool bytes, fleet total $(prom 'sum(vigil_spool_bytes)'), largest $(prom 'max(vigil_spool_bytes)')"
done
mid=$(( ($(date -d "$down" +%s) + $(date -d "$up" +%s)) / 2 ))
log "  cpu readings stored for the middle of the outage ($(date -u -d "@$mid" +%H:%M:%S)): $(curl -s -m 20 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=count(count_over_time(system_cpu_used_pct[2m]))' --data-urlencode "time=$mid" | jq -r '.data.result[0].value[1] // "none"') series"
finish "$down" '' 0

w7=$((wave + 7))
round partition "$pnode cut from the network while wave $w7 lands"
ssh -i "$key" "$phost" "docker inspect -f '{{index .Config.Labels \"vigil.fleet\"}}' $pnode | grep -qx node && docker network disconnect bridge $pnode" 2>&1 | grep -v '^\*\*' || true
cut=$(now); log "  $cut $pnode disconnected"
p=$(push "$w7" good); log "$p"; at=${p%% *}
wait_for "$w7" "$((size - 1))" 300 | both
sleep 60
log "  $pnode on wave $w7 while cut off: $(prom "count(vigil_config_info{host=\"$pnode\",wave=\"$w7\"}) or vector(0)")"
ssh -i "$key" "$phost" "docker network connect bridge $pnode" 2>&1 | grep -v '^\*\*' || true
back=$(now); log "  $back $pnode reconnected"
t0=$(date +%s)
until [ "$(prom "count(vigil_config_info{host=\"$pnode\",wave=\"$w7\"})")" -ge 1 ] 2>/dev/null; do
    sleep 5; [ $(( $(date +%s) - t0 )) -ge 300 ] && break
done
log "  $pnode on wave $w7 $(( $(date +%s) - t0 ))s after reconnecting"
finish "$at" "$w7" $(( $(date +%s) - $(date -d "$at" +%s) ))

echo "done at $(now): $n rounds in $out"
