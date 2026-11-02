#!/usr/bin/env bash
#
# network.sh - network traffic on Linux
#
# Reports the bytes each network interface has moved since boot, from
# /proc/net/dev. These are running totals: graph them as a rate. The
# loopback interface is left out.
#
# Metrics:
#   rx_bytes  bytes received (tag: iface)
#   tx_bytes  bytes sent (tag: iface)
#
# Example output:
#   metric rx_bytes 1415005394 iface=eth0
#   metric tx_bytes 283001078 iface=eth0
#
# Reading the results (starting points: tune them to the machine):
#   These are running totals, so there is no good or bad value: graph the rate
#   of change, and compare it with the speed of the link and your usual level.
#   Healthy  steady, and well below the speed of the link.
#   Watch    above 70 percent of the speed of the link for 15 minutes or more.
#   Act      close to the speed of the link, or no traffic at all on an
#            interface that should be busy. Totals restart after a reboot.
#
# Requires: bash, awk, tr, /proc
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

# An interface name is followed directly by a colon and, for large counters,
# by the first number too: the colons become spaces so the columns line up.
tr ':' ' ' < /proc/net/dev | awk '
    # The first two lines are headers.
    NR > 2 && $1 != "lo" {
        printf "metric rx_bytes %.0f iface=%s\n", $2, $1
        printf "metric tx_bytes %.0f iface=%s\n", $10, $1
    }
'
