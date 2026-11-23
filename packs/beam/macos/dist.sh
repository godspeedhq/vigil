#!/usr/bin/env bash
#
# dist.sh - each Erlang VM's peers: the nodes it is connected to
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
# Reads the connections of each node in BEAM_DIST (<name>=<node> separated
# by ;) with its cookie (BEAM_COOKIE, a secret), by _beam.escript beside
# this script, with Erlang's escript (BEAM_ERLANG, where Erlang is, else the
# PATH's): its peers in the cluster, the hidden ones (tools; Vigil's own
# leaves no trace), and the bytes waiting to go to each.
#
# WARNING: a node's cookie lets whoever holds it run anything on that node.
# This pack never changes anything: it only reads, and _beam.escript lists
# every call it makes. Give Vigil the cookie only if you accept that.
#
# Metrics:
#   nodes             the nodes named in BEAM_DIST
#   up                1 when the node answers, else 0, tagged node=<its
#                     name> and source=dist
#   peers             the nodes it is connected to, as a cluster
#   hidden_peers      hidden nodes connected to it (remote shells, tools)
#   peer              always 1, tagged node=<its name>, source=dist,
#                     peer=<the peer's node> and hidden=<true or false>
#   peer_queue_bytes  bytes waiting to be sent to that peer, tagged the
#                     same (TCP distribution; not over TLS)
#   peers_not_shown   past the first 100 peers, how many were left out
#   busy_limit_bytes  the queue at which a peer's sender is made to wait
#                     (+zdbbl)
#
# Example output:
#   metric nodes 4
#   metric up 1 node=t28 source=dist
#   metric peers 0 node=t28 source=dist
#   metric hidden_peers 0 node=t28 source=dist
#   metric peers_not_shown 0 node=t28 source=dist
#   metric busy_limit_bytes 1048576 node=t28 source=dist
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  peers as many as the cluster's other nodes; peer_queue_bytes
#            near 0.
#   Watch    hidden_peers you do not expect: someone has a remote shell
#            on the node, or a tool holds the cookie.
#   Act      peers lower than the cluster's other nodes: a node is down or
#            cut off (a partition); peer_queue_bytes near busy_limit_bytes:
#            the link to that peer is the bottleneck, and its senders wait.
#
# Requires: bash; Erlang/OTP 25 or later (escript)
# Exit code: 0 on success, nodes up or down, or none named; 1 if escript is
#   missing, BEAM_DIST or BEAM_COOKIE is wrong, or a node refused the cookie

set -u

here=$(cd "$(dirname "$0")" && pwd)
n=$(printf '%s' "${BEAM_DIST-}" | tr ';' '\n' | grep -c '[^[:space:]]')
echo "metric nodes $n"
[ "$n" -gt 0 ] || exit 0

# Erlang's escript: BEAM_ERLANG's (where Erlang is, or its bin), else the
# PATH's.
escript=''
for d in "${BEAM_ERLANG:+$BEAM_ERLANG/bin}" "${BEAM_ERLANG-}"; do
    [ -n "$d" ] && [ -x "$d/escript" ] && { escript=$d/escript; break; }
done
[ -n "$escript" ] || escript=$(command -v escript 2> /dev/null) || {
    echo 'dist: escript not found: BEAM_DIST is read with Erlang/OTP 25 or later (BEAM_ERLANG, where Erlang is, or escript on the PATH)' >&2
    exit 1
}

# A home of this run's own: Erlang writes a cookie file into its home when
# it has none, and never into Vigil's.
home=$(mktemp -d "${TMPDIR:-/tmp}/vigil-beam.XXXXXX") || exit 1
HOME=$home "$escript" "$here/_beam.escript" dist
rc=$?
rm -rf "$home"
exit $rc
