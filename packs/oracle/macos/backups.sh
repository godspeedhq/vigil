#!/usr/bin/env bash
#
# backups.sh - how long since an Oracle database was backed up
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
# Reports, from the control file's record of RMAN's jobs, how long since the
# last full, incremental and archived log backup that completed, the RMAN
# jobs that failed in the last 24 hours and those running, and the last
# database backup's size and duration. One query, read-only, from Oracle's
# basic dynamic performance views and the data dictionary: nothing from the
# Diagnostics or Tuning Pack (no ASH, no AWR, no V$SYSMETRIC).
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
#   full_age_seconds         since the last full backup completed; -1 none
#   incremental_age_seconds  since the last incremental backup; -1 none
#   archivelog_age_seconds   since the last archived log backup; -1 none
#   failed_24h               RMAN jobs that failed, or completed with errors, in
#                            the last 24 hours
#   running                  RMAN jobs running now
#   last_bytes               the last database backup's size
#   last_seconds             how long it took
#
# Example output (the rest are in the same form):
#   metric full_age_seconds 86210
#   metric incremental_age_seconds -1
#   metric archivelog_age_seconds 912
#   metric failed_24h 0
#
# Reading the results (starting points: tune them to the database):
#   Healthy  full_age_seconds (or incremental_age_seconds, with incremental
#            level 0 and 1) within your schedule; archivelog_age_seconds
#            within an hour or so; failed_24h 0.
#   Watch    ages growing past the schedule; last_seconds growing night
#            after night.
#   Act      failed_24h above 0; full_age_seconds and
#            incremental_age_seconds both -1: there is no backup RMAN knows
#            of.
#
# Requires: bash, SQL*Plus (Oracle Instant Client, basic and sqlplus), and a
#   user with what packs/oracle/README.md says to grant
# Exit code: 0 on success, or when the database does not answer; 1 if the
#   database refuses the login or the query, or SQL*Plus is missing

set -u

me=backups
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
-- How long since RMAN last backed up the database and its archived logs,
-- from the control file's record of RMAN's jobs, and what failed.
UNION ALL SELECT 1, x.n, NVL(ROUND((SYSDATE - MAX(j.end_time)) * 86400), -1), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT 'full_age_seconds' AS n, 'DB FULL' AS t FROM dual
          UNION ALL SELECT 'incremental_age_seconds', 'DB INCR' FROM dual
          UNION ALL SELECT 'archivelog_age_seconds', 'ARCHIVELOG' FROM dual) x
    LEFT JOIN v$rman_backup_job_details j ON j.input_type = x.t AND j.status LIKE 'COMPLETED%'
    GROUP BY x.n
UNION ALL SELECT 2, 'failed_24h', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$rman_backup_job_details WHERE status IN ('FAILED', 'COMPLETED WITH ERRORS') AND start_time > SYSDATE - 1
UNION ALL SELECT 3, 'running', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$rman_backup_job_details WHERE status LIKE 'RUNNING%'
-- The last database backup that completed: its size and how long it took.
UNION ALL SELECT 4, x.n, x.v, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT output_bytes, elapsed_seconds FROM v$rman_backup_job_details
          WHERE input_type IN ('DB FULL', 'DB INCR') AND status LIKE 'COMPLETED%'
          ORDER BY end_time DESC FETCH FIRST 1 ROWS ONLY) l
    CROSS APPLY (SELECT 'last_bytes' AS n, l.output_bytes AS v FROM dual
                 UNION ALL SELECT 'last_seconds', l.elapsed_seconds FROM dual) x
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
