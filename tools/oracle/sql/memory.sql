-- The instance's memory: the SGA and its parts, the PGA against its target
-- and its hard limit.
UNION ALL SELECT 1, 'sga_bytes', SUM(value), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$sga
UNION ALL SELECT 2, CASE name WHEN 'Buffer Cache Size' THEN 'buffer_cache_bytes' ELSE 'shared_pool_bytes' END, bytes,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$sgainfo WHERE name IN ('Buffer Cache Size', 'Shared Pool Size')
UNION ALL SELECT 3, 'shared_pool_free_bytes', SUM(bytes), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$sgastat WHERE pool = 'shared pool' AND name = 'free memory'
UNION ALL SELECT 4, CASE name WHEN 'sga_target' THEN 'sga_target_bytes' WHEN 'memory_target' THEN 'memory_target_bytes'
        WHEN 'pga_aggregate_target' THEN 'pga_target_bytes' ELSE 'pga_limit_bytes' END,
    CASE WHEN REGEXP_LIKE(value, '^[0-9]+$') THEN TO_NUMBER(value) END, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$parameter WHERE name IN ('sga_target', 'memory_target', 'pga_aggregate_target', 'pga_aggregate_limit')
UNION ALL SELECT 5, CASE name WHEN 'total PGA allocated' THEN 'pga_allocated_bytes' WHEN 'total PGA inuse' THEN 'pga_inuse_bytes'
        ELSE 'pga_over_allocations_count' END, value, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$pgastat WHERE con_id = 0 AND name IN ('total PGA allocated', 'total PGA inuse', 'over allocation count')
-- The PGA against pga_aggregate_limit, past which Oracle ends sessions.
UNION ALL SELECT 6, 'pga_limit_pct', CASE WHEN REGEXP_LIKE(p.value, '^[0-9]+$') THEN ROUND(100 * a.value / NULLIF(TO_NUMBER(p.value), 0), 2) END,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$pgastat a CROSS JOIN v$parameter p
    WHERE a.con_id = 0 AND a.name = 'total PGA allocated' AND p.name = 'pga_aggregate_limit'
