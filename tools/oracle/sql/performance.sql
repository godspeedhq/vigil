-- The instance's own counters since it started, read from V$SYSSTAT,
-- V$SYS_TIME_MODEL and V$OSSTAT, none of them in a paid pack: running
-- totals, to graph as a rate.
UNION ALL SELECT 1, x.n, SUM(s.value), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$sysstat s
    JOIN (SELECT 'execute count' AS stat, 'executions_count' AS n FROM dual
          UNION ALL SELECT 'user calls', 'user_calls_count' FROM dual
          UNION ALL SELECT 'user commits', 'commits_count' FROM dual
          UNION ALL SELECT 'user rollbacks', 'rollbacks_count' FROM dual
          UNION ALL SELECT 'logons cumulative', 'logons_count' FROM dual
          UNION ALL SELECT 'parse count (total)', 'parses_count' FROM dual
          UNION ALL SELECT 'parse count (hard)', 'hard_parses_count' FROM dual
          UNION ALL SELECT 'parse count (failures)', 'parse_failures_count' FROM dual
          UNION ALL SELECT 'session logical reads', 'logical_reads_count' FROM dual
          UNION ALL SELECT 'physical reads', 'physical_reads_count' FROM dual
          UNION ALL SELECT 'physical writes', 'physical_writes_count' FROM dual
          UNION ALL SELECT 'redo size', 'redo_bytes_count' FROM dual
          UNION ALL SELECT 'bytes received via SQL*Net from client', 'bytes_received_count' FROM dual
          UNION ALL SELECT 'bytes sent via SQL*Net to client', 'bytes_sent_count' FROM dual
          UNION ALL SELECT 'sorts (disk)', 'disk_sorts_count' FROM dual
          UNION ALL SELECT 'table scans (long tables)', 'long_table_scans_count' FROM dual
          UNION ALL SELECT 'enqueue deadlocks', 'deadlocks_count' FROM dual
          UNION ALL SELECT 'enqueue timeouts', 'lock_timeouts_count' FROM dual
          UNION ALL SELECT 'logons current', 'logons_current' FROM dual
          UNION ALL SELECT 'opened cursors current', 'open_cursors' FROM dual) x ON x.stat = s.name
    GROUP BY x.n
-- Time sessions spent in the database, and on CPU, in milliseconds.
UNION ALL SELECT 2, CASE stat_name WHEN 'DB time' THEN 'db_time_ms_count' ELSE 'db_cpu_ms_count' END, ROUND(SUM(value) / 1000),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$sys_time_model WHERE stat_name IN ('DB time', 'DB CPU') GROUP BY stat_name
-- The machine's CPUs, busy and idle, in milliseconds (summed over CPUs).
UNION ALL SELECT 3, CASE stat_name WHEN 'BUSY_TIME' THEN 'host_busy_ms_count' ELSE 'host_idle_ms_count' END, value * 10,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$osstat WHERE stat_name IN ('BUSY_TIME', 'IDLE_TIME')
-- Blocks found in the buffer cache, as a percent, since the instance started.
UNION ALL SELECT 4, 'buffer_cache_hit_pct',
    ROUND(100 * (1 - SUM(CASE name WHEN 'physical reads cache' THEN value END)
        / NULLIF(SUM(CASE WHEN name IN ('consistent gets from cache', 'db block gets from cache') THEN value END), 0)), 2),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$sysstat WHERE name IN ('physical reads cache', 'consistent gets from cache', 'db block gets from cache')
