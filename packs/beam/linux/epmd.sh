#!/usr/bin/env bash
#
# epmd.sh - the Erlang nodes epmd knows, on each machine named
#
# Asks epmd, the Erlang Port Mapper Daemon, which nodes it has: the names
# request of its protocol (what epmd -names sends), over TCP from bash
# itself. It needs no cookie and changes nothing. The machines are in
# BEAM_EPMD, host or host:port separated by spaces or ;, set by the job;
# empty, this machine's (127.0.0.1:4369).
#
# Metrics:
#   epmd_up          1 when epmd answers, else 0, tagged host=<host:port>
#   nodes            the nodes it has, tagged host=<the same>
#   node             always 1, tagged host=<the same>, name=<the node's
#                    name> and port=<its distribution port>
#   nodes_not_shown  past the first 100 nodes of a host, how many were left
#                    out, tagged host=<the same>
#
# Example output:
#   metric epmd_up 1 host=127.0.0.1:4369
#   metric nodes 2 host=127.0.0.1:4369
#   metric node 1 host=127.0.0.1:4369 name=rabbit port=25672
#   metric node 1 host=127.0.0.1:4369 name=rabbitmqcli-512-rabbit port=36093
#   metric nodes_not_shown 0 host=127.0.0.1:4369
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  epmd_up 1; nodes as many as you run, each with its usual name.
#   Watch    a node with a name you do not know: something else on the
#            machine runs Erlang distribution (rabbitmqcli-... and
#            vigil_... nodes come and go: tools connecting).
#   Act      epmd_up 0 where nodes run: no node can find another, so a
#            cluster cannot form again; a node you run missing from it: it
#            stopped, or cannot register.
#
# Requires: bash (its /dev/tcp)
# Exit code: 0 on success, epmd up or down; 1 if BEAM_EPMD is wrong
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

hosts=$(printf '%s' "${BEAM_EPMD-}" | tr ';,' '  ')
[ -n "${hosts// /}" ] || hosts=127.0.0.1

work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-beam.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# epmd's names request: a length of 1 (two bytes) and 'n' (110). It
# answers its own port (four bytes), then a line a node: "name <name> at
# port <port>". Five seconds at most, a host that does not answer too.
names() {
    (exec 3<> "/dev/tcp/$1/$2" && printf '\000\001n' >&3 && cat <&3 > "$work/answer") 2> /dev/null &
    local job=$! i=0
    while kill -0 "$job" 2> /dev/null && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    kill "$job" 2> /dev/null && return 1
    wait "$job"
}

for h in $hosts; do
    case $h in
        \[*\]:*) host=${h%]:*} host=${host#[} port=${h##*]:} ;;
        *:*:*) host=$h port=4369 ;;
        *:*) host=${h%:*} port=${h##*:} ;;
        *) host=$h port=4369 ;;
    esac
    case $port in '' | *[!0-9]*) echo "epmd: BEAM_EPMD: '$h' is not host or host:port" >&2; exit 1 ;; esac
    tag="host=$host:$port"
    rm -f "$work/answer"
    if ! names "$host" "$port" || [ "$(wc -c < "$work/answer" 2> /dev/null || echo 0)" -lt 4 ]; then
        echo "metric epmd_up 0 $tag"
        continue
    fi
    echo "metric epmd_up 1 $tag"
    tail -c +5 "$work/answer" | awk -v tag="$tag" '
        /^name [^ ]+ at port [0-9]+/ {
            n++
            if (n <= 100) { name = $2; gsub(/[^A-Za-z0-9@._-]/, "_", name); line[n] = "metric node 1 " tag " name=" name " port=" $5 }
        }
        END {
            print "metric nodes " n + 0 " " tag
            for (i = 1; i <= n && i <= 100; i++) print line[i]
            print "metric nodes_not_shown " (n > 100 ? n - 100 : 0) " " tag
        }'
done
exit 0
