-- What keeps the database whole: invalid objects, damaged blocks, data
-- files offline or needing recovery, accounts about to expire, and
-- scheduler jobs that failed or broke.
UNION ALL SELECT 1, 'invalid_objects', COUNT(o.object_name), 'pdb', NVL(c.name, (SELECT name FROM v$database)),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT con_id FROM v$containers WHERE name <> 'PDB$SEED' AND open_mode <> 'MOUNTED'
          UNION SELECT 0 FROM v$database WHERE cdb = 'NO') k
    LEFT JOIN v$containers c ON c.con_id = k.con_id
    LEFT JOIN cdb_objects o ON o.con_id = k.con_id AND o.status = 'INVALID'
    GROUP BY c.name
UNION ALL SELECT 2, 'corrupt_blocks', NVL(SUM(blocks), 0), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$database_block_corruption
UNION ALL SELECT 3, 'datafiles_need_recovery', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$recover_file
UNION ALL SELECT 4, 'datafiles_offline', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$datafile WHERE status NOT IN ('ONLINE', 'SYSTEM')
-- Accounts people log in with (not Oracle's own) that expire within 7
-- days, or already in their grace period.
UNION ALL SELECT 5, 'accounts_expiring', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM cdb_users WHERE oracle_maintained = 'N' AND account_status IN ('OPEN', 'EXPIRED(GRACE)')
        AND expiry_date IS NOT NULL AND expiry_date < SYSDATE + 7
UNION ALL SELECT 6, 'scheduler_failed_24h', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM cdb_scheduler_job_run_details WHERE status = 'FAILED' AND log_date > SYSTIMESTAMP - INTERVAL '1' DAY
UNION ALL SELECT 7, 'job_failed_24h', f.n, 'pdb', NVL(c.name, (SELECT name FROM v$database)), 'job', f.owner || '.' || f.job_name,
    NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT con_id, owner, job_name, COUNT(*) AS n FROM cdb_scheduler_job_run_details
          WHERE status = 'FAILED' AND log_date > SYSTIMESTAMP - INTERVAL '1' DAY
          GROUP BY con_id, owner, job_name ORDER BY COUNT(*) DESC FETCH FIRST 10 ROWS ONLY) f
    LEFT JOIN v$containers c ON c.con_id = f.con_id
UNION ALL SELECT 8, 'scheduler_broken', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM cdb_scheduler_jobs WHERE state = 'BROKEN'
