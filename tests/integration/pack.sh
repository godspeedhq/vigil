#!/usr/bin/env bash
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
# Integration test: vigil pack (SPECIFICATION.md 18.10) on Linux and macOS,
# against mock-files.py as the pack repository, signed with a key for this
# run. The twin of Pack.ps1.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-pack-it.XXXXXX")
work=$(cd "$work" && pwd)
root=$work/root
pass=0
fail=0
mock_pid=''

check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"
    fi
}

cleanup() {
    [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

vigil() { bash "$root/app/vigil" --root "$root" "$@"; }
yes_no() { if "$@" > /dev/null 2>&1; then echo yes; else echo no; fi; }
# Precheck refuses the test override (22.4.4).
precheck() { env -u VIGIL_TEST_RELEASE_URL bash "$root/app/vigil" --root "$root" precheck > /dev/null 2>&1; echo $?; }
sha() { if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi; }

# Adds pack $2 at version $3 with jobs $4..., each reporting one metric, to
# packs release $1, and makes $1 the newest: its index carries every version
# published before. $MIN is the Vigil it needs, $DESC its description.
publish() {
    local tag=$1 name=$2 v=$3 d=$work/mock/www/releases/download/$1 f
    shift 3
    rm -rf "$work/stage"
    mkdir -p "$d" "$work/stage"
    make_pack "$work/stage/$name" "$v" "$@"
    f=vigil-pack-$name-$v-$os.tar.gz
    (cd "$work/stage" && tar -czf "$d/$f" "$name")
    printf 'pack\t%s\t%s\t%s\t%s\tdigest\t%s\n' "$name" "$v" "${MIN:-0.0.1}" "$tag" "${DESC:-For the test}" >> "$work/entries"
    printf 'file\t%s\t%s\t%s\t%s\t%s\n' "$name" "$v" "$os" "$f" "$(sha "$d/$f" | cut -c1-64)" >> "$work/entries"
    resign "$tag"
}

# Packs release $1, the newest, with an index of every version so far,
# signed with the key named by $KEY.
resign() {
    local d=$work/mock/www/releases/download/$1
    mkdir -p "$d" "$work/mock/www/api/releases"
    { printf 'format\t1\nrelease\t%s\n' "$1"; cat "$work/entries"; } > "$d/packs.index"
    openssl dgst -sha256 -sign "${KEY:-$work/release.key}" -out "$d/packs.index.sig" "$d/packs.index"
    printf '[{"tag_name": "%s"}, {"tag_name": "v0.3.0"}]\n' "$1" > "$work/mock/www/api/releases/all"
}

# Writes pack base version $2 and jobs $3... in folder $1.
make_pack() {
    local to=$1 pv=$2 j
    shift 2
    mkdir -p "$to"
    printf '[pack]\nversion = %s\nvigil = %s\ndescription = %s\n\n' "$pv" "${MIN:-0.0.1}" "${DESC:-For the test}" > "$to/pack.config"
    for j in "$@"; do
        printf '[job.%s]\nmetric_name = it.%s\nmetrics = up\nrun_every = %s\nmax_runtime = 30s\n\n' "$j" "$j" "${EVERY:-1h}" >> "$to/pack.config"
        printf 'echo "metric up 1" # %s\n' "$pv" > "$to/$j.sh"
    done
}

printf 'bash %s on %s\n' "$BASH_VERSION" "$(uname -s)"
python=''
for p in python3 python; do
    if "$p" -c 'import http.server' > /dev/null 2>&1; then
        python=$p
        break
    fi
done
[ -n "$python" ] || { echo "needs python3"; exit 1; }
mkdir -p "$root" "$work/mock/www"
cp -R "$repo/app" "$repo/vendor" "$root/"
: > "$work/entries"
printf '0.3.0\n' > "$root/app/VERSION"
export HOME=$work
openssl genrsa -out "$work/release.key" 2048 2> /dev/null
openssl genrsa -out "$work/other.key" 2048 2> /dev/null
openssl rsa -in "$work/release.key" -pubout -out "$work/release.pem" 2> /dev/null
"$python" "$here/mock-files.py" "$work/mock" 2> "$work/mock/stderr" &
mock_pid=$!
i=0
while [ ! -s "$work/mock/port" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
export VIGIL_TEST_RELEASE_URL=http://127.0.0.1:$(cat "$work/mock/port") VIGIL_TEST_RELEASE_KEY=$work/release.pem

vigil init --instance pk --backend file --no-pack > /dev/null 2>&1
cfg=$root/config/vigil.config
printf 'echo "metric mine 1"\n' > "$root/scripts/mine.sh"
printf '\n[job.mine]\nfile = scripts/mine.sh\nrun_every = 1h\n' >> "$cfg"
before=$(cksum < "$root/scripts/mine.sh")
case $(uname -s) in Darwin) os=macos ;; *) os=linux ;; esac

# As the installer leaves them.
make_pack "$root/packs/base" 1.0.0 cpu disk

printf 'Turning on\n'
check 'listed, off' 'off' "$(vigil pack list | awk '$1 == "base_cpu" { print $2 }')"
# The file is held open across the change: replaced, it still reads as it was;
# written over, it would read as the new one (46).
chmod 640 "$cfg"
old=$(cat "$cfg")
exec 3< "$cfg"
out=$(vigil pack enable base 2>&1)
check 'enables' 0 "$?"
check 'replaced, not written over: the old file is as it was' "$old" "$(cat <&3)"
exec 3<&-
check 'its mode stays' '-rw-r-----' "$(ls -l "$cfg" | cut -c1-10)"
check 'says what' 'on: base_cpu|on: base_disk' "$(printf '%s' "$out" | tr '\n' '|')"
check 'the jobs are in the configuration' 2 "$(grep -c '^\[job\.base_' "$cfg")"
check 'precheck is happy' 0 "$(precheck)"
vigil run base_cpu > /dev/null 2>&1
check 'a job runs' 0 "$?"
check 'listed, on' 'on' "$(vigil pack list | awk '$1 == "base_cpu" { print $2 }')"
check 'enabling twice changes nothing, and a pack that needs nothing says no more' 'base is already on' "$(vigil pack enable base 2>&1)"
check 'an unknown name is refused' 'vigil: no pack or job called nosuch: vigil pack list' "$(vigil pack enable nosuch 2>&1)"
check 'an unknown job is refused' 'vigil: no job called base_nosuch: vigil pack list' "$(vigil pack enable base_nosuch 2>&1)"
check 'a bad name is refused' 'vigil: not a pack or job name: ../x' "$(vigil pack enable '../x' 2>&1)"

# A pack whose pack.config is here but whose scripts are not, as nginx on
# Windows: nothing to turn on, not "already on" (46).
case $os in macos) osname=macOS ;; *) osname=Linux ;; esac
mkdir -p "$root/packs/elsewhere"
printf '[pack]\nversion = 1.0.0\nvigil = 0.0.1\ndescription = Elsewhere only\n\n[job.x]\nmetric_name = it.x\nmetrics = up\nrun_every = 1h\n' > "$root/packs/elsewhere/pack.config"
sum=$(cksum < "$cfg")
out=$(vigil pack enable elsewhere 2>&1)
check 'a pack with no scripts here is refused' 1 "$?"
check 'saying so, not "already on"' "vigil: pack elsewhere has no scripts for $osname" "$out"
check 'and the configuration is unchanged' "$sum" "$(cksum < "$cfg")"
check 'listed as not available here' "  not available here: no scripts for $osname" "$(vigil pack list | sed -n '/^elsewhere /{n;p;}')"
rm -rf "$root/packs/elsewhere"

printf 'Updating\n'
publish packs-2026.01.01 base 1.0.0 cpu disk
check 'nothing to do' 'pack base 1.0.0 is here: nothing to do' "$(vigil pack update)"
sed -i.bak '/job.base_cpu/,/job.base_disk/s/^run_every = 1h$/run_every = 5m/' "$cfg" && rm -f "$cfg.bak"
publish packs-2026.01.02 base 1.1.0 cpu load
DESC='A web server' publish packs-2026.01.02 web 1.0.0 status
check 'the check says so' 'pack base 1.0.0 is here; 1.1.0 is available: vigil pack update' "$(vigil pack update --check)"
check 'the check changes nothing' 1.0.0 "$(sed -n 's/^version = //p' "$root/packs/base/pack.config")"
was=$(cksum < "$cfg")
out=$(vigil pack update 2>&1)
check 'updates' 0 "$?"
check 'to the new version' 1.1.0 "$(sed -n 's/^version = //p' "$root/packs/base/pack.config")"
check 'installs nothing it was not asked for' no "$(yes_no test -e "$root/packs/web")"
check 'the configuration is not touched' "$was" "$(cksum < "$cfg")"
check 'a job on runs the new script' yes "$(yes_no grep -q '1.1.0' "$root/packs/base/cpu.sh")"
check 'says what changed' yes "$(printf '%s' "$out" | grep -q '^changed: base_cpu' && echo yes || echo no)"
check 'says what is new' yes "$(printf '%s' "$out" | grep -q '^new, not running: base_load. To turn it on: vigil pack enable base_load$' && echo yes || echo no)"
check 'a new script stays off' 0 "$(grep -c '^\[job\.base_load\]' "$cfg")"
check 'but is there' yes "$(yes_no test -f "$root/packs/base/load.sh")"
check 'says what was dropped' yes "$(printf '%s' "$out" | grep -q '^dropped from the pack, still running: base_disk' && echo yes || echo no)"
check 'a dropped script stays while a job uses it' yes "$(yes_no test -f "$root/packs/base/disk.sh")"
vigil run base_disk > /dev/null 2>&1
check 'and the job still runs' 0 "$?"
check 'precheck is still happy' 0 "$(precheck)"
check 'your own script is untouched' "$before" "$(cksum < "$root/scripts/mine.sh")"
check 'the index is kept for searching' yes "$(yes_no test -f "$root/packs/.index")"

printf 'On and off\n'
check 'a new script turns on' 'on: base_load' "$(vigil pack enable base_load 2>&1)"
check 'an edit is kept' 5m "$(sed -n '/job.base_cpu/,/^$/s/^run_every = //p' "$cfg")"
check 'one job turns off' 'off: base_disk' "$(vigil pack disable base_disk 2>&1)"
check 'it leaves the configuration' 0 "$(grep -c 'base_disk\|packs/base/disk' "$cfg")"
check 'turning off twice changes nothing' 'base_disk is already off' "$(vigil pack disable base_disk 2>&1)"
check 'precheck is happy with that' 0 "$(precheck)"
publish packs-2026.01.03 base 1.2.0 cpu load
out=$(vigil pack update 2>&1)
check 'a dropped script goes once no job uses it' no "$(yes_no test -f "$root/packs/base/disk.sh")"

printf 'Searching\n'
# One line, with | for each line break.
lines() { tr '\n' '|' | sed 's/|$//'; }
check 'by a word, as a table' 'Packs in packs-2026.01.03:||Name Version Here About|---- ------- ---- -----|web  1.0.0        A web server' "$(vigil pack search web 2>&1 | lines)"
check 'every word, in any case' 'web  1.0.0        A web server' "$(vigil pack search SERVER a 2>&1 | tail -n 1)"
check 'all, with none' 'base 1.2.0   installed For the test|web  1.0.0             A web server' "$(vigil pack search 2>&1 | tail -n 2 | lines)"
check 'nothing found' 'no pack matches: nosuch' "$(vigil pack search nosuch 2>&1)"
check 'what is not installed' 'Packs in packs-2026.01.03 not installed here:||Name Version Here About|---- ------- ---- -----|web  1.0.0        A web server' "$(vigil pack list --available 2>&1 | lines)"
check 'one pack' "Name       : web|About      : A web server|Here       : not installed: vigil pack install web|Platforms  : $osname||Version Platforms Needs Vigil Release|------- --------- ----------- -------|1.0.0   $(printf '%-9s' "$osname") 0.0.1       packs-2026.01.02" "$(vigil pack info web 2>&1 | lines)"
check 'an unknown one' 'vigil: no pack called nosuch: vigil pack search' "$(vigil pack info nosuch 2>&1)"
# Released after the index here was saved: found, as search fetches the
# newest index rather than read the saved one.
DESC='A database' publish packs-2026.01.03.1 db 1.0.0 status
printf 'info\tdb\t1.0.0\tworks_with\tDB 1 or later\ninfo\tdb\t1.0.0\tprograms_%s\tdbcli\ninfo\tdb\t1.0.0\tsecret\tDB_PW\ninfo\tdb\t1.0.0\tneeds\ta role, as an administrator: CREATE ROLE it\ninfo\tdb\t1.0.0\tneeds\tits log on\ninfo\tdb\t1.0.0\tsetting\tDB_HOST=localhost\ninfo\tdb\t1.0.0\tsetting\tDB_PORT=1\ninfo\tdb\t1.0.0\tdocs\thttps://example.com/packs/README.md#db\n' "$os" >> "$work/entries"
# One with no scripts here, and what it needs on the platform it has.
other=windows otherh=Windows
printf 'pack\telsewhere\t1.0.0\t0.0.1\tpacks-2026.01.03.1\tdigest\tElsewhere only\nfile\telsewhere\t1.0.0\t%s\tvigil-pack-elsewhere-1.0.0-%s.zip\t%s\ninfo\telsewhere\t1.0.0\tprograms_%s\tthat\n' "$other" "$other" "$(printf '0%.0s' $(seq 64))" "$other" >> "$work/entries"
resign packs-2026.01.03.1
check 'a pack released since the index here was saved' 'db   1.0.0        A database' "$(vigil pack search database 2>&1 | tail -n 1)"
check 'and the new index is saved' packs-2026.01.03.1 "$(awk -F '\t' '$1 == "release" { print $2 }' "$root/packs/.index")"
# The newest release's index is the one saved here: not downloaded again
# (backlog 65). Gone from the release, it still answers, and says nothing of
# a repository it could not reach.
rel=$work/mock/www/releases/download/packs-2026.01.03.1
mv "$rel/packs.index" "$work/keep.rel.index"
out=$(vigil pack search database 2> "$work/err")
check 'the newest index, saved here, is not downloaded again' 'db   1.0.0        A database|' "$(printf '%s\n' "$out" | tail -n 1)|$(cat "$work/err")"
mv "$work/keep.rel.index" "$rel/packs.index"
check 'a pack with no scripts here' "elsewhere 1.0.0   not for $osname Elsewhere only" "$(vigil pack search elsewhere 2>&1 | tail -n 1)"
check 'what a pack needs, from its info records' "Name       : db|About      : A database|Here       : not installed: vigil pack install db|Platforms  : $osname|Works with : DB 1 or later|Programs   : dbcli|Secrets    : DB_PW|Needs      : a role, as an administrator:|             CREATE ROLE it|             its log on|Settings   : DB_HOST=localhost DB_PORT=1 (the env lines in vigil.config, once|             enabled)|Docs       : https://example.com/packs/README.md#db" "$(vigil pack info db 2>&1 | sed '/^$/,$d' | lines)"
check 'and on a platform it has no scripts for' "Here       : not for $osname|Platforms  : $otherh|Programs   : that (on $otherh)|Secrets    : none" "$(vigil pack info elsewhere 2>&1 | sed -n '3,4p;5,6p' | lines)"
out=$(VIGIL_TEST_RELEASE_URL=http://127.0.0.1:9 vigil pack search database 2> "$work/err")
check 'offline, from the index saved here' 'db   1.0.0        A database' "$(printf '%s\n' "$out" | tail -n 1)"
check 'saying so' 'vigil: cannot find the latest packs release on GitHub: no network, or its API refused (it allows 60 requests an hour); showing the index saved here, of packs-2026.01.03.1' "$(cat "$work/err")"
mv "$root/packs/.index" "$work/keep.saved"
check 'offline, with none saved' 'vigil: cannot find the latest packs release on GitHub: no network, or its API refused (it allows 60 requests an hour)' "$(VIGIL_TEST_RELEASE_URL=http://127.0.0.1:9 vigil pack info db 2>&1)"
mv "$work/keep.saved" "$root/packs/.index"

printf 'Installing\n'
was=$(cksum < "$cfg")
out=$(vigil pack install web 2>&1)
check 'installs' 0 "$?"
check 'says what, and that it is off' 'installed pack web 1.0.0|off until enabled: web_status|To turn them all on: vigil pack enable web' "$(printf '%s' "$out" | tr '\n' '|' | sed 's/|$//')"
check 'its scripts are here' yes "$(yes_no test -f "$root/packs/web/status.sh")"
check 'the configuration is not touched' "$was" "$(cksum < "$cfg")"
check 'twice: nothing to do' 'pack web 1.0.0 is here: nothing to do' "$(vigil pack install web 2>&1)"
check 'listed, off' off "$(vigil pack list | awk '$1 == "web_status" { print $2 }')"
check 'an unknown pack' 'vigil: no pack called nosuch: vigil pack search' "$(vigil pack install nosuch 2>&1)"
check 'an unknown version' 'vigil: pack web has no version 9.9.9: vigil pack info web' "$(vigil pack install web@9.9.9 2>&1)"
check 'a bad name' 'vigil: not a pack name: ../x' "$(vigil pack install ../x 2>&1)"
MIN=99.0.0 DESC='A web server' publish packs-2026.01.04 web 2.0.0 status
check 'one too new for this Vigil: asked for, refused' 'vigil: pack web 2.0.0 needs Vigil 99.0.0 or later: vigil self update' "$(vigil pack install web@2.0.0 2>&1)"
check 'and update says so, keeping what runs here' 'pack web 1.0.0 is here: nothing to do|  web 2.0.0 needs Vigil 99.0.0 or later: vigil self update' "$(vigil pack update 2>&1 | grep web | tr '\n' '|' | sed 's/|$//')"
check 'an older version, when asked' 'pack base went back from 1.2.0 to 1.1.0' "$(vigil pack install base@1.1.0 2>&1 | head -n 1)"
# One pack by name: the others are left as they are.
check 'update by name: that pack only' 'pack web 1.0.0 is here: nothing to do|  web 2.0.0 needs Vigil 99.0.0 or later: vigil self update' "$(vigil pack update web 2>&1 | tr '\n' '|' | sed 's/|$//')"
check 'and the other pack is left behind' 1.1.0 "$(sed -n 's/^version = //p' "$root/packs/base/pack.config")"
check 'the check, by name' 'pack base 1.1.0 is here; 1.2.0 is available: vigil pack update' "$(vigil pack update --check base 2>&1)"
out=$(vigil pack update nosuch 2>&1)
check 'a pack not installed, by name' 'vigil: pack nosuch is not installed: vigil pack install nosuch|1' "$out|$?"
out=$(vigil pack update base@1.0.0 2>&1)
check 'a version, by name' 'vigil: pack update takes the newest version; for another: vigil pack install base@1.0.0|1' "$out|$?"
check 'an option it does not know' 64 "$(vigil pack update --all > /dev/null 2>&1; echo $?)"
check 'update takes it forward again' 'updated pack base 1.1.0 to 1.2.0' "$(vigil pack update base 2>&1 | grep '^updated')"
sed -i.bak 's/^version = 1.0.0$/version = 5.0.0/' "$root/packs/web/pack.config" && rm -f "$root/packs/web/pack.config.bak"
check 'never back a version on its own' 'pack web 5.0.0 is here: nothing to do' "$(vigil pack update 2>&1 | grep '^pack web')"
sed -i.bak 's/^version = 5.0.0$/version = 1.0.0/' "$root/packs/web/pack.config" && rm -f "$root/packs/web/pack.config.bak"

printf 'Removing\n'
vigil pack enable web > /dev/null 2>&1
check 'refused while on' 'vigil: pack web is in use by: web_status. Turn them off first: vigil pack disable web' "$(vigil pack remove web 2>&1)"
check 'and kept' yes "$(yes_no test -f "$root/packs/web/status.sh")"
vigil pack disable web > /dev/null 2>&1
check 'removes once off' 'removed pack web 1.0.0' "$(vigil pack remove web 2>&1)"
check 'its scripts go' no "$(yes_no test -e "$root/packs/web")"
check 'one not here' 'vigil: pack web is not installed: vigil pack list' "$(vigil pack remove web 2>&1)"
check 'precheck is happy after' 0 "$(precheck)"

printf 'Offline\n'
usb=$work/usb
out=$(vigil pack download web --to "$usb" 2>&1)
check 'downloads' "downloaded web 1.0.0 for $osname: vigil-pack-web-1.0.0-$os.tar.gz|with the signed index. There: vigil pack install <name> --from <this folder>" "$(printf '%s' "$out" | tr '\n' '|' | sed 's/|$//')"
check 'the index and its signature too' 'packs.index packs.index.sig vigil-pack-web-1.0.0-'"$os"'.tar.gz' "$(ls "$usb" | tr '\n' ' ' | sed 's/ $//')"
check 'any version, for another Vigil' "downloaded web 2.0.0 for $osname: vigil-pack-web-2.0.0-$os.tar.gz" "$(vigil pack download web@2.0.0 --to "$usb" 2>&1 | head -n 1)"
check 'a platform it has no scripts for' 'vigil: pack web has no scripts for Windows' "$(vigil pack download web --os windows --to "$usb" 2>&1)"
check 'not a platform' 'vigil: not a platform: beos (linux, macos or windows)' "$(vigil pack download web --os beos --to "$usb" 2>&1)"
# Nothing to reach: only the folder.
offline() { VIGIL_TEST_RELEASE_URL=http://127.0.0.1:9 vigil "$@"; }
out=$(offline pack install web --from "$usb" 2>&1)
check 'installs from the folder, with no network' 'installed pack web 1.0.0' "$(printf '%s' "$out" | head -n 1)"
offline pack remove web > /dev/null 2>&1
check 'a pack not in the folder' "vigil: vigil-pack-base-1.2.0-$os.tar.gz is not in $usb: vigil pack download base@1.2.0 there" "$(offline pack install base@1.2.0 --from "$usb" 2>&1)"
cp "$usb/vigil-pack-web-1.0.0-$os.tar.gz" "$work/keep.tgz"
printf 'x' >> "$usb/vigil-pack-web-1.0.0-$os.tar.gz"
check 'a tampered archive' "vigil: vigil-pack-web-1.0.0-$os.tar.gz does not match the pack index; nothing was changed" "$(offline pack install web --from "$usb" 2>&1)"
cp "$work/keep.tgz" "$usb/vigil-pack-web-1.0.0-$os.tar.gz"
cp "$usb/packs.index" "$work/keep.index"
printf 'pack\tweb\t9.0.0\t0.0.1\tpacks-x\tdigest\tAdded\n' >> "$usb/packs.index"
check 'an index changed after signing' "vigil: the pack index of $usb is not signed by the Vigil release key; nothing was changed" "$(offline pack install web --from "$usb" 2>&1)"
cp "$work/keep.index" "$usb/packs.index"
check 'nothing was installed' no "$(yes_no test -e "$root/packs/web")"

printf 'Refused\n'
snapshot() { cksum < "$cfg"; cksum < "$root/packs/base/pack.config"; }
was=$(snapshot)
KEY=$work/other.key publish packs-2026.02.01 base 1.3.0 cpu
out=$(vigil pack update 2>&1)
check 'a bad signature is refused' 1 "$?"
check 'saying so' 'vigil: the pack index of packs-2026.02.01 is not signed by the Vigil release key; nothing was changed' "$out"
resign packs-2026.02.02
a=$work/mock/www/releases/download/packs-2026.02.01/vigil-pack-base-1.3.0-$os.tar.gz
cp "$a" "$work/keep.tgz"
printf 'x' >> "$a"
check 'a tampered archive is refused' "vigil: vigil-pack-base-1.3.0-$os.tar.gz does not match the pack index; nothing was changed" "$(vigil pack update 2>&1 | grep '^vigil:')"
cp "$work/keep.tgz" "$a"
resign packs-2026.02.03
rm -f "$work/mock/www/releases/download/packs-2026.02.03/packs.index.sig"
check 'a missing signature is refused' 'vigil: cannot download packs.index.sig of packs-2026.02.03' "$(vigil pack update 2>&1)"
check 'and nothing changed' "$was" "$(snapshot)"
printf '[]\n' > "$work/mock/www/api/releases/all"
check 'no packs release' 'vigil: cannot find the latest packs release on GitHub: no network, or its API refused (it allows 60 requests an hour)' "$(vigil pack update 2>&1)"
MIN=99.0.0 publish packs-2026.02.04 base 1.4.0 cpu
out=$(vigil pack update 2>&1)
check 'takes the newest this Vigil runs' 'updated pack base 1.2.0 to 1.3.0' "$(printf '%s' "$out" | grep '^updated')"
check 'and names the one it cannot' '  base 1.4.0 needs Vigil 99.0.0 or later: vigil self update' "$(printf '%s' "$out" | grep 'needs Vigil')"

# A job Vigil cannot accept: the configuration goes back.
EVERY=soon make_pack "$work/bad" 1.7.0 extra
cp "$work/bad/extra.sh" "$root/packs/base/"
cat "$work/bad/pack.config" | sed -n '/^\[job/,$p' >> "$root/packs/base/pack.config"
was=$(cksum < "$cfg")
out=$(vigil pack enable base_extra 2>&1)
check 'a job that would not be valid is refused' 1 "$?"
check 'saying why' yes "$(printf '%s' "$out" | grep -q 'would not be valid' && echo yes || echo no)"
check 'and goes back' "$was" "$(cksum < "$cfg")"

printf 'A configuration from a source\n'
cp "$cfg" "$work/cfg.keep"
printf '[vigil]\nconfig_source = remote\nconfig_file = vigil.config\n\n[source.remote]\ntype = local\npath = /tmp\n' > "$cfg"
vigil pack disable base > /dev/null 2>&1
check 'is not edited' 1 "$?"
cp "$work/cfg.keep" "$cfg"

printf 'What a pack needs\n'
mkdir -p "$root/packs/svc"
printf '[pack]\nversion = 1.0.0\nvigil = 0.0.1\ndescription = A service\nneeds = a role: CREATE ROLE it\nneeds = its page on\n\n' > "$root/packs/svc/pack.config"
for j in a b; do
    printf '[job.%s]\nmetric_name = svc.%s\nmetrics = up\nrun_every = 1h\nmax_runtime = 30s\nenv = SVC_HOST=localhost\nenv = SVC_PORT=1\nsecret = SVC_PASSWORD=secret:SVC_PW\n\n' "$j" "$j" >> "$root/packs/svc/pack.config"
    printf 'echo "metric up 1"\n' > "$root/packs/svc/$j.sh"
done
out=$(vigil pack enable svc 2>&1)
check 'turns on, and says what it needs' 'on: svc_a|on: svc_b|needs secret:SVC_PW: not set: vigil secret set SVC_PW, as the account Vigil runs as|needs a role: CREATE ROLE it|needs its page on|settings in vigil.config: SVC_HOST=localhost SVC_PORT=1' "$(printf '%s' "$out" | tr '\n' '|')"
printf 'x' | vigil secret set SVC_PW --stdin > /dev/null 2>&1
check 'a secret set' 'needs secret:SVC_PW: set' "$(vigil pack enable svc_a 2>&1 | grep '^needs secret')"
sed -i.bak 's/^secret = SVC_PASSWORD=secret:SVC_PW$/secret = SVC_PASSWORD=env:SVC_ENV_PW/' "$cfg" && rm -f "$cfg.bak"
check 'a reference changed to env:' 'needs env:SVC_ENV_PW: from the environment Vigil runs in' "$(vigil pack enable svc 2>&1 | grep '^needs env')"
sed -i.bak 's/^secret = SVC_PASSWORD=env:SVC_ENV_PW$/secret = SVC_PASSWORD=store:vault\/svc#pw/' "$cfg" && rm -f "$cfg.bak"
check 'or to store:, not asked' 'needs store:vault/svc#pw: from a secret store: vigil precheck checks it' "$(vigil pack enable svc 2>&1 | grep '^needs store')"
out=$(vigil pack list 2>&1)
check 'listed under the pack' 'svc_b on|needs store:vault/svc#pw: from a secret store: vigil precheck checks it|needs a role: CREATE ROLE it|needs its page on|settings in vigil.config: SVC_HOST=localhost SVC_PORT=1' "$(printf '%s' "$out" | sed -n '/^svc /,$p' | sed '1,2d; s/^ *//; s/  */ /' | tr '\n' '|' | sed 's/|$//')"
vigil pack disable svc > /dev/null 2>&1
check 'and off again' 0 "$(grep -c 'svc' "$cfg")"
rm -rf "$root/packs/svc"

printf 'Turning off\n'
check 'a whole pack' 'off: base' "$(vigil pack disable base 2>&1)"
check 'the jobs go' 0 "$(grep -c 'base' "$cfg")"
check 'the scripts stay' yes "$(yes_no test -f "$root/packs/base/cpu.sh")"
check 'your own job stays' 1 "$(grep -c '^\[job\.mine\]' "$cfg")"
check 'precheck is happy after' 0 "$(precheck)"

printf 'Packs this account cannot read\n'
if [ "$(id -u)" = 0 ]; then
    printf '  SKIP  root reads everything\n'
else
    had=$(sed -n 's/^version = //p' "$root/packs/base/pack.config")
    chmod 000 "$root/packs/base"
    out=$(vigil pack update --check 2>&1)
    check 'the check is refused' 1 "$?"
    check 'saying why, not that the pack is missing' "vigil: cannot read $root/packs from this account: run this as the account that installed Vigil (sudo for a system install)" "$out"
    out=$(vigil pack update 2>&1)
    check 'and so is the update' 1 "$?"
    chmod 755 "$root/packs/base"
    check 'nothing was changed' "$had" "$(sed -n 's/^version = //p' "$root/packs/base/pack.config")"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
