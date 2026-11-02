#!/usr/bin/env bash
#
# memory.sh - memory use on macOS
#
# Reports memory in use as Activity Monitor counts it: active, wired and
# compressed pages. Cached files are not counted as used.
#
# Metrics:
#   used_pct     percent of memory in use
#   used_bytes   memory in use, in bytes
#   total_bytes  installed memory, in bytes
#
# Example output:
#   metric used_pct 62
#   metric used_bytes 10637131776
#   metric total_bytes 17179869184
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  below 80: room for peaks.
#   Watch    80 to 90, or used_bytes climbing steadily, which can mean a leak.
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

printf '%s\n' "$pages" | awk -v total="$total" '
    # Page size varies by machine: vm_stat states it on its first line.
    /page size of/                   { page = $8 }
    /^Pages active:/                 { used += $3 + 0 }
    /^Pages wired down:/             { used += $4 + 0 }
    /^Pages occupied by compressor:/ { used += $5 + 0 }
    END {
        if (page == 0 || total == 0) exit 1
        bytes = used * page
        printf "metric used_pct %d\n", 100 * bytes / total
        printf "metric used_bytes %.0f\n", bytes
        printf "metric total_bytes %.0f\n", total
    }
'
