# memory.sh - memory in use: active, wired and compressed pages.
total=$(sysctl -n hw.memsize)
vm_stat | awk -v t="$total" '
    /page size of/ { size = $8 }
    /^Pages active:/ { used += $3 + 0 }
    /^Pages wired down:/ { used += $4 + 0 }
    /^Pages occupied by compressor:/ { used += $5 + 0 }
    END {
        b = used * size
        printf "metric used_pct %d\n", 100 * b / t
        printf "metric used_bytes %.0f\n", b
        printf "metric total_bytes %.0f\n", t
    }'
