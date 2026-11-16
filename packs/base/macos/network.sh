#!/usr/bin/env bash
#
# network.sh - network traffic on macOS
#
# Reports what each network interface has moved since boot. These are
# running totals: graph them as a rate. Loopback and interfaces that have
# moved nothing are left out.
#
# Metrics:
#   rx_bytes    bytes received (tag: iface)
#   tx_bytes    bytes sent (tag: iface)
#   rx_packets  packets received (tag: iface)
#   tx_packets  packets sent (tag: iface)
#   rx_errors   received packets with errors (tag: iface)
#   tx_errors   packets that failed to send (tag: iface)
#   tx_drops    packets dropped before sending (tag: iface)
#   rx_drops is not reported: macOS does not count dropped incoming packets
#   per interface
#
# Example output:
#   metric rx_bytes 1415005394 iface=en0
#   metric tx_bytes 283001078 iface=en0
#   metric rx_packets 1872264 iface=en0
#   metric tx_packets 940124 iface=en0
#   metric rx_errors 0 iface=en0
#   metric tx_errors 0 iface=en0
#   metric tx_drops 0 iface=en0
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
# Requires: bash, netstat, awk
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

# -i: interfaces. -b: bytes too. -d: drops too. -n: numbers, not names.
report=$(netstat -ibdn 2> /dev/null) || exit 1

printf '%s\n' "$report" | awk '
    # An interface has several lines: the <Link#n> one has the totals. The
    # address column may be empty, so the counters are found from the end:
    # Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll Drop.
    $3 ~ /^<Link#/ && $1 !~ /^lo/ {
        received = $(NF - 5)
        sent = $(NF - 2)
        if (received + sent > 0) {
            printf "metric rx_bytes %.0f iface=%s\n", received, $1
            printf "metric tx_bytes %.0f iface=%s\n", sent, $1
            printf "metric rx_packets %.0f iface=%s\n", $(NF - 7), $1
            printf "metric tx_packets %.0f iface=%s\n", $(NF - 4), $1
            printf "metric rx_errors %.0f iface=%s\n", $(NF - 6), $1
            printf "metric tx_errors %.0f iface=%s\n", $(NF - 3), $1
            printf "metric tx_drops %.0f iface=%s\n", $NF, $1
        }
    }
'
