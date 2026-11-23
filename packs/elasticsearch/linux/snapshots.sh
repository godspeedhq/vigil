#!/usr/bin/env bash
#
# snapshots.sh - the snapshots in a cluster's repositories
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
# Reports the cluster's snapshot repositories and, for each (the first 20, by
# name), its snapshots: how many, how many failed or partial, the last one's
# state, age, length and failed shards, and how long since the last that
# succeeded. Then the snapshots being taken now. A repository the cluster
# cannot read is reported so, not failed. It only reads: it changes nothing in
# the cluster.
#
# Reads Elasticsearch at ELASTICSEARCH_URL (default https://localhost:9200),
# as ELASTICSEARCH_USER with the password in ELASTICSEARCH_PASSWORD (a
# secret), or with an API key in ELASTICSEARCH_API_KEY (a secret: the encoded
# form Elasticsearch gives), with curl and jq. The login goes to curl on its
# standard input, never on a command line.
# Over https, the certificate is checked against ELASTICSEARCH_CACERT, a CA
# file, when it is set, else the system's CAs. What the scripts share is in
# _elasticsearch.sh, beside this one.
#
# Metrics:
#   up                        1 when Elasticsearch answers, else 0
#   repositories              snapshot repositories
#   running                   snapshots being taken now
#   readable                  1 when the cluster could list a repository,
#                             tagged repository=<its name>
#   snapshots                 its snapshots, tagged the same
#   failed                    of those, failed
#   partial                   partial: some shards missing
#   last_status               the last one's state: 0 SUCCESS, 1 IN_PROGRESS,
#                             2 PARTIAL, 3 FAILED, 4 other; tagged repository
#                             and status=<it>
#   last_age_seconds          since the last one ended (or started, while it
#                             runs)
#   last_duration_seconds     how long it took
#   last_failed_shards        its shards that failed
#   last_success_age_seconds  since the last that succeeded ended; absent when
#                             none has
#   repositories_not_shown    repositories past the first 20, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric repositories 2
#   metric snapshots 1 repository=backups
#   metric last_status 0 repository=backups status=SUCCESS
#   metric last_duration_seconds 4 repository=backups
#   metric last_success_age_seconds 157 repository=backups
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  last_status 0; last_success_age_seconds within your snapshot
#            schedule.
#   Watch    partial above 0; last_duration_seconds growing.
#   Act      last_success_age_seconds past your schedule, or absent: no good
#            backup; last_status 3; readable 0: the repository is gone or
#            broken.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Elasticsearch up or down; 1 if curl or jq is
#   missing, a setting is wrong, the login is refused, this user may not read
#   what the job needs, or the address is not Elasticsearch

set -u

job=snapshots
# shellcheck source=/dev/null
. "$(dirname "$0")/_elasticsearch.sh"

first
need '/_snapshot?filter_path=*.type'
cp "$work/body" "$work/repos"
get '/_snapshot/_status?filter_path=snapshots.snapshot'
rc=$?
case $rc in
    0) jq -r '"metric running \([.snapshots[]?] | length)"' "$work/body" || exit 1 ;;
    3) echo "metric running 0" ;;
    *) why "$rc" '/_snapshot/_status' ;;
esac
jq -r '"metric repositories \(keys | length)", "metric repositories_not_shown \([(keys | length) - 20, 0] | max)"' "$work/repos" || exit 1
jq -r 'keys | sort | .[0:20][]' "$work/repos" > "$work/names" || exit 1
while IFS= read -r repo; do
    enc=$(jq -rn --arg r "$repo" '$r | @uri')
    get "/_cat/snapshots/$enc?format=json&h=id,status,start_epoch,end_epoch,failed_shards,total_shards"
    rc=$?
    case $rc in
        0) ;;
        2 | 4 | 5) why "$rc" "/_cat/snapshots/$enc" ;;
        *) jq -rn --arg r "$repo" "$jqlib"'"metric readable 0 repository=\($r | tag)"'; continue ;;
    esac
    jq -r --arg repo "$repo" --argjson now "$now" "$jqlib"'
        def scode: {"SUCCESS": 0, "IN_PROGRESS": 1, "PARTIAL": 2, "FAILED": 3}[.] // 4;
        "repository=\($repo | tag)" as $t |
        map(. + {s: (.start_epoch | n), e: (.end_epoch | n)}) | sort_by(.s) |
        "metric readable 1 \($t)",
        "metric snapshots \(length) \($t)",
        "metric failed \([.[] | select(.status == "FAILED")] | length) \($t)",
        "metric partial \([.[] | select(.status == "PARTIAL")] | length) \($t)",
        (.[-1] // empty |
            "metric last_status \(.status | scode) \($t) status=\(.status | tag)",
            "metric last_age_seconds \(if .e > 0 then $now - .e else $now - .s end | if . < 0 then 0 else . end) \($t)",
            (if .e > 0 then "metric last_duration_seconds \(.e - .s) \($t)" else empty end),
            "metric last_failed_shards \(.failed_shards | n) \($t)"),
        ([.[] | select(.status == "SUCCESS")][-1] // empty | "metric last_success_age_seconds \([$now - .e, 0] | max) \($t)")
    ' "$work/body" || exit 1
done < "$work/names"
exit 0
