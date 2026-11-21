    # The controller's view, from JMX: which node is the active controller,
    # and from it the cluster's brokers, topics and partitions, offline
    # partitions, leaders not where they prefer, metadata errors, how far its
    # metadata lags, leader elections (unclean ones too, a running total), and
    # its event queue. Only the active controller's values say anything about
    # the cluster: the other nodes report active_controller 0 and nothing else.
    $kcNames = @{
        ActiveBrokerCount = 'brokers'; FencedBrokerCount = 'fenced_brokers'; GlobalTopicCount = 'topics'; GlobalPartitionCount = 'partitions'
        OfflinePartitionsCount = 'offline_partitions'; PreferredReplicaImbalanceCount = 'preferred_imbalance'; MetadataErrorCount = 'metadata_errors'
        LastAppliedRecordLagMs = 'metadata_lag_ms'; TimedOutBrokerHeartbeatCount = 'timed_out_heartbeats'; NewActiveControllersCount = 'controller_changes'
    }
    $statNames = @{ UncleanLeaderElectionsPerSec = 'unclean_elections_count'; LeaderElectionRateAndTimeMs = 'elections_count'; ElectionFromEligibleLeaderReplicasPerSec = 'eligible_leader_elections_count' }
    Invoke-JmxEach {
        $active = $null; $vals = New-Map
        foreach ($r in $rows) {
            $name = Get-Key $r.Name 'name'
            if ($r.Name -cmatch 'type=KafkaController,' -and $r.Attr -ceq 'Value') {
                if ($name -ceq 'ActiveControllerCount') { $active = [int]([double](ConvertTo-Num $r.Value) -gt 0) }
                elseif ($kcNames.ContainsKey($name)) { $vals[$kcNames[$name]] = $r.Value }
            }
            elseif ($r.Name -cmatch 'type=ControllerStats,' -and $r.Attr -ceq 'Count' -and $statNames.ContainsKey($name)) { $vals[$statNames[$name]] = $r.Value }
            elseif ($name -ceq 'EventQueueSize' -and $r.Attr -ceq 'Value') { $vals['event_queue'] = $r.Value }
            elseif ($name -ceq 'EventQueueTimeMs' -and $r.Attr -ceq '99thPercentile') { $vals['event_queue_ms_p99'] = $r.Value }
        }
        if ($null -ne $active) {
            Write-Output "metric active_controller $active broker=$broker"
            if ($active) { foreach ($k in $vals.Keys) { Write-Metric $k $vals[$k] "broker=$broker" } }
        }
    } @('kafka.controller:type=KafkaController,name=*', 'kafka.controller:type=ControllerStats,name=*', 'kafka.controller:type=ControllerEventManager,name=*') 'Version,Value,Count,99thPercentile'
