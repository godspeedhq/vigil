#!/usr/bin/env bash
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# run-oracle.sh - the oracle pack against a real Oracle Database in trouble
# on purpose, with its evidence kept like the other runs'.
#
#   ORACLE_SQLPLUS=<path to sqlplus> scripts/run-oracle.sh [23|21]
#
# 23 (the default) is Oracle Database 23ai Free, 21 is 21c XE, from
# compose.oracle.yaml, one at a time. As SYSDBA: the user the pack asks for,
# as packs/oracle/README.md says, and one without the alert log's grant;
# ARCHIVELOG mode with a fast recovery area; in the PDB, an application
# user whose password expires in 3 days, a 10 MB tablespace filled until an
# insert fails (ORA-01653), a view whose table is gone, and a Scheduler job
# that fails. RMAN backs up the database and the archived logs, and fails a
# backup on purpose; the recovery area is then shrunk to some 90% full; the
# redo logs switch; two sessions deadlock (ORA-00060); and, while the jobs
# run, one session holds a row with its transaction open and another waits
# for it. Every job is run and what it reads is checked; then a wrong
# password, no password, nothing listening, a service that is not there,
# the user without the alert log's grant, the password on no process's
# command line, and Oracle Net's encryption, required (and a server that
# refuses it). Then tests/integration/service-packs.sh runs the pack
# through Vigil. Then the database is put in other states: its PDB closed,
# logins restricted, mounted and not open, shut down. The passwords are
# made here, into this run's own folder, and kept out of the evidence.
# VIGIL_IT_ORACLE_HOLD (below) keeps it up for other machines' tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

release=${1:-23}
case $release in
    23) svc=oracle23 service=FREE pdb=FREEPDB1 port=11523 ;;
    21) svc=oracle21 service=XE pdb=XEPDB1 port=11521 ;;
    *) die 'usage: run-oracle.sh [23|21]' ;;
esac
command -v docker > /dev/null 2>&1 || die 'docker not found: Oracle runs in a container'
command -v openssl > /dev/null 2>&1 || die 'openssl not found'
prog=${ORACLE_SQLPLUS:-$(command -v sqlplus 2> /dev/null)}
[ -n "$prog" ] && [ -x "$prog" ] || die 'sqlplus not found: set ORACLE_SQLPLUS to Instant Client'"'"'s'
file=compose.oracle.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-oracle-it.XXXXXX") || exit 1
root=$work/none
dc() { docker compose -p vigil-oracle --project-directory "$bk_dir" -f "$bk_dir/$file" --profile "$release" "$@"; }
# Oracle passwords, quoted where they are used: each starts with a letter
# all the same.
for n in sys monitor noalert app; do (umask 077 && printf 'Vg%s\n' "$(openssl rand -hex 12)" > "$work/$n.pw"); done
export ORACLE_PASSWORD; ORACLE_PASSWORD=$(cat "$work/sys.pw")
bg=''
trap '[ -z "$bg" ] || kill $bg 2> /dev/null; dc down -v > /dev/null 2>&1; evidence_save "$(cat "$work/sys.pw")" "$(cat "$work/monitor.pw")" "$(cat "$work/noalert.pw")" "$(cat "$work/app.pw")"; rm -rf "$work"' EXIT
evidence_start "pack-oracle-$release" "$bk_dir/$file" "$0" "$@"
printf 'sqlplus  %s, %s\n' "$(LD_LIBRARY_PATH="$(dirname "$prog")" "$prog" -V | grep -i 'release' | head -n 1)" "$prog"
pack=$bk_repo/packs/oracle/linux
[ "$(uname -s)" = Darwin ] && pack=$bk_repo/packs/oracle/macos

dc up -d "$svc" > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'Oracle would not start'; }
c=vigil-oracle-$svc-1
for _ in $(seq 1 120); do docker logs "$c" 2>&1 | grep -q 'DATABASE IS READY TO USE' && break; sleep 5; done
docker logs "$c" 2>&1 | grep -q 'DATABASE IS READY TO USE' || { docker logs --tail 20 "$c"; die 'Oracle did not become ready in 10 minutes'; }
# sys: SQL on stdin, as SYSDBA inside the container (the OS account, no
# password). rman: the same, to RMAN.
sys() { docker exec -i "$c" sqlplus -s -L / as sysdba; }
rman() { docker exec -i "$c" rman target / > "$work/rman.log" 2>&1; }
# app: SQL on stdin as vigil_app in the PDB, its password on stdin too.
app() { { printf 'CONNECT vigil_app/"%s"@//localhost:1521/%s\n' "$(cat "$work/app.pw")" "$pdb"; cat; } | docker exec -i "$c" sqlplus -s -L /nolog; }
say() { printf '\n# %s\n' "$*"; }

say "Oracle $release: the users, ARCHIVELOG with a recovery area, and an application in trouble, as SYSDBA."
# The user the pack asks for, as packs/oracle/README.md says; and one
# without the alert log's grant. The passwords go in on stdin.
{
    printf 'WHENEVER SQLERROR EXIT 1\nSET FEEDBACK OFF\n'
    printf 'CREATE USER C##VIGIL_MONITOR IDENTIFIED BY "%s" CONTAINER=ALL;\n' "$(cat "$work/monitor.pw")"
    printf 'CREATE USER C##VIGIL_NOALERT IDENTIFIED BY "%s" CONTAINER=ALL;\n' "$(cat "$work/noalert.pw")"
    cat << 'SQL'
GRANT CREATE SESSION, SELECT_CATALOG_ROLE TO C##VIGIL_MONITOR CONTAINER=ALL;
ALTER USER C##VIGIL_MONITOR SET CONTAINER_DATA=ALL CONTAINER=CURRENT;
GRANT SELECT ON SYS.V_$DIAG_ALERT_EXT TO C##VIGIL_MONITOR CONTAINER=ALL;
GRANT CREATE SESSION, SELECT_CATALOG_ROLE TO C##VIGIL_NOALERT CONTAINER=ALL;
ALTER USER C##VIGIL_NOALERT SET CONTAINER_DATA=ALL CONTAINER=CURRENT;
HOST mkdir -p /opt/oracle/oradata/fra
ALTER SYSTEM SET db_recovery_file_dest_size = 4G;
ALTER SYSTEM SET db_recovery_file_dest = '/opt/oracle/oradata/fra';
WHENEVER SQLERROR CONTINUE
SHUTDOWN IMMEDIATE
STARTUP MOUNT
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ALTER PLUGGABLE DATABASE ALL OPEN;
SELECT 'mode ' || log_mode FROM v$database;
EXIT
SQL
} | sys > "$work/setup.log" 2>&1 || { cat "$work/setup.log"; die 'could not make the users'; }
grep -q '^mode ARCHIVELOG' "$work/setup.log" || { cat "$work/setup.log"; die 'not in ARCHIVELOG mode'; }
echo 'users    C##VIGIL_MONITOR (as packs/oracle/README.md says), C##VIGIL_NOALERT (the same, without the alert log)'
echo 'archive  ARCHIVELOG, a 4 GB recovery area in /opt/oracle/oradata/fra'
{
    printf 'WHENEVER SQLERROR EXIT 1\nSET FEEDBACK OFF\nALTER SESSION SET CONTAINER = %s;\n' "$pdb"
    printf 'CREATE PROFILE vigil_short LIMIT PASSWORD_LIFE_TIME 3;\n'
    printf 'CREATE USER vigil_app IDENTIFIED BY "%s" PROFILE vigil_short;\n' "$(cat "$work/app.pw")"
    cat << 'SQL'
-- A 10 MB tablespace beside the PDB's own files, that cannot grow.
DECLARE d VARCHAR2(512);
BEGIN
    SELECT SUBSTR(file_name, 1, INSTR(file_name, '/', -1)) INTO d FROM dba_data_files WHERE ROWNUM = 1;
    EXECUTE IMMEDIATE 'CREATE TABLESPACE vigil_small DATAFILE ''' || d || 'vigil_small01.dbf'' SIZE 10M AUTOEXTEND OFF';
END;
/
ALTER USER vigil_app DEFAULT TABLESPACE vigil_small QUOTA UNLIMITED ON vigil_small QUOTA UNLIMITED ON users;
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE JOB TO vigil_app;
CREATE TABLE vigil_app.t (id NUMBER PRIMARY KEY, v NUMBER) TABLESPACE users;
INSERT INTO vigil_app.t SELECT LEVEL, 0 FROM dual CONNECT BY LEVEL <= 3;
COMMIT;
CREATE TABLE vigil_app.filler (pad CHAR(2000)) TABLESPACE vigil_small;
-- A view whose table is gone: invalid.
CREATE TABLE vigil_app.gone (x NUMBER) TABLESPACE users;
CREATE VIEW vigil_app.v_gone AS SELECT x FROM vigil_app.gone;
DROP TABLE vigil_app.gone;
-- A Scheduler job that fails, once.
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(job_name => 'VIGIL_APP.NIGHTLY_LOAD', job_type => 'PLSQL_BLOCK',
        job_action => 'BEGIN RAISE_APPLICATION_ERROR(-20001, ''the load failed''); END;', enabled => TRUE);
END;
/
EXIT
SQL
} | sys > "$work/app.log" 2>&1 || { cat "$work/app.log"; die 'could not make the application'; }
echo "app      in $pdb: vigil_app (password lifetime 3 days), tablespace VIGIL_SMALL (10 MB, no autoextend), an invalid view, a Scheduler job that fails"

printf 'BACKUP DATABASE;\nEXIT\n' | rman || { tail -n 20 "$work/rman.log"; die 'RMAN could not back up the database'; }
printf 'BACKUP ARCHIVELOG ALL;\nEXIT\n' | rman || { tail -n 20 "$work/rman.log"; die 'RMAN could not back up the archived logs'; }
# A backup to a folder that is not there: RMAN fails it.
printf "BACKUP DATAFILE 1 FORMAT '/nonexistent/%%U';\nEXIT\n" | rman && die 'the failing backup did not fail'
grep -m 1 -o 'ORA-[0-9]*: [^.]*' "$work/rman.log" | sed 's/^/rman     the failing backup: /'
echo 'rman     BACKUP DATABASE, BACKUP ARCHIVELOG ALL; and one to /nonexistent, which failed'
# The recovery area: shrunk to some 90% full, of what cannot be freed.
printf "SET HEADING OFF FEEDBACK OFF\nSELECT CEIL((space_used - space_reclaimable) / 0.9 / 1048576) FROM v\$recovery_file_dest;\nEXIT\n" | sys > "$work/fra.out"
mb=$(tr -dc '0-9' < "$work/fra.out")
printf 'ALTER SYSTEM SET db_recovery_file_dest_size = %sM;\nEXIT\n' "$mb" | sys > /dev/null
echo "fra      shrunk to ${mb} MB: some 90% of it holds what cannot be freed"
printf 'BEGIN FOR i IN 1 .. 6 LOOP EXECUTE IMMEDIATE '"'"'ALTER SYSTEM ARCHIVE LOG CURRENT'"'"'; END LOOP; END;\n/\nEXIT\n' | sys > /dev/null
echo 'redo     6 log switches'

# The rest within the alert log's 5 minutes: the tablespace filled until
# an insert fails; a deadlock.
printf 'BEGIN FOR i IN 1 .. 100000 LOOP INSERT INTO filler VALUES (%s); COMMIT; END LOOP; END;\n/\nEXIT\n' "'x'" | app > "$work/fill.log" 2>&1
grep -m 1 -o 'ORA-01653[^.]*' "$work/fill.log" | sed 's/^/fill     /'
printf 'BEGIN UPDATE t SET v = 3 WHERE id = 2; DBMS_SESSION.SLEEP(4); UPDATE t SET v = 3 WHERE id = 3; ROLLBACK; END;\n/\nEXIT\n' | app > "$work/dead1.log" 2>&1 &
printf 'BEGIN UPDATE t SET v = 4 WHERE id = 3; DBMS_SESSION.SLEEP(4); UPDATE t SET v = 4 WHERE id = 2; ROLLBACK; END;\n/\nEXIT\n' | app > "$work/dead2.log" 2>&1 &
wait
cat "$work/dead1.log" "$work/dead2.log" | grep -m 1 -o 'ORA-00060[^.]*' | sed 's/^/deadlock /'
# One session holds row 1, its transaction open and idle; another waits.
# They last until the run deletes $work/blocking, held or not.
: > "$work/blocking"
{ echo 'UPDATE t SET v = 1 WHERE id = 1;'; while [ -e "$work/blocking" ]; do sleep 2; done; echo 'ROLLBACK;'; echo EXIT; } | app > /dev/null 2>&1 &
bg="$bg $!"
sleep 3
{ echo 'UPDATE t SET v = 2 WHERE id = 1;'; echo 'ROLLBACK;'; echo EXIT; } | app > /dev/null 2>&1 &
bg="$bg $!"
echo 'blocking one session holds row 1, its transaction open and idle; another waits for it'
sleep 20

pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+( .*)?$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
within() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" -v b="$5" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a && v + 0 <= b) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2( |$).*$3" "$work/$1.out" && echo yes || echo no; }
said() { grep -q -- "$2" "$work/$1.out" && echo yes || echo no; }
run() {
    printf '\n$ bash packs/oracle/linux/%s.sh%s\n' "$1" "${2:+   ($2)}"
    bash "$pack/$1.sh" > "$work/$1.out" 2> "$work/$1.err"
    printf 'exit %s\n' "$?" >> "$work/$1.err"
    cat "$work/$1.out"
    grep -v '^exit 0$' "$work/$1.err"
}
quiet() { bash "$pack/$1.sh" > "$work/$1.out" 2> "$work/$1.err"; }
jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/oracle/pack.config")
export ORACLE_SQLPLUS=$prog ORACLE_HOST=127.0.0.1 ORACLE_PORT=$port ORACLE_SERVICE=$service ORACLE_USER='C##VIGIL_MONITOR'
export ORACLE_PASSWORD; ORACLE_PASSWORD=$(cat "$work/monitor.pw")

say "Oracle $release: every job, as the pack's scripts print it, as C##VIGIL_MONITOR."
for j in $jobs; do run "$j"; done
say "Oracle $release: what they read."
for j in $jobs; do check "$j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
check 'up, the release, a CDB, the primary' '1 yes' "$(val status up '') $(has status info "release=$release .*cdb=yes role=primary")"
check 'open read-write, in ARCHIVELOG mode, the PDB open' '1 1 1' "$(val status open 'mode=read_write') $(val status archivelog '') $(val status pdb_open "pdb=$pdb")"
check 'sessions and processes, against their limits' 'yes yes' "$(has status sessions_pct '') $(has status processes_pct '')"
check 'the counters: executions, the deadlock, DB time' 'yes yes yes' "$(least performance executions_count '' 1) $(least performance deadlocks_count '' 1) $(least performance db_time_ms_count '' 1)"
check 'one session blocked, one at the head of the chain' '1 1' "$(val activity blocked '') $(val activity head_blockers '')"
check 'the blocked one waits on a row lock: class application' yes "$(least activity active 'class=application' 1)"
check 'the transaction left open, idle, and how long' '1 yes' "$(val activity idle_in_transaction '') $(least activity idle_in_transaction_seconds '' 15)"
check 'the oldest transaction, at least as old' yes "$(least activity oldest_transaction_seconds '' 15)"
check 'waits by class; ten events, each with its count' 'yes 10 10' "$(has waits wait_ms_count 'class=user_i_o') $(grep -c '^metric top_wait_ms_count ' "$work/waits.out") $(grep -c '^metric top_waits_count ' "$work/waits.out")"
check 'VIGIL_SMALL filled: above 85% of what it can hold' yes "$(least tablespaces used_pct "pdb=$pdb tablespace=VIGIL_SMALL kind=permanent" 85)"
check 'and 10 MB at most, online' '10485760 1' "$(val tablespaces max_bytes 'tablespace=VIGIL_SMALL') $(val tablespaces online 'tablespace=VIGIL_SMALL')"
check 'the data files, against db_files' 'yes yes' "$(least tablespaces datafiles '' 1) $(least tablespaces datafiles_max '' 1)"
check 'the recovery area: its limit, some 90% full' 'yes yes' "$(least recovery fra_limit_bytes '' 1) $(within recovery fra_used_pct '' 80 100)"
check 'the log switches, the archiver without error' 'yes 0' "$(least recovery log_switches_1h '' 6) $(val recovery archive_dest_errors '')"
check 'the memory: SGA, PGA against its limit' 'yes yes' "$(least memory sga_bytes '' 1) $(has memory pga_limit_pct '')"
check 'the full backup and the archived logs, minutes old' 'yes yes' "$(within backups full_age_seconds '' 0 3600) $(within backups archivelog_age_seconds '' 0 3600)"
check 'the failed backup counted; the last one, its size' 'yes yes' "$(least backups failed_24h '' 1) $(least backups last_bytes '' 1)"
check 'the invalid view, in the PDB' yes "$(least health invalid_objects "pdb=$pdb" 1)"
check 'the account whose password expires in 3 days' yes "$(least health accounts_expiring '' 1)"
check 'the Scheduler job that failed, by name' 'yes yes' "$(least health scheduler_failed_24h '' 1) $(least health job_failed_24h "pdb=$pdb job=VIGIL_APP.NIGHTLY_LOAD" 1)"
check 'no corrupt blocks, no file needing recovery' '0 0' "$(val health corrupt_blocks '') $(val health datafiles_need_recovery '')"
check 'the alert log: readable, the full tablespace and the deadlock' '1 yes yes' "$(val alerts readable '') $(least alerts error_count 'code=ORA-01653' 1) $(least alerts error_count 'code=ORA-00060' 1)"
check 'and the errors, counted' yes "$(least alerts errors '' 2)"

say "Logins, grants, the password's whereabouts, and Oracle Net's encryption."
ORACLE_PASSWORD=not-the-password bash "$pack/status.sh" > "$work/wrong.out" 2>&1
check 'a wrong password fails the run, and says so' '1 yes' "$? $(said wrong 'ORA-01017')"
sed 's/^/        /' "$work/wrong.out"
ORACLE_PASSWORD='' bash "$pack/status.sh" > "$work/nopw.out" 2>&1
check 'no password set: the run fails, saying where it comes from' '1 yes' "$? $(said nopw 'ORACLE_PASSWORD')"
ORACLE_PORT=11599 bash "$pack/status.sh" > "$work/down.out" 2>&1
check 'nothing listening: the run succeeds, up 0, no_listener' '0 yes' "$? $(grep -qx 'metric up 0 reason=no_listener' "$work/down.out" && echo yes || echo no)"
ORACLE_PORT=11599 bash "$pack/waits.sh" > "$work/down2.out" 2>&1
check 'and another job succeeds, printing nothing' '0 0' "$? $(wc -l < "$work/down2.out" | tr -d ' ')"
ORACLE_SERVICE=NOT_THERE bash "$pack/status.sh" > "$work/nosvc.out" 2>&1
check 'a service the listener does not know: up 0, service_unknown' '0 yes' "$? $(grep -qx 'metric up 0 reason=service_unknown' "$work/nosvc.out" && echo yes || echo no)"
ORACLE_USER='C##VIGIL_NOALERT' ORACLE_PASSWORD=$(cat "$work/noalert.pw") bash "$pack/alerts.sh" > "$work/noalert.out" 2>&1
check "without the alert log's grant: readable 0, and only that, the run succeeding" '0 metric readable 0' "$? $(cat "$work/noalert.out")"
ORACLE_USER='C##VIGIL_NOALERT' ORACLE_PASSWORD=$(cat "$work/noalert.pw") bash "$pack/health.sh" > "$work/noalert2.out" 2>&1
check 'and its other jobs run as before' '0 yes' "$? $(grep -q '^metric invalid_objects ' "$work/noalert2.out" && echo yes || echo no)"
# While a job runs, no process's command line holds the password: every
# process's, read with ps again and again until sqlplus is seen among them
# (grep reads the password from a file, so its own command line holds none).
bash "$pack/tablespaces.sh" > /dev/null 2>&1 &
jp=$!
seen=0
looked=0
for _ in $(seq 1 100); do
    kill -0 "$jp" 2> /dev/null || break
    ps -eww -o args= > "$work/cmdlines" 2> /dev/null
    grep -qFf "$work/monitor.pw" "$work/cmdlines" && seen=1
    grep -q 'sqlplus -s -L /nolog' "$work/cmdlines" && looked=1
    sleep 0.05
done
wait "$jp"
check "the password on no command line while the job ran (sqlplus's seen)" '0 1' "$seen $looked"
# The job's own Oracle Net settings, as its script writes them, and the
# session they make: encrypted, its integrity checked.
sed -n "/^cat > \"\$work\/sqlnet.ora\" << 'ORA'$/,/^ORA$/p" "$pack/status.sh" | sed '1d;$d' > "$work/sqlnet.ora"
{
    printf 'SET HEADING OFF FEEDBACK OFF\nCONNECT C##VIGIL_MONITOR/"%s"@//127.0.0.1:%s/%s\n' "$ORACLE_PASSWORD" "$port" "$service"
    printf 'SELECT network_service_banner FROM v$session_connect_info WHERE sid = SYS_CONTEXT('"'"'USERENV'"'"', '"'"'SID'"'"');\nEXIT\n'
} | TNS_ADMIN=$work LD_LIBRARY_PATH="$(dirname "$prog")" "$prog" -s -L /nolog > "$work/banner.out" 2>&1
grep -iE 'encryption|crypto' "$work/banner.out" | sed 's/^[[:space:]]*/net      /'
check "the job's session: encrypted with AES, its integrity checked" 'yes yes' \
    "$(grep -qiE 'AES(256|192|128) Encryption service adapter' "$work/banner.out" && echo yes || echo no) $(grep -qiE 'SHA(256|384|512) Crypto-checksumming service adapter' "$work/banner.out" && echo yes || echo no)"
# A server that refuses encryption refuses the job: its sqlnet.ora says so
# for a while. It is in the Oracle base home: from 21c, the Oracle home is
# read-only.
docker exec "$c" bash -c 'f=$("$ORACLE_HOME/bin/orabasehome" 2> /dev/null || echo "$ORACLE_HOME")/network/admin/sqlnet.ora; cp -p "$f" /tmp/sqlnet.ora.vigil 2> /dev/null || : > /tmp/sqlnet.ora.vigil; echo "SQLNET.ENCRYPTION_SERVER = REJECTED" >> "$f"'
bash "$pack/status.sh" > "$work/rejected.out" 2>&1
check 'a server that rejects encryption: the run fails, saying so' '1 yes' "$? $(grep -qE 'ORA-12660|ORA-12650' "$work/rejected.out" && echo yes || echo no)"
sed 's/^/        /' "$work/rejected.out"
docker exec "$c" bash -c 'f=$("$ORACLE_HOME/bin/orabasehome" 2> /dev/null || echo "$ORACLE_HOME")/network/admin/sqlnet.ora; if [ -s /tmp/sqlnet.ora.vigil ]; then cp -p /tmp/sqlnet.ora.vigil "$f"; else rm -f "$f"; fi; rm -f /tmp/sqlnet.ora.vigil'
quiet status
check 'and with it put back, up 1 again' 1 "$(val status up '')"

say "The pack through Vigil, against Oracle $release."
export VIGIL_IT_ORACLE_HOST=127.0.0.1 VIGIL_IT_ORACLE_PORT=$port VIGIL_IT_ORACLE_SERVICE=$service VIGIL_IT_ORACLE_SQLPLUS=$prog
export VIGIL_IT_ORACLE_PASSWORD; VIGIL_IT_ORACLE_PASSWORD=$(cat "$work/monitor.pw")
unset ORACLE_SQLPLUS ORACLE_HOST ORACLE_PORT ORACLE_SERVICE ORACLE_USER
ORACLE_PASSWORD=$VIGIL_IT_ORACLE_PASSWORD
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
export ORACLE_SQLPLUS=$prog ORACLE_HOST=127.0.0.1 ORACLE_PORT=$port ORACLE_SERVICE=$service ORACLE_USER='C##VIGIL_MONITOR'
# VIGIL_IT_ORACLE_HOLD=<file>: the database stays up, C##VIGIL_MONITOR's
# password in <file>.d/ (this account's alone), for the tests of other
# machines, until <file> is deleted.
if [ -n "${VIGIL_IT_ORACLE_HOLD-}" ]; then
    (umask 077 && mkdir -p "$VIGIL_IT_ORACLE_HOLD.d" && cp "$work/monitor.pw" "$work/noalert.pw" "$VIGIL_IT_ORACLE_HOLD.d/")
    : > "$VIGIL_IT_ORACLE_HOLD"
    printf 'hold     the database stays up on %s, service %s, until %s is deleted\n' "$port" "$service" "$VIGIL_IT_ORACLE_HOLD"
    while [ -e "$VIGIL_IT_ORACLE_HOLD" ]; do sleep 5; done
    rm -rf "$VIGIL_IT_ORACLE_HOLD.d"
fi
rm -f "$work/blocking"
# shellcheck disable=SC2086
kill $bg 2> /dev/null
bg=''

say "The PDB closed."
printf 'ALTER PLUGGABLE DATABASE %s CLOSE IMMEDIATE;\nEXIT\n' "$pdb" | sys > /dev/null
run status "$pdb closed"
check 'the PDB closed: pdb_open 0, mounted; the CDB still up' '0 1' "$(val status pdb_open "pdb=$pdb mode=mounted") $(val status up '')"
run health "$pdb closed"
check 'and health still runs, the closed PDB left out' 'exit 0 no' "$(tail -n 1 "$work/health.err") $(has health invalid_objects "pdb=$pdb")"
printf 'ALTER PLUGGABLE DATABASE %s OPEN;\nEXIT\n' "$pdb" | sys > /dev/null

say "Logins restricted."
printf 'ALTER SYSTEM ENABLE RESTRICTED SESSION;\nEXIT\n' | sys > /dev/null
run status 'restricted'
check 'logins restricted: up 0, restricted, the run succeeding' 'metric up 0 reason=restricted exit 0' "$(cat "$work/status.out") $(tail -n 1 "$work/status.err")"
printf 'ALTER SYSTEM DISABLE RESTRICTED SESSION;\nEXIT\n' | sys > /dev/null

say "Mounted, not open."
printf 'SHUTDOWN IMMEDIATE\nSTARTUP MOUNT\nEXIT\n' | sys > /dev/null
run status 'mounted'
check 'mounted: up 0, not_open' 'metric up 0 reason=not_open' "$(cat "$work/status.out")"

say "Shut down."
printf 'SHUTDOWN IMMEDIATE\nEXIT\n' | sys > /dev/null
run status 'shut down'
check 'shut down: up 0, the listener knowing no such service' 'metric up 0 reason=service_unknown' "$(cat "$work/status.out")"
run tablespaces 'shut down'
check 'and another job succeeds, printing nothing' 'exit 0 0' "$(tail -n 1 "$work/tablespaces.err") $(wc -l < "$work/tablespaces.out" | tr -d ' ')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
