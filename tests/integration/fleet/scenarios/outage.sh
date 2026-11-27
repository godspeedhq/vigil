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
# outage.sh <backend address> <out dir> - a long backend outage, on the
# backend host. After BASELINE seconds of normal running (default 900), the
# LGTM backend is stopped for OUTAGE seconds (default 7200), then started
# again, and each instance HOSTS matches (a Prometheus regex on host,
# default every bare-metal one: no -c<N>) is watched until its newest
# reading is under 3 minutes old, for at most LIMIT seconds (default
# 14400). Then what the backend holds is counted, in 10-minute buckets
# from the baseline to the end, by instance:
#   cpu readings      system_cpu_used_pct samples (Prometheus)
#   job log lines     base_cpu's run end lines (Loki: messages "end ...")
#   spool bytes       vigil_spool_bytes, which the senders report as they go,
#                     so the outage's own readings show the queues growing
# Prometheus keeps a late sample only within its out-of-order window
# (backend/prometheus.yaml: 6h). Evidence in <out dir>, host names masked
# as in run-all.sh: console.txt, NN-*.txt, outage.png.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ "$#" -eq 2 ] || { sed -n '10,26p' "$0"; exit 64; }
addr=$1 out=$2
baseline=${BASELINE:-900} outage=${OUTAGE:-7200} limit=${LIMIT:-14400}
hosts=${HOSTS:-}
mkdir -p "$out"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
mask() {
    local m=$here/../backend/out/mask.txt sedargs=() n l
    [ -f "$m" ] || { cat; return; }
    while IFS='=' read -r n l; do [ -n "$n" ] && sedargs+=(-e "s/$n/$l/g"); done < "$m"
    sed "${sedargs[@]}"
}
# Every line to the console and, masked, to console.txt and the step's file.
file=$out/console.txt
say() { local l; while IFS= read -r l; do printf '%s\n' "$l"; printf '%s\n' "$l" | mask >> "$out/console.txt"; [ "$file" = "$out/console.txt" ] || printf '%s\n' "$l" | mask >> "$file"; done; }
step() { file=$out/$1.txt; : > "$file"; echo "== $2" | say; }
pq() { curl -s -m 30 'http://127.0.0.1:9090/api/v1/query' --data-urlencode "query=$1"; }
prange() { curl -s -m 60 'http://127.0.0.1:9090/api/v1/query_range' --data-urlencode "query=$1" --data-urlencode "start=$2" --data-urlencode "end=$3" --data-urlencode step=600; }
lrange() { curl -s -m 60 'http://127.0.0.1:3100/loki/api/v1/query' --data-urlencode "query=$1" --data-urlencode "time=$2"; }
sel() { if [ -n "$hosts" ]; then printf 'host=~"%s"' "$hosts"; else printf 'host!~".*-c[0-9]+"'; fi; }
# host age: each matched instance's newest cpu reading, seconds old.
ages() {
    local t
    t=$(date +%s)
    pq "max by (host) (timestamp(system_cpu_used_pct{$(sel)}))" | jq -r --argjson t "$t" '.data.result[] | "\(.metric.host) \($t - (.value[1] | tonumber) | floor)"' | sort
}
ready() { local i; for i in $(seq 120); do curl -s -m 3 http://127.0.0.1:9090/-/ready | grep -q Ready && curl -s -m 3 http://127.0.0.1:3100/ready | grep -q ready && return 0; sleep 2; done; return 1; }

# RESUME="<start> <down> <up>" (epoch seconds, from console.txt) picks up a
# run that stopped after the backend came back: recovery and counting only.
if [ -n "${RESUME:-}" ]; then
read -r t0 down up <<< "$RESUME"
file=$out/console.txt
echo "resumed $(now): baseline from $(date -u -d @"$t0" +%H:%M:%S), backend down $(date -u -d @"$down" +%H:%M:%S) to $(date -u -d @"$up" +%H:%M:%S) UTC" | say
want=${WANT:-5}
else
step 01-baseline "Baseline: $((baseline / 60)) minutes of normal running"
echo "started $(now); instances watched: $(sel)" | say
ages | awk '{ printf "  %-24s newest reading %ss old\n", $1, $2 }' | say
want=$(ages | wc -l | tr -d ' ')
echo "  $want instances" | say
t0=$(date +%s)
sleep "$baseline"

step 02-outage "Outage: the LGTM backend stopped for $((outage / 60)) minutes"
docker stop vigil-fleet-lgtm-1 > /dev/null
down=$(date +%s)
echo "  $(now) LGTM stopped" | say
sleep "$outage"
docker start vigil-fleet-lgtm-1 > /dev/null
up=$(date +%s)
echo "  $(now) LGTM started" | say
ready && echo "  $(now) Prometheus and Loki answer" | say
fi

step 03-recovery "Recovery: each instance until its newest reading is under 3 minutes old"
declare -A done_at
ndone=0
while :; do
    while read -r h a; do
        [ -n "$h" ] || continue
        if [ -z "${done_at[$h]-}" ] && [ "$a" -lt 180 ]; then
            done_at[$h]=$(( $(date +%s) - up ))
            ndone=$((ndone + 1))
            echo "  $(now) $h current again, $(( ${done_at[$h]} / 60 ))m $(( ${done_at[$h]} % 60 ))s after the backend came back" | say
        fi
    done < <(ages)
    [ "$ndone" -ge "$want" ] && break
    if [ $(( $(date +%s) - up )) -ge "$limit" ]; then
        echo "  limit reached: $ndone of $want current" | say
        ages | awk '{ printf "    %-24s newest reading %ss old\n", $1, $2 }' | say
        break
    fi
    sleep 30
done
# Late events of the last minutes, before counting.
sleep 300
end=$(date +%s)

step 04-completeness "What the backend holds, per 10 minutes (bucket ends), baseline, outage ($(date -u -d @$down +%H:%M)-$(date -u -d @$up +%H:%M) UTC) and after"
table() {
    jq -r '.data.result[] | .metric.host as $h | .values[] | "\($h) \(.[0]) \(.[1])"' | mask \
        | awk '{ v = $3; if (v ~ /\./) v = sprintf("%.0f", v); t[$2] = 1; c[$1 " " $2] = v; hs[$1] = 1 }
            END { n = asorti(t, ts); m = asorti(hs, hh); printf "  %-8s", "UTC"; for (j = 1; j <= m; j++) printf " %12s", hh[j]; printf "\n"
                  for (i = 1; i <= n; i++) { printf "  %-8s", strftime("%H:%M", ts[i], 1); for (j = 1; j <= m; j++) printf " %12s", ((hh[j] " " ts[i]) in c) ? c[hh[j] " " ts[i]] : "-"; printf "\n" } }'
}
from=$((t0 + 600))
echo | say
echo "-- cpu readings stored (Prometheus), per 10 minutes" | say
prange "sum by (host) (count_over_time(system_cpu_used_pct{$(sel)}[10m]))" "$from" "$end" | table | say
echo | say
echo "-- base_cpu run end lines stored (Loki), per 10 minutes" | say
for ((t = from; t <= end; t += 600)); do
    lrange "sum by (host) (count_over_time({service_name=\"vigil\"} | $(sel) | job=\"base_cpu\" |~ \"^end \" [10m]))" "$t" \
        | jq -r --argjson t "$t" '.data.result[] | {data: {result: [{metric: {host: .metric.host}, values: [[$t, .value[1]]]}]}}' 2>/dev/null
done | jq -s '{data: {result: [.[].data.result[]]}}' | table | say
echo | say
echo "-- the largest spool each instance reported, per 10 minutes (bytes, Prometheus)" | say
prange "max by (host) (max_over_time(vigil_spool_bytes{$(sel)}[10m]))" "$from" "$end" | table | say
echo | say
echo "-- Prometheus refused as too old, since it started again: $(curl -s -m 10 http://127.0.0.1:9090/metrics | sed -n 's/^prometheus_tsdb_too_old_samples_total{type="float"} //p')" | say

step 05-screenshot "The dashboard over the whole test"
if bash "$here/screenshot.sh" "$addr" "$(date -u -d @"$t0" +%Y-%m-%dT%H:%M:%SZ)" "$(date -u -d @"$end" +%Y-%m-%dT%H:%M:%SZ)" "$out/outage.png" 2>&1 | say; then
    echo "  outage.png" | say
fi
file=$out/console.txt
echo "done at $(now)" | say
