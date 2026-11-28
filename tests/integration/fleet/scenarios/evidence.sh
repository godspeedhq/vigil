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
# evidence.sh <wave> <pushed at, UTC ISO> [<seconds to look>] - what the
# backend recorded about one wave, from the fleet's own data, on the backend
# host (Prometheus 127.0.0.1:9090, Loki 127.0.0.1:3100):
#   - every instance's "configuration revision ... loaded" line for that
#     wave, with its delay after the push, from Loki
#   - every refusal and error line in that window, from Loki
#   - each instance's latest wave and revision, from Prometheus
# Host names given in FLEET_MASK (name=label pairs, space separated) are
# replaced, so the output can be published.
set -eu
[ "$#" -ge 2 ] || { sed -n '10,19p' "$0"; exit 64; }
wave=$1 at=$2 span=${3:-300}
s=$(date -d "$at" +%s)
mask() {
    local sedargs=() p
    for p in ${FLEET_MASK-}; do sedargs+=(-e "s/${p%%=*}/${p#*=}/g"); done
    if [ ${#sedargs[@]} -gt 0 ]; then sed "${sedargs[@]}"; else cat; fi
}
loki() {
    curl -sG -m 20 'http://127.0.0.1:3100/loki/api/v1/query_range' --data-urlencode "query=$1" \
        --data-urlencode "start=${s}000000000" --data-urlencode "end=$(( s + span ))000000000" \
        --data-urlencode 'limit=5000' --data-urlencode 'direction=forward'
}
echo "== wave $wave, pushed $at; the backend's record of the next ${span}s"
echo
echo "-- activations (Loki: each instance's own log line)"
loki "{service_name=\"vigil\"} |= \"configuration revision\" |= \"loaded\" | wave=\"$wave\"" \
    | jq -r --argjson s "$s" '.data.result[] | .stream as $t | .values[]
        | [((.[0] | tonumber / 1e9 | floor) - $s), $t.host, $t.kind, .[1]] | @tsv' \
    | sort -n | mask | awk -F'\t' '{ printf "+%4ss  %-22s %-16s %s\n", $1, $2, $3, $4 } END { print NR " activations" }'
echo
echo "-- refusals and errors (Loki)"
loki '{service_name="vigil"} |~ "ERROR|has errors|refus|INVALID|unknown section|must be"' \
    | jq -r --argjson s "$s" '.data.result[] | .stream as $t | .values[]
        | [((.[0] | tonumber / 1e9 | floor) - $s), $t.host, $t.kind, .[1]] | @tsv' \
    | sort -n | mask | awk -F'\t' '{ k = $4; sub(/ in [0-9]+s, cpu [0-9.]+s/, "", k) } !seen[$2 FS k]++ { printf "+%4ss  %-22s %-16s %s\n", $1, $2, $3, substr($4, 1, 150) } END { print NR " lines (the first of each kind per host shown)" }'
echo
echo "-- each instance's latest configuration at +${span}s (Prometheus)"
curl -s -m 20 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=topk by (host) (1, timestamp(vigil_config_info))' \
    --data-urlencode "time=$(( s + span ))" \
    | jq -r '.data.result[] | [.metric.kind, .metric.host, .metric.os, "wave " + .metric.wave, .metric.revision] | @tsv' \
    | sort | mask | column -t
