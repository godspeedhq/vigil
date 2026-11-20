-- SQL Agent's jobs, from msdb: those that failed in the last 24 hours,
-- those running now, and how long the longest has run. Reading them needs
-- SELECT on four of msdb's tables (packs/README.md): without it, readable 0
-- and nothing else. SQLAgentReaderRole does not give it: it works through
-- Agent's procedures.
IF HAS_PERMS_BY_NAME(N'msdb.dbo.sysjobs', N'OBJECT', N'SELECT') = 1
    AND HAS_PERMS_BY_NAME(N'msdb.dbo.sysjobhistory', N'OBJECT', N'SELECT') = 1
    AND HAS_PERMS_BY_NAME(N'msdb.dbo.sysjobactivity', N'OBJECT', N'SELECT') = 1
    AND HAS_PERMS_BY_NAME(N'msdb.dbo.syssessions', N'OBJECT', N'SELECT') = 1
BEGIN
    INSERT @m (name, v) VALUES ('readable', 1);
    DECLARE @h TABLE (job_id uniqueidentifier, finished datetime, status int);
    INSERT @h SELECT job_id,
        DATEADD(second, (run_time / 10000) * 3600 + (run_time / 100 % 100) * 60 + run_time % 100
            + (run_duration / 10000) * 3600 + (run_duration / 100 % 100) * 60 + run_duration % 100,
            CONVERT(datetime, CONVERT(char(8), run_date), 112)),
        run_status
    FROM msdb.dbo.sysjobhistory WHERE step_id = 0 AND run_date >= CONVERT(int, CONVERT(char(8), DATEADD(day, -2, @now), 112));
    INSERT @m (name, v) SELECT 'jobs', COUNT(*) FROM msdb.dbo.sysjobs;
    INSERT @m (name, v) SELECT 'jobs_enabled', COUNT(*) FROM msdb.dbo.sysjobs WHERE enabled = 1;
    INSERT @m (name, v) SELECT 'failed_24h', COUNT(*) FROM @h WHERE status = 0 AND finished > DATEADD(hour, -24, @now);
    -- Each job that failed in the last 24 hours, the 50 most recent.
    INSERT @m (name, v, k1, t1)
    SELECT TOP (50) 'job_failed_24h', COUNT(*), 'job', j.name FROM @h AS h JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
    WHERE h.status = 0 AND h.finished > DATEADD(hour, -24, @now) GROUP BY j.name ORDER BY MAX(h.finished) DESC;
    -- Running now: started in Agent's current session, not finished.
    DECLARE @a TABLE (job_id uniqueidentifier, started datetime);
    INSERT @a SELECT a.job_id, a.start_execution_date FROM msdb.dbo.sysjobactivity AS a
    WHERE a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL;
    INSERT @m (name, v) SELECT 'running', COUNT(*) FROM @a;
    INSERT @m (name, v) SELECT 'longest_running_seconds', ISNULL(MAX(DATEDIFF_BIG(second, started, @now)), 0) FROM @a WHERE started IS NOT NULL;
END
ELSE
    INSERT @m (name, v) VALUES ('readable', 0);
