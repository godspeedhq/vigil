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
# run-sqlite.sh - the sqlite pack, against databases in every state it reads,
# and two real applications' own, with its evidence kept like the other
# runs'.
#
#   scripts/run-sqlite.sh
#
# With sqlite3 alone, it makes in a folder of its own: a database in
# rollback mode and one in WAL; one with nine rows in ten deleted (free
# pages); one with 64 KB pages, one with auto-vacuum full and one
# incremental; a WAL held by an old reader while a writer goes on, beside
# one that is not; a rollback transaction held open (its journal); one
# locked for writing (EXCLUSIVE); a file of random bytes, an empty one, and
# a copy with a page overwritten. Every job is run and what it reads is
# checked. Then tests/integration/service-packs.sh runs the pack through
# Vigil.
#
# When Docker answers and VIGIL_IT_SQLITE_APPS=1, also two applications that
# keep their data in SQLite, in containers of this run's own (labelled
# vigil.it=sqlite), their data in this run's folder: Grafana (rollback
# mode, as it ships) and Gitea (set to WAL). They are read while they run,
# and checked. At the end only what this run made is removed: no other
# container or image is touched.
#
# On Linux and macOS.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

for p in sqlite3 od awk; do command -v "$p" > /dev/null 2>&1 || die "$p not found"; done
case $(uname -s) in Darwin) os=macos ;; *) os=linux ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-sqlite-it.XXXXXX") || exit 1
root=$work/none
d=$work/db
mkdir -p "$d"
apps=0
if [ "${VIGIL_IT_SQLITE_APPS-}" = 1 ]; then
    command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1 || die 'VIGIL_IT_SQLITE_APPS=1, and Docker does not answer here'
    apps=1
fi
grafana_img=${VIGIL_IT_SQLITE_GRAFANA_IMAGE:-docker.io/grafana/grafana:12.2.1}
gitea_img=${VIGIL_IT_SQLITE_GITEA_IMAGE:-docker.io/gitea/gitea:1.24-rootless}

# The processes holding a database: each sqlite3 reads its statements from
# a pipe this script holds open, and ends when the pipe is closed.
holders=''
hold() {
    local db=$1 fifo=$work/hold.$2
    mkfifo "$fifo"
    sqlite3 "$db" < "$fifo" > /dev/null 2>&1 &
    holders="$holders $!"
    eval "exec $3> \"\$fifo\""
    printf '%s\n' "$4" >&"$3"
}
release() {
    local fd
    for fd in 7 8 9; do eval "exec $fd>&-" 2> /dev/null; done
    # shellcheck disable=SC2086
    [ -z "$holders" ] || wait $holders 2> /dev/null
    holders=''
}
clean() {
    release
    if [ "$apps" = 1 ]; then
        local ids
        ids=$(docker ps -aq --filter label=vigil.it=sqlite 2> /dev/null)
        # shellcheck disable=SC2086
        [ -z "$ids" ] || docker rm -f $ids > /dev/null 2>&1
    fi
}
trap 'clean; evidence_save; chmod -R u+rwX "$work" 2> /dev/null; rm -rf "$work"' EXIT
evidence_start pack-sqlite '' "$0" "$@"
printf 'here     %s, bash %s, sqlite3 %s, as %s\n' "$os" "$BASH_VERSION" "$(sqlite3 --version | awk '{ print $1 }')" "$(id -un)"
[ "$apps" = 1 ] && printf 'apps     Docker %s: %s, %s\n' "$(docker version --format '{{.Server.Version}}')" "$grafana_img" "$gitea_img"

say() { printf '\n# %s\n' "$*"; }
pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
# val <job> <reading> [<db file name>] [<more tags>]: its value; has says
# whether such a line was printed.
pat() { printf '^metric %s [^ ]+' "$1"; [ -n "${2-}" ] && printf ' db=[^ ]*/%s' "$2"; [ -n "${3-}" ] && printf '( .*)? %s' "$3"; printf '( |$)'; }
val() { grep -E "$(pat "$2" "${3-}" "${4-}")" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
has() { grep -qE "$(pat "$2" "${3-}" "${4-}")" "$work/$1.out" && echo yes || echo no; }
least() { awk -v v="$(val "$1" "$2" "${3-}")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
# run <job> [<label>]: the job's script, its output shown (the run's folder
# taken out of the paths) and kept.
run() {
    printf '\n$ bash packs/sqlite/%s/%s.sh%s\n' "$os" "$1" "${2:+   ($2)}"
    bash "$bk_repo/packs/sqlite/$os/$1.sh" > "$work/$1.out" 2> "$work/$1.err"
    printf 'exit %s\n' "$?" >> "$work/$1.err"
    sed "s#$work/#.../#g" "$work/$1.out"
    grep -v '^exit 0$' "$work/$1.err" | sed "s#$work/#.../#g"
}
q() { sqlite3 "$@" > /dev/null || die "sqlite3 failed: $*"; }
rows() { printf "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < %d) INSERT INTO t (v) SELECT randomblob(%d) FROM c;" "$1" "$2"; }

say "Databases in every state the pack reads, made with sqlite3."
q "$d/plain.db" 'CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB);' "$(rows 200 500)"
q "$d/frag.db" 'CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB);' "$(rows 20000 500)" 'DELETE FROM t WHERE id % 10 != 0;'
q "$d/wal.db" 'PRAGMA journal_mode = WAL;' 'CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB);' "$(rows 100 500)"
q "$d/big-pages.db" 'PRAGMA page_size = 65536;' 'CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB);' "$(rows 100 500)"
q "$d/autovac.db" 'PRAGMA auto_vacuum = FULL;' 'CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB);' "$(rows 100 500)"
q "$d/incremental.db" 'PRAGMA auto_vacuum = INCREMENTAL;' 'CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB);' "$(rows 100 500)"
q "$d/held.db" 'CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB);' "$(rows 200 500)"
q "$d/locked.db" 'CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB);' "$(rows 200 500)"
for w in grow calm; do q "$d/$w.db" 'PRAGMA journal_mode = WAL;' 'CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB);' "$(rows 10 100)"; done
head -c 8192 /dev/urandom > "$d/notdb.db"
: > "$d/empty.db"
cp "$d/frag.db" "$d/damaged.db"
# The table's root page overwritten: every read of the table starts there
# (a free page would not do: no check reads what a free page holds).
ps=$(sqlite3 "$d/damaged.db" 'PRAGMA page_size;')
rp=$(sqlite3 "$d/damaged.db" "SELECT rootpage FROM sqlite_schema WHERE name = 't';")
head -c "$ps" /dev/zero | tr '\0' 'Z' | dd of="$d/damaged.db" bs="$ps" seek=$((rp - 1)) conv=notrunc 2> /dev/null

# An old reader holds grow.db's WAL: no checkpoint can finish while a
# writer goes on. calm.db has the same writes and no reader.
hold "$d/grow.db" reader 7 'BEGIN; SELECT count(*) FROM t;'
sleep 1
for w in grow calm; do
    for _ in $(seq 1 40); do q "$d/$w.db" "$(rows 500 1000)"; done
done
# A rollback transaction left open: its journal stays.
hold "$d/held.db" writer 8 "BEGIN IMMEDIATE; UPDATE t SET v = randomblob(600) WHERE id < 100;"
# A database locked for writing: no reader gets in.
hold "$d/locked.db" exclusive 9 'BEGIN EXCLUSIVE;'
sleep 2
ls -l "$d" | awk 'NR > 1 { printf "  %10s  %s\n", $5, $NF }'

if [ "$apps" = 1 ]; then
    say "Two applications keeping their data in SQLite: Grafana (rollback mode) and Gitea (WAL)."
    mkdir -p "$work/grafana" "$work/gitea/data" "$work/gitea/config"
    z=''
    [ "$os" = linux ] && z=':Z'
    docker run -d --label vigil.it=sqlite --name vigilit_sqlite_grafana --user "$(id -u):$(id -g)" \
        -v "$work/grafana:/var/lib/grafana$z" "$grafana_img" > /dev/null || die "cannot start $grafana_img"
    docker run -d --label vigil.it=sqlite --name vigilit_sqlite_gitea --user "$(id -u):$(id -g)" \
        -e GITEA__security__INSTALL_LOCK=true -e GITEA__database__DB_TYPE=sqlite3 \
        -e GITEA__database__PATH=/var/lib/gitea/data/gitea.db -e GITEA__database__SQLITE_JOURNAL_MODE=WAL \
        -v "$work/gitea/data:/var/lib/gitea$z" -v "$work/gitea/config:/etc/gitea$z" "$gitea_img" > /dev/null || die "cannot start $gitea_img"
    for _ in $(seq 1 60); do
        [ -s "$work/grafana/grafana.db" ] && [ -s "$work/gitea/data/data/gitea.db" ] && break
        sleep 2
    done
    # Their migrations done: the tables are there.
    sleep 10
    docker ps --filter label=vigil.it=sqlite --format '  {{.Names}}: {{.Image}}, {{.Status}}'
    app_files="; $work/grafana/grafana.db; $work/gitea/data/data/gitea.db"
fi

all="$d/plain.db; $d/frag.db; $d/wal.db; $d/big-pages.db; $d/autovac.db; $d/incremental.db; $d/grow.db; $d/calm.db; $d/held.db; $d/locked.db; $d/notdb.db; $d/empty.db; $d/damaged.db; $d/nope.db${app_files-}"
export SQLITE_FILES=$all

say "Every job, as the $os scripts print it."
run status
check 'status: runs' 'exit 0' "$(tail -n 1 "$work/status.err")"
run check 'SQLITE_CHECK not set: off'
check 'check: off until asked: checked 0, and nothing else' 'exit 0|1' "$(tail -n 1 "$work/check.err")|$(grep -c . "$work/check.out")"
check 'check: off reads nothing' 0 "$(val check checked)"
SQLITE_CHECK=quick run check 'SQLITE_CHECK=quick'
check 'check: runs' 'exit 0' "$(tail -n 1 "$work/check.err")"

say "What each job must have read."
n=$(printf '%s' "$all" | tr ';' '\n' | grep -c .)
check "status: every database named is counted, and the one not there" "$n 1 0" "$(val status databases) $(val status missing) $(val status found nope.db)"
check 'status: the database files are valid; random bytes are not; an empty file is' '1 1 0 1' "$(val status valid plain.db) $(val status valid wal.db) $(val status valid notdb.db) $(val status valid empty.db)"
check 'status: the journal mode, as written in each header' 'yes yes' "$(has status info plain.db mode=rollback) $(has status info wal.db mode=wal)"
check 'status: the SQLite that last wrote it' yes "$(has status info plain.db "version=$(sqlite3 --version | awk '{ print $1 }')")"
check 'status: auto-vacuum: none, full and incremental' 'yes yes yes' "$(has status info plain.db vacuum=none) $(has status info autovac.db vacuum=full) $(has status info incremental.db vacuum=incremental)"
check 'status: the page size, 64 KB too (written as 1 in the header)' '4096 65536' "$(val status page_size plain.db) $(val status page_size big-pages.db)"
for f in plain frag big-pages; do
    check "status: $f.db: pages and free pages, as sqlite3 counts them" "$(sqlite3 "$d/$f.db" 'PRAGMA page_count;') $(sqlite3 "$d/$f.db" 'PRAGMA freelist_count;')" "$(val status pages "$f.db") $(val status free_pages "$f.db")"
done
check 'status: nine rows in ten deleted: most pages free, and the space they hold' 'yes yes' "$(least status free_pct frag.db 80) $(awk -v b="$(val status free_bytes frag.db)" -v p="$(val status free_pages frag.db)" 'BEGIN { print (b == p * 4096) ? "yes" : "no" }')"
check 'status: the size, as the file is' "$(wc -c < "$d/frag.db" | tr -d ' ')" "$(val status size_bytes frag.db)"
# Without a reader, each writer's last close checkpoints the WAL into the
# database and deletes it: calm.db holds the rows, grow.db's WAL does.
check 'status: the WAL held by an old reader has grown; the same writes without one went into the database' 'yes 0 yes' \
    "$(least status wal_bytes grow.db 15000000) $(val status wal_bytes calm.db) $(least status size_bytes calm.db 15000000)"
check 'status: a database closed cleanly has no WAL' 0 "$(val status wal_bytes wal.db)"
check 'status: the transaction held open: its journal, and how long since it was written' 'yes yes' "$(least status journal_bytes held.db 1) $(has status journal_seconds held.db)"
check 'status: no journal where no transaction is open' '0 no' "$(val status journal_bytes plain.db) $(has status journal_seconds plain.db)"
check 'status: last written: seconds ago, for each' 'yes yes' "$(has status last_write_seconds plain.db) $(least status last_write_seconds frag.db 0)"
check 'check: every database there is checked, but those locked' "$((n - 2))" "$(val check checked)"
check 'check: a sound database is ok; its check timed' '1 0 yes' "$(val check ok frag.db) $(val check problems frag.db) $(has check check_seconds frag.db)"
check 'check: the page overwritten is found' 'yes 0' "$(least check problems damaged.db 1) $(val check ok damaged.db)"
check 'check: at most 100 problems counted, and not the heading sqlite3 puts above them' yes "$(awk -v n="$(val check problems damaged.db)" 'BEGIN { print (n <= 100) ? "yes" : "no [" n "]" }')"
check 'check: random bytes: not a database' 0 "$(val check ok notdb.db)"
check 'check: a WAL held by a reader is checked, read-only' 1 "$(val check ok grow.db)"
check 'check: in rollback mode, a transaction still open does not stop the check' 1 "$(val check ok held.db)"
check 'check: the database locked for writing could not be checked: busy, after 30 seconds' 1 "$(val check busy locked.db)"
check 'check: the damaged ones are counted' 2 "$(val check not_ok)"
if [ "$apps" = 1 ]; then
    check 'grafana.db: found, valid, rollback mode' 'yes 1' "$(has status info grafana.db mode=rollback) $(val status valid grafana.db)"
    check 'gitea.db: found, valid, WAL mode, its WAL there while it runs' 'yes 1 yes' "$(has status info gitea.db mode=wal) $(val status valid gitea.db) $(least status wal_bytes gitea.db 1)"
    check 'grafana.db and gitea.db: checked while they run, and sound' '1 1' "$(val check ok grafana.db) $(val check ok gitea.db)"
fi

say "Released: the reader, the writer and the lock end, and the WAL and the journal go."
release
sleep 1
run status 'released' | grep -E '^\$|(wal_bytes|journal_bytes|journal_seconds) .*(grow|held)\.db'
check 'released: the journal is gone' '0 no' "$(val status journal_bytes held.db) $(has status journal_seconds held.db)"
check 'released: the WAL is deleted as its last connection closes' 0 "$(val status wal_bytes grow.db)"

say "A database this account may not read: the others are read, and the run fails, naming it."
if [ "$(id -u)" -eq 0 ]; then
    printf '  (root reads every file: not tried)\n'
else
    cp "$d/plain.db" "$d/secret.db"
    chmod 000 "$d/secret.db"
    SQLITE_FILES="$d/plain.db; $d/secret.db" bash "$bk_repo/packs/sqlite/$os/status.sh" > "$work/denied.out" 2>&1
    rc=$?
    sed "s#$work/#.../#g" "$work/denied.out" | grep -E 'found|cannot'
    check 'unreadable: exit 1, the others read, and the file named' '1 1 yes' "$rc $(grep -E '^metric found 1 db=.*plain.db' "$work/denied.out" | awk '{ print $3 }') $(grep -q 'cannot read .*secret.db' "$work/denied.out" && echo yes || echo no)"
    chmod 600 "$d/secret.db"
fi
SQLITE_FILES="$d" bash "$bk_repo/packs/sqlite/$os/status.sh" > "$work/folder.out" 2>&1
check 'a folder named: exit 1, said' '1 yes' "$? $(grep -q 'names a folder' "$work/folder.out" && echo yes || echo no)"
SQLITE_FILES='' bash "$bk_repo/packs/sqlite/$os/status.sh" > "$work/none.out" 2>&1
check 'SQLITE_FILES not set: databases 0, and the run succeeds' '0 metric databases 0' "$? $(head -n 1 "$work/none.out")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
direct=$fail

say "The pack through Vigil."
export VIGIL_IT_SQLITE="$d/plain.db; $d/frag.db; $d/damaged.db; $d/nope.db"
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?

if [ "$apps" = 1 ]; then
    say "Only what this run made is removed."
    others_before=$(docker ps -aq | wc -l | tr -d ' ')
    clean
    check "this run's two containers are gone, and no other was touched" "0 $((others_before - 2))" "$(docker ps -aq --filter label=vigil.it=sqlite | wc -l | tr -d ' ') $(docker ps -aq | wc -l | tr -d ' ')"
fi
[ "$direct" -eq 0 ] && [ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
