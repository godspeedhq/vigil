#!/usr/bin/env bash
#
# recovery.sh - what an Oracle database's recovery depends on
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Reports the fast recovery area: its limit, what it holds, what could be
# freed and how full it is; Flashback Database; archive destinations in
# error; log switches in the last hour; and the redo log groups, those still
# needed for crash recovery, and those not yet archived. One query,
# read-only, from Oracle's basic dynamic performance views and the data
# dictionary: nothing from the Diagnostics or Tuning Pack (no ASH, no AWR,
# no V$SYSMETRIC).
#
# Connects with SQL*Plus (Oracle Instant Client) to ORACLE_HOST, ORACLE_PORT
# and ORACLE_SERVICE, the service of the CDB root (or of a database that is
# not a CDB), as ORACLE_USER, with the password in ORACLE_PASSWORD, all set
# by the job. The password goes to SQL*Plus on its standard input, never on
# a command line. Oracle Net's encryption and integrity checks are required,
# by settings of the job's own (it never reads the machine's sqlnet.ora): a
# server that refuses them refuses the job.
#
# Metrics:
#   fra_limit_bytes           the fast recovery area's limit
#                             (db_recovery_file_dest_size); 0 with none
#   fra_used_bytes            what it holds
#   fra_reclaimable_bytes     what could be deleted (backed up, or obsolete)
#   fra_used_pct              used and not reclaimable, as a percent of the
#                             limit
#   flashback_on              1 when Flashback Database is on
#   archive_dest_errors       archive destinations in error
#   archive_dest_error        one of them: 1, tagged dest=
#   log_switches_1h           redo log switches in the last hour
#   redo_groups               redo log groups
#   redo_group_bytes          the size of the largest
#   redo_groups_active        groups still needed for crash recovery (their
#                             checkpoint is not done)
#   redo_groups_not_archived  in ARCHIVELOG mode, groups switched out and not
#                             yet archived
#
# Example output (the rest are in the same form):
#   metric fra_limit_bytes 2147483648
#   metric fra_used_pct 23.1
#   metric archive_dest_errors 0
#   metric log_switches_1h 4
#   metric redo_groups_not_archived 0
#
# Reading the results (starting points: tune them to the database):
#   Healthy  fra_used_pct below 80; archive_dest_errors 0; log_switches_1h a
#            few (Oracle suggests about four an hour).
#   Watch    fra_used_pct above 80; log_switches_1h in the dozens: the redo
#            logs are small for the load; redo_groups_not_archived above 0
#            for more than a switch or two.
#   Act      fra_used_pct near 100 in ARCHIVELOG mode: the archiver stops
#            and so does every change (ORA-00257); archive_dest_errors above
#            0.
#
# Requires: bash, SQL*Plus (Oracle Instant Client, basic and sqlplus), and a
#   user with what packs/oracle/README.md says to grant
# Exit code: 0 on success, or when the database does not answer; 1 if the
#   database refuses the login or the query, or SQL*Plus is missing

set -u

me=recovery
# SQL*Plus: ORACLE_SQLPLUS, else the one on the PATH, else ORACLE_HOME's.
client=${ORACLE_SQLPLUS-}
[ -n "$client" ] || client=$(command -v sqlplus 2> /dev/null) || client=''
[ -n "$client" ] || { [ -x "${ORACLE_HOME-}/bin/sqlplus" ] && client=$ORACLE_HOME/bin/sqlplus; }
[ -n "$client" ] && [ -x "$client" ] || { echo "$me: sqlplus not found: install Oracle Instant Client (basic and sqlplus), and put it on the PATH or set ORACLE_SQLPLUS" >&2; exit 1; }
[ -n "${ORACLE_PASSWORD-}" ] || { echo "$me: no password: the job's secret line gives ORACLE_PASSWORD" >&2; exit 1; }
[ -n "${ORACLE_SERVICE-}" ] || { echo "$me: no ORACLE_SERVICE: set it to the service of the CDB root (or of a database that is not a CDB)" >&2; exit 1; }
case $ORACLE_PASSWORD in *'"'*) echo "$me: the password holds a double quote, which an Oracle password cannot" >&2; exit 1 ;; esac
# Instant Client on Linux finds its libraries in its own folder only
# through LD_LIBRARY_PATH.
dir=$(cd "$(dirname "$client")" && pwd)
if [ "$(uname -s)" = Linux ] && ls "$dir"/libclntsh.so* > /dev/null 2>&1; then
    export LD_LIBRARY_PATH="$dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-oracle.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# Oracle Net settings of the job's own, never the machine's: encryption and
# integrity required, and no wait longer than 10 seconds to connect.
cat > "$work/sqlnet.ora" << 'ORA'
SQLNET.ENCRYPTION_CLIENT = REQUIRED
SQLNET.ENCRYPTION_TYPES_CLIENT = (AES256, AES192, AES128)
SQLNET.CRYPTO_CHECKSUM_CLIENT = REQUIRED
SQLNET.CRYPTO_CHECKSUM_TYPES_CLIENT = (SHA256, SHA384, SHA512)
SQLNET.OUTBOUND_CONNECT_TIMEOUT = 10
TCP.CONNECT_TIMEOUT = 10
NAMES.DIRECTORY_PATH = (EZCONNECT)
ORA
export TNS_ADMIN=$work NLS_LANG=AMERICAN_AMERICA.AL32UTF8
# No login.sql of anyone's: SQL*Plus runs one from these, and from where it
# starts.
unset SQLPATH ORACLE_PATH TWO_TASK LOCAL
cd "$work" || exit 1

# The query, which prints finished metric lines, so every platform's
# script prints the same.
cat > "$work/q.sql" << 'SQL'
-- Numbers with a full stop, whatever the client's or the server's language.
ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';
-- Each reading: an order, a metric name, its value, and up to five tags
-- whose values the footer makes safe. The first row only fixes the types.
WITH m (s, n, v, k1, t1, k2, t2, k3, t3, k4, t4, k5, t5) AS (
SELECT 0, CAST(NULL AS VARCHAR2(64)), CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR2(32)), CAST(NULL AS VARCHAR2(512)),
    CAST(NULL AS VARCHAR2(32)), CAST(NULL AS VARCHAR2(512)), CAST(NULL AS VARCHAR2(32)), CAST(NULL AS VARCHAR2(512)),
    CAST(NULL AS VARCHAR2(32)), CAST(NULL AS VARCHAR2(512)), CAST(NULL AS VARCHAR2(32)), CAST(NULL AS VARCHAR2(512))
FROM dual WHERE 1 = 0
-- What recovery needs: the fast recovery area and how full it is, the
-- archiver, the redo logs and how often they switch.
UNION ALL SELECT 1, x.n, x.v, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT NVL(SUM(space_limit), 0) AS lim, NVL(SUM(space_used), 0) AS used, NVL(SUM(space_reclaimable), 0) AS recl
          FROM v$recovery_file_dest WHERE name IS NOT NULL) f
    CROSS APPLY (SELECT 'fra_limit_bytes' AS n, f.lim AS v FROM dual
                 UNION ALL SELECT 'fra_used_bytes', f.used FROM dual
                 UNION ALL SELECT 'fra_reclaimable_bytes', f.recl FROM dual
                 -- What cannot be freed for new files, as a percent of the limit.
                 UNION ALL SELECT 'fra_used_pct', CASE WHEN f.lim > 0 THEN ROUND(100 * (f.used - f.recl) / f.lim, 2) END FROM dual) x
UNION ALL SELECT 2, 'flashback_on', CASE WHEN flashback_on = 'YES' THEN 1 ELSE 0 END, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$database
-- Archive destinations in error, each by its name.
UNION ALL SELECT 3, 'archive_dest_errors', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$archive_dest WHERE status IN ('ERROR', 'BAD PARAM')
UNION ALL SELECT 4, 'archive_dest_error', 1, 'dest', LOWER(dest_name), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$archive_dest WHERE status IN ('ERROR', 'BAD PARAM')
UNION ALL SELECT 5, 'log_switches_1h', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$log_history WHERE first_time > SYSDATE - 1 / 24
UNION ALL SELECT 6, 'redo_groups', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$log
UNION ALL SELECT 7, 'redo_group_bytes', MAX(bytes), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$log
-- Groups still needed for crash recovery: their checkpoint is not done.
UNION ALL SELECT 8, 'redo_groups_active', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$log WHERE status = 'ACTIVE'
-- In ARCHIVELOG mode, groups switched out and not yet archived.
UNION ALL SELECT 9, 'redo_groups_not_archived', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$log l CROSS JOIN v$database d
    WHERE d.log_mode = 'ARCHIVELOG' AND l.archived = 'NO' AND l.status <> 'CURRENT'
)
-- The readings as metric lines, in order. A value has at most two
-- decimals and a 0 before its point. A tag value keeps A-Z, a-z, 0-9, _, .
-- and -, has anything else as _, and is "none" when empty. At most 1000
-- lines: Vigil reads no more from one run.
SELECT 'metric ' || n || ' ' || REGEXP_REPLACE(TO_CHAR(ROUND(v, 2), 'TM9'), '^(-?)\.', '\10.')
    || CASE WHEN k1 IS NOT NULL THEN ' ' || k1 || '=' || NVL(REGEXP_REPLACE(t1, '[^A-Za-z0-9_.-]', '_'), 'none') END
    || CASE WHEN k2 IS NOT NULL THEN ' ' || k2 || '=' || NVL(REGEXP_REPLACE(t2, '[^A-Za-z0-9_.-]', '_'), 'none') END
    || CASE WHEN k3 IS NOT NULL THEN ' ' || k3 || '=' || NVL(REGEXP_REPLACE(t3, '[^A-Za-z0-9_.-]', '_'), 'none') END
    || CASE WHEN k4 IS NOT NULL THEN ' ' || k4 || '=' || NVL(REGEXP_REPLACE(t4, '[^A-Za-z0-9_.-]', '_'), 'none') END
    || CASE WHEN k5 IS NOT NULL THEN ' ' || k5 || '=' || NVL(REGEXP_REPLACE(t5, '[^A-Za-z0-9_.-]', '_'), 'none') END
FROM m WHERE v IS NOT NULL
ORDER BY s, t1, t2, t3, n
FETCH FIRST 1000 ROWS ONLY;
SQL

# The password on SQL*Plus's standard input, from printf, a builtin: on no
# command line.
{
    printf '%s\n' 'WHENEVER SQLERROR EXIT 3' 'WHENEVER OSERROR EXIT 4' 'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 4000 TRIMOUT ON TAB OFF VERIFY OFF ECHO OFF' 'SET DEFINE OFF SQLBLANKLINES ON SERVEROUTPUT OFF TERMOUT ON'
    printf 'CONNECT %s/"%s"@//%s:%s/%s\n' "${ORACLE_USER:-C##VIGIL_MONITOR}" "$ORACLE_PASSWORD" \
        "${ORACLE_HOST:-localhost}" "${ORACLE_PORT:-1521}" "$ORACLE_SERVICE"
    cat "$work/q.sql"
    printf 'EXIT\n'
} | "$client" -s -L /nolog > "$work/out" 2>&1
if [ "$?" -eq 0 ]; then
    grep '^metric ' "$work/out"
    exit 0
fi
code=$(grep -oE 'ORA-[0-9]{5}' "$work/out" | head -n 1)
why=$(grep -E 'ORA-[0-9]{5}|SP2-[0-9]{4}|TNS-[0-9]{5}' "$work/out" | head -n 3 | tr -s '\r\n' '  ')
[ -n "$why" ] || why=$(tr -s '\r\n' '  ' < "$work/out" | cut -c 1-300)
# It could not be reached, or is not open: a reading, not a failure. A
# refused login and a failed query are failures.
reason=''
case $code in
    ORA-12541) reason=no_listener ;;
    ORA-12514 | ORA-12505 | ORA-12521) reason=service_unknown ;;
    ORA-01033 | ORA-01034 | ORA-01089 | ORA-01090 | ORA-12526 | ORA-12528) reason=not_open ;;
    ORA-01035) reason=restricted ;;
    ORA-12170 | ORA-12535 | ORA-12171) reason=timeout ;;
    ORA-12543 | ORA-12545 | ORA-12537 | ORA-12547 | ORA-12560 | ORA-03113 | ORA-03114 | ORA-03135) reason=unreachable ;;
esac
if [ -n "$reason" ]; then
    :
    exit 0
fi
echo "$me: the query failed: $why" >&2
exit 1
