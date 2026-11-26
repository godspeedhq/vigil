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
# run-mongodb.sh - the mongodb pack against a real replica set in trouble on
# purpose, and an older single server, with its evidence kept like the
# other runs'.
#
#   MONGOSH=<path to mongosh> scripts/run-mongodb.sh
#
# It starts compose.mongodb.yaml: a 9.0 replica set of three, with
# authentication, and an 8.0 server. As root, on each: the user the pack
# asks for (vigil, clusterMonitor), and on the set one with no such role.
# In the set: 10,000 documents; a query that runs for minutes; a
# transaction held open; a secondary stopped from fetching (a fail point)
# while the primary takes writes. On 8.0: writes held behind fsyncLock.
# Every job is run against the primary, a secondary and 8.0, and what it
# reads is checked; then a wrong password, the user without the role,
# nothing listening, and that the password is on no process's command
# line. Then tests/integration/service-packs.sh runs the pack through
# Vigil. Then the set falls apart: a member stops; the primary stops (an
# election); two stop, and none is primary. The passwords and the keyfile
# are made here, into this run's own folder, and kept out of the evidence.
# VIGIL_IT_MONGO_HOLD (below) keeps it up for other machines' tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: MongoDB runs in containers'
prog=${MONGOSH:-mongosh}
command -v "$prog" > /dev/null 2>&1 || die "$prog not found: set MONGOSH to mongosh"
command -v openssl > /dev/null 2>&1 || die 'openssl not found'
file=compose.mongodb.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-mongo-it.XXXXXX") || exit 1
root=$work/none
dc() { docker compose -p vigil-mongo --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
(umask 077 && openssl rand -hex 16 > "$work/root.pw" && openssl rand -hex 16 > "$work/vigil.pw" && openssl rand -hex 16 > "$work/norole.pw")
openssl rand -base64 64 | tr -d '\n' > "$work/key" && chmod 444 "$work/key"
export MONGO_KEYFILE=$work/key MONGO_ROOT_PASSWORD; MONGO_ROOT_PASSWORD=$(cat "$work/root.pw")
bg=''
trap '[ -z "$bg" ] || kill $bg 2> /dev/null; dc down -v > /dev/null 2>&1; evidence_save "$(cat "$work/root.pw")" "$(cat "$work/vigil.pw")" "$(cat "$work/norole.pw")"; rm -rf "$work"' EXIT
evidence_start pack-mongodb "$bk_dir/$file" "$0" "$@"
printf 'mongosh  %s, %s\n' "$("$prog" --version)" "$prog"
pack=$bk_repo/packs/mongodb/linux

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'MongoDB would not start'; }
# adm <container> <js>: as root, inside the container, the root password
# from the environment. The JS has "a", the admin database, logged in.
adm() {
    {
        printf '%s\n' "let a; for (let i = 0; i < 90; i++) { try { a = new Mongo('mongodb://127.0.0.1:27017/?directConnection=true').getDB('admin'); a.auth('root', process.env.MONGO_ROOT_PASSWORD); a.runCommand({ ping: 1 }); break; } catch (e) { a = undefined; sleep(2000); } }"
        printf '%s\n' "if (!a) { print('no connection'); quit(1); }"
        printf '%s\n' "$2"
    } > "$work/adm.$BASHPID.js"
    docker cp "$work/adm.$BASHPID.js" "vigil-mongo-$1-1:/tmp/adm-$BASHPID.js" > /dev/null
    docker exec -e MONGO_ROOT_PASSWORD -e VIGIL_PW -e NOROLE_PW "vigil-mongo-$1-1" mongosh --nodb --quiet --norc --file "/tmp/adm-$BASHPID.js"
}
export VIGIL_PW NOROLE_PW; VIGIL_PW=$(cat "$work/vigil.pw") NOROLE_PW=$(cat "$work/norole.pw")
# The image makes its root user with a mongod of its own first (no replica
# set), then starts the real one: wait for that, on each, before anything.
for c in m1 m2 m3 m80; do
    for _ in $(seq 1 90); do docker logs "vigil-mongo-$c-1" 2>&1 | grep -q 'MongoDB init process complete; ready for start up' && break; sleep 2; done
    docker logs "vigil-mongo-$c-1" 2>&1 | grep -q 'MongoDB init process complete; ready for start up' || die "$c did not finish starting"
done
# Chaining off: each secondary fetches from the primary, so stopping m3's
# fetching holds back m3 alone (with chaining, m2 may fetch from m3, and
# wait with it).
adm m1 "a.runCommand({ replSetInitiate: { _id: 'rs0', settings: { chainingAllowed: false }, members: [{ _id: 0, host: 'm1:27017', priority: 2 }, { _id: 1, host: 'm2:27017' }, { _id: 2, host: 'm3:27017' }] } });
for (let i = 0; i < 90 && !a.runCommand({ hello: 1 }).isWritablePrimary; i++) sleep(1000);
// A transaction may stay open an hour, not 60 seconds, for the run to see it.
a.runCommand({ setParameter: 1, transactionLifetimeLimitSeconds: 3600 });
a.createUser({ user: 'vigil', pwd: process.env.VIGIL_PW, roles: ['clusterMonitor'] });
a.createUser({ user: 'norole', pwd: process.env.NOROLE_PW, roles: [{ role: 'read', db: 'app' }] });
const app = a.getSiblingDB('app');
for (let i = 0; i < 5; i++) app.events.insertMany(Array.from({ length: 2000 }, (_, j) => ({ i, j, v: 'x'.repeat(200) })));
app.events.createIndex({ i: 1 });
app.slow.insertMany(Array.from({ length: 300 }, (_, j) => ({ j })));
print('replica set rs0: m1 primary, m2, m3; users vigil (clusterMonitor) and norole (read on app); app.events 10,000 documents')" || die 'cannot set up the replica set'
adm m80 "a.createUser({ user: 'vigil', pwd: process.env.VIGIL_PW, roles: ['clusterMonitor'] });
a.getSiblingDB('app').events.insertMany(Array.from({ length: 1000 }, (_, j) => ({ j })));
print('8.0: user vigil (clusterMonitor); app.events 1,000 documents')" || die 'cannot set up 8.0'
for _ in $(seq 1 30); do [ "$(adm m1 "print(a.runCommand({ replSetGetStatus: 1 }).members.filter(x => x.stateStr === 'SECONDARY').length)" 2> /dev/null)" = 2 ] && break; sleep 2; done
printf 'mongodb  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say() { printf '\n# %s\n' "$*"; }
pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+( .*)?$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2( |$).*$3" "$work/$1.out" && echo yes || echo no; }
said() { grep -q -- "$2" "$work/$1.out" && echo yes || echo no; }
run() {
    printf '\n$ bash packs/mongodb/linux/%s.sh%s\n' "$1" "${2:+   ($2)}"
    bash "$pack/$1.sh" > "$work/$1.out" 2> "$work/$1.err"
    printf 'exit %s\n' "$?" >> "$work/$1.err"
    cat "$work/$1.out"
    grep -v '^exit 0$' "$work/$1.err"
}
quiet() { bash "$pack/$1.sh" > "$work/$1.out" 2> /dev/null; }
jobs='status replication databases operations'
use() { export MONGODB_URL=mongodb://127.0.0.1:$1 MONGODB_USER=vigil MONGODB_PASSWORD MONGOSH=$prog; MONGODB_PASSWORD=$(cat "$work/vigil.pw"); }

say "The replica set in trouble on purpose, as root."
# A query that runs for minutes: a second a document, on 300 of them.
adm m1 "a.getSiblingDB('app').slow.find({ \$where: 'sleep(1000); return true' }).toArray()" > /dev/null 2>&1 &
bg="$bg $!"
started=$(date +%s)
echo 'query    app.slow: $where sleep(1000), on 300 documents'
# A transaction held open for minutes.
adm m1 "const s = a.getMongo().startSession(); s.startTransaction(); s.getDatabase('app').held.insertOne({ held: 1 }); sleep(1800000); s.abortTransaction()" > /dev/null 2>&1 &
bg="$bg $!"
echo 'transaction  one held open: an insert into app.held, not committed'
# m3 stops fetching from the others, while the primary takes writes.
adm m3 "a.runCommand({ configureFailPoint: 'stopReplProducer', mode: 'alwaysOn' })" > /dev/null
echo 'm3       its fail point stopReplProducer on: it fetches nothing'
for i in $(seq 1 25); do adm m1 "a.getSiblingDB('app').ticks.insertOne({ i: $i, t: new Date() })" > /dev/null; sleep 1; done
echo 'writes   25 inserts into app.ticks, one a second'
w=$((started + 65 - $(date +%s)))
[ "$w" -le 0 ] || { printf '(waiting %s s: the query has run for over 60 s)\n' "$w"; sleep "$w"; }

say "9.0, m1, the primary: every job, as the pack's scripts print it, as vigil."
use 27117
for j in $jobs; do run "$j"; done
say "9.0, m1: what they read."
for j in $jobs; do check "m1: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
check 'm1: up, its version, WiredTiger' '1 yes' "$(val status up '') $(has status info 'version=9\.0\.[0-9]+ engine=wiredTiger')"
check 'm1: connections, and their share' 'yes yes' "$(least status connections '' 3) $(has status connections_pct '')"
check 'm1: operations by kind; inserts counted' 'yes 6' "$(least status operations_count 'op=insert' 25) $(grep -c '^metric operations_count ' "$work/status.out")"
check 'm1: the cache: its limit, 256 MB, and how full' '268435456 yes' "$(val status cache_max_bytes '') $(has status cache_pct '')"
check 'm1: the transaction held open' 1 "$(val status transactions_open '')"
check 'm1: the replica set, from the primary' 'yes 1 3 3 1' "$(has replication info 'set=rs0 role=primary') $(val replication replicated '') $(val replication members '') $(val replication members_healthy '') $(val replication primary '')"
check 'm1: m3 behind, its fetching stopped' yes "$(least replication member_lag_seconds 'member=m3:27017' 10)"
check 'm1: and the furthest behind, m3' "$(val replication member_lag_seconds 'member=m3:27017')" "$(val replication lag_seconds_max '')"
# m2 is not stopped, and fetches from the primary: well ahead of m3. (At
# rest a secondary reads up to some 10 s behind: the primary writes a no-op
# every 10 s, and the secondaries report it a moment later.)
check 'm1: m2 well ahead of m3' yes "$(awk -v a="$(val replication member_lag_seconds 'member=m2:27017')" -v b="$(val replication member_lag_seconds 'member=m3:27017')" 'BEGIN { print (a + 20 < b) ? "yes" : "no [" a " and " b "]" }')"
check 'm1: the oplog: its size and its window' 'yes yes' "$(least replication oplog_max_bytes '' 1000000) $(has replication oplog_window_hours '')"
check 'm1: the databases, app the largest of ours' 'yes yes' "$(least databases databases '' 4) $(least databases db_documents 'db=app' 10000)"
check 'm1: the slow query, running' 'yes yes' "$(least operations slow '' 1) $(has operations op_seconds 'ns=app\.slow op=query')"
check 'm1: and the longest, past a minute' yes "$(least operations longest_seconds '' 60)"
check "m1: the job's own currentOp not counted" no "$(has operations op_seconds 'ns=admin\.\$cmd op=command')"

say "9.0, m2, a secondary: what it sees."
use 27118
run replication
check 'm2: a secondary of rs0, its own lag read' 'yes yes' "$(has replication info 'set=rs0 role=secondary') $(has replication lag_seconds '')"
check 'm2: m3 behind, seen from here too' yes "$(least replication member_lag_seconds 'member=m3:27017' 10)"
adm m3 "a.runCommand({ configureFailPoint: 'stopReplProducer', mode: 'off' })" > /dev/null
for _ in $(seq 1 30); do quiet replication; [ "$(awk -v v="$(val replication lag_seconds_max '')" 'BEGIN { print (v + 0 <= 12) }')" = 1 ] && break; sleep 2; done
check 'm3 fetching again: none further behind than the 10 s no-op' yes "$(awk -v v="$(val replication lag_seconds_max '')" 'BEGIN { print (v + 0 <= 12) ? "yes" : "no [" v "]" }')"

say "8.0, one server: every job; then writes held behind fsyncLock."
use 27180
for j in $jobs; do run "$j"; done
for j in $jobs; do check "8.0: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
check '8.0: up, its version' '1 yes' "$(val status up '') $(has status info 'version=8\.0\.')"
check '8.0: not a replica set, and that is a reading' 'yes 0' "$(has replication info 'set=none role=standalone') $(val replication replicated '')"
adm m80 "a.runCommand({ fsync: 1, lock: true })" > /dev/null
adm m80 "a.getSiblingDB('app').events.insertOne({ waits: 1 })" > /dev/null 2>&1 &
bg="$bg $!"
for _ in $(seq 1 20); do quiet operations; [ "$(least operations waiting_for_lock '' 1)" = yes ] && break; sleep 1; done
run operations 'fsyncLock, an insert waiting'
check '8.0: the insert waiting behind the lock' yes "$(least operations waiting_for_lock '' 1)"
adm m80 "a.runCommand({ fsyncUnlock: 1 })" > /dev/null

say "Logins, roles, and the password's whereabouts, on m1."
use 27117
MONGODB_PASSWORD=not-the-password bash "$pack/status.sh" > "$work/wrong.out" 2>&1
check 'a wrong password fails the run, and says so' '1 yes' "$? $(said wrong 'MongoDB refused the login')"
sed 's/^/        /' "$work/wrong.out"
MONGODB_USER=norole MONGODB_PASSWORD=$(cat "$work/norole.pw") bash "$pack/status.sh" > "$work/norole.out" 2>&1
check 'a user without clusterMonitor fails the run, naming the role' '1 yes' "$? $(said norole 'grant it the clusterMonitor role')"
sed 's/^/        /' "$work/norole.out"
MONGODB_PASSWORD='' bash "$pack/status.sh" > "$work/nopw.out" 2>&1
check 'no password set: the run fails, saying how to set it' '1 yes' "$? $(said nopw 'vigil secret set MONGODB_PASSWORD')"
MONGODB_URL=mongodb://127.0.0.1:27199 bash "$pack/status.sh" > "$work/down.out" 2>&1
check 'nothing listening: the run succeeds, up 0' '0 yes' "$? $(grep -q '^metric up 0$' "$work/down.out" && echo yes || echo no)"
MONGODB_URL="mongodb://vigil:x@127.0.0.1:27117" bash "$pack/status.sh" > "$work/inurl.out" 2>&1
check 'a password in MONGODB_URL is refused' '1 yes' "$? $(said inurl 'MONGODB_URL holds a password')"
# While the job runs, no process's command line holds the password: every
# process's, read with ps again and again until mongosh is seen among them
# (grep reads the password from a file, so its own command line holds none).
bash "$pack/operations.sh" > /dev/null 2>&1 &
jp=$!
seen=0
for _ in $(seq 1 30); do
    kill -0 "$jp" 2> /dev/null || break
    ps -eww -o args= > "$work/cmdlines" 2> /dev/null
    grep -qFf "$work/vigil.pw" "$work/cmdlines" && seen=1
    grep -q '_operations.js' "$work/cmdlines" && looked=1
    sleep 0.1
done
wait "$jp"
check "the password on no command line while the job ran (mongosh's seen)" '0 1' "$seen ${looked:-0}"

say "The pack through Vigil, against m1."
export VIGIL_IT_MONGODB_URL=mongodb://127.0.0.1:27117 VIGIL_IT_MONGODB_USER=vigil VIGIL_IT_MONGOSH=$prog
export VIGIL_IT_MONGODB_PASSWORD; VIGIL_IT_MONGODB_PASSWORD=$(cat "$work/vigil.pw")
unset MONGODB_URL MONGODB_USER MONGODB_PASSWORD MONGOSH
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
# VIGIL_IT_MONGO_HOLD=<file>: the servers stay up, vigil's password in
# <file>.d/ (this account's alone), for the tests of other machines, until
# <file> is deleted.
if [ -n "${VIGIL_IT_MONGO_HOLD-}" ]; then
    (umask 077 && mkdir -p "$VIGIL_IT_MONGO_HOLD.d" && cp "$work/vigil.pw" "$VIGIL_IT_MONGO_HOLD.d/")
    : > "$VIGIL_IT_MONGO_HOLD"
    printf 'hold     the servers stay up, on 27117-27119 and 27180, until %s is deleted\n' "$VIGIL_IT_MONGO_HOLD"
    while [ -e "$VIGIL_IT_MONGO_HOLD" ]; do sleep 5; done
    rm -rf "$VIGIL_IT_MONGO_HOLD.d"
fi
# shellcheck disable=SC2086
kill $bg 2> /dev/null
bg=''

use 27117
say "A member stops: m3."
dc stop m3 > /dev/null 2>&1
for _ in $(seq 1 30); do quiet replication; [ "$(val replication members_down '')" = 1 ] && break; sleep 2; done
run replication 'm3 stopped'
check 'm3 stopped: one member down, its health 0; still a primary' '1 0 1' "$(val replication members_down '') $(val replication member_health 'member=m3:27017') $(val replication primary '')"
dc start m3 > /dev/null 2>&1

say "The primary stops: m1. m2 and m3 elect another."
for _ in $(seq 1 30); do quiet replication; [ "$(val replication members_healthy '')" = 3 ] && break; sleep 2; done
dc stop m1 > /dev/null 2>&1
use 27118
for _ in $(seq 1 45); do quiet replication; [ "$(val replication primary '')" = 1 ] && [ "$(val replication members_down '')" = 1 ] && break; sleep 2; done
run replication 'm1 stopped'
check 'm1 stopped: a new primary, m2 or m3; m1 down' 'yes 1 1' "$(grep -qE '^metric member_health 1 member=m[23]:27017 state=primary$' "$work/replication.out" && echo yes || echo no) $(val replication primary '') $(val replication members_down '')"
dc start m1 > /dev/null 2>&1
for _ in $(seq 1 45); do quiet replication; [ "$(val replication members_healthy '')" = 3 ] && break; sleep 2; done

say "Two stop: m1 and m3. m2 is left, and cannot be primary alone."
dc stop m1 m3 > /dev/null 2>&1
for _ in $(seq 1 45); do quiet replication; [ "$(val replication primary '')" = 0 ] && [ "$(val replication members_down '')" = 2 ] && break; sleep 2; done
run replication 'm1 and m3 stopped'
check 'no primary: m2 secondary, two down, the run succeeds' 'exit 0 yes 0 2' "$(tail -n 1 "$work/replication.err") $(has replication info 'set=rs0 role=secondary') $(val replication primary '') $(val replication members_down '')"
run status 'no primary'
check 'no primary: m2 itself still up' '1 exit 0' "$(val status up '') $(tail -n 1 "$work/status.err")"
dc start m1 m3 > /dev/null 2>&1

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
