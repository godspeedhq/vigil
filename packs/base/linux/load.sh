#!/usr/bin/env bash
#
# load.sh - load average on Linux
#
# Reports the load averages from /proc/loadavg: the average number of
# processes running or waiting to run. Compare it with the number of
# cores: a load above that means work is queueing.
#
# Metrics:
#   load1   average over 1 minute
#   load5   average over 5 minutes
#   load15  average over 15 minutes
#
# Example output:
#   metric load1 1.24
#   metric load5 0.98
#   metric load15 0.87
#
# Reading the results (starting points: tune them to the machine):
#   Compare with the number of CPU cores. For a machine with 4 cores:
#   Healthy  below 4: every core can keep up.
#   Watch    4 to 8 for 15 minutes or more: work is queueing.
#   Act      above 8 for 5 minutes or more: the machine is overloaded.
#   load1 above load15 means load is rising; below it, falling.
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

read -r load1 load5 load15 rest < /proc/loadavg || exit 1

echo "metric load1 $load1"
echo "metric load5 $load5"
echo "metric load15 $load15"
