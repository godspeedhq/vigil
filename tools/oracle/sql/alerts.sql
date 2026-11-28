-- The alert log's last 5 minutes, from V$DIAG_ALERT_EXT: errors, incidents
-- (the serious ones, such as ORA-00600), each ORA- code, and "Checkpoint
-- not complete", when the redo logs are too small for the load. It needs
-- SELECT on V_$DIAG_ALERT_EXT (packs/oracle/README.md).
UNION ALL SELECT 1, 'readable', 1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual
UNION ALL SELECT 2, x.n, x.v, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    -- An error is a line with an ORA- code: the log's own MESSAGE_TYPE marks
    -- routine lines as errors too. An incident is what Oracle filed as one.
    FROM (SELECT COUNT(CASE WHEN REGEXP_LIKE(message_text, 'ORA-[0-9]') THEN 1 END) AS e, COUNT(CASE WHEN message_type = 2 THEN 1 END) AS i,
              COUNT(CASE WHEN message_text LIKE '%Checkpoint not complete%' THEN 1 END) AS c
          FROM v$diag_alert_ext WHERE originating_timestamp > SYSTIMESTAMP - INTERVAL '5' MINUTE) a
    CROSS APPLY (SELECT 'errors' AS n, a.e AS v FROM dual
                 UNION ALL SELECT 'incidents', a.i FROM dual
                 UNION ALL SELECT 'checkpoint_not_complete', a.c FROM dual) x
UNION ALL SELECT 3, 'error_count', COUNT(*), 'code', code, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    -- The alert log writes some codes without their leading zeros (ORA-1653):
    -- each as ORA- and five digits.
    FROM (SELECT 'ORA-' || LPAD(REGEXP_SUBSTR(message_text, 'ORA-0*([0-9]{1,5})', 1, 1, NULL, 1), 5, '0') AS code FROM v$diag_alert_ext
          WHERE originating_timestamp > SYSTIMESTAMP - INTERVAL '5' MINUTE AND message_text LIKE '%ORA-%')
    WHERE code <> 'ORA-' GROUP BY code
