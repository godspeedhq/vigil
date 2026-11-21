# Each broker's traffic, all topics together (a running total each), from
# JMX. kafka.server:type=BrokerTopicMetrics,name=* matches only the
# all-topics objects: a topic's own have a topic key too.
report() {
    printf '%s\n' "$out" | awk -F '\t' -v b="$broker" "$AWKFMT"'
        BEGIN {
            m["MessagesInPerSec"] = "messages_in_count"; m["BytesInPerSec"] = "bytes_in_count"
            m["BytesOutPerSec"] = "bytes_out_count"; m["BytesRejectedPerSec"] = "bytes_rejected_count"
            m["ReplicationBytesInPerSec"] = "replication_bytes_in_count"; m["ReplicationBytesOutPerSec"] = "replication_bytes_out_count"
            m["TotalProduceRequestsPerSec"] = "produce_requests_count"; m["TotalFetchRequestsPerSec"] = "fetch_requests_count"
            m["FailedProduceRequestsPerSec"] = "failed_produce_requests_count"; m["FailedFetchRequestsPerSec"] = "failed_fetch_requests_count"
            m["ProduceMessageConversionsPerSec"] = "produce_conversions_count"; m["FetchMessageConversionsPerSec"] = "fetch_conversions_count"
            m["InvalidMessageCrcRecordsPerSec"] = "invalid_crc_records_count"; m["InvalidOffsetOrSequenceRecordsPerSec"] = "invalid_sequence_records_count"
        }
        $1 ~ /type=BrokerTopicMetrics,name=/ && $1 ~ /:Count$/ {
            n = $1; sub(/.*name=/, "", n); sub(/:Count$/, "", n)
            if ((n in m) && (v = fmt($2)) != "") printf "metric %s %s broker=%s\n", m[n], v, b
        }'
}
jmx_each report --object-name 'kafka.server:type=BrokerTopicMetrics,name=*' --attributes Version,Count
exit 0
