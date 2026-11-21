# Each broker as the cluster lists it, then what it holds, from every
# partition's leader, replicas and in-sync replicas.
brokers_list || exit 0
brokers=$out
run kafka-topics "${conn[@]}" --describe || exit 0
{
    printf '%s\n' "$brokers" | sed -n 's/.*(id: \([0-9][0-9]*\) rack: \([^ )]*\)\( isFenced: \([a-z]*\)\)*).*/B \1 \2 \4/p'
    printf '%s\n' "$out" | grep -F 'Partition: '
} | awk -F '\t' '
    function val(f,  i) { i = index(f, ": "); return i ? substr(f, i + 2) : "" }
    $0 ~ /^B / { split($0, b, " "); id = b[2]; known[id] = 1; rack[id] = b[3]; fenced[id] = (b[4] == "true"); next }
    {
        leader = ""; reps = ""; isr = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^Leader: /) leader = val($i)
            else if ($i ~ /^Replicas: /) reps = val($i)
            else if ($i ~ /^Isr: /) isr = val($i)
        }
        if (leader ~ /^[0-9]+$/) leaders[leader]++
        n = split(reps, r, ",")
        delete in_isr; m = split(isr, s, ","); for (j = 1; j <= m; j++) in_isr[s[j]] = 1
        for (j = 1; j <= n; j++) {
            replicas[r[j]]++
            if (!(r[j] in in_isr)) behind[r[j]]++
            if (!(r[j] in known)) unseen[r[j]] = 1
        }
        if (n > 0) preferred[r[1]]++
    }
    END {
        # A broker that holds replicas but is not listed is down: shown as
        # online 0, so its replicas still show where they are.
        for (id in unseen) { known[id] = 1; down[id] = 1 }
        shown = 0
        for (id in known) {
            if (++shown > 150) { hidden++; continue }
            t = "broker=" id " rack=" (rack[id] == "" || rack[id] == "null" ? "none" : rack[id])
            printf "metric online %d %s\n", (id in down) ? 0 : 1, t
            if (!(id in down)) printf "metric fenced %d broker=%s\n", fenced[id], id
            printf "metric leaders %d broker=%s\n", leaders[id], id
            printf "metric replicas %d broker=%s\n", replicas[id], id
            printf "metric out_of_sync_replicas %d broker=%s\n", behind[id], id
            printf "metric preferred_leaders %d broker=%s\n", preferred[id], id
        }
        printf "metric brokers_not_shown %d\n", hidden
    }'
exit 0
