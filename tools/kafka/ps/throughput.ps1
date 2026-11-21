    # Each broker's traffic, all topics together (a running total each), from
    # JMX. kafka.server:type=BrokerTopicMetrics,name=* matches only the
    # all-topics objects: a topic's own have a topic key too.
    $names = @{
        MessagesInPerSec = 'messages_in_count'; BytesInPerSec = 'bytes_in_count'; BytesOutPerSec = 'bytes_out_count'
        BytesRejectedPerSec = 'bytes_rejected_count'; ReplicationBytesInPerSec = 'replication_bytes_in_count'
        ReplicationBytesOutPerSec = 'replication_bytes_out_count'; TotalProduceRequestsPerSec = 'produce_requests_count'
        TotalFetchRequestsPerSec = 'fetch_requests_count'; FailedProduceRequestsPerSec = 'failed_produce_requests_count'
        FailedFetchRequestsPerSec = 'failed_fetch_requests_count'; ProduceMessageConversionsPerSec = 'produce_conversions_count'
        FetchMessageConversionsPerSec = 'fetch_conversions_count'; InvalidMessageCrcRecordsPerSec = 'invalid_crc_records_count'
        InvalidOffsetOrSequenceRecordsPerSec = 'invalid_sequence_records_count'
    }
    Invoke-JmxEach {
        foreach ($r in $rows) {
            if ($r.Attr -cne 'Count' -or $r.Name -cnotmatch 'type=BrokerTopicMetrics,') { continue }
            $n = Get-Key $r.Name 'name'
            if ($names.ContainsKey($n)) { Write-Metric $names[$n] $r.Value "broker=$broker" }
        }
    } @('kafka.server:type=BrokerTopicMetrics,name=*') 'Version,Count'
