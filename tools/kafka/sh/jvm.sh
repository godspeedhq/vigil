# Each broker's JVM and its logs, from JMX: heap used against the most it
# may use, garbage collection (a running total of collections and of the
# time they took, per collector), open files against the limit, CPU,
# threads, how long it has run; how long flushing the log to disk takes,
# the log cleaner (compaction), and log directories offline.
now=$(date +%s)
report() {
    printf '%s\n' "$out" | awk -F '\t' -v b="$broker" -v now="$now" "$AWKFMT"'
        function out(name, v, tags) { if ((v = fmt(v)) != "") printf "metric %s %s broker=%s%s\n", name, v, b, tags }
        /:HeapMemoryUsage/ {
            if (match($2, /used=[0-9]+/)) out("heap_used_bytes", substr($2, RSTART + 5, RLENGTH - 5), "")
            if (match($2, /max=[0-9]+/)) out("heap_max_bytes", substr($2, RSTART + 4, RLENGTH - 4), "")
            next
        }
        /type=GarbageCollector/ {
            g = $1; sub(/.*name=/, "", g); sub(/,type=.*/, "", g); gsub(/[^A-Za-z0-9_.-]/, "_", g)
            if ($1 ~ /:CollectionCount$/) out("gc_count", $2, " gc=" g)
            else if ($1 ~ /:CollectionTime$/) out("gc_ms_count", $2, " gc=" g)
            next
        }
        /:OpenFileDescriptorCount/ { out("open_files", $2, ""); next }
        /:MaxFileDescriptorCount/ { out("max_files", $2, ""); next }
        /:ProcessCpuLoad/ { if ((v = fmt($2)) != "" && v >= 0) out("cpu_pct", v * 100, ""); next }
        /:ThreadCount/ { out("threads", $2, ""); next }
        /app-info,id=[0-9]+:StartTimeMs/ { if ((v = fmt($2)) != "") out("uptime_seconds", now - int(v / 1000), ""); next }
        /LogFlushRateAndTimeMs:99thPercentile/ { out("flush_ms_p99", $2, ""); next }
        /LogFlushRateAndTimeMs:Count/ { out("flushes_count", $2, ""); next }
        /name=max-dirty-percent:Value/ { out("cleaner_max_dirty_pct", $2, ""); next }
        /name=time-since-last-run-ms:Value/ { out("cleaner_idle_seconds", int($2 / 1000), ""); next }
        /name=DeadThreadCount:Value/ { out("cleaner_dead_threads", $2, ""); next }
        # Before the cleaner first runs this holds nonsense, below 0.
        /name=max-clean-time-secs:Value/ { if ($2 + 0 >= 0) out("cleaner_max_clean_seconds", $2, ""); next }
        /OfflineLogDirectoryCount:Value/ { out("offline_log_dirs", $2, "") }'
}
jmx_each report \
    --object-name 'java.lang:type=Memory' \
    --object-name 'java.lang:type=GarbageCollector,name=*' \
    --object-name 'java.lang:type=OperatingSystem' \
    --object-name 'java.lang:type=Threading' \
    --object-name 'kafka.log:type=LogFlushStats,name=LogFlushRateAndTimeMs' \
    --object-name 'kafka.log:type=LogCleanerManager,name=*' \
    --object-name 'kafka.log:type=LogCleaner,name=*' \
    --object-name 'kafka.log:type=LogManager,name=OfflineLogDirectoryCount' \
    --attributes Version,StartTimeMs,HeapMemoryUsage,CollectionCount,CollectionTime,OpenFileDescriptorCount,MaxFileDescriptorCount,ProcessCpuLoad,ThreadCount,Value,99thPercentile,Count
exit 0
