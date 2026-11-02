# disk.sh - each real file system's use.
df -P -k -x tmpfs -x devtmpfs -x squashfs -x overlay 2> /dev/null |
    awk 'NR > 1 && NF == 6 && $2 > 0 {
        printf "metric used_pct %d mount=%s\n", 100 * $3 / ($3 + $4), $6
        printf "metric used_bytes %.0f mount=%s\n", $3 * 1024, $6
        printf "metric total_bytes %.0f mount=%s\n", $2 * 1024, $6
    }'
