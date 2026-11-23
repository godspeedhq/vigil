#!/usr/bin/env bash
#
# tasks.sh - the tasks a cluster runs, and the cluster tasks waiting
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
# Reports the tasks running in the cluster, as OpenSearch lists them
# (searches, bulk writes, reindexing, updates and deletes by query, snapshots,
# force merges...): how many, the longest, those running past a minute, those
# cancelled but still running, and how many of each kind. Then the 20 longest,
# with how long each has run; for reindexing and by-query work, what it reads
# and writes (never a search's query). Then the cluster tasks waiting for the
# elected cluster manager, the oldest first. The task list itself, persistent
# tasks and a task's children are left out. It only reads: it changes nothing
# in the cluster.
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
#   up                 1 when OpenSearch answers, else 0
#   tasks              tasks running
#   longest_seconds    how long the longest has run
#   over_60s           tasks running for more than a minute
#   cancellable        tasks that may be cancelled
#   cancelled          tasks cancelled but still running
#   searches           searches running
#   action_tasks       tasks of a kind, tagged action=<it> (the 10 most)
#   running_seconds    how long a task has run, tagged action=<it>,
#                      node=<where it runs> and what=<for reindexing and
#                      by-query work, what it reads and writes; else none>
#   tasks_not_shown    tasks past the 20 longest, left out
#   pending            cluster tasks waiting for the cluster manager
#   pending_oldest_ms  how long the oldest has waited
#   pending_ms         how long one has waited, tagged priority=<it> and
#                      source=<what asked for it> (the 20 oldest)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric tasks 1
#   metric longest_seconds 46
#   metric action_tasks 1 action=indices:data/write/reindex
#   metric running_seconds 46 action=indices:data/write/reindex node=os310a what=reindex_from__logs-ok__to__logs-slow_
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  over_60s 0, but for reindexing, snapshots and force merges you
#            started; pending 0.
#   Watch    searches running for minutes: an expensive query (searches, and
#            the running_seconds of indices:data/read/search); cancelled above
#            0 for long.
#   Act      pending above 0 and pending_oldest_ms in seconds: the cluster
#            manager falls behind, and mappings, settings and shard moves
#            wait; a search running for many minutes, holding memory and
#            threads.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, OpenSearch up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, this user may not read what the
#   job needs, or the address is not OpenSearch

set -u

job=tasks
# shellcheck source=/dev/null
. "$(dirname "$0")/_opensearch.sh"

first
need '/_cat/nodes?format=json&full_id=true&h=id,name'
cp "$work/body" "$work/cat"
need '/_tasks?detailed=true&group_by=none&filter_path=tasks.action,tasks.node,tasks.running_time_in_nanos,tasks.cancellable,tasks.cancelled,tasks.description,tasks.parent_task_id'
jq -r --slurpfile cat "$work/cat" "$jqlib"'
    ($cat[0] | map({key: .id, value: .name}) | from_entries) as $nm |
    [.tasks[]? | select(.parent_task_id == null and (.action | startswith("cluster:monitor/tasks/lists") | not) and (.action | endswith("[c]") | not))
        | . + {s: ((.running_time_in_nanos | n) / 1e9 | floor)}] | sort_by(-.s, .action) |
    "metric tasks \(length)",
    "metric longest_seconds \(.[0].s // 0)",
    "metric over_60s \([.[] | select(.s > 60)] | length)",
    "metric cancellable \([.[] | select(.cancellable)] | length)",
    "metric cancelled \([.[] | select(.cancelled == true)] | length)",
    "metric searches \([.[] | select(.action | startswith("indices:data/read/search"))] | length)",
    (group_by(.action) | sort_by(-length, .[0].action) | .[0:10][] | "metric action_tasks \(length) action=\(.[0].action | tag)"),
    (.[0:20][] | "metric running_seconds \(.s) action=\(.action | tag) node=\($nm[.node] // .node | tag) what=\(if (.action | test("reindex|byquery")) then (.description // "" | tag) else "none" end)"),
    "metric tasks_not_shown \([length - 20, 0] | max)"
' "$work/body" || exit 1
need '/_cluster/pending_tasks'
jq -r "$jqlib"'
    [.tasks[]?] | sort_by(-(.time_in_queue_millis | n)) |
    "metric pending \(length)",
    "metric pending_oldest_ms \(.[0].time_in_queue_millis // 0 | n)",
    (.[0:20][] | "metric pending_ms \(.time_in_queue_millis | n) priority=\(.priority | tag) source=\(.source | tag)")
' "$work/body" || exit 1
exit 0
