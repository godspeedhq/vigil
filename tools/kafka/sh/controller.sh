# The controller's view, from JMX: which node is the active controller, and
# from it the cluster's brokers, topics and partitions, offline partitions,
# leaders not where they prefer, metadata errors, how far its metadata lags,
# leader elections (unclean ones too, a running total), and its event queue.
# Only the active controller's values say anything about the cluster: the
# other nodes report active_controller 0 and nothing else.
report() {
    printf '%s\n' "$out" | awk -F '\t' -v b="$broker" "$AWKFMT"'
        BEGIN {
            m["ActiveBrokerCount"] = "brokers"; m["FencedBrokerCount"] = "fenced_brokers"
            m["GlobalTopicCount"] = "topics"; m["GlobalPartitionCount"] = "partitions"
            m["OfflinePartitionsCount"] = "offline_partitions"; m["PreferredReplicaImbalanceCount"] = "preferred_imbalance"
            m["MetadataErrorCount"] = "metadata_errors"; m["LastAppliedRecordLagMs"] = "metadata_lag_ms"
            m["TimedOutBrokerHeartbeatCount"] = "timed_out_heartbeats"; m["NewActiveControllersCount"] = "controller_changes"
            s["UncleanLeaderElectionsPerSec"] = "unclean_elections_count"; s["LeaderElectionRateAndTimeMs"] = "elections_count"
            s["ElectionFromEligibleLeaderReplicasPerSec"] = "eligible_leader_elections_count"
        }
        { n = $1; sub(/.*name=/, "", n); a = n; sub(/^[^:]*:/, "", a); sub(/:.*/, "", n) }
        /type=KafkaController,name=ActiveControllerCount:Value/ { active = ($2 + 0 > 0) ? 1 : 0; next }
        /type=KafkaController,/ && a == "Value" && (n in m) { kc[m[n]] = $2; next }
        /type=ControllerStats,/ && a == "Count" && (n in s) { kc[s[n]] = $2; next }
        /name=EventQueueSize:Value/ { kc["event_queue"] = $2; next }
        /name=EventQueueTimeMs:99thPercentile/ { kc["event_queue_ms_p99"] = $2; next }
        END {
            if (active == "") exit
            printf "metric active_controller %d broker=%s\n", active, b
            if (!active) exit
            for (k in kc) if ((v = fmt(kc[k])) != "") printf "metric %s %s broker=%s\n", k, v, b
        }'
}
jmx_each report \
    --object-name 'kafka.controller:type=KafkaController,name=*' \
    --object-name 'kafka.controller:type=ControllerStats,name=*' \
    --object-name 'kafka.controller:type=ControllerEventManager,name=*' \
    --attributes Version,Value,Count,99thPercentile
exit 0
