-- tempdb: its size, its free space, and what fills it.
INSERT @m (name, v) SELECT 'size_bytes', SUM(CONVERT(bigint, size)) * 8192.0 FROM tempdb.sys.database_files WHERE type = 0;
INSERT @m (name, v) SELECT 'free_bytes', SUM(unallocated_extent_page_count) * 8192.0 FROM tempdb.sys.dm_db_file_space_usage;
INSERT @m (name, v)
SELECT 'free_pct', CONVERT(decimal(38, 2), 100.0 * SUM(u.unallocated_extent_page_count) / NULLIF(SUM(u.total_page_count), 0))
FROM tempdb.sys.dm_db_file_space_usage AS u;
-- Row versions, for snapshot isolation and online index builds.
INSERT @m (name, v) SELECT 'version_store_bytes', SUM(version_store_reserved_page_count) * 8192.0 FROM tempdb.sys.dm_db_file_space_usage;
-- Temporary tables and table variables.
INSERT @m (name, v) SELECT 'user_objects_bytes', SUM(user_object_reserved_page_count) * 8192.0 FROM tempdb.sys.dm_db_file_space_usage;
-- Sorts, hashes and spools.
INSERT @m (name, v) SELECT 'internal_objects_bytes', SUM(internal_object_reserved_page_count) * 8192.0 FROM tempdb.sys.dm_db_file_space_usage;
INSERT @m (name, v) SELECT 'log_used_pct', CONVERT(decimal(38, 2), value) FROM @pc WHERE obj = N'Databases' AND counter = N'Percent Log Used' AND inst = N'tempdb';
INSERT @m (name, v) SELECT 'data_files', COUNT(*) FROM tempdb.sys.database_files WHERE type = 0;
