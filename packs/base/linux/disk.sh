#!/usr/bin/env bash
#
# disk.sh - file system use on Linux
#
# Reports each real file system, one set of metrics per mount point.
# Memory-backed and read-only image file systems are left out, and so is
# a mount point with a space in its name, which a metric tag cannot hold.
#
# Metrics:
#   used_pct     percent of usable space in use (tag: mount)
#   used_bytes   space in use, in bytes (tag: mount)
#   total_bytes  size of the file system, in bytes (tag: mount)
#
# Example output:
#   metric used_pct 71 mount=/
#   metric used_bytes 305175781376 mount=/
#   metric total_bytes 429496729600 mount=/
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  below 80.
#   Watch    80 to 90, or used_bytes growing fast: work out when it fills up.
#   Act      above 90: free some space. At 100, writes fail, and databases
#            and logs usually go with them.
#
# Requires: bash, df, awk
# Exit code: 0 on success, 1 if df fails
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

# -P gives one line per file system, in columns that are the same everywhere.
# -k gives sizes in kibibytes.
report=$(df -P -k -x tmpfs -x devtmpfs -x squashfs -x overlay 2> /dev/null) || exit 1

printf '%s\n' "$report" | awk '
    # Skips the header, zero-sized file systems and names with a space.
    NR > 1 && NF == 6 && $2 > 0 {
        # used + available, not the total: root keeps some space in reserve,
        # so this is the number that reaches 100 when writes start to fail.
        printf "metric used_pct %d mount=%s\n", 100 * $3 / ($3 + $4), $6
        printf "metric used_bytes %.0f mount=%s\n", $3 * 1024, $6
        printf "metric total_bytes %.0f mount=%s\n", $2 * 1024, $6
    }
'
