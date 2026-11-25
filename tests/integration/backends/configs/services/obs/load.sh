#!/bin/sh
#
# load.sh - what the obs test stack is asked, every few seconds
# (compose.obs.yaml): logs pushed straight to Loki and VictoriaLogs, some of
# them wrong on purpose, and queries, good and bad, to everything that
# answers them. It runs in the stack's own network and reaches nothing else.
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

q() { curl -s -o /dev/null -m 5 "$@" || true; }
long=$(head -c 400 /dev/zero | tr '\0' 'x')
n=0
while :; do
    n=$((n + 1))
    now=$(date +%s)
    old=$((now - 7200))
    ancient=$((now - 864000))
    # Loki: one entry it keeps, one too old, one line too long.
    q -H 'Content-Type: application/json' -X POST http://loki:3100/loki/api/v1/push \
        -d "{\"streams\":[{\"stream\":{\"app\":\"load\",\"kind\":\"good\"},\"values\":[[\"${now}000000000\",\"entry $n\"]]}]}"
    q -H 'Content-Type: application/json' -X POST http://loki:3100/loki/api/v1/push \
        -d "{\"streams\":[{\"stream\":{\"app\":\"load\",\"kind\":\"old\"},\"values\":[[\"${old}000000000\",\"too old $n\"]]}]}"
    q -H 'Content-Type: application/json' -X POST http://loki:3100/loki/api/v1/push \
        -d "{\"streams\":[{\"stream\":{\"app\":\"load\",\"kind\":\"long\"},\"values\":[[\"${now}000000000\",\"$long\"]]}]}"
    # VictoriaLogs: one entry it keeps, one older than its retention.
    # (It takes JSON lines only as application/stream+json: sent as a form,
    # it answers 200 and keeps nothing.)
    printf '{"_time":"%s","app":"load","_msg":"entry %s"}\n{"_time":"%s","app":"load","_msg":"too old %s"}\n' "$now" "$n" "$ancient" "$n" |
        q -H 'Content-Type: application/stream+json' -X POST 'http://victorialogs:9428/insert/jsonline?_stream_fields=app' --data-binary @-
    # Queries that work, and queries that cannot.
    q 'http://prometheus:9090/api/v1/query?query=up'
    q 'http://prometheus:9090/api/v1/query?query=up%7B'
    q 'http://victoriametrics:8428/api/v1/query?query=up'
    q 'http://victoriametrics:8428/api/v1/query?query=up%7B'
    q 'http://mimir:9009/prometheus/api/v1/query?query=up'
    q 'http://mimir:9009/prometheus/api/v1/query?query=up%7B'
    q -G 'http://loki:3100/loki/api/v1/query_range' --data-urlencode 'query={app="load"}' --data-urlencode 'limit=5'
    q -G 'http://loki:3100/loki/api/v1/query_range' --data-urlencode 'query={app='
    q -G 'http://victorialogs:9428/select/logsql/query' --data-urlencode 'query=app:load' --data-urlencode 'limit=5'
    q -G 'http://victorialogs:9428/select/logsql/query' --data-urlencode 'query=(('
    q 'http://tempo:3200/api/search?limit=5'
    q -G 'http://tempo:3200/api/search' --data-urlencode 'q={'
    q 'http://grafana:3000/api/health'
    q 'http://alertmanager:9093/api/v2/alerts'
    sleep 4
done
