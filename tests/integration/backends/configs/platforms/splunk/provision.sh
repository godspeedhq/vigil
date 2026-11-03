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
# provision.sh - prepares the test Splunk Enterprise for Vigil, through its
# management API: a metrics index and an events index, the HTTP Event
# Collector on plain HTTP, and one token for each index. Safe to run again.
#
#   bash configs/platforms/splunk/provision.sh      (scripts/start.sh splunk runs it)
#
# Reads SPLUNK_PASSWORD, VIGIL_SPLUNK_METRICS_TOKEN and VIGIL_SPLUNK_LOGS_TOKEN
# from the environment or ../../../.env. The management API has the container's
# own self-signed certificate, so curl -k is used here, for this local test
# container only; Vigil itself never skips a certificate check.

set -u

here=$(cd "$(dirname "$0")" && pwd)
[ -f "$here/../../../.env" ] && set -a && . "$here/../../../.env" && set +a
: "${SPLUNK_PASSWORD:?set SPLUNK_PASSWORD}"
: "${VIGIL_SPLUNK_METRICS_TOKEN:?set VIGIL_SPLUNK_METRICS_TOKEN}"
: "${VIGIL_SPLUNK_LOGS_TOKEN:?set VIGIL_SPLUNK_LOGS_TOKEN}"
api=https://127.0.0.1:8089

# The password goes on curl's standard input as a config line, never on its
# command line.
call() {
    printf 'user = "admin:%s"\n' "$SPLUNK_PASSWORD" |
        curl -sk -K - -o /dev/null -w '%{http_code}' "$@"
}

printf 'waiting for the management API'
i=0
until [ "$(call "$api/services/server/info")" = 200 ]; do
    i=$((i + 1))
    [ "$i" -ge 120 ] && { printf '\nSplunk did not come up in 10 minutes\n'; exit 1; }
    printf '.'
    sleep 5
done
printf ' up\n'

# 201 created, 409 already there: both fine.
ok() { case $1 in 200 | 201 | 409) printf 'ok    %s\n' "$2" ;; *) printf 'FAIL  %s (HTTP %s)\n' "$2" "$1"; fail=1 ;; esac; }
fail=0
ok "$(call "$api/services/data/indexes" -d name=vigil_metrics -d datatype=metric)" 'index vigil_metrics (metrics)'
ok "$(call "$api/services/data/indexes" -d name=vigil_logs -d datatype=event)" 'index vigil_logs (events)'
ok "$(call "$api/servicesNS/nobody/splunk_httpinput/data/inputs/http/http" -d disabled=0 -d enableSSL=0)" 'HTTP Event Collector on, plain HTTP'
hec=$api/servicesNS/nobody/splunk_httpinput/data/inputs/http
ok "$(call "$hec" -d name=vigil-metrics -d index=vigil_metrics -d indexes=vigil_metrics -d token="$VIGIL_SPLUNK_METRICS_TOKEN")" 'token vigil-metrics'
ok "$(call "$hec" -d name=vigil-logs -d index=vigil_logs -d indexes=vigil_logs -d token="$VIGIL_SPLUNK_LOGS_TOKEN")" 'token vigil-logs'
exit "$fail"
