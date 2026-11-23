#!/usr/bin/env bash
#
# process.sh - every Erlang VM on this machine, as the OS sees it
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
# Finds each beam.smp process and reports its memory, CPU, threads, open
# files and uptime, named by its node name (-sname or -name, on its command
# line or in its -args_file), else by what it was started with (-s rabbit:
# rabbit, as RabbitMQ names itself once started), else by its process id.
# It reads nothing else from a command line: one may hold the cookie, and
# this script says only whether it does. Nothing to set up; another
# account's open files need root.
#
# Metrics:
#   beams                   the Erlang VMs running on this machine
#   running                 always 1, tagged node=<its node name, else its
#                           -s module, else pid<n>> and erts=<the runtime's
#                           version, 16.1.2>
#   rss_bytes               memory it holds (resident), tagged node=<the same>
#   cpu_seconds             CPU time it has used, user and system
#   threads                 its threads (schedulers, dirty schedulers,
#                           async and others)
#   open_files              files and sockets it has open (root, or its
#                           own account)
#   open_files_max          the most it may have open (its soft limit)
#   uptime_seconds          how long it has run
#   cookie_on_command_line  1 when -setcookie is on its command line, which
#                           every account here can read, else 0
#   beams_not_shown         past the first 100 VMs, how many were left out
#
# Example output:
#   metric beams 5
#   metric running 1 node=t28@127.0.0.1 erts=16.4.0.7
#   metric rss_bytes 68915200 node=t28@127.0.0.1
#   metric cpu_seconds 71.67 node=t28@127.0.0.1
#   metric threads 24 node=t28@127.0.0.1
#   metric open_files_max 1024 node=t28@127.0.0.1
#   metric uptime_seconds 101 node=t28@127.0.0.1
#   metric cookie_on_command_line 0 node=t28@127.0.0.1
#   metric beams_not_shown 0
#
# Reading the results (starting points: tune them to the node):
#   Healthy  beams as many as you run; rss_bytes steady over days;
#            open_files well below open_files_max; uptime_seconds rising.
#   Watch    rss_bytes climbing for hours without falling back; open_files
#            past 70% of open_files_max; cookie_on_command_line 1: any
#            account here can read the cookie (use ~/.erlang.cookie, or
#            -args_file with a file only its account reads).
#   Act      beams lower than you run: a VM is gone (beam.crashdumps says
#            why); uptime_seconds back near 0: it restarted; open_files
#            past 90% of open_files_max: it is about to refuse connections.
#
# Requires: bash and /proc
# Exit code: 0 on success, VMs or none

set -u

tick=$(getconf CLK_TCK 2> /dev/null) || tick=100
page=$(getconf PAGESIZE 2> /dev/null) || page=4096
read -r up _ < /proc/uptime
up=${up%.*}

# A tag's value: no spaces, quotes or control characters.
clean() { printf '%s' "$1" | tr -d '"'"'"'`' | tr -c 'A-Za-z0-9@._:/+=,-' '_' | cut -c1-120; }

# The node name a VM was given: -sname or -name, on its command line, else
# in a file it was given with -args_file (when this account can read it).
node_of() {
    local -a args=("$@")
    local i n=${#args[@]} f w
    for ((i = 0; i < n - 1; i++)); do
        case ${args[$i]} in
            -sname | -name) printf '%s' "${args[$((i + 1))]}"; return ;;
        esac
    done
    for ((i = 0; i < n - 1; i++)); do
        [ "${args[$i]}" = -args_file ] || continue
        f=${args[$((i + 1))]}
        [ -r "$f" ] || continue
        w=$(sed -n 's/^[[:space:]]*-s\{0,1\}name[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$f" 2> /dev/null | head -1)
        [ -n "$w" ] && { printf '%s' "$w"; return; }
    done
    # A VM that names itself once started (RabbitMQ does): what it was
    # started with, -s <module>.
    for ((i = 0; i < n - 1; i++)); do
        case ${args[$i]}:${args[$((i + 1))]} in
            -s:-*) ;;
            -s:*) printf '%s' "${args[$((i + 1))]}"; return ;;
        esac
    done
}

count=0
shown=0
out=()
for d in /proc/[0-9]*; do
    comm=$(cat "$d/comm" 2> /dev/null) || continue
    [ "$comm" = beam.smp ] || continue
    pid=${d#/proc/}
    mapfile -d '' -t args < "$d/cmdline" 2> /dev/null || continue
    [ "${#args[@]}" -gt 0 ] || continue
    count=$((count + 1))
    [ "$shown" -lt 100 ] || continue
    shown=$((shown + 1))

    node=$(node_of "${args[@]}")
    [ -n "$node" ] && node=$(clean "$node") || node=pid$pid
    erts=$(printf '%s' "${args[0]}" | sed -n 's|.*/erts-\([0-9][0-9.]*\)/.*|\1|p')
    cookie=0
    for a in "${args[@]}"; do [ "$a" = -setcookie ] && cookie=1; done

    # /proc/<pid>/stat: after the name in brackets, utime (14), stime (15)
    # and the start, in ticks since boot (22).
    stat=$(cat "$d/stat" 2> /dev/null) || continue
    set -- ${stat##*) }
    utime=${12} stime=${13} start=${20} rss_pages=${22}
    threads=$(sed -n 's/^Threads:[[:space:]]*//p' "$d/status" 2> /dev/null)
    files=''
    if [ -r "$d/fd" ] && [ -x "$d/fd" ]; then
        files=$(ls -U "$d/fd" 2> /dev/null | wc -l)
    fi
    max=$(sed -n 's/^Max open files[[:space:]]*\([0-9]*\).*/\1/p' "$d/limits" 2> /dev/null)

    tag="node=$node"
    out+=("metric running 1 $tag${erts:+ erts=$erts}")
    out+=("metric rss_bytes $((rss_pages * page)) $tag")
    out+=("metric cpu_seconds $(awk -v t=$((utime + stime)) -v k="$tick" 'BEGIN { printf "%.2f", t / k }') $tag")
    [ -n "$threads" ] && out+=("metric threads $threads $tag")
    [ -n "$files" ] && out+=("metric open_files $((files)) $tag")
    [ -n "$max" ] && out+=("metric open_files_max $max $tag")
    out+=("metric uptime_seconds $((up - start / tick)) $tag")
    out+=("metric cookie_on_command_line $cookie $tag")
done

echo "metric beams $count"
[ "${#out[@]}" -gt 0 ] && printf '%s\n' "${out[@]}"
echo "metric beams_not_shown $((count - shown))"
exit 0
