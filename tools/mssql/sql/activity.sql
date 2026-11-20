-- What the server is doing now: sessions, requests, blocking, and the oldest
-- work. Its own session, and SQL Server's internal ones, are left out.
DECLARE @s TABLE (session_id int PRIMARY KEY, status nvarchar(30), open_tran int, last_end datetime);
INSERT @s SELECT session_id, status, open_transaction_count, last_request_end_time
    FROM sys.dm_exec_sessions WHERE is_user_process = 1 AND session_id <> @@SPID;
DECLARE @r TABLE (session_id int PRIMARY KEY, blocked_by int, start_time datetime, wait_type nvarchar(60), wait_ms bigint);
INSERT @r SELECT r.session_id, r.blocking_session_id, r.start_time, r.wait_type, r.wait_time
    FROM sys.dm_exec_requests AS r JOIN @s AS s ON s.session_id = r.session_id
    -- A request that waits for work by design is not stuck.
    WHERE ISNULL(r.wait_type, N'') NOT IN (N'WAITFOR', N'BROKER_RECEIVE_WAITFOR', N'XE_LIVE_TARGET_TVF');

INSERT @m (name, v, k1, t1)
SELECT 'sessions', SUM(CASE WHEN s.session_id IS NULL THEN 0 ELSE 1 END), 'state', st.state
FROM (VALUES (N'running'), (N'sleeping'), (N'dormant'), (N'preconnect')) AS st(state)
LEFT JOIN @s AS s ON s.status = st.state
GROUP BY st.state;
INSERT @m (name, v) SELECT 'requests', COUNT(*) FROM @r WHERE start_time IS NOT NULL;
INSERT @m (name, v) SELECT 'requests_blocked', COUNT(*) FROM @r WHERE blocked_by <> 0;
-- A head blocker blocks others and waits on no one.
INSERT @m (name, v)
SELECT 'head_blockers', COUNT(DISTINCT b.blocked_by) FROM @r AS b
WHERE b.blocked_by <> 0 AND NOT EXISTS (SELECT 1 FROM @r AS h WHERE h.session_id = b.blocked_by AND h.blocked_by <> 0);
INSERT @m (name, v)
SELECT 'longest_request_seconds', ISNULL(MAX(DATEDIFF_BIG(second, start_time, @now)), 0) FROM @r WHERE start_time IS NOT NULL;
-- The longest wait now, and what it waits on.
INSERT @m (name, v, k1, t1)
SELECT TOP (1) 'longest_wait_seconds', w.wait_ms / 1000.0, 'type', w.wait_type
FROM (SELECT wait_ms, wait_type FROM @r WHERE wait_type IS NOT NULL
      UNION ALL SELECT 0, N'none') AS w
ORDER BY w.wait_ms DESC;
-- The oldest transaction a user session holds open.
INSERT @m (name, v)
SELECT 'oldest_transaction_seconds', ISNULL(MAX(DATEDIFF_BIG(second, t.transaction_begin_time, @now)), 0)
FROM sys.dm_tran_session_transactions AS st
JOIN sys.dm_tran_active_transactions AS t ON t.transaction_id = st.transaction_id
JOIN @s AS s ON s.session_id = st.session_id WHERE t.transaction_begin_time IS NOT NULL;
-- Asleep with a transaction open: an application that did not commit, and
-- the classic cause of blocking.
INSERT @m (name, v) SELECT 'idle_in_transaction', COUNT(*) FROM @s WHERE status = N'sleeping' AND open_tran > 0;
INSERT @m (name, v)
SELECT 'idle_in_transaction_seconds', ISNULL(MAX(DATEDIFF_BIG(second, last_end, @now)), 0)
FROM @s WHERE status = N'sleeping' AND open_tran > 0 AND last_end IS NOT NULL;
-- Snapshot transactions keep row versions in tempdb for as long as they run.
INSERT @m (name, v)
SELECT 'longest_snapshot_seconds', ISNULL(MAX(elapsed_time_seconds), 0) FROM sys.dm_tran_active_snapshot_database_transactions;
