-- Settings that are risky, or left at a default that rarely suits, as
-- numbers a dashboard can compare across servers or watch for change.
DECLARE @cfg TABLE (name nvarchar(70) PRIMARY KEY, v bigint);
INSERT @cfg SELECT name, CONVERT(bigint, value_in_use) FROM sys.configurations;
INSERT @m (name, v) SELECT 'max_server_memory_mb', v FROM @cfg WHERE name = N'max server memory (MB)';
-- Left at its default, SQL Server may take the machine's memory.
INSERT @m (name, v) SELECT 'max_server_memory_default', CASE WHEN v >= 2147483647 THEN 1 ELSE 0 END FROM @cfg WHERE name = N'max server memory (MB)';
INSERT @m (name, v) SELECT 'maxdop', v FROM @cfg WHERE name = N'max degree of parallelism';
INSERT @m (name, v) SELECT 'cost_threshold', v FROM @cfg WHERE name = N'cost threshold for parallelism';
INSERT @m (name, v) SELECT 'optimize_for_ad_hoc', v FROM @cfg WHERE name = N'optimize for ad hoc workloads';
-- Features that run code outside SQL Server: off unless needed.
INSERT @m (name, v) SELECT 'xp_cmdshell', v FROM @cfg WHERE name = N'xp_cmdshell';
INSERT @m (name, v) SELECT 'clr_enabled', v FROM @cfg WHERE name = N'clr enabled';
INSERT @m (name, v) SELECT 'ole_automation', v FROM @cfg WHERE name = N'Ole Automation Procedures';
INSERT @m (name, v) SELECT 'remote_admin_connections', v FROM @cfg WHERE name = N'remote admin connections';
-- The sa login, and how many logins are sysadmin.
INSERT @m (name, v) SELECT 'sa_enabled', CASE WHEN is_disabled = 0 THEN 1 ELSE 0 END FROM sys.server_principals WHERE sid = 0x01;
INSERT @m (name, v)
SELECT 'sysadmins', COUNT(*) FROM sys.server_role_members AS rm JOIN sys.server_principals AS p ON p.principal_id = rm.member_principal_id
WHERE rm.role_principal_id = SUSER_ID(N'sysadmin') AND p.is_disabled = 0;
-- Faster file growth, and memory Windows cannot page out.
INSERT @m (name, v)
SELECT TOP (1) 'instant_file_init', CASE WHEN instant_file_initialization_enabled = N'Y' THEN 1 ELSE 0 END
FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server (%';
INSERT @m (name, v) SELECT 'locked_pages', CASE WHEN sql_memory_model > 1 THEN 1 ELSE 0 END FROM sys.dm_os_sys_info;
