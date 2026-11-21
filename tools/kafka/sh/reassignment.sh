# The partition moves in progress, as the cluster lists them:
#   orders-0: replicas: 2,1. adding: 2. removing: 1.
# A topic's name may hold a "-": a partition's topic is all before its last.
run kafka-reassign-partitions "${conn[@]}" --list || exit 0
printf '%s\n' "$out" | awk '
    /: replicas: / {
        name = $1; sub(/:$/, "", name); topic = name; sub(/-[0-9]+$/, "", topic)
        parts++; per[topic]++
        if (match($0, /adding: [0-9,]+/)) adding += split(substr($0, RSTART + 8, RLENGTH - 8), x, ",")
        if (match($0, /removing: [0-9,]+/)) removing += split(substr($0, RSTART + 10, RLENGTH - 10), x, ",")
    }
    END {
        printf "metric partitions %d\nmetric adding_replicas %d\nmetric removing_replicas %d\n", parts, adding, removing
        n = 0; for (t in per) n++
        printf "metric topics %d\n", n
        n = 0; for (t in per) if (++n <= 100) printf "metric topic_partitions %d topic=%s\n", per[t], t
    }'
exit 0
