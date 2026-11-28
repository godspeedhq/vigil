"""Writes packs/oracle: pack.config, and each job's script for Linux and macOS
(bash) and Windows (PowerShell), from the job SQL in tools/oracle/sql and the
documentation below. Every script hands the same query to SQL*Plus, which
prints finished metric lines, so the platforms agree by construction.

    python tools/oracle/gen.py . tools/oracle/sql
"""
import os
import sys
import textwrap

repo, sqldir = sys.argv[1], sys.argv[2]
out = os.path.join(repo, 'packs', 'oracle')

NOTICE = [
    'Copyright (c) Bankole Ogundero and the Vigil contributors',
    'SPDX-License-Identifier: Apache-2.0',
    '',
    'Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or',
    'implied. Run it at your own risk: review it first, and test it before you',
    'rely on it. In no event shall the authors or copyright holders be liable',
    'for any claim, damages or other liability arising from its use. See the',
    'LICENSE file for the full terms.',
]

CONNECT = (
    "Connects with SQL*Plus (Oracle Instant Client) to ORACLE_HOST, ORACLE_PORT "
    "and ORACLE_SERVICE, the service of the CDB root (or of a database that is "
    "not a CDB), as ORACLE_USER, with the password in ORACLE_PASSWORD, all set "
    "by the job. The password goes to SQL*Plus on its standard input, never on "
    "a command line. Oracle Net's encryption and integrity checks are "
    "required, by settings of the job's own (it never reads the machine's "
    "sqlnet.ora): a server that refuses them refuses the job.")
READONLY = (
    "One query, read-only, from Oracle's basic dynamic performance views and "
    "the data dictionary: nothing from the Diagnostics or Tuning Pack (no "
    "ASH, no AWR, no V$SYSMETRIC).")

# job, metric_name, schedule, title, what, metrics, example, healthy, watch, act
JOBS = [
    dict(job='status', metric_name='oracle', when='run_every   = 1m', title='an Oracle database\'s health',
         what="Reports whether the database answers and what it is, whether it is open and how, how long it "
              "has run, ARCHIVELOG mode, its CPUs, its sessions and processes "
              "against their limits, and each pluggable database, open or not.",
         metrics=[
             ('up', "1 when it answers; else 0, tagged reason=<no_listener, service_unknown, not_open, restricted (logins restricted to DBAs), timeout or unreachable>"),
             ('info', 'always 1, tagged release=<19, 21 or 23>, version=<its full version>, edition=<ee, se, xe, free>, cdb=<yes or no> and role=<primary, physical_standby and the like>'),
             ('uptime_seconds', 'how long the instance has run'),
             ('open', '1 when the instance is open, tagged mode=<read_write, read_only, mounted>'),
             ('archivelog', '1 in ARCHIVELOG mode'),
             ('cpus', 'the CPUs it sees'),
             ('sessions', 'sessions now'),
             ('sessions_max', 'the most it allows (the sessions parameter)'),
             ('sessions_pct', 'sessions, as a percent of the most'),
             ('processes', 'processes now'),
             ('processes_max', 'the most it allows (the processes parameter)'),
             ('processes_pct', 'processes, as a percent of the most'),
             ('pdbs', 'pluggable databases, the seed left out'),
             ('pdb_open', '1 when open, tagged pdb= and mode='),
         ],
         example=['metric up 1', 'metric info 1 release=23 version=23.26.4.0.0 edition=free cdb=yes role=primary',
                  'metric open 1 mode=read_write', 'metric sessions_pct 34.47',
                  'metric pdb_open 1 pdb=FREEPDB1 mode=read_write'],
         healthy="up 1; open 1 with mode=read_write (a primary); pdb_open 1 for each PDB.",
         watch="sessions_pct or processes_pct above 80; uptime_seconds back near 0: it restarted.",
         act="up 0; pdb_open 0 for a PDB that should be open; processes_pct near 100: new connections "
             "are refused (ORA-00020); up 0 with reason=restricted when no one is doing maintenance."),
    dict(job='performance', metric_name='oracle.performance', when='run_every   = 1m', title="an Oracle database's workload counters",
         what="Reports the instance's own counters since it started: executions, calls, commits and "
              "rollbacks, logons, parses, reads and writes, redo, network, disk sorts, long scans, "
              "deadlocks and lock timeouts; time in the database and on CPU; the machine's CPU; and the "
              "buffer cache's hit ratio.",
         metrics=[
             ('executions_count', 'SQL statements executed (a running total)'),
             ('user_calls_count', 'calls from clients (a running total)'),
             ('commits_count', 'commits (a running total)'),
             ('rollbacks_count', 'rollbacks (a running total)'),
             ('logons_count', 'logons (a running total)'),
             ('logons_current', 'sessions logged on now'),
             ('parses_count', 'statements parsed (a running total)'),
             ('hard_parses_count', 'parsed from scratch, with no shared cursor (a running total)'),
             ('parse_failures_count', 'parses that failed (a running total)'),
             ('logical_reads_count', 'blocks read, from memory or disk (a running total)'),
             ('physical_reads_count', 'blocks read from disk (a running total)'),
             ('physical_writes_count', 'blocks written to disk (a running total)'),
             ('redo_bytes_count', 'redo generated (a running total)'),
             ('bytes_received_count', 'bytes from clients (a running total)'),
             ('bytes_sent_count', 'bytes to clients (a running total)'),
             ('disk_sorts_count', 'sorts too big for memory (a running total)'),
             ('long_table_scans_count', 'whole scans of large tables (a running total)'),
             ('deadlocks_count', 'deadlocks (a running total)'),
             ('lock_timeouts_count', 'lock requests that timed out (a running total)'),
             ('open_cursors', 'cursors open now'),
             ('db_time_ms_count', 'time sessions spent in the database, waiting or working, in ms (a running total)'),
             ('db_cpu_ms_count', 'of that, on CPU (a running total)'),
             ('host_busy_ms_count', "the machine's CPUs busy, summed, in ms (a running total)"),
             ('host_idle_ms_count', 'and idle (a running total)'),
             ('buffer_cache_hit_pct', 'blocks found in memory, as a percent, since the instance started'),
         ],
         example=['metric executions_count 269816', 'metric commits_count 39', 'metric hard_parses_count 4268',
                  'metric db_time_ms_count 57102', 'metric buffer_cache_hit_pct 98.71'],
         healthy="db_time_ms_count's rate steady with the workload; deadlocks_count flat.",
         watch="hard_parses_count close to parses_count: statements are not shared (literals, not bind "
               "variables); db_cpu_ms_count's rate a small share of db_time's: sessions mostly wait "
               "(oracle_waits says on what).",
         act="deadlocks_count rising; db_time_ms_count's rate far above its usual. The _count totals "
             "restart with the instance: graph them as a rate."),
    dict(job='activity', metric_name='oracle.activity', when='run_every   = 1m', title='what an Oracle database is doing now',
         what="Reports user sessions by state, what the active ones are doing (on CPU or waiting, by the "
              "wait's class), sessions blocked and the sessions at the head of a blocking chain, the longest "
              "call running, transactions and the oldest, sessions asleep with a transaction open, and long "
              "operations still running. Every container's; its own session left out.",
         metrics=[
             ('sessions', 'user sessions, tagged state=<active, inactive, killed and the like>'),
             ('active', 'active ones, tagged class=<cpu, or the class of their wait: user_i_o, concurrency, application...>'),
             ('blocked', 'sessions waiting on another'),
             ('longest_blocked_seconds', 'how long the longest of them has waited'),
             ('head_blockers', 'sessions that block others and wait on no one'),
             ('longest_active_seconds', 'how long the longest call running has run'),
             ('transactions', 'transactions open'),
             ('oldest_transaction_seconds', 'how long the oldest has been open'),
             ('idle_in_transaction', 'sessions asleep with a transaction open'),
             ('idle_in_transaction_seconds', 'how long the longest of them has slept'),
             ('long_operations', 'long operations (scans, sorts, backups) still running'),
         ],
         example=['metric sessions 4 state=active', 'metric active 1 class=application', 'metric blocked 1',
                  'metric head_blockers 1', 'metric oldest_transaction_seconds 95'],
         healthy="blocked and head_blockers 0; idle_in_transaction 0.",
         watch="oldest_transaction_seconds in minutes: it holds locks and undo; longest_active_seconds "
               "growing past what the application runs.",
         act="head_blockers above 0 for minutes: one session holds up others, find it (V$SESSION's "
             "BLOCKING_SESSION); idle_in_transaction above 0 for long: an application that did not commit."),
    dict(job='waits', metric_name='oracle.waits', when='cron        = 1/5 * * * *', title='where an Oracle database spends its time waiting',
         what="Reports the time the instance's sessions waited since it started, by wait class, and its ten "
              "most costly wait events. Idle waits are left out.",
         metrics=[
             ('wait_ms_count', 'milliseconds waited, tagged class=<user_i_o, system_i_o, commit, concurrency, application, configuration, network, scheduler, cluster, other...> (a running total)'),
             ('waits_count', 'waits (a running total)'),
             ('top_wait_ms_count', 'milliseconds waited on one of the ten most costly events, tagged event= (a running total)'),
             ('top_waits_count', 'waits on that event (a running total)'),
         ],
         example=['metric wait_ms_count 6020 class=user_i_o', 'metric wait_ms_count 550 class=commit',
                  'metric top_wait_ms_count 4435 event=db_file_sequential_read',
                  'metric top_waits_count 9468 event=db_file_sequential_read'],
         healthy="each class's rate steady with the workload.",
         watch="user_i_o rising: reads from disk (the data does not fit in the buffer cache, or the disk is "
               "slow); commit rising: the redo log's disk is slow (log file sync); concurrency: latches "
               "and buffer contention.",
         act="application rising: row locks (enq: TX - row lock contention): blocking, see "
             "oracle_activity; configuration rising: log switches waiting or space (oracle_recovery). The "
             "totals restart with the instance: graph them as a rate."),
    dict(job='tablespaces', metric_name='oracle.tablespace', when='cron        = 2/5 * * * *', title="how full an Oracle database's tablespaces are",
         what="Reports each tablespace in every container (the 100 fullest) against the most it can grow "
              "to, autoextend counted, and whether it is online; and the data files against db_files.",
         metrics=[
             ('tablespaces', 'tablespaces, every container'),
             ('tablespaces_not_shown', 'tablespaces beyond the 100 reported'),
             ('used_pct', 'used, as a percent of the most it can grow to, tagged pdb=, tablespace= and kind=<permanent, undo or temporary>'),
             ('used_bytes', 'used'),
             ('max_bytes', 'the most it can grow to'),
             ('online', '1 when online'),
             ('datafiles', 'data files'),
             ('datafiles_max', 'the most allowed (db_files)'),
         ],
         example=['metric used_pct 91.4 pdb=SHOP tablespace=DATA kind=permanent',
                  'metric max_bytes 104857600 pdb=SHOP tablespace=DATA kind=permanent',
                  'metric online 1 pdb=SHOP tablespace=DATA kind=permanent', 'metric datafiles 11'],
         healthy="used_pct below 80 for permanent tablespaces; online 1.",
         watch="used_pct above 85, or rising steadily; datafiles near datafiles_max.",
         act="used_pct above 95: inserts fail with ORA-01653 or ORA-01654 (unable to extend); online 0 for "
             "a tablespace in use. Undo and temporary tablespaces fill and empty with the workload."),
    dict(job='recovery', metric_name='oracle.recovery', when='cron        = 3/5 * * * *', title="what an Oracle database's recovery depends on",
         what="Reports the fast recovery area: its limit, what it holds, what could be freed and how full "
              "it is; Flashback Database; archive destinations in error; log switches in the last hour; "
              "and the redo log groups, those still needed for crash recovery, and those not yet archived.",
         metrics=[
             ('fra_limit_bytes', 'the fast recovery area\'s limit (db_recovery_file_dest_size); 0 with none'),
             ('fra_used_bytes', 'what it holds'),
             ('fra_reclaimable_bytes', 'what could be deleted (backed up, or obsolete)'),
             ('fra_used_pct', 'used and not reclaimable, as a percent of the limit'),
             ('flashback_on', '1 when Flashback Database is on'),
             ('archive_dest_errors', 'archive destinations in error'),
             ('archive_dest_error', 'one of them: 1, tagged dest='),
             ('log_switches_1h', 'redo log switches in the last hour'),
             ('redo_groups', 'redo log groups'),
             ('redo_group_bytes', 'the size of the largest'),
             ('redo_groups_active', 'groups still needed for crash recovery (their checkpoint is not done)'),
             ('redo_groups_not_archived', 'in ARCHIVELOG mode, groups switched out and not yet archived'),
         ],
         example=['metric fra_limit_bytes 2147483648', 'metric fra_used_pct 23.1', 'metric archive_dest_errors 0',
                  'metric log_switches_1h 4', 'metric redo_groups_not_archived 0'],
         healthy="fra_used_pct below 80; archive_dest_errors 0; log_switches_1h a few (Oracle suggests about "
                 "four an hour).",
         watch="fra_used_pct above 80; log_switches_1h in the dozens: the redo logs are small for the load; "
               "redo_groups_not_archived above 0 for more than a switch or two.",
         act="fra_used_pct near 100 in ARCHIVELOG mode: the archiver stops and so does every change "
             "(ORA-00257); archive_dest_errors above 0."),
    dict(job='memory', metric_name='oracle.memory', when='cron        = 4/5 * * * *', title="an Oracle database's memory",
         what="Reports the SGA and its targets, the buffer cache and the shared pool and its free memory, "
              "and the PGA: allocated and in use against its target, its hard limit and how close to it, and "
              "how often the target was not enough.",
         metrics=[
             ('sga_bytes', 'the SGA'),
             ('sga_target_bytes', 'sga_target (0: not set)'),
             ('memory_target_bytes', 'memory_target (0: not set)'),
             ('buffer_cache_bytes', 'the buffer cache'),
             ('shared_pool_bytes', 'the shared pool'),
             ('shared_pool_free_bytes', 'free in it'),
             ('pga_allocated_bytes', 'PGA allocated'),
             ('pga_inuse_bytes', 'PGA in use'),
             ('pga_target_bytes', 'pga_aggregate_target'),
             ('pga_limit_bytes', 'pga_aggregate_limit'),
             ('pga_limit_pct', 'PGA allocated, as a percent of the limit'),
             ('pga_over_allocations_count', 'times the PGA had to go past its target (a running total)'),
         ],
         example=['metric sga_bytes 1603452272', 'metric shared_pool_free_bytes 53138864',
                  'metric pga_allocated_bytes 398779392', 'metric pga_limit_pct 18.57'],
         healthy="pga_limit_pct below 70; pga_over_allocations_count flat.",
         watch="pga_over_allocations_count rising: pga_aggregate_target is too small; shared_pool_free_bytes "
               "falling toward 0 with hard parses rising.",
         act="pga_limit_pct near 100: Oracle ends the sessions using the most PGA (ORA-04036); "
             "shared_pool_free_bytes near 0 with ORA-04031 in the alert log."),
    dict(job='backups', metric_name='oracle.backups', when='cron        = 12/15 * * * *', title="how long since an Oracle database was backed up",
         what="Reports, from the control file's record of RMAN's jobs, how long since the last full, "
              "incremental and archived log backup that completed, the RMAN jobs that failed in the last 24 "
              "hours and those running, and the last database backup's size and duration.",
         metrics=[
             ('full_age_seconds', 'since the last full backup completed; -1 none'),
             ('incremental_age_seconds', 'since the last incremental backup; -1 none'),
             ('archivelog_age_seconds', 'since the last archived log backup; -1 none'),
             ('failed_24h', 'RMAN jobs that failed, or completed with errors, in the last 24 hours'),
             ('running', 'RMAN jobs running now'),
             ('last_bytes', 'the last database backup\'s size'),
             ('last_seconds', 'how long it took'),
         ],
         example=['metric full_age_seconds 86210', 'metric incremental_age_seconds -1',
                  'metric archivelog_age_seconds 912', 'metric failed_24h 0'],
         healthy="full_age_seconds (or incremental_age_seconds, with incremental level 0 and 1) within your "
                 "schedule; archivelog_age_seconds within an hour or so; failed_24h 0.",
         watch="ages growing past the schedule; last_seconds growing night after night.",
         act="failed_24h above 0; full_age_seconds and incremental_age_seconds both -1: there is no backup "
             "RMAN knows of."),
    dict(job='health', metric_name='oracle.health', when='cron        = 8/15 * * * *', title="what keeps an Oracle database whole",
         what="Reports invalid objects in each container; blocks known to be corrupt; data files that need "
              "recovery or are offline; accounts (not Oracle's own) that expire within 7 days; and Oracle "
              "Scheduler jobs that failed in the last 24 hours, or are broken.",
         metrics=[
             ('invalid_objects', 'invalid objects, tagged pdb='),
             ('corrupt_blocks', 'blocks known to be corrupt (V$DATABASE_BLOCK_CORRUPTION: found by RMAN or by a read)'),
             ('datafiles_need_recovery', 'data files that need media recovery'),
             ('datafiles_offline', 'data files not online'),
             ('accounts_expiring', 'open accounts, not Oracle\'s own, whose password expires within 7 days or is in its grace period'),
             ('scheduler_failed_24h', 'Scheduler job runs that failed in the last 24 hours'),
             ('job_failed_24h', 'a job that failed in them: its failures, tagged pdb= and job=<owner.name> (the 10 with the most)'),
             ('scheduler_broken', 'Scheduler jobs broken (stopped after failing too often)'),
         ],
         example=['metric invalid_objects 0 pdb=CDB_ROOT', 'metric corrupt_blocks 0',
                  'metric scheduler_failed_24h 3', 'metric job_failed_24h 3 pdb=SHOP job=APP.NIGHTLY_LOAD'],
         healthy="corrupt_blocks 0; datafiles_need_recovery and datafiles_offline 0; scheduler_failed_24h 0.",
         watch="invalid_objects growing after a deployment; accounts_expiring above 0: an application's "
               "login about to lock it out.",
         act="corrupt_blocks above 0: run RMAN VALIDATE and recover the blocks; datafiles_need_recovery "
             "above 0; scheduler_broken above 0."),
    dict(job='alerts', metric_name='oracle.alerts', when='cron        = 0/5 * * * *', title="what an Oracle database's alert log said",
         what="Reports the alert log's last 5 minutes, from V$DIAG_ALERT_EXT: errors (lines with an ORA- code), incidents (critical "
              "errors, such as ORA-00600 and ORA-07445, that Oracle records with a dump), each ORA- code and "
              "how often, and \"Checkpoint not complete\". Reading it needs SELECT on V_$DIAG_ALERT_EXT "
              "(packs/oracle/README.md): without it, readable 0 and nothing else.",
         metrics=[
             ('readable', '1 when this user may read the alert log, else 0'),
             ('errors', 'lines with an ORA- code in the last 5 minutes'),
             ('incidents', 'of them, critical errors with an incident (ORA-00600, ORA-07445 and the like)'),
             ('error_count', 'of them, by code, tagged code=<ORA- and five digits>'),
             ('checkpoint_not_complete', '"Checkpoint not complete" in the last 5 minutes: changes waited for a redo log'),
         ],
         example=['metric readable 1', 'metric errors 2', 'metric incidents 0', 'metric error_count 2 code=ORA-01653'],
         healthy="readable 1; errors 0; incidents 0.",
         watch="errors above 0: read them in the alert log; checkpoint_not_complete above 0: the redo logs "
               "are too small or too few.",
         act="incidents above 0: an ORA-00600 or ORA-07445, open a service request; error_count with "
             "code=ORA-01653, ORA-01654 or ORA-01688 (unable to extend), ORA-00257 (archiver stuck), "
             "ORA-04031 (shared pool) or ORA-00060 (deadlock)."),
]

DOWN_CODES = [
    # Nothing listening, or the address cannot be reached.
    ('no_listener', ['ORA-12541']),
    ('service_unknown', ['ORA-12514', 'ORA-12505', 'ORA-12521']),
    ('not_open', ['ORA-01033', 'ORA-01034', 'ORA-01089', 'ORA-01090', 'ORA-12526', 'ORA-12528']),
    # Open, but in restricted mode: only users with RESTRICTED SESSION.
    ('restricted', ['ORA-01035']),
    ('timeout', ['ORA-12170', 'ORA-12535', 'ORA-12171']),
    ('unreachable', ['ORA-12543', 'ORA-12545', 'ORA-12537', 'ORA-12547', 'ORA-12560', 'ORA-03113', 'ORA-03114', 'ORA-03135']),
]

SQLNET = [
    'SQLNET.ENCRYPTION_CLIENT = REQUIRED',
    'SQLNET.ENCRYPTION_TYPES_CLIENT = (AES256, AES192, AES128)',
    'SQLNET.CRYPTO_CHECKSUM_CLIENT = REQUIRED',
    'SQLNET.CRYPTO_CHECKSUM_TYPES_CLIENT = (SHA256, SHA384, SHA512)',
    'SQLNET.OUTBOUND_CONNECT_TIMEOUT = 10',
    'TCP.CONNECT_TIMEOUT = 10',
    'NAMES.DIRECTORY_PATH = (EZCONNECT)',
]

# Before the connection: errors end SQL*Plus, and its output is the query's
# rows only.
PRELUDE = [
    'WHENEVER SQLERROR EXIT 3',
    'WHENEVER OSERROR EXIT 4',
    'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 4000 TRIMOUT ON TAB OFF VERIFY OFF ECHO OFF',
    'SET DEFINE OFF SQLBLANKLINES ON SERVEROUTPUT OFF TERMOUT ON',
]


def wrap(text, width, first='', rest=''):
    return textwrap.wrap(text, width, initial_indent=first, subsequent_indent=rest, break_on_hyphens=False) or [first]


def metrics_doc(metrics, indent):
    w = max(len(n) for n, _ in metrics) + 2
    lines = []
    for n, d in metrics:
        lines += wrap(d, 78 - len(indent), first=(indent + '  ' + n).ljust(len(indent) + 2 + w), rest=' ' * (len(indent) + 2 + w))
    return lines


def doc(j, ps):
    """The header's text, as lines without a comment marker."""
    c = []
    c += wrap(j['what'] + ' ' + READONLY, 74)
    c += ['']
    c += wrap(CONNECT, 74)
    c += ['', 'Metrics:']
    c += metrics_doc(j['metrics'], '')
    c += ['', 'Example output (the rest are in the same form):']
    c += ['  ' + e for e in j['example']]
    c += ['', 'Reading the results (starting points: tune them to the database):']
    c += wrap(j['healthy'], 74, first='  Healthy  ', rest=' ' * 11)
    c += wrap(j['watch'], 74, first='  Watch    ', rest=' ' * 11)
    c += wrap(j['act'], 74, first='  Act      ', rest=' ' * 11)
    c += ['']
    if ps:
        c += ['Requires: Windows PowerShell 5.1 or PowerShell 7, SQL*Plus (Oracle',
              '  Instant Client, basic and sqlplus), and a user with what',
              '  packs/oracle/README.md says to grant']
    else:
        c += ['Requires: bash, SQL*Plus (Oracle Instant Client, basic and sqlplus), and a',
              '  user with what packs/oracle/README.md says to grant']
    first = ('Exit code: 0 on success, database up or down; 1 if' if j['job'] == 'status'
             else 'Exit code: 0 on success, or when the database does not answer; 1 if')
    why = 'the database refuses the login or the query, or SQL*Plus is missing'
    c += wrap(first + ' ' + why, 74, rest='  ')
    return c


def sql_for(j):
    parts = ['_head.sql', j['job'] + '.sql', '_foot.sql']
    text = ''.join(open(os.path.join(sqldir, p), encoding='utf-8').read() for p in parts)
    # Nothing that would end the bash heredoc or the PowerShell here-string,
    # nor a line SQL*Plus would take as a command of its own.
    for line in text.split('\n'):
        assert line != 'SQL' and not line.startswith("'@") and not line.startswith(('@', '#', '/', '!')), line
    assert '\t' not in text and '&' not in text
    return text.rstrip('\n') + '\n'


def down_case_sh():
    lines = []
    for reason, codes in DOWN_CODES:
        lines.append('    %s) reason=%s ;;' % (' | '.join(codes), reason))
    return '\n'.join(lines)


def down_ps():
    lines = []
    for reason, codes in DOWN_CODES:
        lines.append("    '%s' = '%s'" % ('|'.join(c.replace('ORA-', '') for c in codes), reason))
    return '\n'.join(lines)


SH_BODY = r'''set -u

me=@JOB@
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
@SQLNET@ORA
export TNS_ADMIN=$work NLS_LANG=AMERICAN_AMERICA.AL32UTF8
# No login.sql of anyone's: SQL*Plus runs one from these, and from where it
# starts.
unset SQLPATH ORACLE_PATH TWO_TASK LOCAL
cd "$work" || exit 1

# The query, which prints finished metric lines, so every platform's
# script prints the same.
cat > "$work/q.sql" << 'SQL'
@SQL@SQL

# The password on SQL*Plus's standard input, from printf, a builtin: on no
# command line.
{
    printf '%s\n' @PRELUDE@
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
@DOWNCASE@
esac
if [ -n "$reason" ]; then
    @DOWN@
    exit 0
fi
@REFUSED@echo "$me: the query failed: $why" >&2
exit 1
'''

PS_BODY = r'''$ErrorActionPreference = 'Stop'
$me = '@JOB@'

# The query, which prints finished metric lines, so every platform's script
# prints the same.
$sql = @'
@SQL@'@

# SQL*Plus: ORACLE_SQLPLUS, else the one on the PATH, else ORACLE_HOME's.
$client = $env:ORACLE_SQLPLUS
if (-not $client) { $c = Get-Command sqlplus.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { $client = $c.Source } }
if (-not $client -and $env:ORACLE_HOME -and (Test-Path -LiteralPath (Join-Path $env:ORACLE_HOME 'bin\sqlplus.exe'))) { $client = Join-Path $env:ORACLE_HOME 'bin\sqlplus.exe' }
if (-not $client -or -not (Test-Path -LiteralPath $client)) { [Console]::Error.WriteLine("${me}: sqlplus not found: install Oracle Instant Client (basic and sqlplus), and put it on the PATH or set ORACLE_SQLPLUS"); exit 1 }
if (-not $env:ORACLE_PASSWORD) { [Console]::Error.WriteLine("${me}: no password: the job's secret line gives ORACLE_PASSWORD"); exit 1 }
if (-not $env:ORACLE_SERVICE) { [Console]::Error.WriteLine("${me}: no ORACLE_SERVICE: set it to the service of the CDB root (or of a database that is not a CDB)"); exit 1 }
if ($env:ORACLE_PASSWORD.Contains('"')) { [Console]::Error.WriteLine("${me}: the password holds a double quote, which an Oracle password cannot"); exit 1 }
$user = if ($env:ORACLE_USER) { $env:ORACLE_USER } else { 'C##VIGIL_MONITOR' }
$hostName = if ($env:ORACLE_HOST) { $env:ORACLE_HOST } else { 'localhost' }
$port = if ($env:ORACLE_PORT) { $env:ORACLE_PORT } else { '1521' }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-oracle.' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    # Oracle Net settings of the job's own, never the machine's: encryption
    # and integrity required, and no wait longer than 10 seconds to connect.
    [System.IO.File]::WriteAllText((Join-Path $work 'sqlnet.ora'), @'
@SQLNET@'@)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $client
    $psi.Arguments = '-s -L /nolog'
    $psi.WorkingDirectory = $work
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['TNS_ADMIN'] = $work
    $psi.EnvironmentVariables['NLS_LANG'] = 'AMERICAN_AMERICA.AL32UTF8'
    # No login.sql of anyone's: SQL*Plus runs one from these, and from where
    # it starts.
    foreach ($v in 'SQLPATH', 'ORACLE_PATH', 'TWO_TASK', 'LOCAL') { $psi.EnvironmentVariables.Remove($v) }
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    # The password on SQL*Plus's standard input: on no command line.
    $in = $p.StandardInput
    $in.NewLine = "`n"
@PRELUDEPS@    $in.WriteLine('CONNECT ' + $user + '/"' + $env:ORACLE_PASSWORD + '"@//' + $hostName + ':' + $port + '/' + $env:ORACLE_SERVICE)
    $in.Write($sql.Replace("`r`n", "`n"))
    $in.WriteLine('EXIT')
    $in.Close()
    $p.WaitForExit()
    $out = $outTask.Result + $errTask.Result
    $rc = $p.ExitCode
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

if ($rc -eq 0) {
    foreach ($l in ($out -split "`r?`n")) { if ($l.StartsWith('metric ')) { Write-Output $l } }
    exit 0
}
$code = ''
if ($out -match 'ORA-(\d{5})') { $code = $Matches[1] }
$why = (($out -split "`r?`n") | Where-Object { $_ -match 'ORA-\d{5}|SP2-\d{4}|TNS-\d{5}' } | Select-Object -First 3) -join ' '
if (-not $why) { $why = ($out -replace '\s+', ' ').Trim() }
# It could not be reached, or is not open: a reading, not a failure. A
# refused login and a failed query are failures.
$reasons = [ordered]@{
@DOWNPS@
}
foreach ($k in $reasons.Keys) {
    if ($code -and ($k.Split('|') -contains $code)) {
@DOWNPSOUT@        exit 0
    }
}
@REFUSEDPS@[Console]::Error.WriteLine("${me}: the query failed: $why")
exit 1
'''


def sh_script(j):
    head = ['#!/usr/bin/env bash', '#', '# %s.sh - %s' % (j['job'], j['title']), '#']
    head += [('# ' + n).rstrip() for n in NOTICE] + ['#']
    head += [('# ' + l).rstrip() for l in doc(j, False)]
    prelude = ' '.join("'%s'" % p for p in PRELUDE)
    body = SH_BODY.replace('@JOB@', j['job']).replace('@SQL@', sql_for(j)).replace('@SQLNET@', '\n'.join(SQLNET) + '\n')
    body = body.replace('@PRELUDE@', prelude).replace('@DOWNCASE@', down_case_sh())
    body = body.replace('@DOWN@', "echo \"metric up 0 reason=$reason\"" if j['job'] == 'status' else ':')
    refused = ''
    if j['job'] == 'alerts':
        refused = ('# Without SELECT on V_$DIAG_ALERT_EXT, a reading: say so, and nothing else.\n'
                   'case $code in ORA-00942 | ORA-01031) echo \'metric readable 0\'; exit 0 ;; esac\n')
    body = body.replace('@REFUSED@', refused)
    return '\n'.join(head) + '\n\n' + body


def ps_script(j):
    head = ['#Requires -Version 5.1', '', '<#', '.SYNOPSIS', '    %s.ps1 - %s, on Windows' % (j['job'], j['title']), '.NOTES']
    head += [('    ' + n).rstrip() for n in NOTICE]
    head += ['.DESCRIPTION']
    head += [('    ' + l).rstrip() for l in doc(j, True)]
    head += ['#>']
    prelude = ''.join("    $in.WriteLine('%s')\n" % p for p in PRELUDE)
    body = PS_BODY.replace('@JOB@', j['job']).replace('@SQL@', sql_for(j)).replace('@SQLNET@', '\n'.join(SQLNET) + '\n')
    body = body.replace('@PRELUDEPS@', prelude).replace('@DOWNPS@', down_ps())
    body = body.replace('@DOWNPSOUT@', "        Write-Output \"metric up 0 reason=$($reasons[$k])\"\n" if j['job'] == 'status' else '')
    refused = ''
    if j['job'] == 'alerts':
        refused = ("# Without SELECT on V_$DIAG_ALERT_EXT, a reading: say so, and nothing else.\n"
                   "if ($code -eq '00942' -or $code -eq '01031') { Write-Output 'metric readable 0'; exit 0 }\n")
    body = body.replace('@REFUSEDPS@', refused)
    return '\n'.join(head) + '\n\n' + body


def pack_config():
    p = ['# oracle - Oracle Database 19c, 21c and 23ai, on this machine or any it can',
         '# reach, with SQL*Plus: whether it answers and is open, its workload, sessions',
         '# and blocking, waits, tablespaces, the fast recovery area and redo, memory,',
         '# RMAN backups, what keeps it whole, and its alert log. Only Oracle\'s basic',
         '# views: nothing from the Diagnostics or Tuning Pack. Linux, macOS and',
         '# Windows. See SPECIFICATION.md section 18.10 for this format.',
         '#',
         '# The jobs that run every 5 or 15 minutes each have minutes of their own',
         '# (cron, local time), so few runs start together.',
         '#',
         '# Off until enabled: vigil pack enable oracle. It logs in as a read-only',
         '# user; create one once, as SYSDBA, in the CDB root (packs/oracle/README.md',
         '# has it all, and the names for a database that is not a CDB):',
         "#   CREATE USER C##VIGIL_MONITOR IDENTIFIED BY \"...\" CONTAINER=ALL;",
         '#   GRANT CREATE SESSION, SELECT_CATALOG_ROLE TO C##VIGIL_MONITOR CONTAINER=ALL;',
         '#   ALTER USER C##VIGIL_MONITOR SET CONTAINER_DATA=ALL CONTAINER=CURRENT;',
         '#   GRANT SELECT ON SYS.V_$DIAG_ALERT_EXT TO C##VIGIL_MONITOR CONTAINER=ALL;',
         '# and give Vigil its password:',
         '#   vigil secret set ORACLE_MONITOR_PASSWORD',
         '# Then set ORACLE_SERVICE (and the host and port) in the env lines of the',
         '# jobs vigil pack enable writes into the configuration.',
         '#']
    p += [('# ' + n).rstrip() for n in NOTICE]
    p += ['',
          '[pack]',
          'version     = 1.0.0',
          '# vigil: the oldest Vigil this pack runs on. vigil pack update refuses the',
          '# pack on an older one.',
          'vigil       = 0.3.0',
          'description = Oracle Database: up and open, workload, sessions and blocking, waits, tablespaces, recovery area and redo, memory, RMAN backups, integrity, scheduler jobs, alert log',
          '# What vigil pack info shows besides: the servers it is meant for, the',
          '# programs its scripts need on each platform, and where it is explained.',
          'works_with  = Oracle Database 19c, 21c and 23ai, a CDB or not (tested: 23ai Free and 21c XE)',
          'programs_linux = sqlplus (Oracle Instant Client, basic and sqlplus)',
          'programs_macos = sqlplus (Oracle Instant Client, basic and sqlplus)',
          'programs_windows = PowerShell 5.1 or later, sqlplus (Oracle Instant Client, basic and sqlplus)',
          'docs        = https://github.com/godspeedhq/vigil/blob/main/packs/oracle/README.md',
          'needs       = a read-only user, as SYSDBA in the CDB root: CREATE USER C##VIGIL_MONITOR IDENTIFIED BY "..." CONTAINER=ALL; GRANT CREATE SESSION, SELECT_CATALOG_ROLE TO C##VIGIL_MONITOR CONTAINER=ALL; ALTER USER C##VIGIL_MONITOR SET CONTAINER_DATA=ALL CONTAINER=CURRENT (not a CDB: VIGIL_MONITOR, without CONTAINER and CONTAINER_DATA)',
          'needs       = for oracle_alerts: GRANT SELECT ON SYS.V_$DIAG_ALERT_EXT TO C##VIGIL_MONITOR CONTAINER=ALL',
          '']
    for j in JOBS:
        names = [n for n, _ in j['metrics']]
        p += ['[job.%s]' % j['job'],
              'metric_name = %s' % j['metric_name'],
              'metrics     = %s' % ', '.join(names),
              j['when'],
              'max_runtime = %s' % ('1m' if j['job'] in ('tablespaces', 'health', 'alerts', 'backups') else '30s'),
              'env         = ORACLE_HOST=localhost',
              'env         = ORACLE_PORT=1521',
              'env         = ORACLE_SERVICE=ORCLCDB',
              'env         = ORACLE_USER=C##VIGIL_MONITOR',
              'secret      = ORACLE_PASSWORD=secret:ORACLE_MONITOR_PASSWORD',
              '']
    return '\n'.join(p).rstrip('\n') + '\n'


os.makedirs(os.path.join(out, 'linux'), exist_ok=True)
os.makedirs(os.path.join(out, 'macos'), exist_ok=True)
os.makedirs(os.path.join(out, 'windows'), exist_ok=True)
open(os.path.join(out, 'pack.config'), 'w', encoding='utf-8', newline='\n').write(pack_config())
for j in JOBS:
    s = sh_script(j)
    for os_ in ('linux', 'macos'):
        open(os.path.join(out, os_, j['job'] + '.sh'), 'w', encoding='utf-8', newline='\n').write(s)
    open(os.path.join(out, 'windows', j['job'] + '.ps1'), 'w', encoding='utf-8', newline='\n').write(ps_script(j))
print('wrote', len(JOBS), 'jobs')
