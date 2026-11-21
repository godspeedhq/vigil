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

    # Every broker's log directories: their partitions and sizes, any error
    # (an offline directory), and future replicas (a move between
    # directories). The tool answers in one line of JSON, read as the bash
    # script reads it, split at each "{": Windows PowerShell's ConvertFrom-Json
    # refuses one longer than 2 MB, as a large cluster's is. Every partition
    # is then a piece of its own, and each directory's logDir and error come
    # after its partitions.
    if ((Invoke-Kafka 'kafka-log-dirs' ($conn + @('--describe'))) -ne 0) { return }
    $json = @($script:out -split "`r?`n" | Where-Object { $_.StartsWith('{') })
    $json = if ($json.Count) { $json[-1] } else { '' }
    $dirs = New-Object 'System.Collections.Generic.List[object]'
    $bsize = New-Map; $tsize = New-Map
    $broker = ''; $size = [double]0; $parts = 0; $future = 0
    foreach ($piece in $json.Split('{')) {
        if ($piece -cmatch '"broker":(\d+)') { $broker = $Matches[1]; continue }
        if ($piece -cmatch '"partition":"([^"]*)"') {
            $topic = $Matches[1] -creplace '-\d+$', ''
            $s = if ($piece -cmatch '"size":(\d+)') { [double]$Matches[1] } else { [double]0 }
            $size += $s; $parts++
            $tsize[$topic] = [double]$tsize[$topic] + $s
            $bsize[$broker] = [double]$bsize[$broker] + $s
            if ($piece -cmatch '"isFuture":true') { $future++ }
        }
        if ($piece -cmatch '"logDir":"([^"]*)"') {
            $dirs.Add(@{ Broker = $broker; Dir = (ConvertTo-Tag $Matches[1]); Size = $size; Parts = $parts; Offline = [int]($piece -cnotmatch '"error":null'); Future = $future })
            $size = [double]0; $parts = 0; $future = 0
        }
    }
    $offline = 0
    foreach ($d in $dirs) {
        $tags = "broker=$($d.Broker) dir=$($d.Dir)"
        Write-Metric 'size_bytes' $d.Size $tags
        Write-Output "metric partitions $($d.Parts) $tags"
        Write-Output "metric offline $($d.Offline) $tags"
        Write-Output "metric future_replicas $($d.Future) $tags"
        $offline += $d.Offline
    }
    Write-Output "metric dirs $($dirs.Count)"
    Write-Output "metric dirs_offline $offline"
    foreach ($b in $bsize.Keys) { Write-Metric 'broker_size_bytes' $bsize[$b] "broker=$b" }
    $n = 0; $hidden = 0
    foreach ($t in $tsize.Keys) { if (++$n -gt 100) { $hidden++; continue }; Write-Metric 'topic_size_bytes' $tsize[$t] "topic=$t" }
    Write-Output "metric topics_not_shown $hidden"

    # Tiered storage (Kafka 3.6 on), from JMX when KAFKA_JMX is set: what each
    # broker has copied to remote storage, and what it still has to copy. A
    # broker without tiered storage has neither.
    Invoke-JmxEach {
        foreach ($r in $rows) {
            if ($r.Attr -cne 'Value') { continue }
            switch -CaseSensitive (Get-Key $r.Name 'name') {
                'RemoteLogSizeBytes' { Write-Metric 'remote_size_bytes' $r.Value "broker=$broker" }
                'RemoteCopyLagBytes' { Write-Metric 'remote_copy_lag_bytes' $r.Value "broker=$broker" }
            }
        }
    } @('kafka.server:type=BrokerTopicMetrics,name=RemoteLogSizeBytes', 'kafka.server:type=BrokerTopicMetrics,name=RemoteCopyLagBytes') 'Version,Value'
