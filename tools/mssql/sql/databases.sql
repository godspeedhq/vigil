-- Each database: whether it is online, how big it is, how full its log is
-- and why that log cannot be reused, and its settings. The 75 biggest, so a
-- server with hundreds stays under Vigil's limit.
DECLARE @d TABLE (database_id int PRIMARY KEY, name nvarchar(128), state int, read_only bit, recovery nvarchar(60),
    compat int, reuse nvarchar(60), data_kb bigint, log_kb bigint, log_used_kb bigint, log_pct int, active bigint);
INSERT @d
SELECT TOP (75) d.database_id, d.name, d.state, d.is_read_only, d.recovery_model_desc, d.compatibility_level, d.log_reuse_wait_desc,
    ds.value, ls.value, lu.value, lp.value, a.value
FROM sys.databases AS d
LEFT JOIN @pc AS ds ON ds.obj = N'Databases' AND ds.counter = N'Data File(s) Size (KB)' AND ds.inst = d.name
LEFT JOIN @pc AS ls ON ls.obj = N'Databases' AND ls.counter = N'Log File(s) Size (KB)' AND ls.inst = d.name
LEFT JOIN @pc AS lu ON lu.obj = N'Databases' AND lu.counter = N'Log File(s) Used Size (KB)' AND lu.inst = d.name
LEFT JOIN @pc AS lp ON lp.obj = N'Databases' AND lp.counter = N'Percent Log Used' AND lp.inst = d.name
LEFT JOIN @pc AS a ON a.obj = N'Databases' AND a.counter = N'Active Transactions' AND a.inst = d.name
ORDER BY ISNULL(ds.value, 0) DESC, d.name;
-- Query Store, from each database that can be opened: 0 off, 1 read only
-- (often because it is full), 2 read and write, 3 in error.
DECLARE @q TABLE (database_id int PRIMARY KEY, state int);
DECLARE @qsql nvarchar(max) = N'';
SELECT @qsql = @qsql + N' UNION ALL SELECT ' + CONVERT(nvarchar(10), d.database_id) + N', actual_state FROM '
    + QUOTENAME(d.name) + N'.sys.database_query_store_options'
FROM @d AS dd JOIN sys.databases AS d ON d.database_id = dd.database_id
WHERE d.state = 0 AND d.user_access = 0 AND HAS_DBACCESS(d.name) = 1 AND d.database_id NOT IN (2, 3);
IF LEN(@qsql) > 0
BEGIN
    SET @qsql = STUFF(@qsql, 1, 11, N'');
    INSERT @q EXEC sys.sp_executesql @qsql;
END;
DECLARE @server_compat int = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) * 10;

INSERT @m (name, v) SELECT 'databases', COUNT(*) FROM sys.databases;
INSERT @m (name, v) SELECT 'databases_not_shown', CASE WHEN COUNT(*) > 75 THEN COUNT(*) - 75 ELSE 0 END FROM sys.databases;
INSERT @m (name, v, k1, t1, k2, t2, k3, t3)
SELECT x.name, x.v, 'database', d.name, x.k2, x.t2, x.k3, x.t3
FROM @d AS d
LEFT JOIN @q AS q ON q.database_id = d.database_id
CROSS APPLY (VALUES
    ('online', CASE WHEN d.state = 0 THEN 1 ELSE 0 END, NULL, NULL, NULL, NULL),
    -- 0 online, 1 restoring, 2 recovering, 3 recovery pending, 4 suspect,
    -- 5 emergency, 6 offline.
    ('state', d.state, 'state', LOWER(REPLACE((SELECT state_desc FROM sys.databases WHERE database_id = d.database_id), N' ', N'_')), NULL, NULL),
    ('read_only', CONVERT(int, d.read_only), NULL, NULL, NULL, NULL),
    ('recovery', 1, 'model', LOWER(d.recovery), NULL, NULL),
    ('data_bytes', ISNULL(d.data_kb, 0) * 1024.0, NULL, NULL, NULL, NULL),
    ('log_bytes', ISNULL(d.log_kb, 0) * 1024.0, NULL, NULL, NULL, NULL),
    ('log_used_bytes', ISNULL(d.log_used_kb, 0) * 1024.0, NULL, NULL, NULL, NULL),
    ('log_used_pct', ISNULL(d.log_pct, 0), NULL, NULL, NULL, NULL),
    -- What keeps the log from being reused: 0 nothing, 1 something, named.
    ('log_reuse_waiting', CASE WHEN d.reuse = N'NOTHING' THEN 0 ELSE 1 END, 'reason', LOWER(d.reuse), NULL, NULL),
    ('active_transactions', ISNULL(d.active, 0), NULL, NULL, NULL, NULL),
    ('compatibility_level', d.compat, NULL, NULL, NULL, NULL),
    ('compatibility_behind', CASE WHEN d.compat < @server_compat THEN 1 ELSE 0 END, NULL, NULL, NULL, NULL)
) AS x(name, v, k2, t2, k3, t3)
ORDER BY d.name;
INSERT @m (name, v, k1, t1)
SELECT 'query_store', q.state, 'database', d.name FROM @q AS q JOIN @d AS d ON d.database_id = q.database_id ORDER BY d.name;
