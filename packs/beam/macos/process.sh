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
#                           own account; from lsof)
#   open_files_max          not on macOS: the limit is not readable per
#                           process (launchctl limit maxfiles shows the
#                           machine's)
#   uptime_seconds          how long it has run
#   cookie_on_command_line  1 when -setcookie is on its command line, which
#                           every account here can read, else 0
#   beams_not_shown         past the first 100 VMs, how many were left out
#
# Example output:
#   metric beams 2
#   metric running 1 node=tm erts=16.4.0.7
#   metric rss_bytes 48087040 node=tm
#   metric cpu_seconds 55.12 node=tm
#   metric threads 24 node=tm
#   metric open_files 32 node=tm
#   metric uptime_seconds 56 node=tm
#   metric cookie_on_command_line 0 node=tm
#   metric running 1 node=rabbit erts=16.4.0.7
#   metric beams_not_shown 0
#
# Reading the results (starting points: tune them to the node):
#   Healthy  beams as many as you run; rss_bytes steady over days;
#            uptime_seconds rising.
#   Watch    rss_bytes climbing for hours without falling back;
#            cookie_on_command_line 1: any account here can read the cookie
#            (use ~/.erlang.cookie, or -args_file with a file only its
#            account reads).
#   Act      beams lower than you run: a VM is gone (beam.crashdumps says
#            why); uptime_seconds back near 0: it restarted.
#
# Requires: bash, ps; lsof for open_files
# Exit code: 0 on success, VMs or none

set -u

# A tag's value: no spaces, quotes or control characters.
clean() { printf '%s' "$1" | tr -d '"'"'"'`' | tr -c 'A-Za-z0-9@._:/+=,-' '_' | cut -c1-120; }

# [[dd-]hh:]mm:ss[.cc], as ps gives time and etime, in seconds.
seconds() {
    printf '%s' "$1" | awk '{
        d = 0; t = $0
        if (index(t, "-")) { d = substr(t, 1, index(t, "-") - 1); t = substr(t, index(t, "-") + 1) }
        n = split(t, p, ":"); s = 0
        for (i = 1; i <= n; i++) s = s * 60 + p[i]
        printf "%.2f", d * 86400 + s
    }'
}

# The node name a VM was given: -sname or -name, on its command line, else
# in a file it was given with -args_file (when this account can read it),
# else its -s module. ps gives the command line as one string: split at
# spaces.
node_of() {
    local prev='' w f s=''
    for w in $1; do
        case $prev in
            -sname | -name) printf '%s' "$w"; return ;;
            -args_file) f=$w ;;
            -s) case $w in -*) ;; *) [ -n "$s" ] || s=$w ;; esac ;;
        esac
        prev=$w
    done
    if [ -n "${f-}" ] && [ -r "$f" ]; then
        w=$(sed -n 's/^[[:space:]]*-s\{0,1\}name[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$f" 2> /dev/null | head -1)
        [ -n "$w" ] && { printf '%s' "$w"; return; }
    fi
    printf '%s' "$s"
}

count=0
shown=0
out=''
while read -r pid rss cpu etime comm; do
    [ "${comm##*/}" = beam.smp ] || continue
    count=$((count + 1))
    [ "$shown" -lt 100 ] || continue
    shown=$((shown + 1))
    args=$(ps -ww -o args= -p "$pid" 2> /dev/null) || continue

    node=$(node_of "$args")
    if [ -n "$node" ]; then node=$(clean "$node"); else node=pid$pid; fi
    erts=$(printf '%s' "$comm" | sed -n 's|.*/erts-\([0-9][0-9.]*\)/.*|\1|p')
    cookie=0
    case " $args " in *' -setcookie '*) cookie=1 ;; esac
    threads=$(ps -M -p "$pid" 2> /dev/null | tail -n +2 | wc -l | tr -d ' ')
    files=''
    if command -v lsof > /dev/null 2>&1; then
        files=$(lsof -n -P -p "$pid" 2> /dev/null | tail -n +2 | wc -l | tr -d ' ')
        [ "$files" = 0 ] && files=''
    fi

    tag="node=$node"
    out="$out
metric running 1 $tag${erts:+ erts=$erts}
metric rss_bytes $((rss * 1024)) $tag
metric cpu_seconds $(seconds "$cpu") $tag"
    [ -n "$threads" ] && [ "$threads" != 0 ] && out="$out
metric threads $threads $tag"
    [ -n "$files" ] && out="$out
metric open_files $files $tag"
    out="$out
metric uptime_seconds $(seconds "$etime" | sed 's/\..*//') $tag
metric cookie_on_command_line $cookie $tag"
done << EOF
$(ps -axww -o pid=,rss=,time=,etime=,comm= 2> /dev/null)
EOF

echo "metric beams $count"
[ -n "$out" ] && printf '%s\n' "${out#?}"
echo "metric beams_not_shown $((count - shown))"
exit 0
