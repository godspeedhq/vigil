#!/usr/bin/env bash
#
# processes.sh - the busiest programs on macOS
#
# Reports the 10 programs using the most CPU and the 10 using the most
# memory, from ps: often the same ones, reported once. Processes with the
# same name count together (20 helpers of one browser are one program), and
# only the name is sent: never a process id, which would make a new series
# every restart, or a command line, which can hold a password.
#
# Metrics:
#   cpu_pct       percent of the whole machine's CPU, all cores together, so
#                 it adds up with system.cpu.used_pct (tag: name). macOS
#                 averages it over the last minute or so, so a short burst
#                 shows smaller than it was
#   memory_bytes  resident memory, in bytes (tag: name)
#
# Example output:
#   metric cpu_pct 12.5 name=postgres
#   metric memory_bytes 1462763520 name=postgres
#   metric cpu_pct 3.0 name=WindowServer
#   metric memory_bytes 214958080 name=WindowServer
#
# Reading the results (starting points: tune them to the machine):
#   Look at it when system.cpu.used_pct or system.memory.used_pct is high: it
#   names what is using the machine. A program whose memory_bytes only ever
#   grows may be leaking.
#
# Requires: bash, ps, sysctl, awk
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

readonly TOP=10

cores=$(sysctl -n hw.logicalcpu 2> /dev/null || echo 1)
# The program is last, as a path that may hold spaces.
report=$(ps -A -o pcpu=,rss=,comm= 2> /dev/null) || exit 1

printf '%s\n' "$report" | awk -v cores="$cores" -v top="$TOP" '
    NF >= 3 {
        cpu = $1; mem = $2
        $1 = ""; $2 = ""
        name = $0
        sub(/^ +/, "", name)
        sub(/.*\//, "", name)
        gsub(/[^A-Za-z0-9_.:-]/, "_", name)
        if (name == "") next
        used[name] += cpu
        # ps gives resident memory in kibibytes.
        rss[name] += mem * 1024
        names[name] = 1
    }
    END {
        if (cores <= 0) cores = 1
        # The top by CPU, then by memory, without sort: awk on macOS has no
        # asort.
        for (k = 1; k <= top; k++) {
            best = ""
            for (n in names) if (!(n in pick_cpu) && used[n] > 0 && (best == "" || used[n] > used[best])) best = n
            if (best != "") { pick_cpu[best] = 1; picked[best] = 1 }
            best = ""
            for (n in names) if (!(n in pick_mem) && (best == "" || rss[n] > rss[best])) best = n
            if (best != "") { pick_mem[best] = 1; picked[best] = 1 }
        }
        # ps counts one core as 100 percent.
        for (n in picked) {
            printf "metric cpu_pct %.1f name=%s\n", used[n] / cores, n
            printf "metric memory_bytes %.0f name=%s\n", rss[n], n
        }
    }
'
