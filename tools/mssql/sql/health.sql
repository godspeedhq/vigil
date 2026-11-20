-- What keeps a database safe and able to grow: its last integrity check,
-- its log's shape, files near their limit, disk space, encryption, and
-- pages SQL Server found damaged. tempdb is left out where it does not
-- apply. At most 150 databases and 100 files, so a server with thousands
-- stays under Vigil's limit.
DECLARE @d TABLE (database_id int PRIMARY KEY, name nvarchar(128), checkdb datetime);
INSERT @d SELECT TOP (150) database_id, name, CONVERT(datetime, DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime'))
FROM sys.databases WHERE state = 0 AND database_id <> 2 ORDER BY name;
-- Days since the last DBCC CHECKDB that found nothing; never checked, -1.
INSERT @m (name, v, k1, t1)
SELECT 'checkdb_age_days', CASE WHEN checkdb IS NULL OR checkdb < '19010101' THEN -1 ELSE DATEDIFF(day, checkdb, @now) END, 'database', name
FROM @d ORDER BY name;
-- Virtual log files: thousands make startup, restores and failovers slow.
INSERT @m (name, v, k1, t1)
SELECT 'vlfs', (SELECT COUNT(*) FROM sys.dm_db_log_info(d.database_id)), 'database', d.name FROM @d AS d ORDER BY d.name;
-- Files that grow by a percentage: each growth bigger, and slower, than the last.
INSERT @m (name, v, k1, t1)
SELECT 'pct_growth_files', COUNT(*), 'database', DB_NAME(database_id) FROM @f WHERE pct_growth = 1
GROUP BY database_id ORDER BY DB_NAME(database_id);
-- Files with a maximum size: how much of it they use (writes fail at 100).
INSERT @m (name, v, k1, t1, k2, t2, k3, t3)
SELECT TOP (100) 'max_size_used_pct', CONVERT(decimal(38, 2), 100.0 * pages / max_pages), 'database', DB_NAME(database_id), 'file', name, 'kind', kind
FROM @f WHERE max_pages > 0 ORDER BY 1.0 * pages / max_pages DESC;
-- Space on each volume that holds a database file.
DECLARE @v TABLE (mount nvarchar(256) PRIMARY KEY, total bigint, free bigint);
INSERT @v SELECT ISNULL(v.volume_mount_point, ISNULL(v.logical_volume_name, N'unknown')), MAX(v.total_bytes), MAX(v.available_bytes)
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS s CROSS APPLY sys.dm_os_volume_stats(s.database_id, s.file_id) AS v WHERE s.database_id IN (SELECT database_id FROM sys.databases)
GROUP BY ISNULL(v.volume_mount_point, ISNULL(v.logical_volume_name, N'unknown'));
INSERT @m (name, v, k1, t1)
SELECT x.name, x.v, 'volume', v.mount FROM @v AS v
CROSS APPLY (VALUES ('volume_total_bytes', v.total), ('volume_free_bytes', v.free),
    ('volume_free_pct', CONVERT(decimal(38, 2), 100.0 * v.free / NULLIF(v.total, 0)))) AS x(name, v)
WHERE x.v IS NOT NULL ORDER BY v.mount;
-- Express edition stops a database at 10 GB of data.
IF CONVERT(int, SERVERPROPERTY('EngineEdition')) = 4
    INSERT @m (name, v, k1, t1)
    SELECT 'express_limit_used_pct', CONVERT(decimal(38, 2), 100.0 * SUM(pages) / (10.0 * 1024 * 1024 * 1024 / 8192)), 'database', DB_NAME(database_id)
    FROM @f WHERE kind = N'data' AND database_id > 4 GROUP BY database_id ORDER BY DB_NAME(database_id);
-- Transparent data encryption: 3 encrypted, 2 encrypting, 4 changing its
-- key, 5 decrypting, 1 not yet, for each database with a key.
INSERT @m (name, v, k1, t1)
SELECT 'encryption_state', encryption_state, 'database', DB_NAME(database_id) FROM sys.dm_database_encryption_keys
WHERE database_id <> 2 ORDER BY DB_NAME(database_id);
-- Pages SQL Server found damaged (bad checksum, torn page, other I/O
-- errors), not yet repaired or restored: any is a reason to act.
INSERT @m (name, v) SELECT 'suspect_pages', COUNT(*) FROM msdb.dbo.suspect_pages WHERE event_type IN (1, 2, 3);
