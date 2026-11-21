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
report() {
    printf '%s\n' "$out" | awk -F '\t' -v b="$broker" "$AWKFMT"'
        function out(name, v, tags) { if ((v = fmt(v)) != "") printf "metric %s %s broker=%s%s\n", name, v, b, tags }
        /RequestMetrics,name=TotalTimeMs,request=/ {
            r = $1; sub(/.*request=/, "", r); a = r; sub(/^[^:]*:/, "", a); sub(/:.*/, "", r)
            if (a == "99thPercentile") out("total_ms_p99", $2, " request=" r)
            else if (a == "Count") out("requests_count", $2, " request=" r)
            next
        }
        /RequestMetrics,name=RequestQueueTimeMs,request=.*:99thPercentile/ { r = $1; sub(/.*request=/, "", r); sub(/:.*/, "", r); out("queue_ms_p99", $2, " request=" r); next }
        /RequestMetrics,name=RemoteTimeMs,request=.*:99thPercentile/ { r = $1; sub(/.*request=/, "", r); sub(/:.*/, "", r); out("remote_ms_p99", $2, " request=" r); next }
        /RequestChannel,name=RequestQueueSize:Value/ { out("request_queue", $2, ""); next }
        /RequestChannel,name=ResponseQueueSize:Value/ { out("response_queue", $2, ""); next }
        /PurgatorySize,delayedOperation=/ { o = $1; sub(/.*delayedOperation=/, "", o); sub(/:.*/, "", o); out("purgatory", $2, " operation=" tolower(o)); next }
        # The idle shares are fractions, 0 to 1: as percents.
        /RequestHandlerAvgIdlePercent:OneMinuteRate/ { if ((v = fmt($2)) != "") out("handler_idle_pct", v * 100, ""); next }
        /NetworkProcessorAvgIdlePercent:Value/ { if ((v = fmt($2)) != "") out("network_idle_pct", v * 100, "") }'
}
objs=()
for r in Produce FetchConsumer FetchFollower; do
    objs+=(--object-name "kafka.network:type=RequestMetrics,name=TotalTimeMs,request=$r"
        --object-name "kafka.network:type=RequestMetrics,name=RequestQueueTimeMs,request=$r"
        --object-name "kafka.network:type=RequestMetrics,name=RemoteTimeMs,request=$r")
done
jmx_each report "${objs[@]}" \
    --object-name 'kafka.network:type=RequestChannel,name=RequestQueueSize' \
    --object-name 'kafka.network:type=RequestChannel,name=ResponseQueueSize' \
    --object-name 'kafka.server:type=DelayedOperationPurgatory,name=PurgatorySize,delayedOperation=Produce' \
    --object-name 'kafka.server:type=DelayedOperationPurgatory,name=PurgatorySize,delayedOperation=Fetch' \
    --object-name 'kafka.server:type=KafkaRequestHandlerPool,name=RequestHandlerAvgIdlePercent' \
    --object-name 'kafka.network:type=SocketServer,name=NetworkProcessorAvgIdlePercent' \
    --attributes Version,Value,Count,99thPercentile,OneMinuteRate
exit 0
