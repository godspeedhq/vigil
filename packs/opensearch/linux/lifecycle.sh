#!/usr/bin/env bash
#
# lifecycle.sh - OpenSearch's Index State Management and snapshot management
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
# Reports OpenSearch's Index State Management (ISM): the indices it manages
# and in which state, those whose action failed (with the action and
# OpenSearch's message) and those it no longer runs. Then snapshot management:
# each policy, whether it is on, its last snapshot's state and age, whether it
# is failing and why, and its next run. Snapshot management skips every run
# while the cluster is red, so a red cluster soon shows here too. It only
# reads: it changes nothing in the cluster.
#
# Reads OpenSearch at OPENSEARCH_URL (default https://localhost:9200), as
# OPENSEARCH_USER with the password in OPENSEARCH_PASSWORD (a secret), with
# curl and jq. The login goes to curl on its standard input, never on a
# command line.
# Over https, the certificate is checked against OPENSEARCH_CACERT, a CA file,
# when it is set, else the system's CAs. What the scripts share is in
# _opensearch.sh, beside this one.
#
# Metrics:
#   up                   1 when OpenSearch answers, else 0
#   ism_managed          indices ISM manages
#   ism_failed           of those, whose action failed
#   ism_disabled         whose policy ISM no longer runs (it stops after an
#                        action fails for good)
#   ism_in_state         indices in a state of their policy, tagged state=<its
#                        name>
#   ism_failure          always 1, for each index whose action failed, tagged
#                        index, policy, action=<it> and reason=<OpenSearch's
#                        message> (the first 100)
#   ism_retries          times its action was retried, tagged index
#   ism_not_shown        indices past the first 1000, left out
#   sm_policies          snapshot management policies
#   sm_enabled           of those, on
#   sm_last_status       a policy's last snapshot: 0 SUCCESS, 1 IN_PROGRESS or
#                        RETRYING, 2 TIME_LIMIT_EXCEEDED, 3 FAILED, 4 none
#                        yet; tagged policy=<its name> and status=<it>
#   sm_failing           1 when its last snapshot failed, tagged policy and
#                        reason=<why, or not_given when OpenSearch does not
#                        say>
#   sm_last_age_seconds  since its last snapshot ended (or began), tagged
#                        policy
#   sm_next_seconds      until its next snapshot, tagged policy
#   sm_deletion_failing  1 when its last deletion of old snapshots failed,
#                        tagged policy
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric ism_managed 1
#   metric ism_failed 1
#   metric ism_failure 1 index=ism-broken policy=rollover-broken action=rollover reason=Missing_rollover_alias_index_setting__index_ism-broken_
#   metric sm_last_status 0 policy=nightly-ok status=SUCCESS
#   metric sm_last_status 3 policy=nightly-ro status=FAILED
#   metric sm_failing 1 policy=nightly-ro reason=not_given
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  ism_failed 0; every sm_last_status 0, sm_failing 0.
#   Watch    ism_disabled above 0: ISM gave up on those indices;
#            sm_last_age_seconds past the policy's schedule.
#   Act      ism_failed above 0: indices not rolled over or deleted, disks
#            fill (the reason says why); sm_failing 1: no new snapshots (the
#            reason says why); sm_last_status 4 for long on a red cluster:
#            snapshot management skips every run until it is green or yellow.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, OpenSearch up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, this user may not read what the
#   job needs, or the address is not OpenSearch

set -u

job=lifecycle
# shellcheck source=/dev/null
. "$(dirname "$0")/_opensearch.sh"

first
get '/_plugins/_ism/explain?size=1000&filter_path=total_managed_indices,*.index,*.policy_id,*.enabled,*.state.name,*.action.name,*.action.failed,*.action.consumed_retries,*.step.name,*.step.step_status,*.retry_info.failed,*.info.message'
rc=$?
case $rc in
    0) jq -r "$jqlib"'
        (.total_managed_indices | n) as $total |
        [to_entries[] | select(.key != "total_managed_indices") | .value + {index: (.value.index // .key)}] | sort_by(.index) |
        "metric ism_managed \($total)",
        "metric ism_failed \([.[] | select(.action.failed == true or .step.step_status == "failed")] | length)",
        "metric ism_disabled \([.[] | select(.enabled == false)] | length)",
        (group_by(.state.name // "none")[] | "metric ism_in_state \(length) state=\(.[0].state.name // "none" | tag)"),
        ([.[] | select(.action.failed == true or .step.step_status == "failed")] | .[0:100][] | "index=\(.index | tag)" as $t |
            "metric ism_failure 1 \($t) policy=\(.policy_id | tag) action=\(.action.name // .step.name // "" | tag) reason=\(.info.message // "" | tag)",
            "metric ism_retries \(.action.consumed_retries | n) \($t)"),
        "metric ism_not_shown \([$total - length, 0] | max)"
    ' "$work/body" || exit 1 ;;
    3) ;;
    *) why "$rc" '/_plugins/_ism/explain' ;;
esac
get '/_plugins/_sm/policies/*/_explain'
rc=$?
case $rc in
    0) jq -r --argjson now "$now" "$jqlib"'
        def scode: {"SUCCESS": 0, "IN_PROGRESS": 1, "RETRYING": 1, "TIME_LIMIT_EXCEEDED": 2, "FAILED": 3}[. // ""] // 4;
        [.policies[]?] | sort_by(.name) |
        "metric sm_policies \(length)",
        "metric sm_enabled \([.[] | select(.enabled == true)] | length)",
        (.[] | "policy=\(.name | tag)" as $t | .creation.latest_execution as $l |
            "metric sm_last_status \($l.status | scode) \($t) status=\($l.status // "none" | tag)",
            "metric sm_failing \(if $l.status == "FAILED" then 1 else 0 end) \($t) reason=\(if $l.status == "FAILED" then ($l.info.cause // $l.info.message // "not_given" | tag) else "none" end)",
            (if $l.end_time or $l.start_time then "metric sm_last_age_seconds \([$now - (($l.end_time // $l.start_time) / 1000) | floor, 0] | max) \($t)" else empty end),
            (if .creation.trigger.time then "metric sm_next_seconds \([(.creation.trigger.time / 1000) - $now | floor, 0] | max) \($t)" else empty end),
            (if .deletion then "metric sm_deletion_failing \(if .deletion.latest_execution.status == "FAILED" then 1 else 0 end) \($t)" else empty end))
    ' "$work/body" || exit 1 ;;
    3) ;;
    *) why "$rc" '/_plugins/_sm/policies' ;;
esac
exit 0
