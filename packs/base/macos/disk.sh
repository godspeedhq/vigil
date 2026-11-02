# disk.sh - each real volume's use, leaving out the system's own.
df -P -k -l |
    awk 'NR > 1 && NF == 6 && $1 ~ /^\/dev\// && $2 > 0 &&
        $6 !~ /^\/System\/Volumes\/(VM|Preboot|Update|xarts|iSCPreboot|Hardware)/ {
        printf "metric used_pct %d mount=%s\n", 100 * $3 / ($3 + $4), $6
        printf "metric used_bytes %.0f mount=%s\n", $3 * 1024, $6
        printf "metric total_bytes %.0f mount=%s\n", $2 * 1024, $6
    }'
