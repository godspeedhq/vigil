# Every group's state and members. Consumer groups, from
# kafka-consumer-groups:
#   GROUP COORDINATOR (ID) ASSIGNMENT-STRATEGY STATE #MEMBERS
# and, with Kafka 4's tools, share and streams groups, each type named by
# kafka-groups. A tool this Kafka does not have, or a group type the
# cluster has not turned on, is left out.
run kafka-consumer-groups "${conn[@]}" --describe --all-groups --state || exit 0
rows=$(printf '%s\n' "$out" | awk '$1 != "GROUP" && NF >= 5 && $NF ~ /^[0-9]+$/ { print "C", $1, $(NF - 1), $NF }')
types=''
if kt kafka-groups > /dev/null && try kafka-groups "${conn[@]}" --list; then
    types=$(printf '%s\n' "$out" | awk '$1 != "GROUP" && NF >= 2 { print "T", $1, tolower($2) }')
fi
for kind in share streams; do
    kt "kafka-$kind-groups" > /dev/null || continue
    try "kafka-$kind-groups" "${conn[@]}" --describe --all-groups --state || continue
    rows=$rows$'\n'$(printf '%s\n' "$out" | awk -v k="$kind" '$1 != "GROUP" && NF >= 4 && $NF ~ /^[0-9]+$/ { print "S", $1, $(NF - 1), $NF, k }')
done
printf '%s\n%s\n' "$types" "$rows" | awk '
    $1 == "T" { type[$2] = $3; next }
    $1 == "C" || $1 == "S" {
        g = $2; st = tolower($3); m = $4
        t = ($1 == "S") ? $5 : ((g in type) ? type[g] : "classic")
        by[t SUBSEP st]++; all_members += m; groups++
        mem[g] = m; gt[g] = t
        if (st ~ /rebalance|assigning|reconciling/) rebal++
        if (st == "empty") empty++
        if (st == "dead") dead++
    }
    END {
        printf "metric all_groups %d\nmetric all_members %d\n", groups, all_members
        printf "metric rebalancing %d\nmetric empty %d\nmetric dead %d\n", rebal, empty, dead
        for (k in by) { split(k, p, SUBSEP); printf "metric groups %d type=%s state=%s\n", by[k], p[1], p[2] }
        n = 0
        for (g in mem) { if (++n > 150) { hidden++; continue }; printf "metric members %d group=%s type=%s\n", mem[g], g, gt[g] }
        printf "metric groups_not_shown %d\n", hidden
    }'
exit 0
