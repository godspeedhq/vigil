#!/usr/bin/env bash
#
# host.sh - what this machine is, and how long it has been up, on macOS
#
# Reports the time since boot, the number of processes and of logical
# cores, and one info metric whose tags say what the machine runs. Tag
# values cannot hold spaces: a space becomes _.
#
# Metrics:
#   uptime_seconds  seconds since the machine started
#   process_count   processes running now
#   cores           logical cores (hardware threads)
#   info            always 1 (tags: os_name, os_version, kernel, cpu_model)
#
# Example output:
#   metric uptime_seconds 4452987
#   metric process_count 471
#   metric cores 4
#   metric info 1 os_name=macOS os_version=12.7.6 kernel=21.6.0 cpu_model=Intel(R)_Core(TM)_i5-5250U_CPU_@_1.60GHz
#
# Reading the results (starting points: tune them to the machine):
#   uptime_seconds  going back to near 0 is a restart: expected after
#                   updates, worth a look otherwise.
#   process_count   steady for the machine; climbing without end usually
#                   means processes are started and never end.
#   info            a changed os_version shows an update took.
#
# Requires: bash, sysctl, sw_vers, ps, awk
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

# A tag value: quotes and line ends go, spaces become _, and an empty one
# is "unknown".
tag() {
    local v
    v=$(printf '%s' "$1" | tr -d "\"'\r\n" | tr -s ' \t' '__')
    printf '%s' "${v:-unknown}"
}

# { sec = 1790391290, usec = 821970 } Sat Sep 26 03:54:50 2026
boot=$(sysctl -n kern.boottime 2> /dev/null | awk '{ gsub(/,/, ""); print $4 }')
case $boot in '' | *[!0-9]*) exit 1 ;; esac
cores=$(sysctl -n hw.logicalcpu 2> /dev/null || echo 0)
processes=$(ps -A -o pid= 2> /dev/null | wc -l)
# Apple silicon names the chip in brand_string too.
model=$(sysctl -n machdep.cpu.brand_string 2> /dev/null)

echo "metric uptime_seconds $(($(date +%s) - boot))"
echo "metric process_count $((processes + 0))"
echo "metric cores $cores"
echo "metric info 1 os_name=$(tag "$(sw_vers -productName 2> /dev/null)") os_version=$(tag "$(sw_vers -productVersion 2> /dev/null)") kernel=$(tag "$(uname -r)") cpu_model=$(tag "$model")"
