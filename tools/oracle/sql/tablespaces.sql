-- Each tablespace in every container, against the most it can grow to
-- (autoextend counted): the 100 fullest. And the data files against
-- db_files.
UNION ALL SELECT 1, 'tablespaces', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM cdb_tablespace_usage_metrics
UNION ALL SELECT 2, 'tablespaces_not_shown', GREATEST(COUNT(*) - 100, 0), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM cdb_tablespace_usage_metrics
UNION ALL SELECT 3, x.n, x.v, 'pdb', u.pdb, 'tablespace', u.tablespace_name, 'kind', u.kind, NULL, NULL, NULL, NULL
    FROM (SELECT NVL(c.name, (SELECT name FROM v$database)) AS pdb, m.tablespace_name, LOWER(t.contents) AS kind,
              m.used_percent, m.used_space * t.block_size AS used_bytes, m.tablespace_size * t.block_size AS max_bytes,
              CASE t.status WHEN 'ONLINE' THEN 1 ELSE 0 END AS is_online
          FROM cdb_tablespace_usage_metrics m
          JOIN cdb_tablespaces t ON t.con_id = m.con_id AND t.tablespace_name = m.tablespace_name
          LEFT JOIN v$containers c ON c.con_id = m.con_id
          ORDER BY m.used_percent DESC FETCH FIRST 100 ROWS ONLY) u
    CROSS APPLY (SELECT 'used_pct' AS n, ROUND(u.used_percent, 2) AS v FROM dual
                 UNION ALL SELECT 'used_bytes', u.used_bytes FROM dual
                 UNION ALL SELECT 'max_bytes', u.max_bytes FROM dual
                 UNION ALL SELECT 'online', u.is_online FROM dual) x
UNION ALL SELECT 4, 'datafiles', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$datafile
UNION ALL SELECT 5, 'datafiles_max', CASE WHEN REGEXP_LIKE(value, '^[0-9]+$') THEN TO_NUMBER(value) END, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$parameter WHERE name = 'db_files'
