-- User sessions now, in every container: their state, what the active ones
-- wait on, blocking, the longest call and transaction. This job's own
-- session is left out.
-- Active and inactive always, even at 0; killed and the rest when there are any.
UNION ALL SELECT 1, 'sessions', COUNT(s.sid), 'state', LOWER(k.status), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT 'ACTIVE' AS status FROM dual UNION ALL SELECT 'INACTIVE' FROM dual
          UNION SELECT status FROM v$session WHERE type = 'USER') k
    LEFT JOIN v$session s ON s.status = k.status AND s.type = 'USER' AND s.sid <> SYS_CONTEXT('USERENV', 'SID')
    GROUP BY k.status
-- What the active ones do: on CPU, or waiting, by the wait's class. One
-- waiting on an idle event (a client that has not answered) is left out.
UNION ALL SELECT 2, 'active', COUNT(*), 'class',
    CASE WHEN state = 'WAITING' THEN LOWER(REPLACE(wait_class, ' ', '_')) ELSE 'cpu' END,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session WHERE type = 'USER' AND status = 'ACTIVE' AND sid <> SYS_CONTEXT('USERENV', 'SID')
        AND NOT (state = 'WAITING' AND wait_class = 'Idle')
    GROUP BY CASE WHEN state = 'WAITING' THEN LOWER(REPLACE(wait_class, ' ', '_')) ELSE 'cpu' END
UNION ALL SELECT 3, 'blocked', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session WHERE blocking_session IS NOT NULL AND blocking_session_status = 'VALID'
UNION ALL SELECT 4, 'longest_blocked_seconds', NVL(ROUND(MAX(wait_time_micro) / 1e6, 2), 0),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session WHERE blocking_session IS NOT NULL AND blocking_session_status = 'VALID'
-- Sessions that block others and wait on no one: where a chain starts.
UNION ALL SELECT 5, 'head_blockers', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session h
    WHERE (h.blocking_session IS NULL OR h.blocking_session_status <> 'VALID')
      AND EXISTS (SELECT 1 FROM v$session w WHERE w.blocking_session = h.sid AND w.blocking_session_status = 'VALID')
UNION ALL SELECT 6, 'longest_active_seconds', NVL(MAX(last_call_et), 0), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session WHERE type = 'USER' AND status = 'ACTIVE' AND sid <> SYS_CONTEXT('USERENV', 'SID')
UNION ALL SELECT 7, 'transactions', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$transaction
UNION ALL SELECT 8, 'oldest_transaction_seconds', NVL(ROUND((SYSDATE - MIN(start_date)) * 86400), 0),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$transaction
-- Asleep with a transaction open: an application that did not commit.
UNION ALL SELECT 9, 'idle_in_transaction', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session WHERE type = 'USER' AND status = 'INACTIVE' AND taddr IS NOT NULL
UNION ALL SELECT 10, 'idle_in_transaction_seconds', NVL(MAX(last_call_et), 0), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session WHERE type = 'USER' AND status = 'INACTIVE' AND taddr IS NOT NULL
UNION ALL SELECT 11, 'long_operations', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session_longops WHERE time_remaining > 0 AND sofar < totalwork
