#!/usr/bin/env bash
#
# memory.sh - memory use on macOS
#
# Reports memory in use as Activity Monitor counts it: active, wired and
# compressed pages. Cached files are not counted as used.
#
# Metrics:
#   used_pct          percent of memory in use
#   used_bytes        memory in use, in bytes
#   total_bytes       installed memory, in bytes
#   available_bytes   the rest: total_bytes - used_bytes
#   swap_used_bytes   swap in use, in bytes
#   swap_total_bytes  swap files' size, in bytes; macOS grows and shrinks it
#                     as needed
#   commit_used_bytes and commit_limit_bytes are Windows only
#
# Example output:
#   metric used_pct 62
#   metric used_bytes 10637131776
#   metric total_bytes 17179869184
#   metric available_bytes 6542737408
#   metric swap_used_bytes 181403648
#   metric swap_total_bytes 1073741824
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  below 80: room for peaks.
#   Watch    80 to 90, or used_bytes climbing steadily, which can mean a leak.
#            swap_used_bytes growing while used_pct is high.
#   Act      above 90 for 5 minutes or more: the machine may start to swap,
#            or the system may stop processes to free memory.
#
# Requires: bash, sysctl, vm_stat, awk
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

total=$(sysctl -n hw.memsize 2> /dev/null) || exit 1
pages=$(vm_stat 2> /dev/null) || exit 1
# total = 1024.00M  used = 173.00M  free = 851.00M  (encrypted)
swap=$(sysctl -n vm.swapusage 2> /dev/null) || swap=''

printf '%s\n--swap--\n%s\n' "$pages" "$swap" | awk -v total="$total" '
    # A size such as 1024.00M, in bytes.
    function bytes(s,    n, unit) {
        n = s + 0
        unit = substr(s, length(s))
        if (unit == "K") return n * 1024
        if (unit == "M") return n * 1048576
        if (unit == "G") return n * 1073741824
        if (unit == "T") return n * 1099511627776
        return n
    }
    $0 == "--swap--" { part = 2; next }
    part == 2 {
        for (i = 1; i < NF; i++) {
            if ($i == "total" && $(i + 1) == "=") swap_total = bytes($(i + 2))
            if ($i == "used" && $(i + 1) == "=") swap_used = bytes($(i + 2))
        }
        next
    }
    # Page size varies by machine: vm_stat states it on its first line.
    /page size of/                   { page = $8 }
    /^Pages active:/                 { used += $3 + 0 }
    /^Pages wired down:/             { used += $4 + 0 }
    /^Pages occupied by compressor:/ { used += $5 + 0 }
    END {
        if (page == 0 || total == 0) exit 1
        b = used * page
        printf "metric used_pct %d\n", 100 * b / total
        printf "metric used_bytes %.0f\n", b
        printf "metric total_bytes %.0f\n", total
        printf "metric available_bytes %.0f\n", total - b
        printf "metric swap_used_bytes %.0f\n", swap_used
        printf "metric swap_total_bytes %.0f\n", swap_total
    }
'
