-- How long since RMAN last backed up the database and its archived logs,
-- from the control file's record of RMAN's jobs, and what failed.
UNION ALL SELECT 1, x.n, NVL(ROUND((SYSDATE - MAX(j.end_time)) * 86400), -1), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT 'full_age_seconds' AS n, 'DB FULL' AS t FROM dual
          UNION ALL SELECT 'incremental_age_seconds', 'DB INCR' FROM dual
          UNION ALL SELECT 'archivelog_age_seconds', 'ARCHIVELOG' FROM dual) x
    LEFT JOIN v$rman_backup_job_details j ON j.input_type = x.t AND j.status LIKE 'COMPLETED%'
    GROUP BY x.n
UNION ALL SELECT 2, 'failed_24h', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$rman_backup_job_details WHERE status IN ('FAILED', 'COMPLETED WITH ERRORS') AND start_time > SYSDATE - 1
UNION ALL SELECT 3, 'running', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$rman_backup_job_details WHERE status LIKE 'RUNNING%'
-- The last database backup that completed: its size and how long it took.
UNION ALL SELECT 4, x.n, x.v, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT output_bytes, elapsed_seconds FROM v$rman_backup_job_details
          WHERE input_type IN ('DB FULL', 'DB INCR') AND status LIKE 'COMPLETED%'
          ORDER BY end_time DESC FETCH FIRST 1 ROWS ONLY) l
    CROSS APPLY (SELECT 'last_bytes' AS n, l.output_bytes AS v FROM dual
                 UNION ALL SELECT 'last_seconds', l.elapsed_seconds FROM dual) x
