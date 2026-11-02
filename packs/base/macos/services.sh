#!/usr/bin/env bash
#
# services.sh - failed services on macOS
#
# Reports how many launchd jobs last exited with an error and are not
# running now. Only jobs visible to the account running this are counted.
#
# Metrics:
#   failed  number of failed jobs
#
# Example output:
#   metric failed 3
#
# Reading the results (starting points: tune them to the machine):
#   macOS often has a few jobs that exited with an error and do no harm, so
#   learn the usual number for this machine first.
#   Healthy  steady at the usual number.
#   Watch    higher than usual.
#   Act      still rising. To see which: launchctl list
#
# Requires: bash, launchctl, awk
# Exit code: 0 on success, 1 if launchctl fails
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

jobs_list=$(launchctl list 2> /dev/null) || exit 1

# Columns: PID, last exit status, label. A PID of "-" means it is not running.
printf '%s\n' "$jobs_list" | awk '
    NR > 1 && $1 == "-" && $2 != 0 { failed++ }
    END { printf "metric failed %d\n", failed }
'
