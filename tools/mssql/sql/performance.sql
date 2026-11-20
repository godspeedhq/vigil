-- SQL Server's own counters. Those named _count are running totals since it
-- started: graph them as rates.
DECLARE @c TABLE (id int IDENTITY PRIMARY KEY, name varchar(64), obj nvarchar(128), counter nvarchar(128), inst nvarchar(128));
INSERT @c (name, obj, counter, inst) VALUES
    ('batch_requests_count', N'SQL Statistics', N'Batch Requests/sec', N''),
    ('compilations_count', N'SQL Statistics', N'SQL Compilations/sec', N''),
    ('recompilations_count', N'SQL Statistics', N'SQL Re-Compilations/sec', N''),
    ('transactions_count', N'Databases', N'Transactions/sec', N'_Total'),
    ('logins_count', N'General Statistics', N'Logins/sec', N''),
    ('logouts_count', N'General Statistics', N'Logouts/sec', N''),
    ('processes_blocked', N'General Statistics', N'Processes blocked', N''),
    ('errors_count', N'SQL Errors', N'Errors/sec', N'_Total'),
    ('page_life_expectancy_seconds', N'Buffer Manager', N'Page life expectancy', N''),
    ('lazy_writes_count', N'Buffer Manager', N'Lazy writes/sec', N''),
    ('checkpoint_pages_count', N'Buffer Manager', N'Checkpoint pages/sec', N''),
    ('page_reads_count', N'Buffer Manager', N'Page reads/sec', N''),
    ('page_writes_count', N'Buffer Manager', N'Page writes/sec', N''),
    ('lock_waits_count', N'Locks', N'Lock Waits/sec', N'_Total'),
    ('lock_timeouts_count', N'Locks', N'Lock Timeouts/sec', N'_Total'),
    ('deadlocks_count', N'Locks', N'Number of Deadlocks/sec', N'_Total'),
    ('page_splits_count', N'Access Methods', N'Page Splits/sec', N''),
    ('full_scans_count', N'Access Methods', N'Full Scans/sec', N''),
    ('memory_grants_pending', N'Memory Manager', N'Memory Grants Pending', N''),
    ('memory_grants_outstanding', N'Memory Manager', N'Memory Grants Outstanding', N'');
INSERT @m (name, v)
SELECT c.name, p.value FROM @c AS c JOIN @pc AS p ON p.obj = c.obj AND p.counter = c.counter AND p.inst = c.inst ORDER BY c.id;
-- A ratio counter is two: the value and its base.
INSERT @m (name, v)
SELECT 'buffer_cache_hit_pct', CONVERT(decimal(38, 2), 100.0 * r.value / b.value)
FROM @pc AS r JOIN @pc AS b ON b.obj = r.obj AND b.counter = N'Buffer cache hit ratio base'
WHERE r.obj = N'Buffer Manager' AND r.counter = N'Buffer cache hit ratio' AND b.value > 0;
-- Indexes the optimizer wished it had, since the server started: how many,
-- and the most a single one would have improved its queries.
INSERT @m (name, v)
SELECT 'missing_indexes', COUNT(*) FROM sys.dm_db_missing_index_group_stats;
INSERT @m (name, v)
SELECT 'missing_index_top_impact_pct', ISNULL(MAX(CONVERT(decimal(38, 2), avg_user_impact)), 0) FROM sys.dm_db_missing_index_group_stats;
