#!/usr/bin/env bash
#
# processes.sh - the busiest programs on Linux
#
# Reads every process's CPU time from /proc twice, one second apart, and
# reports the 10 programs that used the most CPU in that second and the 10
# using the most memory: often the same ones, reported once. Processes with
# the same name count together (20 workers of one server are one program),
# and only the name is sent: never a process id, which would make a new
# series every restart, or a command line, which can hold a password.
#
# Metrics:
#   cpu_pct       percent of the whole machine's CPU, all cores together, so
#                 it adds up with system.cpu.used_pct (tag: name)
#   memory_bytes  resident memory, in bytes (tag: name)
#
# Example output:
#   metric cpu_pct 12.5 name=postgres
#   metric memory_bytes 1462763520 name=postgres
#   metric cpu_pct 3.0 name=java
#   metric memory_bytes 2147483648 name=java
#
# Reading the results (starting points: tune them to the machine):
#   Look at it when system.cpu.used_pct or system.memory.used_pct is high: it
#   names what is using the machine. A program whose memory_bytes only ever
#   grows may be leaking.
#
# Requires: bash, awk, cat, /proc
# Exit code: 0 on success, 1 if the data cannot be read
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

readonly SAMPLE_SECONDS=1
readonly TOP=10

page=$(getconf PAGESIZE 2> /dev/null || echo 4096)

# One line each, "<pid> (<name>) <state> ...". cat goes on past a process
# that ends while it reads, where awk would stop.
first=$(cat /proc/[0-9]*/stat 2> /dev/null)
read -r _ a b c d e f g h _ < /proc/stat || exit 1
first_total=$((a + b + c + d + e + f + g + h))
sleep "$SAMPLE_SECONDS"
second=$(cat /proc/[0-9]*/stat 2> /dev/null)
read -r _ a b c d e f g h _ < /proc/stat || exit 1
total=$((a + b + c + d + e + f + g + h - first_total))

[ -n "$second" ] || exit 1

printf '%s\n--second--\n%s\n' "$first" "$second" | awk -v total="$total" -v page="$page" -v top="$TOP" '
    $0 == "--second--" { part = 2; next }
    {
        # The name is between the first ( and the last ), and may hold
        # spaces or brackets itself.
        lp = index($0, "(")
        rp = 0
        for (i = length($0); i > lp; i--) if (substr($0, i, 1) == ")") { rp = i; break }
        if (!lp || !rp) next
        pid = substr($0, 1, lp - 2)
        name = substr($0, lp + 1, rp - lp - 1)
        split(substr($0, rp + 2), f, " ")
        # After the name: state is 1, user time 12, system time 13, and
        # resident pages 22.
        cpu = f[12] + f[13]
        if (part != 2) { before[pid] = cpu; next }
        # A process that started during the second counts from 0.
        gsub(/[^A-Za-z0-9_.:-]/, "_", name)
        if (name == "") next
        delta = cpu - ((pid in before) ? before[pid] : 0)
        if (delta > 0) used[name] += delta
        mem[name] += f[22] * page
        names[name] = 1
    }
    END {
        if (total <= 0) total = 1
        # The top by CPU, then by memory, without sort: awk on macOS and
        # mawk have no asort.
        for (k = 1; k <= top; k++) {
            best = ""
            for (n in names) if (!(n in pick_cpu) && used[n] > 0 && (best == "" || used[n] > used[best])) best = n
            if (best != "") { pick_cpu[best] = 1; picked[best] = 1 }
            best = ""
            for (n in names) if (!(n in pick_mem) && (best == "" || mem[n] > mem[best])) best = n
            if (best != "") { pick_mem[best] = 1; picked[best] = 1 }
        }
        for (n in picked) {
            printf "metric cpu_pct %.1f name=%s\n", 100 * used[n] / total, n
            printf "metric memory_bytes %.0f name=%s\n", mem[n], n
        }
    }
'
