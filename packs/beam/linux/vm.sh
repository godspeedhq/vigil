#!/usr/bin/env bash
#
# vm.sh - what each Erlang VM says about itself: memory, limits, run queues
#
# Reads each node two ways, whichever is set on the job:
#   BEAM_PROMETHEUS  <name>=<url> separated by ;: a node's Prometheus page
#                    (erlang_vm_*, as prometheus.erl and RabbitMQ give it:
#                    RabbitMQ's is http://127.0.0.1:15692/metrics), with curl
#   BEAM_DIST        <name>=<node> separated by ;: the node itself, with its
#                    cookie (BEAM_COOKIE, a secret), by _beam.escript beside
#                    this script, with Erlang's escript (BEAM_ERLANG, where
#                    Erlang is, else the PATH's)
# The metrics are the same either way, tagged source=prometheus or
# source=dist. Prometheus gives no version or uptime; the cookie gives both.
#
# WARNING: a node's cookie lets whoever holds it run anything on that node.
# This pack never changes anything: it only reads, and _beam.escript lists
# every call it makes. Give Vigil the cookie only if you accept that.
#
# Metrics:
#   nodes                   the nodes named in BEAM_PROMETHEUS and BEAM_DIST
#   up                      1 when the node answers, else 0, tagged
#                           node=<its name> and source=<prometheus or dist>
#   version                 always 1, tagged the same, otp=<its release> and
#                           erts=<its runtime's version> (dist only)
#   memory_bytes            memory it has allocated, tagged the same and
#                           kind=<total, processes, system, atom, binary,
#                           code or ets>
#   processes               its processes (Erlang's, not the OS's)
#   process_limit           the most it may have (+P)
#   process_pct             processes, as a percentage of process_limit
#   ports                   its ports: sockets, files and drivers open
#   port_limit              the most it may have (+Q)
#   port_pct                ports, as a percentage of port_limit
#   atoms                   its atoms, which are never freed
#   atom_limit              the most it may have (+t): past it, the VM dies
#   atom_pct                atoms, as a percentage of atom_limit
#   ets_tables              its ETS tables
#   ets_limit               the most it may have
#   ets_pct                 ets_tables, as a percentage of ets_limit
#   schedulers_online       schedulers running Erlang code
#   run_queue               processes and ports ready to run, waiting for a
#                           scheduler
#   dirty_cpu_run_queue     work waiting for a dirty CPU scheduler (NIFs)
#   dirty_io_run_queue      work waiting for a dirty I/O scheduler (files)
#   reductions_count        reductions, its unit of work (a running total)
#   gcs_count               garbage collections (a running total)
#   gc_reclaimed_bytes      memory they reclaimed (a running total)
#   context_switches_count  process switches (a running total)
#   received_bytes          bytes its ports received (a running total)
#   sent_bytes              bytes its ports sent (a running total)
#   uptime_seconds          how long it has run (dist only)
#
# Example output:
#   metric nodes 1
#   metric up 1 node=rabbit source=prometheus
#   metric memory_bytes 69603512 node=rabbit source=prometheus kind=total
#   metric memory_bytes 15782680 node=rabbit source=prometheus kind=processes
#   metric memory_bytes 53820832 node=rabbit source=prometheus kind=system
#   metric memory_bytes 1179937 node=rabbit source=prometheus kind=atom
#   metric memory_bytes 250208 node=rabbit source=prometheus kind=binary
#   metric memory_bytes 25707942 node=rabbit source=prometheus kind=code
#   metric memory_bytes 3770728 node=rabbit source=prometheus kind=ets
#   metric processes 398 node=rabbit source=prometheus
#   metric process_limit 1048576 node=rabbit source=prometheus
#   metric process_pct 0.04 node=rabbit source=prometheus
#   metric atoms 36289 node=rabbit source=prometheus
#   metric atom_limit 5000000 node=rabbit source=prometheus
#   metric atom_pct 0.73 node=rabbit source=prometheus
#   metric run_queue 0 node=rabbit source=prometheus
#   metric reductions_count 43609426 node=rabbit source=prometheus
#
# Reading the results (starting points: tune them to the node):
#   Healthy  up 1; process_pct, port_pct, atom_pct and ets_pct low and
#            flat; run_queue near 0 most of the time; memory_bytes of kind
#            total steady once warmed up.
#   Watch    atom_pct rising and never falling: something makes atoms from
#            input (list_to_atom), and atoms are never freed; process_pct
#            or ets_pct climbing: a leak; run_queue above schedulers_online
#            for minutes: the VM is short of CPU; kind=binary climbing:
#            large binaries held on to (a process keeps a reference).
#   Act      up 0; atom_pct past 80: at 100 the VM dies; process_pct or
#            port_pct past 80: at 100 nothing new can start, connections
#            are refused; memory_bytes total near the machine's memory.
#
# Requires: bash; curl, for BEAM_PROMETHEUS; Erlang/OTP 25 or later, for
#   BEAM_DIST
# Exit code: 0 on success, nodes up or down; 1 if curl or escript is
#   missing, a setting is wrong, a page is not Erlang's, or a node refused
#   the cookie
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
prom=${BEAM_PROMETHEUS-}
dist=${BEAM_DIST-}
entries() { printf '%s' "$1" | tr ';' '\n' | grep -c '[^[:space:]]'; }
echo "metric nodes $(($(entries "$prom") + $(entries "$dist")))"
rc=0

# Prometheus: each page, as Erlang names its own figures.
if [ "$(entries "$prom")" -gt 0 ]; then
    command -v curl > /dev/null 2>&1 || { echo 'vm: curl not found: BEAM_PROMETHEUS is read with curl' >&2; exit 1; }
fi
while IFS= read -r entry; do
    entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$entry" ] || continue
    name=${entry%%=*} url=${entry#*=}
    if [ "$name" = "$entry" ] || [ -z "$name" ] || [ -z "$url" ]; then
        echo "vm: BEAM_PROMETHEUS: '$entry' is not <name>=<url>, as in rabbit=http://127.0.0.1:15692/metrics" >&2
        exit 1
    fi
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9@._:-' '_')
    tag="node=$name source=prometheus"
    page=$(curl -sS -m 15 -f "$url" 2>&1)
    case $? in
        0) ;;
        6 | 7 | 28 | 52 | 56)
            echo "metric up 0 $tag"
            continue
            ;;
        *)
            echo "metric up 0 $tag"
            echo "vm: $name: $url did not give a page: $page" >&2
            rc=1
            continue
            ;;
    esac
    if ! printf '%s\n' "$page" | grep -q '^erlang_vm_'; then
        echo "metric up 0 $tag"
        echo "vm: $name: $url answers, but with no erlang_vm_ lines: not an Erlang node's Prometheus page" >&2
        rc=1
        continue
    fi
    echo "metric up 1 $tag"
    printf '%s\n' "$page" | awk -v tag="$tag" '
        /^#/ { next }
        { key = $1; v = $2 }
        key == "erlang_vm_memory_bytes{kind=\"system\"}"    { sys = v }
        key == "erlang_vm_memory_bytes{kind=\"processes\"}" { procs = v }
        key ~ /^erlang_vm_memory_system_bytes[{]usage="(atom|binary|code|ets)"[}]$/ {
            k = key; sub(/.*usage="/, "", k); sub(/".*/, "", k); kind[k] = v
        }
        key == "erlang_vm_processes"            { m["processes"] = v }
        key == "erlang_vm_process_limit"        { m["process_limit"] = v }
        key == "erlang_vm_ports"                { m["ports"] = v }
        key == "erlang_vm_port_limit"           { m["port_limit"] = v }
        key == "erlang_vm_atoms"                { m["atoms"] = v }
        key == "erlang_vm_atom_limit"           { m["atom_limit"] = v }
        key == "erlang_vm_memory_ets_tables"    { m["ets_tables"] = v }
        key == "erlang_vm_ets_limit"            { m["ets_limit"] = v }
        key == "erlang_vm_schedulers_online"    { m["schedulers_online"] = v }
        key == "erlang_vm_statistics_run_queues_length"          { m["run_queue"] = v }
        key == "erlang_vm_statistics_dirty_cpu_run_queue_length" { m["dirty_cpu_run_queue"] = v }
        key == "erlang_vm_statistics_dirty_io_run_queue_length"  { m["dirty_io_run_queue"] = v }
        key == "erlang_vm_statistics_reductions_total"           { m["reductions_count"] = v }
        key == "erlang_vm_statistics_garbage_collection_number_of_gcs_total"  { m["gcs_count"] = v }
        key == "erlang_vm_statistics_garbage_collection_bytes_reclaimed_total" { m["gc_reclaimed_bytes"] = v }
        key == "erlang_vm_statistics_context_switches_total"     { m["context_switches_count"] = v }
        key == "erlang_vm_statistics_bytes_received_total"       { m["received_bytes"] = v }
        key == "erlang_vm_statistics_bytes_output_total"         { m["sent_bytes"] = v }
        function out(n) { if (n in m) printf "metric %s %s %s\n", n, m[n], tag }
        function pct(n, l, p) {
            out(n); out(l)
            if ((n in m) && (l in m) && m[l] > 0) printf "metric %s %.2f %s\n", p, 100 * m[n] / m[l], tag
        }
        END {
            if (sys != "" && procs != "") printf "metric memory_bytes %.0f %s kind=total\n", sys + procs, tag
            if (procs != "") printf "metric memory_bytes %s %s kind=processes\n", procs, tag
            if (sys != "") printf "metric memory_bytes %s %s kind=system\n", sys, tag
            split("atom binary code ets", ks, " ")
            for (i = 1; i <= 4; i++) if (ks[i] in kind) printf "metric memory_bytes %s %s kind=%s\n", kind[ks[i]], tag, ks[i]
            pct("processes", "process_limit", "process_pct")
            pct("ports", "port_limit", "port_pct")
            pct("atoms", "atom_limit", "atom_pct")
            pct("ets_tables", "ets_limit", "ets_pct")
            split("schedulers_online run_queue dirty_cpu_run_queue dirty_io_run_queue reductions_count gcs_count gc_reclaimed_bytes context_switches_count received_bytes sent_bytes", rest, " ")
            for (i = 1; i in rest; i++) out(rest[i])
        }'
done << EOF
$(printf '%s' "$prom" | tr ';' '\n')
EOF

# The cookie: _beam.escript, with Erlang's escript, in a home of this run's
# own (Erlang writes a cookie file into its home when it has none: never
# Vigil's).
if [ "$(entries "$dist")" -gt 0 ]; then
    escript=''
    for d in "${BEAM_ERLANG:+$BEAM_ERLANG/bin}" "${BEAM_ERLANG-}"; do
        [ -n "$d" ] && [ -x "$d/escript" ] && { escript=$d/escript; break; }
    done
    [ -n "$escript" ] || escript=$(command -v escript 2> /dev/null) || {
        echo 'vm: escript not found: BEAM_DIST is read with Erlang/OTP 25 or later (BEAM_ERLANG, where Erlang is, or escript on the PATH)' >&2
        exit 1
    }
    home=$(mktemp -d "${TMPDIR:-/tmp}/vigil-beam.XXXXXX") || exit 1
    HOME=$home "$escript" "$here/_beam.escript" vm || rc=1
    rm -rf "$home"
fi
exit $rc
