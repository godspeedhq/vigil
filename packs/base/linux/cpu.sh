#!/usr/bin/env bash
#
# cpu.sh - CPU use on Linux
#
# Reads the CPU time counters in /proc/stat twice, one second apart, and
# reports the share of that second the CPU spent working, and on what.
#
# Metrics:
#   used_pct     percent of CPU time in use, across all cores
#   user_pct     of which running programs (user and nice)
#   system_pct   of which the kernel (system, irq and softirq)
#   iowait_pct   idle while waiting for a disk; not part of used_pct
#   steal_pct    taken by the hypervisor for other virtual machines; part of
#                used_pct
#
# Example output:
#   metric used_pct 37
#   metric user_pct 29
#   metric system_pct 7
#   metric iowait_pct 2
#   metric steal_pct 0
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  used_pct below 70: normal work, and short spikes to 100 are fine.
#   Watch    used_pct 70 to 90 for 15 minutes or more: little room left for a
#            peak. iowait_pct above 10: the disks are holding work back.
#   Act      used_pct above 90 for 5 minutes or more: find what is using the
#            CPU (system.processes). steal_pct above 10 on a virtual machine:
#            its host is overcommitted.
#
# Requires: bash, /proc
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

readonly STAT_FILE=/proc/stat
readonly SAMPLE_SECONDS=1

# Reads the first line of /proc/stat, the total across all cores. steal is
# missing on very old kernels.
read_counters() {
    local label nice irq softirq rest
    read -r label user nice system idle iowait irq softirq steal rest < "$STAT_FILE" || return 1
    user=$((user + nice))
    system=$((system + irq + softirq))
    steal=${steal:-0}
}

read_counters || exit 1
first_user=$user first_system=$system first_idle=$idle first_iowait=$iowait first_steal=$steal

sleep "$SAMPLE_SECONDS"

read_counters || exit 1
user=$((user - first_user))
system=$((system - first_system))
idle=$((idle - first_idle))
iowait=$((iowait - first_iowait))
steal=$((steal - first_steal))
total=$((user + system + idle + iowait + steal))

# Guards against a division by zero on a clock that did not move.
[ "$total" -gt 0 ] || total=1

echo "metric used_pct $((100 * (user + system + steal) / total))"
echo "metric user_pct $((100 * user / total))"
echo "metric system_pct $((100 * system / total))"
echo "metric iowait_pct $((100 * iowait / total))"
echo "metric steal_pct $((100 * steal / total))"
