#!/usr/bin/env bash
#
# memory.sh - memory use on Linux
#
# Reports memory in use from /proc/meminfo. Memory the kernel can reclaim
# on demand, such as the page cache, does not count as used.
#
# Metrics:
#   used_pct          percent of memory in use
#   used_bytes        memory in use, in bytes
#   total_bytes       installed memory, in bytes
#   available_bytes   memory available to programs without swapping, in bytes
#   swap_used_bytes   swap in use, in bytes
#   swap_total_bytes  swap configured, in bytes (0 with no swap)
#   commit_used_bytes and commit_limit_bytes are Windows only
#
# Example output:
#   metric used_pct 62
#   metric used_bytes 10637131776
#   metric total_bytes 17179869184
#   metric available_bytes 6542737408
#   metric swap_used_bytes 916045824
#   metric swap_total_bytes 8188325888
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  below 80: room for peaks.
#   Watch    80 to 90, or used_bytes climbing steadily, which can mean a leak.
#            swap_used_bytes growing while used_pct is high.
#   Act      above 90 for 5 minutes or more: the machine may start to swap,
#            or the system may stop processes to free memory.
#
# Requires: bash, awk, /proc
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

awk '
    # Values in /proc/meminfo are in kibibytes.
    $1 == "MemTotal:"     { total = $2 }
    $1 == "MemAvailable:" { available = $2; found = 1 }
    $1 == "MemFree:"      { free = $2 }
    $1 == "Buffers:"      { buffers = $2 }
    $1 == "Cached:"       { cached = $2 }
    $1 == "SwapTotal:"    { swap_total = $2 }
    $1 == "SwapFree:"     { swap_free = $2 }
    END {
        if (total == 0) exit 1
        # Kernels before 3.14 have no MemAvailable: this is its usual estimate.
        if (!found) available = free + buffers + cached
        used = total - available
        printf "metric used_pct %d\n", 100 * used / total
        printf "metric used_bytes %.0f\n", used * 1024
        printf "metric total_bytes %.0f\n", total * 1024
        printf "metric available_bytes %.0f\n", available * 1024
        printf "metric swap_used_bytes %.0f\n", (swap_total - swap_free) * 1024
        printf "metric swap_total_bytes %.0f\n", swap_total * 1024
    }
' /proc/meminfo
