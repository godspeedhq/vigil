#!/usr/bin/env bash
#
# host.sh - what this machine is, and how long it has been up, on Linux
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
#   metric uptime_seconds 1229172
#   metric process_count 323
#   metric cores 4
#   metric info 1 os_name=Fedora_Linux_44_(Workstation_Edition) os_version=44 kernel=7.1.5-200.fc44.x86_64 cpu_model=Intel(R)_Core(TM)_i5-2520M_CPU_@_2.50GHz
#
# Reading the results (starting points: tune them to the machine):
#   uptime_seconds  going back to near 0 is a restart: expected after
#                   updates, worth a look otherwise.
#   process_count   steady for the machine; climbing without end usually
#                   means processes are started and never end.
#   info            a changed os_version or kernel shows an update took.
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

# A tag value: quotes and line ends go, spaces become _, and an empty one
# is "unknown".
tag() {
    local v
    v=$(printf '%s' "$1" | tr -d "\"'\r\n" | tr -s ' \t' '__')
    printf '%s' "${v:-unknown}"
}

read -r uptime _ < /proc/uptime || exit 1
processes=0
for p in /proc/[0-9]*; do processes=$((processes + 1)); done
cores=$(awk '/^processor[[:space:]]*:/ { n++ } END { print n + 0 }' /proc/cpuinfo)
[ "$cores" -gt 0 ] || cores=$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 0)
# ARM machines often name the model under another key, or not at all.
model=$(awk -F': *' '/^(model name|Model|Hardware)[[:space:]]*:/ { print $2; exit }' /proc/cpuinfo)

name='' version=''
if [ -r /etc/os-release ]; then
    name=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release)
    version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release)
fi

echo "metric uptime_seconds ${uptime%.*}"
echo "metric process_count $processes"
echo "metric cores $cores"
echo "metric info 1 os_name=$(tag "$name") os_version=$(tag "$version") kernel=$(tag "$(uname -r)") cpu_model=$(tag "$model")"
