#!/usr/bin/env bash
#
# breakers.sh - the circuit breakers of a cluster's nodes
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
# Reports each node's circuit breakers, the limits Elasticsearch sets on the
# memory a request, field data, requests in flight and the node as a whole
# (the parent) may take: what each holds against its limit, and how often it
# tripped, refusing a request rather than running out of memory. It only
# reads: it changes nothing in the cluster.
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
#   up                  1 when Elasticsearch answers, else 0
#   tripped_total       trips of every breaker of every node, since each
#                       started (a counter)
#   max_used_pct        the fullest breaker, as a percentage of its limit
#   estimated_bytes     what a breaker holds, tagged node=<its name> and
#                       breaker=<the breaker>
#   limit_bytes         its limit, tagged the same
#   used_pct            estimated_bytes, as a percentage of the limit
#   tripped             its trips, since the node started (a counter)
#   breakers_not_shown  breakers past the first 600, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric tripped_total 14
#   metric max_used_pct 51.88
#   metric estimated_bytes 188663528 node=es95a breaker=parent
#   metric limit_bytes 382520524 node=es95a breaker=parent
#   metric used_pct 49.32 node=es95a breaker=parent
#   metric tripped 7 node=es95a breaker=request
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  tripped_total flat; the parent breaker's used_pct below 85.
#   Watch    the parent breaker's used_pct above 85: the node is short of
#            memory for what it is asked.
#   Act      tripped rising: requests refused (HTTP 429,
#            circuit_breaking_exception); on parent, the node's memory is too
#            small for its load; on fielddata, a text field aggregated.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Elasticsearch up or down; 1 if curl or jq is
#   missing, a setting is wrong, the login is refused, this user may not read
#   what the job needs, or the address is not Elasticsearch

set -u

job=breakers
# shellcheck source=/dev/null
. "$(dirname "$0")/_elasticsearch.sh"

first
need '/_nodes/stats/breaker?filter_path=nodes.*.name,nodes.*.breakers'
jq -r "$jqlib"'
    [.nodes[] | .name as $nm | .breakers | to_entries[] |
        {node: $nm, breaker: .key, est: (.value.estimated_size_in_bytes | n), lim: (.value.limit_size_in_bytes | n), tripped: (.value.tripped | n)}]
    | sort_by(.node, .breaker) |
    "metric tripped_total \([.[].tripped] | add // 0)",
    "metric max_used_pct \([.[] | pct(.est; .lim)] | max // 0)",
    (.[0:600][] | "node=\(.node | tag) breaker=\(.breaker | tag)" as $t |
        "metric estimated_bytes \(.est) \($t)",
        "metric limit_bytes \(.lim) \($t)",
        "metric used_pct \(pct(.est; .lim)) \($t)",
        "metric tripped \(.tripped) \($t)"),
    "metric breakers_not_shown \([length - 600, 0] | max)"
' "$work/body" || exit 1
exit 0
