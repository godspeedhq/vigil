#!/usr/bin/env bash
#
# diskio.sh - disk reads and writes on macOS
#
# Reports what each physical disk has read and written since boot, from
# the storage drivers' statistics in the I/O registry. These are running
# totals: graph them as a rate. A disk APFS builds on part of another
# (disk1 on disk0s2) is left out: its I/O is the physical disk's, counted
# once.
#
# Metrics:
#   read_bytes   bytes read (tag: disk)
#   write_bytes  bytes written (tag: disk)
#   reads        reads completed (tag: disk)
#   writes       writes completed (tag: disk)
#   busy_ms is not reported: macOS does not count it
#
# Example output:
#   metric read_bytes 365976187392 disk=disk0
#   metric write_bytes 425091751936 disk=disk0
#   metric reads 17750204 disk=disk0
#   metric writes 17906532 disk=disk0
#
# Reading the results (starting points: tune them to the machine):
#   These are running totals, so there is no good or bad value: graph the rate
#   of change against your usual level. A rate far above it, for long, is
#   worth finding the reason for (system.processes). Totals restart after a
#   reboot.
#
# Requires: bash, ioreg, awk
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

# Each storage driver lists its "Statistics", and its disk's "BSD Name"
# follows below it.
report=$(ioreg -r -c IOBlockStorageDriver -w 0 -l 2> /dev/null) || exit 1

printf '%s\n' "$report" | awk '
    # A value from Statistics = {"Bytes (Read)"=365976187392,...}.
    function stat(key,    i) {
        i = index(stats, "\"" key "\"=")
        if (!i) return 0
        return substr(stats, i + length(key) + 3) + 0
    }
    /"Statistics" = \{/ {
        stats = $0
        # The driver of a physical disk times its I/O; the driver of a disk APFS
        # builds counts bytes and operations only.
        physical = index(stats, "\"Total Time (Read)\"") > 0
        waiting = 1
        next
    }
    waiting && /"BSD Name" = / {
        waiting = 0
        if (!physical) next
        name = $0
        sub(/.*"BSD Name" = "/, "", name)
        sub(/".*/, "", name)
        printf "metric read_bytes %.0f disk=%s\n", stat("Bytes (Read)"), name
        printf "metric write_bytes %.0f disk=%s\n", stat("Bytes (Write)"), name
        printf "metric reads %.0f disk=%s\n", stat("Operations (Read)"), name
        printf "metric writes %.0f disk=%s\n", stat("Operations (Write)"), name
    }
'
