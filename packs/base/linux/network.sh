# network.sh - bytes each interface has moved since boot, from /proc/net/dev.
tr ':' ' ' < /proc/net/dev |
    awk 'NR > 2 && $1 != "lo" {
        printf "metric rx_bytes %.0f iface=%s\n", $2, $1
        printf "metric tx_bytes %.0f iface=%s\n", $10, $1
    }'
