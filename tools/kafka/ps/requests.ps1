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

    # How each broker serves requests, from JMX: the time produce, consumer
    # fetch and follower fetch requests take (99th percentile, in ms, as the
    # broker measures it over its recent requests) and how many it has served;
    # how long they queue; the request and response queues; requests parked in
    # purgatory; and how idle its request handler and network threads are.
    $objs = @()
    foreach ($r in 'Produce', 'FetchConsumer', 'FetchFollower') {
        foreach ($m in 'TotalTimeMs', 'RequestQueueTimeMs', 'RemoteTimeMs') { $objs += "kafka.network:type=RequestMetrics,name=$m,request=$r" }
    }
    $objs += @('kafka.network:type=RequestChannel,name=RequestQueueSize', 'kafka.network:type=RequestChannel,name=ResponseQueueSize',
        'kafka.server:type=DelayedOperationPurgatory,name=PurgatorySize,delayedOperation=Produce',
        'kafka.server:type=DelayedOperationPurgatory,name=PurgatorySize,delayedOperation=Fetch',
        'kafka.server:type=KafkaRequestHandlerPool,name=RequestHandlerAvgIdlePercent', 'kafka.network:type=SocketServer,name=NetworkProcessorAvgIdlePercent')
    Invoke-JmxEach {
        $b = "broker=$broker"
        foreach ($r in $rows) {
            $name = Get-Key $r.Name 'name'
            $req = Get-Key $r.Name 'request'
            switch -CaseSensitive ("$name`:$($r.Attr)") {
                'TotalTimeMs:99thPercentile' { Write-Metric 'total_ms_p99' $r.Value "$b request=$req" }
                'TotalTimeMs:Count' { Write-Metric 'requests_count' $r.Value "$b request=$req" }
                'RequestQueueTimeMs:99thPercentile' { Write-Metric 'queue_ms_p99' $r.Value "$b request=$req" }
                'RemoteTimeMs:99thPercentile' { Write-Metric 'remote_ms_p99' $r.Value "$b request=$req" }
                'RequestQueueSize:Value' { Write-Metric 'request_queue' $r.Value $b }
                'ResponseQueueSize:Value' { Write-Metric 'response_queue' $r.Value $b }
                'PurgatorySize:Value' { Write-Metric 'purgatory' $r.Value "$b operation=$((Get-Key $r.Name 'delayedOperation').ToLowerInvariant())" }
                # The idle shares are fractions, 0 to 1: as percents.
                'RequestHandlerAvgIdlePercent:OneMinuteRate' { $v = ConvertTo-Num $r.Value; if ($null -ne $v) { Write-Metric 'handler_idle_pct' ([double]$v * 100) $b } }
                'NetworkProcessorAvgIdlePercent:Value' { $v = ConvertTo-Num $r.Value; if ($null -ne $v) { Write-Metric 'network_idle_pct' ([double]$v * 100) $b } }
            }
        }
    } $objs 'Version,Value,Count,99thPercentile,OneMinuteRate'
