#!/usr/bin/env bash
#
# network.sh - network traffic on macOS
#
# Reports the bytes each network interface has moved since boot. These are
# running totals: graph them as a rate. Loopback and interfaces that have
# moved nothing are left out.
#
# Metrics:
#   rx_bytes  bytes received (tag: iface)
#   tx_bytes  bytes sent (tag: iface)
#
# Example output:
#   metric rx_bytes 1415005394 iface=en0
#   metric tx_bytes 283001078 iface=en0
#
# Reading the results (starting points: tune them to the machine):
#   These are running totals, so there is no good or bad value: graph the rate
#   of change, and compare it with the speed of the link and your usual level.
#   Healthy  steady, and well below the speed of the link.
#   Watch    above 70 percent of the speed of the link for 15 minutes or more.
#   Act      close to the speed of the link, or no traffic at all on an
#            interface that should be busy. Totals restart after a reboot.
#
# Requires: bash, netstat, awk
# Exit code: 0 on success, 1 if netstat fails
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

report=$(netstat -ibn 2> /dev/null) || exit 1

printf '%s\n' "$report" | awk '
    # An interface has several lines: the <Link#n> one has the totals. The
    # address column may be empty, so the counters are found from the end.
    $3 ~ /^<Link#/ && $1 !~ /^lo/ {
        received = $(NF - 4)
        sent = $(NF - 1)
        if (received + sent > 0) {
            printf "metric rx_bytes %.0f iface=%s\n", received, $1
            printf "metric tx_bytes %.0f iface=%s\n", sent, $1
        }
    }
'
