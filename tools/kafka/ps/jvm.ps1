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

    # Each broker's JVM and its logs, from JMX: heap used against the most it
    # may use, garbage collection (a running total of collections and of the
    # time they took, per collector), open files against the limit, CPU,
    # threads, how long it has run; how long flushing the log to disk takes,
    # the log cleaner (compaction), and log directories offline.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Invoke-JmxEach {
        $b = "broker=$broker"
        foreach ($r in $rows) {
            $name = Get-Key $r.Name 'name'
            if ($r.Attr -ceq 'HeapMemoryUsage') {
                if ($r.Value -cmatch 'used=(\d+)') { Write-Metric 'heap_used_bytes' $Matches[1] $b }
                if ($r.Value -cmatch 'max=(\d+)') { Write-Metric 'heap_max_bytes' $Matches[1] $b }
                continue
            }
            if ($r.Name -cmatch 'type=GarbageCollector') {
                $g = $name -creplace '[^A-Za-z0-9_.-]', '_'
                if ($r.Attr -ceq 'CollectionCount') { Write-Metric 'gc_count' $r.Value "$b gc=$g" }
                elseif ($r.Attr -ceq 'CollectionTime') { Write-Metric 'gc_ms_count' $r.Value "$b gc=$g" }
                continue
            }
            switch -CaseSensitive ("$name`:$($r.Attr)") {
                ':OpenFileDescriptorCount' { Write-Metric 'open_files' $r.Value $b }
                ':MaxFileDescriptorCount' { Write-Metric 'max_files' $r.Value $b }
                ':ProcessCpuLoad' { $v = ConvertTo-Num $r.Value; if ($null -ne $v -and [double]$v -ge 0) { Write-Metric 'cpu_pct' ([double]$v * 100) $b } }
                ':ThreadCount' { Write-Metric 'threads' $r.Value $b }
                ':StartTimeMs' { $v = ConvertTo-Num $r.Value; if ($null -ne $v -and $r.Name -cmatch 'app-info,id=') { Write-Metric 'uptime_seconds' ($now - [long][Math]::Floor([double]$v / 1000)) $b } }
                'LogFlushRateAndTimeMs:99thPercentile' { Write-Metric 'flush_ms_p99' $r.Value $b }
                'LogFlushRateAndTimeMs:Count' { Write-Metric 'flushes_count' $r.Value $b }
                'max-dirty-percent:Value' { Write-Metric 'cleaner_max_dirty_pct' $r.Value $b }
                'time-since-last-run-ms:Value' { $v = ConvertTo-Num $r.Value; if ($null -ne $v) { Write-Metric 'cleaner_idle_seconds' ([long][Math]::Floor([double]$v / 1000)) $b } }
                'DeadThreadCount:Value' { Write-Metric 'cleaner_dead_threads' $r.Value $b }
                # Before the cleaner first runs this holds nonsense, below 0.
                'max-clean-time-secs:Value' { $v = ConvertTo-Num $r.Value; if ($null -ne $v -and [double]$v -ge 0) { Write-Metric 'cleaner_max_clean_seconds' $v $b } }
                'OfflineLogDirectoryCount:Value' { Write-Metric 'offline_log_dirs' $r.Value $b }
            }
        }
    } @('java.lang:type=Memory', 'java.lang:type=GarbageCollector,name=*', 'java.lang:type=OperatingSystem', 'java.lang:type=Threading',
        'kafka.log:type=LogFlushStats,name=LogFlushRateAndTimeMs', 'kafka.log:type=LogCleanerManager,name=*', 'kafka.log:type=LogCleaner,name=*',
        'kafka.log:type=LogManager,name=OfflineLogDirectoryCount') 'Version,StartTimeMs,HeapMemoryUsage,CollectionCount,CollectionTime,OpenFileDescriptorCount,MaxFileDescriptorCount,ProcessCpuLoad,ThreadCount,Value,99thPercentile,Count'
