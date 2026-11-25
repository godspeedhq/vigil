#!/usr/bin/env bash
#
# datasources.sh - does every Grafana data source answer
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
# Lists Grafana's data sources and asks Grafana to check each one, as the Test
# button on its settings page does: Grafana makes one small query to it and
# says whether it answered. A data source that does not answer is a dashboard
# that shows nothing and an alert rule that cannot fire. It needs a token: a
# Viewer's is enough, and can change nothing. It only reads: every request is
# a GET, and it changes nothing.
#
# Reads GRAFANA_URL (default http://localhost:3000): /api/datasources and, for
# each of the first 20 by name, /api/datasources/uid/<uid>/health, with
# GRAFANA_TOKEN (or GRAFANA_USER and GRAFANA_PASSWORD).
# What the scripts share is in _grafana.sh, beside this one.
#
# Metrics:
#   up                     1 when Grafana answered, else 0
#   login_ok               1 when the token (or the user) may list the data
#                          sources; 0 when there is none, or it is refused
#                          (and nothing more is read)
#   datasource_ok          1 when the data source answered Grafana's check,
#                          else 0; tagged name=<its name> and type=<its kind>
#   datasources            data sources configured
#   datasources_failing    of those checked, the ones that did not answer
#   datasources_not_shown  data sources past the first 20, not checked
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric login_ok 1
#   metric datasource_ok 0 name=Dead type=prometheus
#   metric datasource_ok 1 name=Loki type=loki
#   metric datasource_ok 1 name=Prometheus type=prometheus
#   metric datasource_ok 1 name=Tempo type=tempo
#   metric datasources 4
#   metric datasources_failing 1
#   metric datasources_not_shown 0
#
# Reading the results (starting points: tune them to your own):
#   Healthy  login_ok 1; datasources_failing 0.
#   Watch    datasources_not_shown above 0: only the first 20 by name are
#            checked.
#   Act      datasources_failing above 0: datasource_ok 0 names it. Its
#            dashboards are empty and the alert rules that read it error (the
#            alerting job) until it answers again; login_ok 0: the token is
#            missing, expired or revoked, and this job sees nothing.
#
# Requires: bash, curl, jq
# Exit code: 0, whatever it reads, when Grafana does not answer (up 0), and
#   when there is no login or it is refused (login_ok 0); 1 when it answers
#   wrong, or curl or jq is missing

set -u

job=datasources
# shellcheck source=/dev/null
. "$(dirname "$0")/_grafana.sh"
needs curl jq

# The data sources, and what each answers when asked for its health: only
# with a login (GRAFANA_TOKEN, or GRAFANA_USER and GRAFANA_PASSWORD).
if [ -z "${GRAFANA_TOKEN-}" ] && [ -z "${GRAFANA_USER-}" ]; then
    echo "metric login_ok 0"
    echo "$job: no login: this job needs a Viewer's token (secret = GRAFANA_TOKEN=secret:GRAFANA_TOKEN; packs/grafana/README.md)" >&2
    exit 0
fi
get '/api/datasources' list
case $? in
    0) echo "metric up 1"; echo "metric login_ok 1" ;;
    2 | 5) echo "metric up 0"; exit 0 ;;
    4) echo "metric up 1"; echo "metric login_ok 0"; exit 0 ;;
    *) echo "metric up 0"; exit 1 ;;
esac
jq -r 'sort_by(.name) | .[] | [.uid, .type, .name] | @tsv' "$work/list" > "$work/ds" || { echo "$job: /api/datasources did not answer with a list" >&2; exit 1; }
total=$(grep -c . "$work/ds")
shown=0 failing=0
while IFS=$'\t' read -r uid type name; do
    [ "$shown" -lt 20 ] || break
    shown=$((shown + 1))
    code=$(login | curl -sS -g -m 20 -K - -o "$work/health" -w '%{http_code}' "$url/api/datasources/uid/$(printf '%s' "$uid" | jq -sRr @uri)/health" 2> /dev/null)
    ok=0
    [ "$code" = 200 ] && [ "$(jq -r '.status // empty' "$work/health" 2> /dev/null)" = OK ] && ok=1
    [ "$ok" = 1 ] || failing=$((failing + 1))
    echo "metric datasource_ok $ok name=$(tag "$name") type=$(tag "$type")"
done < "$work/ds"
echo "metric datasources $total"
echo "metric datasources_failing $failing"
echo "metric datasources_not_shown $((total - shown))"
exit 0
