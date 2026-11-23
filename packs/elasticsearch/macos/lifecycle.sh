#!/usr/bin/env bash
#
# lifecycle.sh - Elasticsearch's lifecycles: ILM, SLM and data streams'
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
# Reports Elasticsearch's index lifecycle management (ILM): whether it runs,
# the indices it manages and in which phase, those whose step failed (with the
# step and Elasticsearch's reason) and those on one step for more than a day.
# Then snapshot lifecycle management (SLM): whether it runs, and each policy's
# last success and failure, whether it is failing now and why, its snapshots
# taken and failed, and its next run. Then the data stream lifecycle: the data
# streams it manages, and their backing indices in error. It only reads: it
# changes nothing in the cluster.
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
#   up                            1 when Elasticsearch answers, else 0
#   ilm_running                   1 when ILM runs, tagged mode=<RUNNING,
#                                 STOPPING or STOPPED>
#   ilm_managed                   indices ILM manages
#   ilm_errors                    of those, with a failed step
#   ilm_stuck                     on one step (not the wait for a rollover)
#                                 for more than a day
#   ilm_in_phase                  indices in a phase, tagged phase=<hot, warm,
#                                 cold, frozen or delete>
#   ilm_error                     always 1, for each index whose step failed,
#                                 tagged index, policy, step=<the step that
#                                 failed> and reason=<Elasticsearch's reason>
#                                 (the first 100)
#   ilm_error_retries             times its step was retried, tagged index
#   ilm_step_age_seconds          how long a stuck index has been on its step,
#                                 tagged index and step (the 20 longest)
#   slm_running                   1 when SLM runs, tagged mode=<it>
#   slm_policies                  SLM policies
#   slm_failing                   1 when a policy's last run failed, tagged
#                                 policy=<its name> and reason=<why>
#   slm_last_success_age_seconds  since its last snapshot that succeeded,
#                                 tagged policy
#   slm_last_failure_age_seconds  since its last failure, tagged policy
#   slm_taken                     snapshots it has taken (a counter), tagged
#                                 policy
#   slm_failed                    snapshots it failed to take (a counter),
#                                 tagged policy
#   slm_next_seconds              until its next run, tagged policy
#   dlm_data_streams              data streams the data stream lifecycle
#                                 manages (8.11 and later)
#   dlm_backing_indices           their backing indices
#   dlm_errors                    of those, in error
#   dlm_error                     a data stream's backing indices in error,
#                                 tagged data_stream=<its name>
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric ilm_running 1 mode=RUNNING
#   metric ilm_errors 1
#   metric ilm_error 1 index=ilm-broken policy=rollover-broken step=check-rollover-ready reason=setting__index.lifecycle.rollover_alias__for_index__ilm-broken__is_empty_or_not_defined
#   metric ilm_error_retries 5 index=ilm-broken
#   metric slm_failing 0 policy=nightly-ok reason=none
#   metric slm_last_success_age_seconds 45 policy=nightly-ok
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  ilm_running and slm_running 1; ilm_errors 0; slm_failing 0
#            everywhere; dlm_errors 0.
#   Watch    ilm_stuck above 0: an index waits on a step (a shrink with no
#            node to go to, a replica that will not allocate);
#            slm_last_success_age_seconds past the policy's schedule.
#   Act      ilm_errors above 0: indices not rolled over, not deleted (disks
#            fill); slm_failing 1: no new snapshots (the reason says why);
#            ilm_running 0 left after maintenance.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Elasticsearch up or down; 1 if curl or jq is
#   missing, a setting is wrong, the login is refused, this user may not read
#   what the job needs, or the address is not Elasticsearch

set -u

job=lifecycle
# shellcheck source=/dev/null
. "$(dirname "$0")/_elasticsearch.sh"

first
get '/_ilm/status'
rc=$?
case $rc in
    0) jq -r "$jqlib"'"metric ilm_running \(if .operation_mode == "RUNNING" then 1 else 0 end) mode=\(.operation_mode | tag)"' "$work/body" || exit 1 ;;
    3) ;;
    *) why "$rc" '/_ilm/status' ;;
esac
get '/*,.*/_ilm/explain?only_managed=true&filter_path=indices.*.index,indices.*.policy,indices.*.phase,indices.*.action,indices.*.step,indices.*.failed_step,indices.*.step_info.reason,indices.*.step_info.type,indices.*.failed_step_retry_count,indices.*.step_time_millis'
rc=$?
case $rc in
    0) jq -r --argjson now "$now" "$jqlib"'
        [.indices[]?] |
        "metric ilm_managed \(length)",
        "metric ilm_errors \([.[] | select(.step == "ERROR")] | length)",
        ([.[] | select(.step != "ERROR" and .step != "complete" and .step != "check-rollover-ready" and .step_time_millis != null)
            | . + {age: ($now - (.step_time_millis / 1000) | floor)} | select(.age > 86400)] | sort_by(-.age, .index) |
            "metric ilm_stuck \(length)",
            (.[0:20][] | "metric ilm_step_age_seconds \(.age) index=\(.index | tag) step=\(.step | tag)")),
        (group_by(.phase // "none")[] | "metric ilm_in_phase \(length) phase=\(.[0].phase // "none" | tag)"),
        ([.[] | select(.step == "ERROR")] | sort_by(.index) | .[0:100][] | "index=\(.index | tag)" as $t |
            "metric ilm_error 1 \($t) policy=\(.policy | tag) step=\(.failed_step | tag) reason=\(.step_info.reason // .step_info.type // "" | tag)",
            "metric ilm_error_retries \(.failed_step_retry_count | n) \($t)")
    ' "$work/body" || exit 1 ;;
    3) ;;
    *) why "$rc" '/_ilm/explain' ;;
esac
get '/_slm/status'
rc=$?
case $rc in
    0) jq -r "$jqlib"'"metric slm_running \(if .operation_mode == "RUNNING" then 1 else 0 end) mode=\(.operation_mode | tag)"' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_slm/status' ;;
esac
get '/_slm/policy'
rc=$?
case $rc in
    0) jq -r --argjson now "$now" "$jqlib"'
        "metric slm_policies \(length)",
        (to_entries | sort_by(.key)[] | "policy=\(.key | tag)" as $t | .value |
            (.last_success.time // .last_success.start_time) as $ok | .last_failure.time as $bad |
            "metric slm_failing \(if $bad != null and ($ok == null or $bad > $ok) then 1 else 0 end) \($t) reason=\(if $bad != null and ($ok == null or $bad > $ok) then (.last_failure.details // "" | (fromjson? | .reason) // . | tag) else "none" end)",
            (if $ok then "metric slm_last_success_age_seconds \([$now - $ok / 1000 | floor, 0] | max) \($t)" else empty end),
            (if $bad then "metric slm_last_failure_age_seconds \([$now - $bad / 1000 | floor, 0] | max) \($t)" else empty end),
            "metric slm_taken \(.stats.snapshots_taken | n) \($t)",
            "metric slm_failed \(.stats.snapshots_failed | n) \($t)",
            (if .next_execution_millis then "metric slm_next_seconds \([.next_execution_millis / 1000 - $now | floor, 0] | max) \($t)" else empty end))
    ' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_slm/policy' ;;
esac
get '/_lifecycle/stats'
rc=$?
case $rc in
    0) jq -r "$jqlib"'
        "metric dlm_data_streams \(.data_stream_count | n)",
        "metric dlm_backing_indices \([.data_streams[]?.backing_indices_in_total | n] | add // 0)",
        "metric dlm_errors \([.data_streams[]?.backing_indices_in_error | n] | add // 0)",
        ([.data_streams[]? | select((.backing_indices_in_error | n) > 0)] | sort_by(.name)[] | "metric dlm_error \(.backing_indices_in_error) data_stream=\(.name | tag)")
    ' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_lifecycle/stats' ;;
esac
exit 0
