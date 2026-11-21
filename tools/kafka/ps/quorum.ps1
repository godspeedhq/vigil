    # The quorum's state, then each controller's (and observer's) replication
    # of the metadata log. A cluster on ZooKeeper has no quorum: kraft 0.
    $rc = Invoke-Kafka 'kafka-metadata-quorum' ($conn + @('describe', '--status')) -Soft
    if ($rc -eq 2) { return }
    if ($rc -eq 1) { Write-Output 'metric kraft 0'; return }
    Write-Output 'metric kraft 1'
    $names = @{ LeaderId = 'leader_id'; LeaderEpoch = 'leader_epoch'; HighWatermark = 'high_watermark'; MaxFollowerLag = 'max_follower_lag'; MaxFollowerLagTimeMs = 'max_follower_lag_ms' }
    foreach ($l in ($script:out -split "`r?`n")) {
        if ($l -cmatch '^(\w+):\s*(-?\d+)\s*$' -and $names.ContainsKey($Matches[1])) { Write-Metric $names[$Matches[1]] $Matches[2] }
        elseif ($l -cmatch '^CurrentVoters:') { Write-Output "metric voters $(([regex]::Matches($l, '"id":')).Count)" }
        elseif ($l -cmatch '^CurrentObservers:') { Write-Output "metric observers $(([regex]::Matches($l, '"id":')).Count)" }
    }

    # Per node: how far behind the leader's log, and how long since it last
    # fetched and last caught up. A time the leader has not seen is -1: left
    # out. Columns found by their headers: DirectoryId came in Kafka 3.8.
    if ((Invoke-Kafka 'kafka-metadata-quorum' ($conn + @('describe', '--replication'))) -ne 0) { return }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $col = @{}
    foreach ($l in ($script:out -split "`r?`n")) {
        $f = @($l.Trim() -split '\s+')
        if ($f[0] -ceq 'NodeId') { for ($i = 0; $i -lt $f.Count; $i++) { $col[$f[$i]] = $i }; continue }
        if ($f[0] -cnotmatch '^\d+$' -or -not $col.ContainsKey('Lag')) { continue }
        $tags = "node=$($f[0]) role=$($f[$col['Status']].ToLowerInvariant())"
        Write-Metric 'node_lag' $f[$col['Lag']] $tags
        foreach ($k in @(@('LastFetchTimestamp', 'node_fetch_age_seconds'), @('LastCaughtUpTimestamp', 'node_caught_up_age_seconds'))) {
            $v = $f[$col[$k[0]]]
            if ($v -cmatch '^\d+$') { Write-Metric $k[1] ([Math]::Max(0, $now - [long][Math]::Floor([long]$v / 1000))) $tags }
        }
    }
