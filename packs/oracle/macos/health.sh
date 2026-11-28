#!/usr/bin/env bash
#
# health.sh - what keeps an Oracle database whole
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
# Reports invalid objects in each container; blocks known to be corrupt;
# data files that need recovery or are offline; accounts (not Oracle's own)
# that expire within 7 days; and Oracle Scheduler jobs that failed in the
# last 24 hours, or are broken. One query, read-only, from Oracle's basic
# dynamic performance views and the data dictionary: nothing from the
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
#   invalid_objects          invalid objects, tagged pdb=
#   corrupt_blocks           blocks known to be corrupt
#                            (V$DATABASE_BLOCK_CORRUPTION: found by RMAN or by a
#                            read)
#   datafiles_need_recovery  data files that need media recovery
#   datafiles_offline        data files not online
#   accounts_expiring        open accounts, not Oracle's own, whose password
#                            expires within 7 days or is in its grace period
#   scheduler_failed_24h     Scheduler job runs that failed in the last 24 hours
#   job_failed_24h           a job that failed in them: its failures, tagged
#                            pdb= and job=<owner.name> (the 10 with the most)
#   scheduler_broken         Scheduler jobs broken (stopped after failing too
#                            often)
#
# Example output (the rest are in the same form):
#   metric invalid_objects 0 pdb=CDB_ROOT
#   metric corrupt_blocks 0
#   metric scheduler_failed_24h 3
#   metric job_failed_24h 3 pdb=SHOP job=APP.NIGHTLY_LOAD
#
# Reading the results (starting points: tune them to the database):
#   Healthy  corrupt_blocks 0; datafiles_need_recovery and datafiles_offline
#            0; scheduler_failed_24h 0.
#   Watch    invalid_objects growing after a deployment; accounts_expiring
#            above 0: an application's login about to lock it out.
#   Act      corrupt_blocks above 0: run RMAN VALIDATE and recover the
#            blocks; datafiles_need_recovery above 0; scheduler_broken above
#            0.
#
# Requires: bash, SQL*Plus (Oracle Instant Client, basic and sqlplus), and a
#   user with what packs/oracle/README.md says to grant
# Exit code: 0 on success, or when the database does not answer; 1 if the
#   database refuses the login or the query, or SQL*Plus is missing

set -u

me=health
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
-- What keeps the database whole: invalid objects, damaged blocks, data
-- files offline or needing recovery, accounts about to expire, and
-- scheduler jobs that failed or broke.
UNION ALL SELECT 1, 'invalid_objects', COUNT(o.object_name), 'pdb', NVL(c.name, (SELECT name FROM v$database)),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT con_id FROM v$containers WHERE name <> 'PDB$SEED' AND open_mode <> 'MOUNTED'
          UNION SELECT 0 FROM v$database WHERE cdb = 'NO') k
    LEFT JOIN v$containers c ON c.con_id = k.con_id
    LEFT JOIN cdb_objects o ON o.con_id = k.con_id AND o.status = 'INVALID'
    GROUP BY c.name
UNION ALL SELECT 2, 'corrupt_blocks', NVL(SUM(blocks), 0), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$database_block_corruption
UNION ALL SELECT 3, 'datafiles_need_recovery', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$recover_file
UNION ALL SELECT 4, 'datafiles_offline', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$datafile WHERE status NOT IN ('ONLINE', 'SYSTEM')
-- Accounts people log in with (not Oracle's own) that expire within 7
-- days, or already in their grace period.
UNION ALL SELECT 5, 'accounts_expiring', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM cdb_users WHERE oracle_maintained = 'N' AND account_status IN ('OPEN', 'EXPIRED(GRACE)')
        AND expiry_date IS NOT NULL AND expiry_date < SYSDATE + 7
UNION ALL SELECT 6, 'scheduler_failed_24h', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM cdb_scheduler_job_run_details WHERE status = 'FAILED' AND log_date > SYSTIMESTAMP - INTERVAL '1' DAY
UNION ALL SELECT 7, 'job_failed_24h', f.n, 'pdb', NVL(c.name, (SELECT name FROM v$database)), 'job', f.owner || '.' || f.job_name,
    NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT con_id, owner, job_name, COUNT(*) AS n FROM cdb_scheduler_job_run_details
          WHERE status = 'FAILED' AND log_date > SYSTIMESTAMP - INTERVAL '1' DAY
          GROUP BY con_id, owner, job_name ORDER BY COUNT(*) DESC FETCH FIRST 10 ROWS ONLY) f
    LEFT JOIN v$containers c ON c.con_id = f.con_id
UNION ALL SELECT 8, 'scheduler_broken', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM cdb_scheduler_jobs WHERE state = 'BROKEN'
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
    ORA-01033 | ORA-01034 | ORA-01089 | ORA-01090 | ORA-12528) reason=not_open ;;
    ORA-01035 | ORA-12526) reason=restricted ;;
    ORA-12170 | ORA-12535 | ORA-12171) reason=timeout ;;
    ORA-12543 | ORA-12545 | ORA-12537 | ORA-12547 | ORA-12560 | ORA-03113 | ORA-03114 | ORA-03135) reason=unreachable ;;
esac
if [ -n "$reason" ]; then
    :
    exit 0
fi
echo "$me: the query failed: $why" >&2
exit 1
