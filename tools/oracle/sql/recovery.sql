-- What recovery needs: the fast recovery area and how full it is, the
-- archiver, the redo logs and how often they switch.
UNION ALL SELECT 1, x.n, x.v, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT NVL(SUM(space_limit), 0) AS lim, NVL(SUM(space_used), 0) AS used, NVL(SUM(space_reclaimable), 0) AS recl
          FROM v$recovery_file_dest WHERE name IS NOT NULL) f
    CROSS APPLY (SELECT 'fra_limit_bytes' AS n, f.lim AS v FROM dual
                 UNION ALL SELECT 'fra_used_bytes', f.used FROM dual
                 UNION ALL SELECT 'fra_reclaimable_bytes', f.recl FROM dual
                 -- What cannot be freed for new files, as a percent of the limit.
                 UNION ALL SELECT 'fra_used_pct', CASE WHEN f.lim > 0 THEN ROUND(100 * (f.used - f.recl) / f.lim, 2) END FROM dual) x
UNION ALL SELECT 2, 'flashback_on', CASE WHEN flashback_on = 'YES' THEN 1 ELSE 0 END, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$database
-- Archive destinations in error, each by its name.
UNION ALL SELECT 3, 'archive_dest_errors', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$archive_dest WHERE status IN ('ERROR', 'BAD PARAM')
UNION ALL SELECT 4, 'archive_dest_error', 1, 'dest', LOWER(dest_name), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$archive_dest WHERE status IN ('ERROR', 'BAD PARAM')
UNION ALL SELECT 5, 'log_switches_1h', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$log_history WHERE first_time > SYSDATE - 1 / 24
UNION ALL SELECT 6, 'redo_groups', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$log
UNION ALL SELECT 7, 'redo_group_bytes', MAX(bytes), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$log
-- Groups still needed for crash recovery: their checkpoint is not done.
UNION ALL SELECT 8, 'redo_groups_active', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$log WHERE status = 'ACTIVE'
-- In ARCHIVELOG mode, groups switched out and not yet archived.
UNION ALL SELECT 9, 'redo_groups_not_archived', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$log l CROSS JOIN v$database d
    WHERE d.log_mode = 'ARCHIVELOG' AND l.archived = 'NO' AND l.status <> 'CURRENT'
