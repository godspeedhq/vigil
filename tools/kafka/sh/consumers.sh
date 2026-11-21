# Every consumer group's committed offsets against the end of each
# partition, one row a partition:
#   GROUP TOPIC PARTITION CURRENT-OFFSET LOG-END-OFFSET LAG CONSUMER-ID HOST CLIENT-ID
# A partition with no committed offset shows "-": its lag is not known.
run kafka-consumer-groups "${conn[@]}" --describe --all-groups || exit 0
printf '%s\n' "$out" | awk '
    $1 != "GROUP" && NF >= 6 && $3 ~ /^[0-9]+$/ {
        g = $1; t = $2; k = g SUBSEP t
        seen[g] = 1; pair[k] = 1
        if ($6 ~ /^[0-9]+$/) {
            lag[k] += $6; glag[g] += $6; total += $6
            if ($6 > max[k]) max[k] = $6
        } else nooff[k]++
    }
    END {
        for (g in seen) groups++
        printf "metric groups %d\nmetric total_lag %.0f\n", groups, total
        n = 0
        for (k in pair) {
            if (++n > 150) { hidden++; continue }
            split(k, p, SUBSEP)
            tags = "group=" p[1] " topic=" p[2]
            printf "metric lag %.0f %s\nmetric lag_max %.0f %s\n", lag[k], tags, max[k], tags
            if (nooff[k]) printf "metric no_offset_partitions %d %s\n", nooff[k], tags
        }
        printf "metric pairs_not_shown %d\n", hidden
        n = 0; for (g in seen) if (++n <= 150) printf "metric group_lag %.0f group=%s\n", glag[g], g
    }'
exit 0
