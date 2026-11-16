#!/usr/bin/env bash
#
# disk.sh - file system use on Linux
#
# Reports each real file system, one set of metrics per mount point.
# Memory-backed and read-only image file systems are left out, and so is
# a mount point with a space in its name, which a metric tag cannot hold.
#
# Metrics:
#   used_pct         percent of usable space in use (tag: mount)
#   used_bytes       space in use, in bytes (tag: mount)
#   total_bytes      size of the file system, in bytes (tag: mount)
#   inodes_used_pct  percent of inodes (file entries) in use (tag: mount);
#                    left out for file systems with no fixed number, such as
#                    btrfs
#
# Example output:
#   metric used_pct 71 mount=/
#   metric used_bytes 305175781376 mount=/
#   metric total_bytes 429496729600 mount=/
#   metric inodes_used_pct 12 mount=/
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  below 80.
#   Watch    80 to 90, or used_bytes growing fast: work out when it fills up.
#   Act      above 90: free some space. At 100, writes fail, and databases
#            and logs usually go with them. The same goes for
#            inodes_used_pct: many small files can fill a disk that still
#            has space.
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
# -k gives sizes in kibibytes, -i inodes instead.
skip='-x tmpfs -x devtmpfs -x squashfs -x overlay'
# shellcheck disable=SC2086
space=$(df -P -k $skip 2> /dev/null) || exit 1
# shellcheck disable=SC2086
inodes=$(df -P -i $skip 2> /dev/null) || inodes=''

printf '%s\n--inodes--\n%s\n' "$space" "$inodes" | awk '
    $0 == "--inodes--" { part = 2; next }
    # Skips the headers, zero-sized file systems and names with a space.
    part != 2 && $1 != "Filesystem" && NF == 6 && $2 > 0 {
        n++; mount[n] = $6; size[n] = $2; used[n] = $3; avail[n] = $4
    }
    part == 2 && $1 != "Filesystem" && NF == 6 && $2 > 0 { inode_pct[$6] = int(100 * $3 / $2) }
    END {
        for (i = 1; i <= n; i++) {
            # used + available, not the total: root keeps some space in
            # reserve, so this is the number that reaches 100 when writes
            # start to fail.
            printf "metric used_pct %d mount=%s\n", 100 * used[i] / (used[i] + avail[i]), mount[i]
            printf "metric used_bytes %.0f mount=%s\n", used[i] * 1024, mount[i]
            printf "metric total_bytes %.0f mount=%s\n", size[i] * 1024, mount[i]
            if (mount[i] in inode_pct) printf "metric inodes_used_pct %d mount=%s\n", inode_pct[mount[i]], mount[i]
        }
    }
'
