-- How long since each database was last backed up, from msdb's history:
-- full, differential, and for a database whose log needs backing up (full
-- or bulk-logged recovery), its log. -1: none in the last 400 days. At
-- most 150 databases, so a server with thousands stays under Vigil's limit.
DECLARE @b TABLE (name nvarchar(128), type char(1), last datetime, PRIMARY KEY (name, type));
INSERT @b SELECT database_name, type, MAX(backup_finish_date) FROM msdb.dbo.backupset
WHERE backup_finish_date > DATEADD(day, -400, @now) AND type IN ('D', 'I', 'L') GROUP BY database_name, type;
DECLARE @d TABLE (name nvarchar(128) PRIMARY KEY, recovery int);
INSERT @d SELECT TOP (150) name, recovery_model FROM sys.databases WHERE database_id <> 2 AND state = 0 AND source_database_id IS NULL ORDER BY name;
INSERT @m (name, v, k1, t1)
SELECT x.name, x.v, 'database', d.name FROM @d AS d
CROSS APPLY (VALUES
    ('full_age_seconds', ISNULL((SELECT DATEDIFF_BIG(second, last, @now) FROM @b WHERE name = d.name AND type = 'D'), -1)),
    -- master has full backups only.
    ('diff_age_seconds', CASE WHEN d.name = N'master' THEN NULL ELSE ISNULL((SELECT DATEDIFF_BIG(second, last, @now) FROM @b WHERE name = d.name AND type = 'I'), -1) END),
    -- Simple recovery (3) has no log backups.
    ('log_age_seconds', CASE WHEN d.recovery = 3 THEN NULL ELSE ISNULL((SELECT DATEDIFF_BIG(second, last, @now) FROM @b WHERE name = d.name AND type = 'L'), -1) END)
) AS x(name, v)
WHERE x.v IS NOT NULL ORDER BY d.name;
INSERT @m (name, v)
SELECT 'never_backed_up', COUNT(*) FROM @d AS d WHERE d.name <> N'tempdb' AND NOT EXISTS (SELECT 1 FROM @b WHERE name = d.name AND type = 'D');
