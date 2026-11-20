-- SQL Server's memory: what it aims for and holds, what holds it, and
-- whether it or the machine runs low.
INSERT @m (name, v) SELECT 'target_bytes', value * 1024.0 FROM @pc WHERE obj = N'Memory Manager' AND counter = N'Target Server Memory (KB)';
INSERT @m (name, v) SELECT 'total_bytes', value * 1024.0 FROM @pc WHERE obj = N'Memory Manager' AND counter = N'Total Server Memory (KB)';
INSERT @m (name, v) SELECT 'process_bytes', physical_memory_in_use_kb * 1024.0 FROM sys.dm_os_process_memory;
INSERT @m (name, v) SELECT 'process_low', CONVERT(int, process_physical_memory_low) FROM sys.dm_os_process_memory;
INSERT @m (name, v) SELECT 'system_total_bytes', total_physical_memory_kb * 1024.0 FROM sys.dm_os_sys_memory;
INSERT @m (name, v) SELECT 'system_available_bytes', available_physical_memory_kb * 1024.0 FROM sys.dm_os_sys_memory;
INSERT @m (name, v) SELECT 'system_low', CONVERT(int, system_low_memory_signal_state) FROM sys.dm_os_sys_memory;
INSERT @m (name, v) SELECT 'buffer_pool_bytes', value * 8192.0 FROM @pc WHERE obj = N'Buffer Manager' AND counter = N'Database pages';
INSERT @m (name, v) SELECT 'memory_grants_bytes', value * 1024.0 FROM @pc WHERE obj = N'Memory Manager' AND counter = N'Granted Workspace Memory (KB)';
-- Plans: all of them, and those used once and never again, which mostly
-- waste the cache ("optimize for ad hoc workloads" helps).
INSERT @m (name, v) SELECT 'plan_cache_bytes', ISNULL(SUM(CONVERT(bigint, size_in_bytes)), 0) FROM sys.dm_exec_cached_plans;
INSERT @m (name, v)
SELECT 'single_use_plan_bytes', ISNULL(SUM(CONVERT(bigint, size_in_bytes)), 0) FROM sys.dm_exec_cached_plans
WHERE usecounts = 1 AND objtype = N'Adhoc';
-- In-Memory OLTP.
INSERT @m (name, v)
SELECT 'xtp_bytes', ISNULL(SUM(pages_kb), 0) * 1024.0 FROM sys.dm_os_memory_clerks WHERE type = N'MEMORYCLERK_XTP';
-- The five clerks that hold the most.
INSERT @m (name, v, k1, t1)
SELECT TOP (5) 'clerk_bytes', SUM(pages_kb) * 1024.0, 'clerk', LOWER(REPLACE(type, N'MEMORYCLERK_', N''))
FROM sys.dm_os_memory_clerks GROUP BY type ORDER BY SUM(pages_kb) DESC;
