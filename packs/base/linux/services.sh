#!/usr/bin/env bash
#
# services.sh - failed services on Linux
#
# Reports how many systemd units are in the failed state. A host without
# systemd reports nothing, and that is not an error.
#
# Metrics:
#   failed  number of failed units
#
# Example output:
#   metric failed 0
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  0.
#   Act      1 or more: something that should be running is not. To see
#            what: systemctl --failed
#
# Requires: bash, systemd for a result
# Exit code: 0, always
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

command -v systemctl > /dev/null 2>&1 || exit 0

# One line per failed unit, with no header or footer.
failed=$(systemctl --failed --no-legend --plain 2> /dev/null | wc -l)

# Arithmetic drops the padding some versions of wc add.
echo "metric failed $((failed + 0))"
