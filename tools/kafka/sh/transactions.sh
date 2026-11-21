# Transactions by state, then those open longer than KAFKA_TXN_LONG seconds
# (default 300). Counts only: a transactional id names an application.
#   TransactionalId Coordinator ProducerId TransactionState
long=${KAFKA_TXN_LONG:-300}
case $long in '' | *[!0-9]*) echo "@JOB@: KAFKA_TXN_LONG is '$long': give it in seconds" >&2; exit 1 ;; esac
run kafka-transactions "${conn[@]}" list || exit 0
printf '%s\n' "$out" | awk '
    $1 != "TransactionalId" && NF >= 4 { st = tolower($4); by[st]++; n++ }
    END {
        printf "metric all_transactions %d\n", n
        for (s in by) printf "metric transactions %d state=%s\n", by[s], s
        printf "metric ongoing %d\n", by["ongoing"]
    }'
# The filter is by age, whatever the state: only those still ongoing count.
run kafka-transactions "${conn[@]}" list --duration-filter "$((long * 1000))" || exit 0
printf '%s\n' "$out" | awk '$1 != "TransactionalId" && NF >= 4 && tolower($4) == "ongoing" { n++ } END { printf "metric long_running %d\n", n }'
exit 0
