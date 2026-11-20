-- What the server is, how long it has run, and its connections.
DECLARE @major int = CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));
DECLARE @edition nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('Edition'));
INSERT @m (name, v) VALUES ('up', 1);
INSERT @m (name, v, k1, t1, k2, t2, k3, t3, k4, t4, k5, t5)
SELECT 'info', 1,
    'release', CASE @major WHEN 15 THEN N'2019' WHEN 16 THEN N'2022' WHEN 17 THEN N'2025' ELSE CONVERT(nvarchar(10), @major) END,
    'version', CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')),
    'update', ISNULL(CONVERT(nvarchar(128), SERVERPROPERTY('ProductUpdateLevel')), CONVERT(nvarchar(128), SERVERPROPERTY('ProductLevel'))),
    'edition', LOWER(LEFT(@edition, CHARINDEX(N' ', @edition + N' ') - 1)),
    'os', LOWER((SELECT TOP (1) host_platform FROM sys.dm_os_host_info));
INSERT @m (name, v) SELECT 'uptime_seconds', DATEDIFF_BIG(second, sqlserver_start_time, @now) FROM sys.dm_os_sys_info;
INSERT @m (name, v) SELECT 'cpus', cpu_count FROM sys.dm_os_sys_info;
INSERT @m (name, v) SELECT 'schedulers', COUNT(*) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE';
INSERT @m (name, v) SELECT 'connections', value FROM @pc WHERE obj = N'General Statistics' AND counter = N'User Connections';
INSERT @m (name, v) VALUES ('connections_max', @@MAX_CONNECTIONS);
INSERT @m (name, v) VALUES ('clustered', ISNULL(CONVERT(int, SERVERPROPERTY('IsClustered')), 0));
INSERT @m (name, v) VALUES ('hadr_enabled', ISNULL(CONVERT(int, SERVERPROPERTY('IsHadrEnabled')), 0));
-- A failover cluster's current node.
IF CONVERT(int, SERVERPROPERTY('IsClustered')) = 1
    INSERT @m (name, v, k1, t1) VALUES ('cluster_node', 1, 'node', CONVERT(nvarchar(128), SERVERPROPERTY('ComputerNamePhysicalNetBIOS')));
-- SQL Agent runs the scheduled backups; Express has none.
INSERT @m (name, v) SELECT TOP (1) 'agent_running', CASE WHEN status_desc = N'Running' THEN 1 ELSE 0 END
    FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%';
