# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# A fragment of the kafka pack: tools/kafka/gen.py writes packs/kafka from it.

# Every broker's log directories: their partitions and sizes, any error (an
# offline directory), and future replicas (a move between directories). The
# tool answers in one line of JSON; split at each "{", every partition is a
# line of its own, and each directory's logDir and error come after its
# partitions.
run kafka-log-dirs "${conn[@]}" --describe || exit 0
printf '%s\n' "$out" | grep '^{' | tail -n 1 | tr '{' '\n' | awk '
    /"broker":/ { b = $0; sub(/.*"broker":/, "", b); sub(/[^0-9].*/, "", b); broker = b; next }
    /"partition":/ {
        p = $0; sub(/.*"partition":"/, "", p); sub(/".*/, "", p); topic = p; sub(/-[0-9]+$/, "", topic)
        s = $0; sub(/.*"size":/, "", s); sub(/[^0-9].*/, "", s)
        size += s; parts++; tsize[topic] += s; bsize[broker] += s
        if ($0 ~ /"isFuture":true/) future++
    }
    /"logDir":/ {
        d = $0; sub(/.*"logDir":"/, "", d); sub(/".*/, "", d); gsub(/[[:space:][:cntrl:]]/, "_", d)
        err = ($0 ~ /"error":null/) ? 0 : 1
        k = broker SUBSEP d; dsize[k] = size; dparts[k] = parts; derr[k] = err; dfut[k] = future
        size = 0; parts = 0; future = 0
    }
    END {
        for (k in dsize) {
            split(k, x, SUBSEP); tags = "broker=" x[1] " dir=" x[2]
            printf "metric size_bytes %.0f %s\nmetric partitions %d %s\nmetric offline %d %s\nmetric future_replicas %d %s\n", dsize[k], tags, dparts[k], tags, derr[k], tags, dfut[k], tags
            dirs++; if (derr[k]) offline++
        }
        printf "metric dirs %d\nmetric dirs_offline %d\n", dirs, offline
        for (b in bsize) printf "metric broker_size_bytes %.0f broker=%s\n", bsize[b], b
        n = 0; for (t in tsize) { if (++n > 100) { hidden++; continue }; printf "metric topic_size_bytes %.0f topic=%s\n", tsize[t], t }
        printf "metric topics_not_shown %d\n", hidden
    }'

# Tiered storage (Kafka 3.6 on), from JMX when KAFKA_JMX is set: what each
# broker has copied to remote storage, and what it still has to copy. A
# broker without tiered storage has neither.
remote() {
    printf '%s\n' "$out" | awk -F '\t' -v b="$broker" "$AWKFMT"'
        /name=RemoteLogSizeBytes:Value/ { if ((v = fmt($2)) != "") printf "metric remote_size_bytes %s broker=%s\n", v, b }
        /name=RemoteCopyLagBytes:Value/ { if ((v = fmt($2)) != "") printf "metric remote_copy_lag_bytes %s broker=%s\n", v, b }'
}
jmx_each remote \
    --object-name 'kafka.server:type=BrokerTopicMetrics,name=RemoteLogSizeBytes' \
    --object-name 'kafka.server:type=BrokerTopicMetrics,name=RemoteCopyLagBytes' \
    --attributes Version,Value
exit 0
