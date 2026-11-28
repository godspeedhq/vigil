#!/usr/bin/env bash
#
# status.sh - an Oracle database's health
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
# Reports whether the database answers and what it is, whether it is open
# and how, how long it has run, ARCHIVELOG mode, its CPUs, its sessions and
# processes against their limits, and each pluggable database, open or not.
# One query, read-only, from Oracle's basic dynamic performance views and
# the data dictionary: nothing from the Diagnostics or Tuning Pack (no ASH,
# no AWR, no V$SYSMETRIC).
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
#   up              1 when it answers; else 0, tagged reason=<no_listener,
#                   service_unknown, not_open, restricted (logins restricted to
#                   DBAs), timeout or unreachable>
#   info            always 1, tagged release=<19, 21 or 23>, version=<its full
#                   version>, edition=<ee, se, xe, free>, cdb=<yes or no> and
#                   role=<primary, physical_standby and the like>
#   uptime_seconds  how long the instance has run
#   open            1 when the instance is open, tagged mode=<read_write,
#                   read_only, mounted>
#   archivelog      1 in ARCHIVELOG mode
#   cpus            the CPUs it sees
#   sessions        sessions now
#   sessions_max    the most it allows (the sessions parameter)
#   sessions_pct    sessions, as a percent of the most
#   processes       processes now
#   processes_max   the most it allows (the processes parameter)
#   processes_pct   processes, as a percent of the most
#   pdbs            pluggable databases, the seed left out
#   pdb_open        1 when open, tagged pdb= and mode=
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric info 1 release=23 version=23.26.4.0.0 edition=free cdb=yes role=primary
#   metric open 1 mode=read_write
#   metric sessions_pct 34.47
#   metric pdb_open 1 pdb=FREEPDB1 mode=read_write
#
# Reading the results (starting points: tune them to the database):
#   Healthy  up 1; open 1 with mode=read_write (a primary); pdb_open 1 for
#            each PDB.
#   Watch    sessions_pct or processes_pct above 80; uptime_seconds back
#            near 0: it restarted.
#   Act      up 0; pdb_open 0 for a PDB that should be open; processes_pct
#            near 100: new connections are refused (ORA-00020); up 0 with
#            reason=restricted when no one is doing maintenance.
#
# Requires: bash, SQL*Plus (Oracle Instant Client, basic and sqlplus), and a
#   user with what packs/oracle/README.md says to grant
# Exit code: 0 on success, database up or down; 1 if the database refuses
#   the login or the query, or SQL*Plus is missing

set -u

me=status
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
-- What the database is, whether it is open, how long it has run, and its
-- sessions and processes against their limits.
UNION ALL SELECT 1, 'up', 1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual
UNION ALL SELECT 2, 'info', 1, 'release', REGEXP_SUBSTR(i.version_full, '^[0-9]+'), 'version', i.version_full,
    'edition', LOWER(i.edition), 'cdb', LOWER(d.cdb), 'role', LOWER(REPLACE(d.database_role, ' ', '_'))
    FROM v$instance i CROSS JOIN v$database d
UNION ALL SELECT 3, 'uptime_seconds', ROUND((SYSDATE - startup_time) * 86400), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$instance
UNION ALL SELECT 4, 'open', CASE WHEN i.status = 'OPEN' THEN 1 ELSE 0 END, 'mode', LOWER(REPLACE(d.open_mode, ' ', '_')),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$instance i CROSS JOIN v$database d
UNION ALL SELECT 6, 'archivelog', CASE WHEN log_mode = 'ARCHIVELOG' THEN 1 ELSE 0 END, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$database
UNION ALL SELECT 7, 'cpus', value, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$osstat WHERE stat_name = 'NUM_CPUS'
-- Sessions and processes against the most the instance allows.
UNION ALL SELECT 8, x.n, x.v, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT resource_name AS k, current_utilization AS cur,
              CASE WHEN TRIM(limit_value) IN ('UNLIMITED', '0') THEN NULL ELSE TO_NUMBER(TRIM(limit_value)) END AS lim
          FROM v$resource_limit WHERE resource_name IN ('sessions', 'processes')) r
    CROSS APPLY (
        SELECT r.k AS n, r.cur AS v FROM dual
        UNION ALL SELECT r.k || '_max', r.lim FROM dual
        UNION ALL SELECT r.k || '_pct', ROUND(100 * r.cur / r.lim, 2) FROM dual
    ) x
-- Each pluggable database but the seed: open or not.
UNION ALL SELECT 9, 'pdbs', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$pdbs WHERE name <> 'PDB$SEED'
UNION ALL SELECT 10, 'pdb_open', CASE WHEN open_mode IN ('READ WRITE', 'READ ONLY') THEN 1 ELSE 0 END,
    'pdb', name, 'mode', LOWER(REPLACE(open_mode, ' ', '_')), NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$pdbs WHERE name <> 'PDB$SEED'
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
    echo "metric up 0 reason=$reason"
    exit 0
fi
echo "$me: the query failed: $why" >&2
exit 1
