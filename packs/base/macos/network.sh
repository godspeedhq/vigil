# network.sh - bytes each interface has moved since boot. Counted from the end
# of the line, since an interface may have no address column.
netstat -ibn |
    awk '$3 ~ /^<Link#/ && $1 !~ /^lo/ && $(NF - 4) + $(NF - 1) > 0 {
        printf "metric rx_bytes %.0f iface=%s\n", $(NF - 4), $1
        printf "metric tx_bytes %.0f iface=%s\n", $(NF - 1), $1
    }'
