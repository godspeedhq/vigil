#!/usr/bin/env bash
#
# network.sh - network traffic on Linux
#
# Reports what each network interface has moved since boot, from
# /proc/net/dev. These are running totals: graph them as a rate. The
# loopback interface is left out, and so are the veth pairs containers
# come and go with: the bridge they join (docker0) carries their traffic.
#
# Metrics:
#   rx_bytes    bytes received (tag: iface)
#   tx_bytes    bytes sent (tag: iface)
#   rx_packets  packets received (tag: iface)
#   tx_packets  packets sent (tag: iface)
#   rx_errors   received packets with errors (tag: iface)
#   tx_errors   packets that failed to send (tag: iface)
#   rx_drops    received packets dropped, for lack of room or of a taker
#               (tag: iface)
#   tx_drops    packets dropped before sending (tag: iface)
#
# Example output:
#   metric rx_bytes 1415005394 iface=eth0
#   metric tx_bytes 283001078 iface=eth0
#   metric rx_packets 1872264 iface=eth0
#   metric tx_packets 940124 iface=eth0
#   metric rx_errors 0 iface=eth0
#   metric tx_errors 0 iface=eth0
#   metric rx_drops 12 iface=eth0
#   metric tx_drops 0 iface=eth0
#
# Reading the results (starting points: tune them to the machine):
#   These are running totals, so there is no good or bad value: graph the rate
#   of change, and compare it with the speed of the link and your usual level.
#   Healthy  steady, and well below the speed of the link; errors at 0.
#   Watch    above 70 percent of the link speed for 15 minutes or more, or
#            errors or drops rising.
#   Act      close to the link speed, no traffic where there should be some,
#            or errors rising steadily: a cable, a port or a driver. Totals
#            restart after a reboot.
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
    # Skips the headers, loopback and the veth pairs containers come and go
    # with: the bridge they join (docker0) carries their traffic.
    NR > 2 && $1 != "lo" && $1 !~ /^veth/ {
        printf "metric rx_bytes %.0f iface=%s\n", $2, $1
        printf "metric tx_bytes %.0f iface=%s\n", $10, $1
        printf "metric rx_packets %.0f iface=%s\n", $3, $1
        printf "metric tx_packets %.0f iface=%s\n", $11, $1
        printf "metric rx_errors %.0f iface=%s\n", $4, $1
        printf "metric tx_errors %.0f iface=%s\n", $12, $1
        printf "metric rx_drops %.0f iface=%s\n", $5, $1
        printf "metric tx_drops %.0f iface=%s\n", $13, $1
    }
'
