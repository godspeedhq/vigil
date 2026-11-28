-- Where the instance's sessions have waited since it started, by class,
-- and its ten most costly wait events. Idle waits are left out.
UNION ALL SELECT 1, 'wait_ms_count', time_waited * 10, 'class', LOWER(REPLACE(wait_class, ' ', '_')),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$system_wait_class WHERE wait_class <> 'Idle'
UNION ALL SELECT 2, 'waits_count', total_waits, 'class', LOWER(REPLACE(wait_class, ' ', '_')),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$system_wait_class WHERE wait_class <> 'Idle'
UNION ALL SELECT 3, x.n, x.v, 'event', e.event, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT event, time_waited_micro, total_waits FROM v$system_event WHERE wait_class <> 'Idle'
          ORDER BY time_waited_micro DESC FETCH FIRST 10 ROWS ONLY) e
    CROSS APPLY (SELECT 'top_wait_ms_count' AS n, ROUND(e.time_waited_micro / 1000) AS v FROM dual
                 UNION ALL SELECT 'top_waits_count', e.total_waits FROM dual) x
