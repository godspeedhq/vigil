#!/usr/bin/env bash
#
# tables.sh - inside each Erlang VM: its ETS tables, the largest
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
# Reads every ETS table of each node in BEAM_DIST (<name>=<node> separated by
# ;) with its cookie (BEAM_COOKIE, a secret), by _beam.escript beside this
# script, with Erlang's escript (BEAM_ERLANG, where Erlang is, else the
# PATH's): its size and memory, and the process that owns it.
#
# WARNING: a node's cookie lets whoever holds it run anything on that node.
# This pack never changes anything: it only reads, and _beam.escript lists
# every call it makes. Give Vigil the cookie only if you accept that.
#
# Metrics:
#   nodes               the nodes named in BEAM_DIST
#   up                  1 when the node answers, else 0, tagged node=<its
#                       name> and source=dist
#   tables              its ETS tables
#   objects             the objects in them all
#   memory_bytes        the memory they all hold
#   table_memory_bytes  memory one of the ten largest holds, tagged
#                       node=<its name>, source=dist, table=<its name,
#                       with (unnamed) when it is not a named table> and
#                       owner=<the process that owns it>
#   table_objects       objects one of the ten fullest holds, tagged the
#                       same
#
# Example output:
#   metric nodes 4
#   metric up 1 node=t28 source=dist
#   metric tables 22 node=t28 source=dist
#   metric objects 10963 node=t28 source=dist
#   metric memory_bytes 2620088 node=t28 source=dist
#   metric table_memory_bytes 2350152 node=t28 source=dist table=leaky_cache owner=trouble:cache/1
#   metric table_memory_bytes 139824 node=t28 source=dist table=code_server owner=code_server
#   metric table_objects 10480 node=t28 source=dist table=leaky_cache owner=trouble:cache/1
#   metric table_objects 396 node=t28 source=dist table=code_server owner=code_server
#
# Reading the results (starting points: tune them to the node):
#   Healthy  tables steady; the largest tables the same ones, at a size
#            your data explains.
#   Watch    one table_objects rising and never falling: a cache with no
#            eviction, or entries never deleted.
#   Act      memory_bytes a large share of beam.vm memory_bytes total and
#            climbing: a table will take the VM's memory; tables rising
#            run after run: tables made and never deleted (beam.vm ets_pct
#            shows how near the limit).
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
    echo 'tables: escript not found: BEAM_DIST is read with Erlang/OTP 25 or later (BEAM_ERLANG, where Erlang is, or escript on the PATH)' >&2
    exit 1
}

# A home of this run's own: Erlang writes a cookie file into its home when
# it has none, and never into Vigil's.
home=$(mktemp -d "${TMPDIR:-/tmp}/vigil-beam.XXXXXX") || exit 1
HOME=$home "$escript" "$here/_beam.escript" tables
rc=$?
rm -rf "$home"
exit $rc
