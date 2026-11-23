#!/usr/bin/env bash
#
# ingest.sh - the ingest pipelines of a cluster
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
# Reports the documents the cluster's ingest pipelines have taken, failed and
# taken time over, every node together, and each pipeline that has run, those
# that failed most first: its documents, its failures and their share, and its
# average time. It only reads: it changes nothing in the cluster.
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
#   up                   1 when Elasticsearch answers, else 0
#   count                documents through any pipeline, every node (a
#                        counter)
#   failed               of those, failed (a counter)
#   time_ms              time spent in pipelines (a counter)
#   current              documents in a pipeline now
#   failed_pct           failed, as a percentage of count
#   pipelines            pipelines that have run
#   pipeline_count       a pipeline's documents, tagged pipeline=<its name> (a
#                        counter)
#   pipeline_failed      its failures (a counter)
#   pipeline_failed_pct  its failures, as a percentage of its documents
#   pipeline_time_ms     its time (a counter)
#   pipeline_avg_ms      its average time a document
#   pipelines_not_shown  pipelines past the first 100, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric count 7
#   metric failed 3
#   metric failed_pct 42.86
#   metric pipeline_count 6 pipeline=parse
#   metric pipeline_failed 3 pipeline=parse
#   metric pipeline_failed_pct 50 pipeline=parse
#   metric pipeline_avg_ms 17 pipeline=parse
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  failed flat.
#   Watch    pipeline_avg_ms rising: a pipeline slows every write through it.
#   Act      pipeline_failed rising: documents refused, or indexed with an
#            error (a grok pattern that no longer matches, a field of a type
#            the pipeline did not expect).
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Elasticsearch up or down; 1 if curl or jq is
#   missing, a setting is wrong, the login is refused, this user may not read
#   what the job needs, or the address is not Elasticsearch

set -u

job=ingest
# shellcheck source=/dev/null
. "$(dirname "$0")/_elasticsearch.sh"

first
need '/_nodes/stats/ingest?filter_path=nodes.*.ingest.total,nodes.*.ingest.pipelines.*.count,nodes.*.ingest.pipelines.*.failed,nodes.*.ingest.pipelines.*.time_in_millis,nodes.*.ingest.pipelines.*.current'
jq -r "$jqlib"'
    [.nodes[]?.ingest] as $i |
    ([$i[].total.count | n] | add // 0) as $c | ([$i[].total.failed | n] | add // 0) as $f |
    "metric count \($c)",
    "metric failed \($f)",
    "metric time_ms \([$i[].total.time_in_millis | n] | add // 0)",
    "metric current \([$i[].total.current | n] | add // 0)",
    "metric failed_pct \(pct($f; $c))",
    ([$i[].pipelines // {} | to_entries[]] | group_by(.key) |
        map({name: .[0].key, count: (map(.value.count | n) | add), failed: (map(.value.failed | n) | add), time: (map(.value.time_in_millis | n) | add)})
        | map(select(.count > 0 or .failed > 0)) | sort_by(-.failed, -.count, .name) |
        "metric pipelines \(length)",
        (.[0:100][] | "pipeline=\(.name | tag)" as $t |
            "metric pipeline_count \(.count) \($t)",
            "metric pipeline_failed \(.failed) \($t)",
            "metric pipeline_failed_pct \(pct(.failed; .count)) \($t)",
            "metric pipeline_time_ms \(.time) \($t)",
            "metric pipeline_avg_ms \(if .count > 0 then (.time / .count | r2) else 0 end) \($t)"),
        "metric pipelines_not_shown \([length - 100, 0] | max)")
' "$work/body" || exit 1
exit 0
