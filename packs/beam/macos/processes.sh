#!/usr/bin/env bash
#
# processes.sh - inside each Erlang VM: the longest mailboxes, the processes
# holding the most memory, the busiest
#
# Reads every process of each node in BEAM_DIST (<name>=<node> separated by
# ;) with its cookie (BEAM_COOKIE, a secret), by _beam.escript beside this
# script, with Erlang's escript (BEAM_ERLANG, where Erlang is, else the
# PATH's): its mailbox, memory and reductions, one process at a time. Past
# 20,000 processes, the first 20,000. Each process is named by its
# registered name, else by what it runs (a gen_server's module).
#
# WARNING: a node's cookie lets whoever holds it run anything on that node.
# This pack never changes anything: it only reads, and _beam.escript lists
# every call it makes. Give Vigil the cookie only if you accept that.
#
# Metrics:
#   nodes                     the nodes named in BEAM_DIST
#   up                        1 when the node answers, else 0, tagged
#                             node=<its name> and source=dist
#   processes_read            the processes read
#   processes_not_read        past 20,000, the processes left out
#   mailbox_messages          messages waiting, in every mailbox read
#   mailboxes_over_1000       processes with more than 1,000 waiting
#   mailbox                   messages waiting for one of the ten longest
#                             mailboxes, tagged node=<its name>,
#                             source=dist and process=<its name>
#   process_memory_bytes      memory of one of the ten largest processes
#                             (its heap, stack and mailbox), tagged the same
#   process_reductions_count  work done by one of the ten busiest, since it
#                             started (a running total), tagged the same
#
# Example output:
#   metric nodes 1
#   metric up 1 node=n28 source=dist
#   metric processes_read 50 node=n28 source=dist
#   metric processes_not_read 0 node=n28 source=dist
#   metric mailbox_messages 0 node=n28 source=dist
#   metric mailboxes_over_1000 0 node=n28 source=dist
#   metric process_memory_bytes 230496 node=n28 source=dist process=code_server
#   metric process_memory_bytes 34528 node=n28 source=dist process=application_controller
#   metric process_reductions_count 121107 node=n28 source=dist process=code_server
#
# Reading the results (starting points: tune them to the node):
#   Healthy  mailbox_messages near 0; mailboxes_over_1000 0; the largest
#            processes the same ones, at about the same size, run to run.
#   Watch    a mailbox growing run after run: that process takes messages
#            in faster than it handles them; one process_memory_bytes
#            climbing: it holds on to state, or to large binaries.
#   Act      mailboxes_over_1000 above 0 and rising: a process is falling
#            behind, and its memory grows with its mailbox until the VM
#            runs out; the busiest is the same process every run, far ahead
#            of the rest: a hot spot.
#
# Requires: bash; Erlang/OTP 25 or later (escript)
# Exit code: 0 on success, nodes up or down, or none named; 1 if escript is
#   missing, BEAM_DIST or BEAM_COOKIE is wrong, or a node refused the cookie
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

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
    echo 'processes: escript not found: BEAM_DIST is read with Erlang/OTP 25 or later (BEAM_ERLANG, where Erlang is, or escript on the PATH)' >&2
    exit 1
}

# A home of this run's own: Erlang writes a cookie file into its home when
# it has none, and never into Vigil's.
home=$(mktemp -d "${TMPDIR:-/tmp}/vigil-beam.XXXXXX") || exit 1
HOME=$home "$escript" "$here/_beam.escript" processes
rc=$?
rm -rf "$home"
exit $rc
