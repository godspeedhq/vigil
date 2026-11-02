# memory.sh - memory in use, from /proc/meminfo.
awk '$1 == "MemTotal:" { t = $2 } $1 == "MemAvailable:" { a = $2 }
    END {
        if (t > 0) {
            printf "metric used_pct %d\n", 100 * (t - a) / t
            printf "metric used_bytes %.0f\n", (t - a) * 1024
            printf "metric total_bytes %.0f\n", t * 1024
        }
    }' /proc/meminfo
