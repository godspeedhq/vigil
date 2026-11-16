#!/usr/bin/env bash
#
# diskio.sh - disk reads and writes on Linux
#
# Reports what each physical disk has read and written since boot, from
# /proc/diskstats. These are running totals: graph them as a rate.
# Partitions are left out (their disk counts them), and so are devices
# with no hardware behind them: loop, RAM, zram, device-mapper and RAID
# devices, whose I/O their disks already count.
#
# Metrics:
#   read_bytes   bytes read (tag: disk)
#   write_bytes  bytes written (tag: disk)
#   reads        reads completed (tag: disk)
#   writes       writes completed (tag: disk)
#   busy_ms      milliseconds the disk was busy (tag: disk); as a rate,
#                busy_ms / 10 per second is the percent of time it was busy
#
# Example output:
#   metric read_bytes 45890229248 disk=sda
#   metric write_bytes 218179698688 disk=sda
#   metric reads 756183 disk=sda
#   metric writes 6363810 disk=sda
#   metric busy_ms 3472849 disk=sda
#
# Reading the results (starting points: tune them to the machine):
#   These are running totals, so there is no good or bad value: graph the rate
#   of change against your usual level.
#   Healthy  busy below 50 percent of the time.
#   Watch    busy above 80 percent for 15 minutes or more: the disk is the
#            bottleneck, and system.cpu.iowait_pct usually rises with it.
#   Act      busy near 100 percent with work waiting: find what is reading or
#            writing, or move it to a faster disk. Totals restart after a
#            reboot.
#
# Requires: bash, awk, /proc, /sys
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

# A disk with hardware behind it has a device link in /sys/block.
disks=''
for d in /sys/block/*; do
    [ -e "$d/device" ] && disks="$disks ${d##*/}"
done

[ -r /proc/diskstats ] || exit 1

awk -v disks="$disks" '
    BEGIN { n = split(disks, list, " "); for (i = 1; i <= n; i++) want[list[i]] = 1 }
    # Fields: major, minor, name, reads, merged, sectors read, ms reading,
    # writes, merged, sectors written, ms writing, in flight, ms busy. A
    # sector here is always 512 bytes, whatever the disk.
    ($3 in want) {
        printf "metric read_bytes %.0f disk=%s\n", $6 * 512, $3
        printf "metric write_bytes %.0f disk=%s\n", $10 * 512, $3
        printf "metric reads %.0f disk=%s\n", $4, $3
        printf "metric writes %.0f disk=%s\n", $8, $3
        printf "metric busy_ms %.0f disk=%s\n", $13, $3
    }
' /proc/diskstats
