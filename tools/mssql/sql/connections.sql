-- How clients connect: encrypted or not, how they authenticate, and to
-- which databases. Counts only: never a host, a program or a login name.
DECLARE @c TABLE (session_id int PRIMARY KEY, encrypted bit, auth nvarchar(40), database_id int);
INSERT @c SELECT c.session_id, CASE WHEN c.encrypt_option = N'TRUE' THEN 1 ELSE 0 END, c.auth_scheme, s.database_id
FROM sys.dm_exec_connections AS c JOIN sys.dm_exec_sessions AS s ON s.session_id = c.session_id
WHERE s.is_user_process = 1 AND c.parent_connection_id IS NULL;
INSERT @m (name, v, k1, t1)
SELECT 'connections', SUM(CASE WHEN c.session_id IS NULL THEN 0 ELSE 1 END), 'encrypted', e.e FROM (VALUES (N'yes', 1), (N'no', 0)) AS e(e, b)
LEFT JOIN @c AS c ON c.encrypted = e.b GROUP BY e.e ORDER BY e.e DESC;
-- SQL: a SQL Server login and password. KERBEROS or NTLM: Windows; NTLM where
-- Kerberos was expected is a common, quiet misconfiguration.
INSERT @m (name, v, k1, t1)
SELECT 'connections_by_auth', SUM(CASE WHEN c.session_id IS NULL THEN 0 ELSE 1 END), 'auth', LOWER(a.a) FROM (VALUES (N'SQL'), (N'KERBEROS'), (N'NTLM')) AS a(a)
LEFT JOIN @c AS c ON c.auth = a.a GROUP BY a.a ORDER BY a.a;
-- The 50 databases with the most sessions.
INSERT @m (name, v, k1, t1)
SELECT TOP (50) 'sessions', COUNT(*), 'database', DB_NAME(database_id) FROM sys.dm_exec_sessions
WHERE is_user_process = 1 AND session_id <> @@SPID GROUP BY database_id ORDER BY COUNT(*) DESC, DB_NAME(database_id);
