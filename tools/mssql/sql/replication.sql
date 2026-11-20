-- Always On availability groups, from this server: each replica it knows
-- of, and each database's queues. Nothing with no availability group. A
-- group is named where this login may see its name (VIEW DEFINITION on the
-- group: sys.availability_groups shows nothing more without it); else by
-- its id.
-- A primary knows every replica; a secondary, itself.
INSERT @m (name, v, k1, t1, k2, t2)
SELECT x.name, x.v, 'group', ISNULL(g.name, CONVERT(nvarchar(36), s.group_id)), 'replica', r.replica_server_name
FROM sys.dm_hadr_availability_replica_states AS s
JOIN sys.availability_replicas AS r ON r.replica_id = s.replica_id
LEFT JOIN sys.availability_groups AS g ON g.group_id = s.group_id
CROSS APPLY (VALUES
    ('primary', CASE WHEN s.role = 1 THEN 1 ELSE 0 END),
    ('connected', CASE WHEN s.connected_state = 1 THEN 1 ELSE 0 END),
    -- 2 healthy, 1 partly, 0 not.
    ('health', ISNULL(s.synchronization_health, 0)),
    ('local', s.is_local)
) AS x(name, v)
ORDER BY ISNULL(g.name, CONVERT(nvarchar(36), s.group_id)), r.replica_server_name;
INSERT @m (name, v, k1, t1, k2, t2, k3, t3)
SELECT x.name, x.v, 'group', ISNULL(g.name, CONVERT(nvarchar(36), d.group_id)), 'replica', r.replica_server_name, 'database', DB_NAME(d.database_id)
FROM sys.dm_hadr_database_replica_states AS d
JOIN sys.availability_replicas AS r ON r.replica_id = d.replica_id
LEFT JOIN sys.availability_groups AS g ON g.group_id = d.group_id
CROSS APPLY (VALUES
    -- 2 synchronized, 1 synchronizing, 0 neither (or suspended).
    ('sync_state', CASE d.synchronization_state WHEN 2 THEN 2 WHEN 1 THEN 1 ELSE 0 END),
    ('suspended', CONVERT(int, d.is_suspended)),
    ('send_queue_bytes', ISNULL(d.log_send_queue_size, 0) * 1024.0),
    ('send_rate_bytes', ISNULL(d.log_send_rate, 0) * 1024.0),
    ('redo_queue_bytes', ISNULL(d.redo_queue_size, 0) * 1024.0),
    ('redo_rate_bytes', ISNULL(d.redo_rate, 0) * 1024.0),
    ('lag_seconds', ISNULL(d.secondary_lag_seconds, 0))
) AS x(name, v)
WHERE d.is_local = 0 OR NOT EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states WHERE role = 1 AND is_local = 1)
ORDER BY ISNULL(g.name, CONVERT(nvarchar(36), d.group_id)), r.replica_server_name, DB_NAME(d.database_id);
