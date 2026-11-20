-- Reads, writes and the time spent waiting on them, for each database file,
-- since SQL Server started (running totals: graph them as rates; latency is
-- the stall's rate over the reads' or writes'). The 120 files that have
-- waited longest, so a server with thousands stays under Vigil's limit.
INSERT @m (name, v, k1, t1, k2, t2, k3, t3)
SELECT x.name, x.v, 'database', DB_NAME(s.database_id), 'file', ISNULL(f.name, N'file' + CONVERT(nvarchar(10), s.file_id)),
    'kind', ISNULL(f.kind, CASE WHEN s.file_id = 2 THEN N'log' ELSE N'data' END)
FROM (SELECT TOP (120) * FROM sys.dm_io_virtual_file_stats(NULL, NULL) WHERE database_id IN (SELECT database_id FROM sys.databases) ORDER BY io_stall DESC) AS s
LEFT JOIN @f AS f ON f.database_id = s.database_id AND f.file_id = s.file_id
CROSS APPLY (VALUES
    ('reads_count', s.num_of_reads),
    ('writes_count', s.num_of_writes),
    ('read_bytes_count', s.num_of_bytes_read),
    ('written_bytes_count', s.num_of_bytes_written),
    ('read_stall_ms_count', s.io_stall_read_ms),
    ('write_stall_ms_count', s.io_stall_write_ms),
    ('size_bytes', s.size_on_disk_bytes)
) AS x(name, v)
ORDER BY DB_NAME(s.database_id), s.file_id;
INSERT @m (name, v)
SELECT 'files_not_shown', CASE WHEN COUNT(*) > 120 THEN COUNT(*) - 120 ELSE 0 END FROM sys.dm_io_virtual_file_stats(NULL, NULL) WHERE database_id IN (SELECT database_id FROM sys.databases);
