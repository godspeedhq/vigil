-- CPU, as SQL Server sees it, and whether work waits for a CPU or a thread.
-- Its scheduler monitor records CPU use once a minute: the newest record.
DECLARE @cpu xml = (SELECT TOP (1) CONVERT(xml, record) FROM sys.dm_os_ring_buffers
    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE N'%<SystemHealth>%' ORDER BY [timestamp] DESC);
DECLARE @sql int = @cpu.value('(//SystemHealth/ProcessUtilization)[1]', 'int');
DECLARE @idle int = @cpu.value('(//SystemHealth/SystemIdle)[1]', 'int');
IF @sql IS NOT NULL INSERT @m (name, v) VALUES ('sql_pct', @sql);
-- The rest of the machine, from what is idle: Windows only, as SQL Server
-- on Linux records idle as 0.
IF @sql IS NOT NULL AND @idle IS NOT NULL AND (SELECT TOP (1) host_platform FROM sys.dm_os_host_info) = N'Windows'
    INSERT @m (name, v) VALUES ('other_pct', CASE WHEN 100 - @idle - @sql > 0 THEN 100 - @idle - @sql ELSE 0 END);
-- Tasks ready to run that wait for a CPU, and those that wait for a thread.
INSERT @m (name, v) SELECT 'runnable_tasks', SUM(runnable_tasks_count) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE';
INSERT @m (name, v) SELECT 'work_queued', SUM(work_queue_count) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE';
INSERT @m (name, v) SELECT 'pending_disk_io', SUM(pending_disk_io_count) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE';
-- Worker threads: at the most, a new query cannot start at all.
INSERT @m (name, v) SELECT 'workers', SUM(current_workers_count) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE';
INSERT @m (name, v) SELECT 'workers_max', max_workers_count FROM sys.dm_os_sys_info;
INSERT @m (name, v)
SELECT 'workers_pct', CONVERT(decimal(38, 2), 100.0 * SUM(s.current_workers_count) / MAX(i.max_workers_count))
FROM sys.dm_os_schedulers AS s CROSS JOIN sys.dm_os_sys_info AS i WHERE s.status = N'VISIBLE ONLINE';
