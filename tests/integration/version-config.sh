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
# Integration test: [vigil] version (SPECIFICATION.md 18.11) on Linux and
# macOS. A real supervisor follows the version its configuration names, up
# and down, through the vigil_update worker, against mock-files.py as the
# release server with releases built by tools/release/package.sh: an
# update, a downgrade, a release that is not there yet, one that does not
# run, one that would go back past a data format change, and a version
# from a fetched configuration. vigil self update refuses while it is set.
#
# HOME is a throwaway folder, so nothing of the account's own is touched.
# Under Git Bash a running script holds its own folder, so it is skipped.
#
# Needs curl, openssl and python3 (or python).
#
# Exit code: 0 all passed, 1 any failed.

set -u

case $(uname -s) in
    Linux | Darwin) ;;
    *)
        printf 'SKIP version-config: needs Linux or macOS\n'
        exit 0
        ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-version.XXXXXX")
work=$(cd "$work" && pwd)
root=$work/root
pass=0
fail=0
mock_pid=''
sup=''

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
    [ -n "$sup" ] && kill "$sup" 2>/dev/null
    [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null
    sleep 1
    rm -rf "$work"
}
trap cleanup EXIT

vigil() { bash "$root/app/vigil" --root "$root" "$@"; }
version_of() { cat "$root/app/VERSION" 2> /dev/null; }
sup_log() { cat "$root"/logs/supervisor/2*.log 2> /dev/null; }
update_value() { sed -n "s/^$1 *= *//p" "$root/state/update.state" 2> /dev/null; }
runs() { cat "$root"/logs/jobs/"$1"/*.log 2>/dev/null | grep -c 'run start'; }

# Waits up to $1 seconds for the command after it to succeed.
wait_until() {
    local n=$(($1 * 2))
    shift
    while ! "$@" > /dev/null 2>&1 && [ "$n" -gt 0 ]; do
        sleep 0.5
        n=$((n - 1))
    done
}
is_version() { [ "$(version_of)" = "$1" ]; }
is_result() { [ "$(update_value version)" = "$1" ] && [ "$(update_value result)" = "$2" ]; }

# Sets [vigil] version in configuration file $1 to $2, or removes it for -.
set_version() {
    awk -v v="$2" '
        /^version *=/ && sec == "vigil" { next }
        { print }
        /^\[/ { sec = $0; gsub(/[][]/, "", sec); if (sec == "vigil" && v != "-") print "version = " v }
    ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# What the run did, when a check fails.
explain() {
    printf '        app/VERSION %s; update.reported %s; update.state:\n' "$(version_of)" "$(cat "$root/state/update.reported" 2> /dev/null)"
    sed 's/^/          /' "$root/state/update.state" 2> /dev/null
    # Every line about updates and reloads, not only the last ones.
    sup_log | grep -E 'as the configuration asks|could not be|reloading|staying on|started, pid|stopped' | sed 's/^/        sup: /'
    cat "$root"/logs/jobs/vigil_update/*.log 2> /dev/null | tail -40 | sed 's/^/        update: /'
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

# Publishes release $1 on the mock, built from this repository.
publish() {
    local d="$www/releases/download/v$1"
    mkdir -p "$d" "$www/releases/tag"
    bash "$repo/tools/release/package.sh" "$1" "$d" > /dev/null || { printf 'packaging failed\n'; exit 1; }
    : > "$www/releases/tag/v$1"
}

# Publishes release $2, made from release $1 by running $3 in its app/.
variant() {
    local from=$1 to=$2 how=$3 d
    rm -rf "$work/variant"
    mkdir -p "$work/variant"
    tar -xzf "$www/releases/download/v$from/vigil-$from.tar.gz" -C "$work/variant"
    mv "$work/variant/vigil-$from" "$work/variant/vigil-$to"
    printf '%s\n' "$to" > "$work/variant/vigil-$to/app/VERSION"
    (cd "$work/variant/vigil-$to/app" && eval "$how")
    d=$www/releases/download/v$to
    mkdir -p "$d"
    tar -czf "$d/vigil-$to.tar.gz" -C "$work/variant" "vigil-$to"
    cp "$repo/install.sh" "$d/"
    (cd "$d" && { sha256sum "vigil-$to.tar.gz" install.sh 2>/dev/null || shasum -a 256 "vigil-$to.tar.gz" install.sh; } | sed 's/ \*/  /' > SHA256SUMS)
    openssl dgst -sha256 -sign "$work/release.key" -out "$d/SHA256SUMS.sig" "$d/SHA256SUMS"
    : > "$www/releases/tag/v$to"
}

mkdir -p "$work/mock/www" "$work/home"
# A release key for this run, known to Vigil only through the test override.
openssl genrsa -out "$work/release.key" 2048 2> /dev/null
openssl rsa -in "$work/release.key" -pubout -out "$work/release.pem" 2> /dev/null
export VIGIL_SIGN_KEY=$work/release.key VIGIL_TEST_RELEASE_KEY=$work/release.pem
www=$work/mock/www
"$python" "$here/mock-files.py" "$work/mock" 2> "$work/mock/stderr" &
mock_pid=$!
i=0
while [ ! -s "$work/mock/port" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
port=$(cat "$work/mock/port" 2>/dev/null)
[ -n "$port" ] || { cat "$work/mock/stderr"; exit 1; }
export VIGIL_TEST_RELEASE_URL=http://127.0.0.1:$port
export HOME=$work/home

publish 0.1.0-it
publish 0.2.0-it
printf '/releases/latest /releases/tag/v0.2.0-it\n' > "$work/mock/redirects"

# --- installed, with a supervisor and a job that runs throughout -----------------------

sh "$www/releases/download/v0.1.0-it/install.sh" --user --version 0.1.0-it --prefix "$root" --instance vc --backend file --no-service < /dev/null > "$work/out" 2>&1
rc=$?
check 'installed' 0 "$rc"
[ "$rc" -eq 0 ] || { sed 's/^/        /' "$work/out"; exit 1; }
cfg=$root/config/vigil.config
printf 'echo "metric beats 1"\n' > "$root/scripts/beat.sh"
printf '\n[job.beat]\nfile      = scripts/beat.sh\nrun_every = 2s\n' >> "$cfg"
sed -i.bak 's/^tick *= *.*/tick = 1s/' "$cfg" && rm -f "$cfg.bak"
grep -q '^tick' "$cfg" || printf '\n[scheduler]\ntick = 1s\n' >> "$cfg"

# Not through vigil(): $! must be the supervisor, not a subshell.
bash "$root/app/vigil" --root "$root" supervise > /dev/null 2>&1 &
sup=$!
wait_until 30 test "$(runs beat)" -ge 1
check 'without version, nothing moves' 0.1.0-it "$(version_of)"
vigil self update --check > "$work/out" 2>&1
check 'without version, self update is not refused' 0 "$?"

# --- an update ----------------------------------------------------------------------

set_version "$cfg" 0.2.0-it
wait_until 90 is_version 0.2.0-it
check 'it updates to the version named' 0.2.0-it "$(version_of)"
wait_until 30 is_result 0.2.0-it succeeded
check 'and records it' succeeded "$(update_value result)"
check 'as the same supervisor process' yes "$(kill -0 "$sup" 2>/dev/null && echo yes || echo no)"
check 'which runs the new version' 0.2.0-it "$(vigil version --supervisor)"
wait_until 20 sh -c "cat '$root'/logs/supervisor/2*.log | grep -q 'Vigil is now 0.2.0-it'"
check 'the supervisor log says so' 1 "$(sup_log | grep -c 'Vigil is now 0.2.0-it, as the configuration asks')"
check 'and said what it was doing' 1 "$(sup_log | grep -c 'updating Vigil 0.1.0-it to 0.2.0-it, as the configuration asks')"
check 'the configuration was not written to' 1 "$(grep -c '^version = 0.2.0-it$' "$cfg")"
[ "$(version_of)" = 0.2.0-it ] || explain
before=$(runs beat)
wait_until 20 test "$(runs beat)" -ge $((before + 2))
check 'jobs carry on' yes "$([ "$(runs beat)" -ge $((before + 2)) ] && echo yes || echo no)"

vigil self update > "$work/out" 2>&1
check 'self update is refused while version is set' 1 "$?"
check 'saying where to go' 1 "$(grep -c 'the version is set in the configuration (version = 0.2.0-it): change it there to update, or remove it to use vigil self update' "$work/out")"
vigil self update --version 0.1.0-it > /dev/null 2>&1
check 'with --version too' 1 "$?"
vigil self update --check > /dev/null 2>&1
check '--check still works' 0 "$?"
env -u VIGIL_TEST_RELEASE_URL bash "$root/app/vigil" --root "$root" precheck > "$work/out" 2>&1
check 'precheck notes the version' 1 "$(grep -c 'note  version 0.2.0-it: this is 0.2.0-it$' "$work/out")"
check 'and that this account can update' 1 "$(grep -c 'note  this account can update Vigil: it owns' "$work/out")"

# --- a downgrade ----------------------------------------------------------------------

set_version "$cfg" 0.1.0-it
wait_until 90 is_version 0.1.0-it
check 'it goes back to an older version named' 0.1.0-it "$(version_of)"
wait_until 30 is_result 0.1.0-it succeeded
check 'and records it' succeeded "$(update_value result)"
[ "$(version_of)" = 0.1.0-it ] || explain

# --- a release that is not there yet: logged, kept, tried again --------------------------------

set_version "$cfg" 0.5.0-it
wait_until 60 is_result 0.5.0-it unavailable
check 'a release not there: recorded as unavailable' unavailable "$(update_value result)"
check 'nothing changed' 0.1.0-it "$(version_of)"
wait_until 20 sh -c "cat '$root'/logs/supervisor/2*.log | grep -q 'Vigil 0.5.0-it, which the configuration asks for, could not be downloaded'"
check 'logged as a warning' 1 "$(sup_log | grep -c 'WARN supervisor Vigil 0.5.0-it, which the configuration asks for, could not be downloaded: cannot download Vigil 0.5.0-it: is there such a release?; staying on 0.1.0-it, trying again in 5 minutes')"
vigil status > "$work/out" 2>&1
check 'status shows it' 1 "$(grep -c 'the configuration asks for 0.5.0-it; this is 0.1.0-it' "$work/out")"
check 'and why' 1 "$(grep -c 'could not be downloaded: cannot download Vigil 0.5.0-it' "$work/out")"
check 'jobs carry on meanwhile' yes "$(kill -0 "$sup" 2>/dev/null && echo yes || echo no)"
publish 0.5.0-it
# Five minutes, made short: the record is aged instead.
sed -i.bak 's/^epoch .*/epoch   = 1/' "$root/state/update.state" && rm -f "$root/state/update.state.bak"
wait_until 90 is_version 0.5.0-it
check 'once it is there, the retry takes it' 0.5.0-it "$(version_of)"
[ "$(version_of)" = 0.5.0-it ] || explain

# --- a release that does not run: rolled back, not tried again ---------------------------------

variant 0.5.0-it 0.9.0-it "printf '#!/usr/bin/env bash\nexit 1\n' > vigil"
set_version "$cfg" 0.9.0-it
wait_until 90 is_result 0.9.0-it failed
check 'a release that does not run: recorded as failed' failed "$(update_value result)"
check 'the working version stays' 0.5.0-it "$(version_of)"
check 'and runs' 'Vigil 0.5.0-it' "$(vigil version)"
check 'the reason is the installer''s' 1 "$(update_value reason | grep -c 'went back to the version that was installed')"
wait_until 20 sh -c "cat '$root'/logs/supervisor/2*.log | grep -q 'Vigil 0.9.0-it, which the configuration asks for, could not be installed'"
check 'logged as an error' 1 "$(sup_log | grep -c 'ERROR supervisor Vigil 0.9.0-it, which the configuration asks for, could not be installed: .*; staying on 0.5.0-it until the configuration names another version')"
at=$(update_value epoch)
sleep 8
check 'not tried again' "$at" "$(update_value epoch)"
check 'started once' 1 "$(sup_log | grep -c 'to 0.9.0-it, as the configuration asks')"
vigil status > "$work/out" 2>&1
check 'status shows it' 1 "$(grep -c 'could not be installed: .*; not tried again until the version changes' "$work/out")"
check 'no app.old is left' no "$([ -e "$root/app.old" ] && echo yes || echo no)"

# --- back past a data format change: refused -----------------------------------------------

variant 0.5.0-it 0.6.0-it "mkdir -p migrations && printf 'exit 0\n' > migrations/2.sh && printf 'exit 0\n' > migrations/2.ps1"
set_version "$cfg" 0.6.0-it
wait_until 90 is_version 0.6.0-it
check 'a release with a new data format' 0.6.0-it "$(version_of)"
wait_until 20 sh -c "[ \"\$(cat '$root/state/format' 2>/dev/null)\" = 2 ]"
check 'migrates the data' 2 "$(cat "$root/state/format" 2>/dev/null)"
set_version "$cfg" 0.5.0-it
wait_until 120 is_result 0.5.0-it failed
check 'going back past it fails' failed "$(update_value result)"
check 'and changes nothing' 0.6.0-it "$(version_of)"
check 'the supervisor says why' 1 "$(sup_log | grep -c 'staying on Vigil 0.6.0-it, not reloading to 0.5.0-it')"
check 'the supervisor is still running' yes "$(kill -0 "$sup" 2>/dev/null && echo yes || echo no)"
[ "$(version_of)" = 0.6.0-it ] || explain

# --- the version from a fetched configuration ----------------------------------------------------

variant 0.6.0-it 0.7.0-it ':'
mkdir -p "$work/fleet/hosts"
set_version "$cfg" 0.7.0-it
cp "$cfg" "$work/fleet/hosts/vc.config"
cat > "$cfg.new" <<EOF
[vigil]
config_source = fleet
config_file   = hosts/vc.config

[source.fleet]
type        = local
path        = $work/fleet
check_every = 1s
EOF
mv "$cfg.new" "$cfg"
wait_until 90 is_version 0.7.0-it
check 'a fetched configuration moves it' 0.7.0-it "$(version_of)"
[ "$(version_of)" = 0.7.0-it ] || explain
vigil self update > "$work/out" 2>&1
check 'self update is refused by the fetched version' 1 "$(grep -c 'version = 0.7.0-it' "$work/out")"
vigil status > "$work/out" 2>&1
check 'status reads the backends of the fetched configuration' 0 "$(grep -c 'no backend' "$work/out")"
# Latest first, so that once the line is gone self update finds nothing to do.
printf '/releases/latest /releases/tag/v0.7.0-it\n' > "$work/mock/redirects"
set_version "$work/fleet/hosts/vc.config" -
wait_until 30 sh -c "! bash '$root/app/vigil' --root '$root' self update 2>&1 | grep -q 'set in the configuration'"
vigil self update > "$work/out" 2>&1
check 'removing the line gives self update back' 0 "$?"
check 'nothing moved meanwhile' 0.7.0-it "$(version_of)"

check 'no run crashed' 0 "$(sup_log | grep -c 'crashed')"
check 'the supervisor ran throughout' yes "$(kill -0 "$sup" 2>/dev/null && echo yes || echo no)"
[ "$fail" -eq 0 ] || explain
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
