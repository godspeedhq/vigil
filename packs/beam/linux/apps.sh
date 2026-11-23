#!/usr/bin/env bash
#
# apps.sh - the applications each Erlang VM runs, and their versions
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
# Reads the applications of each node in BEAM_DIST (<name>=<node> separated
# by ;) with its cookie (BEAM_COOKIE, a secret), by _beam.escript beside
# this script, with Erlang's escript (BEAM_ERLANG, where Erlang is, else the
# PATH's): what application:which_applications() says.
#
# WARNING: a node's cookie lets whoever holds it run anything on that node.
# This pack never changes anything: it only reads, and _beam.escript lists
# every call it makes. Give Vigil the cookie only if you accept that.
#
# Metrics:
#   nodes           the nodes named in BEAM_DIST
#   up              1 when the node answers, else 0, tagged node=<its name>
#                   and source=dist
#   apps            the applications it runs
#   app             always 1, tagged node=<its name>, source=dist,
#                   app=<the application> and version=<its version>
#   apps_not_shown  past the first 100, how many were left out
#
# Example output:
#   metric nodes 1
#   metric up 1 node=n27 source=dist
#   metric apps 2 node=n27 source=dist
#   metric app 1 node=n27 source=dist app=stdlib version=6.2.2.5
#   metric app 1 node=n27 source=dist app=kernel version=10.2.7.5
#   metric apps_not_shown 0 node=n27 source=dist
#
# Reading the results (starting points: tune them to the node):
#   Healthy  apps the same, run to run, with the versions you deployed.
#   Watch    a version you did not deploy: something was upgraded in
#            place, or a node runs an older release than the others.
#   Act      apps lower than usual: an application stopped (one that is
#            not permanent stops alone, and the node carries on without it).
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
    echo 'apps: escript not found: BEAM_DIST is read with Erlang/OTP 25 or later (BEAM_ERLANG, where Erlang is, or escript on the PATH)' >&2
    exit 1
}

# A home of this run's own: Erlang writes a cookie file into its home when
# it has none, and never into Vigil's.
home=$(mktemp -d "${TMPDIR:-/tmp}/vigil-beam.XXXXXX") || exit 1
HOME=$home "$escript" "$here/_beam.escript" apps
rc=$?
rm -rf "$home"
exit $rc
