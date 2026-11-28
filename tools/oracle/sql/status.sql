-- What the database is, whether it is open, how long it has run, and its
-- sessions and processes against their limits.
UNION ALL SELECT 1, 'up', 1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual
UNION ALL SELECT 2, 'info', 1, 'release', REGEXP_SUBSTR(i.version_full, '^[0-9]+'), 'version', i.version_full,
    'edition', LOWER(i.edition), 'cdb', LOWER(d.cdb), 'role', LOWER(REPLACE(d.database_role, ' ', '_'))
    FROM v$instance i CROSS JOIN v$database d
UNION ALL SELECT 3, 'uptime_seconds', ROUND((SYSDATE - startup_time) * 86400), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$instance
UNION ALL SELECT 4, 'open', CASE WHEN i.status = 'OPEN' THEN 1 ELSE 0 END, 'mode', LOWER(REPLACE(d.open_mode, ' ', '_')),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$instance i CROSS JOIN v$database d
UNION ALL SELECT 6, 'archivelog', CASE WHEN log_mode = 'ARCHIVELOG' THEN 1 ELSE 0 END, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$database
UNION ALL SELECT 7, 'cpus', value, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$osstat WHERE stat_name = 'NUM_CPUS'
-- Sessions and processes against the most the instance allows.
UNION ALL SELECT 8, x.n, x.v, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT resource_name AS k, current_utilization AS cur,
              CASE WHEN TRIM(limit_value) IN ('UNLIMITED', '0') THEN NULL ELSE TO_NUMBER(TRIM(limit_value)) END AS lim
          FROM v$resource_limit WHERE resource_name IN ('sessions', 'processes')) r
    CROSS APPLY (
        SELECT r.k AS n, r.cur AS v FROM dual
        UNION ALL SELECT r.k || '_max', r.lim FROM dual
        UNION ALL SELECT r.k || '_pct', ROUND(100 * r.cur / r.lim, 2) FROM dual
    ) x
-- Each pluggable database but the seed: open or not.
UNION ALL SELECT 9, 'pdbs', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$pdbs WHERE name <> 'PDB$SEED'
UNION ALL SELECT 10, 'pdb_open', CASE WHEN open_mode IN ('READ WRITE', 'READ ONLY') THEN 1 ELSE 0 END,
    'pdb', name, 'mode', LOWER(REPLACE(open_mode, ' ', '_')), NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$pdbs WHERE name <> 'PDB$SEED'
