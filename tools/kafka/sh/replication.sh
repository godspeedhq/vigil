# Every partition: its leader, replicas, in-sync replicas, eligible leader
# replicas, and any move in progress. A topic's min.insync.replicas is in
# its Configs when it is not Kafka's default, 1.
run kafka-topics "${conn[@]}" --describe || exit 0
printf '%s\n' "$out" | grep -q '^Topic: ' || no_topics
printf '%s\n' "$out" | awk -F '\t' '
    function val(f,  i) { i = index(f, ": "); return i ? substr(f, i + 2) : "" }
    function count(list) { return list == "" ? 0 : split(list, tmp, ",") }
    /^Topic: / {
        topic = val($1); minisr[topic] = 1; topics++
        for (i = 1; i <= NF; i++) if ($i ~ /^Configs: /) {
            if (match($i, /(^|[ ,])min\.insync\.replicas=[0-9]+/)) {
                v = substr($i, RSTART, RLENGTH); sub(/.*=/, "", v); minisr[topic] = v + 0
            }
        }
        next
    }
    /Partition: / {
        leader = ""; reps = ""; isr = ""; elr = ""; moving = 0
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^Topic: /) topic = val($i)
            else if ($i ~ /^Leader: /) leader = val($i)
            else if ($i ~ /^Replicas: /) reps = val($i)
            else if ($i ~ /^Isr: /) isr = val($i)
            else if ($i ~ /^Elr: /) elr = val($i)
            else if ($i ~ /^(Adding|Removing) Replicas: / && val($i) != "") moving = 1
        }
        parts++
        r = count(reps); s = count(isr); split(reps, first, ",")
        if (leader == "none" || leader == "-1" || leader == "") { offline++; off_t[topic]++ }
        else if (leader != first[1]) notpref++
        if (s < r) { urp++; urp_t[topic]++ }
        if (s < minisr[topic]) { under++; under_t[topic]++ }
        else if (s == minisr[topic] && s < r) atmin++
        if (count(elr) > 0) elrs++
        if (moving) moves++
    }
    END {
        printf "metric topics %d\nmetric partitions %d\n", topics, parts
        printf "metric under_replicated %d\nmetric offline %d\nmetric under_min_isr %d\n", urp, offline, under
        printf "metric at_min_isr %d\nmetric not_preferred_leader %d\nmetric with_eligible_leaders %d\nmetric reassigning %d\n", atmin, notpref, elrs, moves
        # The topics with a partition in trouble, by name (at most 100 of each).
        n = 0; for (t in urp_t) if (++n <= 100) printf "metric topic_under_replicated %d topic=%s\n", urp_t[t], t
        n = 0; for (t in off_t) if (++n <= 100) printf "metric topic_offline %d topic=%s\n", off_t[t], t
        n = 0; for (t in under_t) if (++n <= 100) printf "metric topic_under_min_isr %d topic=%s\n", under_t[t], t
    }'
exit 0
