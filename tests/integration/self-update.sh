#!/usr/bin/env bash
#
# Integration test: vigil self update (SPECIFICATION.md 18.7) on Linux and
# macOS, against mock-files.py as the release server, with releases built by
# tools/release/package.sh. Finding the latest release, updating, leaving
# config/ and scripts/ alone, refusing whatever does not verify, and going
# back when a new version does not run. With sudo without a password, as on
# CI runners, a running system service is updated too.
#
# HOME is a throwaway folder, so nothing of the account's own is touched.
#
# Needs python3 (or python).
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-update-it.XXXXXX")
work=$(cd "$work" && pwd)
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

printf 'bash %s on %s\n' "$BASH_VERSION" "$(uname -s)"
python=''
for p in python3 python; do
    if "$p" -c 'import http.server' > /dev/null 2>&1; then
        python=$p
        break
    fi
done
[ -n "$python" ] || { echo "needs python3"; exit 1; }

# Publishes release $1 on the mock, and makes it the latest.
publish() {
    local d="$www/releases/download/v$1"
    mkdir -p "$d" "$www/releases/tag"
    bash "$repo/tools/release/package.sh" "$1" "$d" > /dev/null || { printf 'packaging failed\n'; exit 1; }
    : > "$www/releases/tag/v$1"
    latest "$1"
}
latest() { printf '/releases/latest /releases/tag/v%s\n' "$1" > "$work/mock/redirects"; }

version_of() { cat "$root/app/VERSION" 2> /dev/null; }
vigil() { bash "$root/app/vigil" --root "$root" "$@"; }

mkdir -p "$work/mock/www" "$work/home"
www=$work/mock/www
case $(uname -s) in
    MINGW* | MSYS* | CYGWIN*) mockdir=$(cygpath -m "$work/mock") ;;
    *) mockdir=$work/mock ;;
esac
"$python" "$here/mock-files.py" "$mockdir" 2> "$work/mock/stderr" &
mock_pid=$!
i=0
while [ ! -s "$work/mock/port" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
port=$(cat "$work/mock/port" 2>/dev/null)
check 'mock started' yes "$([ -n "$port" ] && echo yes || echo no)"
[ -n "$port" ] || { cat "$work/mock/stderr"; exit 1; }
export VIGIL_TEST_RELEASE_URL=http://127.0.0.1:$port
export HOME=$work/home

# --- a copy from the repository -----------------------------------------------

bash "$repo/app/vigil" version > "$work/out" 2>&1
check 'version: a repository copy says so' 1 "$(grep -c 'from the repository' "$work/out")"
bash "$repo/app/vigil" self update > "$work/out" 2>&1
check 'a repository copy is not updated' 1 "$?"
check 'saying why' 1 "$(grep -c 'update it with git' "$work/out")"

# --- the one-line path: the installer finds the latest release itself ----------------

publish 0.0.1-it
root=$work/root
sh "$www/releases/download/v0.0.1-it/install.sh" --user --prefix "$root" --instance it --backend file --no-service < /dev/null > "$work/out" 2>&1
rc=$?
check 'install from the latest release' 0 "$rc"
[ "$rc" -eq 0 ] || sed 's/^/        /' "$work/out"
check 'its version' 'Vigil 0.0.1-it' "$(vigil version)"

printf '# my change\n' >> "$root/config/vigil.config"
printf 'echo mine\n' > "$root/scripts/mine.sh"
cfg=$(cksum < "$root/config/vigil.config")

# --- nothing newer ----------------------------------------------------------------

vigil self update > "$work/out" 2>&1
check 'up to date: succeeds' 0 "$?"
check 'up to date: says so' 1 "$(grep -c 'nothing to do' "$work/out")"

# --- a newer release ------------------------------------------------------------------

publish 0.0.2-it
vigil self update --check > "$work/out" 2>&1
check '--check: succeeds' 0 "$?"
check '--check: names the new version' 1 "$(grep -c '0.0.2-it is available' "$work/out")"
check '--check: changes nothing' 0.0.1-it "$(version_of)"

# A job running across the update finishes, under the code it started with.
# (Not under Git Bash, where the running vigil would hold app/ in place.)
slow=0
case $(uname -s) in
    Linux | Darwin)
        slow=1
        printf 'sleep 8\necho finished slowly\n' > "$root/scripts/slow.sh"
        printf '\n[job.slow]\nfile = scripts/slow.sh\nrun_every = 3650d\n' >> "$root/config/vigil.config"
        cfg=$(cksum < "$root/config/vigil.config")
        vigil run slow > "$work/slow.out" 2>&1 &
        slow_pid=$!
        i=0
        while [ ! -f "$root/state/jobs/slow.state" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
        ;;
esac

vigil self update > "$work/out" 2>&1
rc=$?
check 'update succeeds' 0 "$rc"
[ "$rc" -eq 0 ] || sed 's/^/        /' "$work/out"
check 'the new version is installed' 0.0.2-it "$(version_of)"
if [ "$slow" = 1 ]; then
    wait "$slow_pid"
    check 'the running job finished' 1 "$(grep -c 'run end succeeded' "$root"/logs/jobs/slow/*.log)"
    check 'and ran once' 1 "$(grep -c 'run start' "$root"/logs/jobs/slow/*.log)"
fi
check 'the configuration is untouched' "$cfg" "$(cksum < "$root/config/vigil.config")"
check 'scripts are untouched' yes "$([ -f "$root/scripts/mine.sh" ] && echo yes)"
check 'no app.old or app.new is left' no "$([ -e "$root/app.old" ] || [ -e "$root/app.new" ] && echo yes || echo no)"
check 'no service was registered' 0 "$(vigil status 2>/dev/null | grep -c '^service: active')"
vigil precheck > /dev/null 2>&1
check 'precheck refuses the test release server' 1 "$?"

# --- a version on request, older included -------------------------------------------------

vigil self update --version 0.0.1-it > /dev/null 2>&1
check '--version goes back' 0.0.1-it "$(version_of)"
vigil self update --version 9.9.9 > "$work/out" 2>&1
check 'no such release: fails' 1 "$?"
check 'no such release: says so' 1 "$(grep -c 'cannot download' "$work/out")"
check 'no such release: nothing changed' 0.0.1-it "$(version_of)"

# --- what does not verify changes nothing ---------------------------------------------------

d=$www/releases/download/v0.0.2-it
cp "$d/install.sh" "$work/install.sh.good"
printf '\n# tampered\n' >> "$d/install.sh"
vigil self update > "$work/out" 2>&1
check 'a tampered installer is refused' 1 "$?"
check 'saying why' 1 "$(grep -c 'does not match its SHA256SUMS' "$work/out")"
check 'and nothing changed' 0.0.1-it "$(version_of)"
cp "$work/install.sh.good" "$d/install.sh"

cp "$d/vigil-0.0.2-it.tar.gz" "$work/good.tar.gz"
printf 'x' >> "$d/vigil-0.0.2-it.tar.gz"
vigil self update > "$work/out" 2>&1
check 'a tampered archive is refused' 1 "$?"
check 'saying why' 1 "$(grep -c 'SHA-256 mismatch' "$work/out")"
check 'and nothing changed' 0.0.1-it "$(version_of)"
cp "$work/good.tar.gz" "$d/vigil-0.0.2-it.tar.gz"

# --- a release that does not run: back to the one that does ------------------------------------

mkdir "$work/broken"
tar -xzf "$d/vigil-0.0.2-it.tar.gz" -C "$work/broken"
mv "$work/broken/vigil-0.0.2-it" "$work/broken/vigil-0.0.3-it"
printf '0.0.3-it\n' > "$work/broken/vigil-0.0.3-it/app/VERSION"
printf '#!/usr/bin/env bash\nexit 1\n' > "$work/broken/vigil-0.0.3-it/app/vigil"
d3=$www/releases/download/v0.0.3-it
mkdir -p "$d3"
tar -czf "$d3/vigil-0.0.3-it.tar.gz" -C "$work/broken" vigil-0.0.3-it
cp "$repo/install.sh" "$d3/"
(cd "$d3" && { sha256sum vigil-0.0.3-it.tar.gz install.sh 2>/dev/null || shasum -a 256 vigil-0.0.3-it.tar.gz install.sh; } | sed 's/ \*/  /' > SHA256SUMS)
: > "$www/releases/tag/v0.0.3-it"
latest 0.0.3-it
vigil self update > "$work/out" 2>&1
check 'a release that does not run fails' 1 "$?"
check 'saying why' 1 "$(grep -c 'went back to the version that was installed' "$work/out")"
check 'the old version is back' 0.0.1-it "$(version_of)"
check 'and works' 'Vigil 0.0.1-it' "$(vigil version)"
check 'no app.old is left' no "$([ -e "$root/app.old" ] && echo yes || echo no)"

# --- runs waiting for a slot survive a restart -------------------------------------------------

printf 'echo waited\n' > "$root/scripts/waited.sh"
printf '\n[job.waited]\nfile = scripts/waited.sh\nrun_every = 3650d\n' >> "$root/config/vigil.config"
mkdir -p "$root/state"
printf 'pending= waited gone\nqueued=\n' > "$root/state/pending"
vigil supervise --once > /dev/null 2>&1
i=0
while [ ! -f "$root/state/jobs/waited.state" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
check 'a waiting run is picked up' yes "$([ -f "$root/state/jobs/waited.state" ] && echo yes || echo no)"
check 'and the list is cleared' no "$([ -e "$root/state/pending" ] && echo yes || echo no)"

# --- update notices ----------------------------------------------------------------------------

latest 0.0.2-it
export XDG_CACHE_HOME=$work/cache
vigil version > "$work/out" 2> "$work/err"
check 'notice: stdout stays clean' 'Vigil 0.0.1-it' "$(cat "$work/out")"
i=0
while [ ! -f "$XDG_CACHE_HOME/vigil/update-check" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
vigil version > /dev/null 2> "$work/err"
check 'notice: names the new version' 1 "$(grep -c 'Vigil 0.0.2-it is available' "$work/err")"
VIGIL_NO_UPDATE_CHECK=1 vigil version > /dev/null 2> "$work/err"
check 'notice: can be turned off' 0 "$(wc -c < "$work/err" | tr -d ' ')"
: > "$work/mock/requests.log"
vigil version > /dev/null 2>&1
sleep 2
check 'notice: asks at most once a day' 0 "$(grep -c '"path"' "$work/mock/requests.log")"

# --- hot reload: a supervisor that is running, whoever started it --------------------------------

case $(uname -s) in
    Linux | Darwin)
        vigil self update --version 0.0.1-it > /dev/null 2>&1
        vigil supervise > /dev/null 2>&1 &
        sup=$!
        i=0
        while [ "$(vigil version --supervisor 2>/dev/null)" != 0.0.1-it ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
        check 'reload: the supervisor is running' 0.0.1-it "$(vigil version --supervisor)"
        vigil self update --version 0.0.2-it > "$work/out" 2>&1
        check 'reload: updated' 0 "$?"
        i=0
        while [ "$(vigil version --supervisor 2>/dev/null)" != 0.0.2-it ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
        check 'reload: it came up as the new version' 0.0.2-it "$(vigil version --supervisor)"
        check 'reload: the same process' yes "$(kill -0 "$sup" 2>/dev/null && echo yes || echo no)"
        kill "$sup" 2>/dev/null
        wait "$sup" 2>/dev/null
        check 'reload: it says so' 1 "$(grep -hc 'reloading: Vigil 0.0.1-it to 0.0.2-it' "$root"/logs/supervisor/2*.log | sort -n | tail -1)"
        ;;
esac

# --- another account's install ---------------------------------------------------------------

latest 0.0.2-it
if [ "$(uname -s)" = Linux ] && sudo -n true 2> /dev/null; then
    sudo chown -R root "$root/app"
    vigil self update > "$work/out" 2>&1
    check "another account's install is refused" 1 "$?"
    check 'saying who should' 1 "$(grep -c 'run this as that account' "$work/out")"
    sudo chown -R "$(id -u)" "$root/app"
fi

# --- a running system service -----------------------------------------------------------------

if ! sudo -n true 2> /dev/null; then
    printf 'SKIP system mode: needs sudo without a password\n'
else
    sys=/opt/vigil-update-$$
    sudo VIGIL_TEST_RELEASE_URL="$VIGIL_TEST_RELEASE_URL" sh "$www/releases/download/v0.0.1-it/install.sh" --system --prefix "$sys" --version 0.0.1-it --instance it-sys < /dev/null > "$work/out" 2>&1
    rc=$?
    check 'system: installed' 0 "$rc"
    [ "$rc" -eq 0 ] || sed 's/^/        /' "$work/out"
    active() { sudo /usr/local/bin/vigil status 2> /dev/null | sed -n '1s/^service: \([a-z]*\).*/\1/p'; }
    check 'system: the service is active' active "$(active)"
    pid_of() { sudo sed -n 's/^pid = //p' "$sys/state/supervisor.lock"; }
    pid1=$(pid_of)
    /usr/local/bin/vigil self update > "$work/out" 2>&1
    check 'system: refused without sudo' 1 "$?"
    sudo VIGIL_TEST_RELEASE_URL="$VIGIL_TEST_RELEASE_URL" /usr/local/bin/vigil self update > "$work/out" 2>&1
    rc=$?
    check 'system: updated' 0 "$rc"
    [ "$rc" -eq 0 ] || sed 's/^/        /' "$work/out"
    check 'system: the new version' 0.0.2-it "$(cat "$sys/app/VERSION")"
    check 'system: the service is active after' active "$(active)"
    check 'system: not restarted: the same process' "$pid1" "$(pid_of)"
    latest 0.0.3-it
    sudo VIGIL_TEST_RELEASE_URL="$VIGIL_TEST_RELEASE_URL" /usr/local/bin/vigil self update > "$work/out" 2>&1
    check 'system: a release that does not run fails' 1 "$?"
    check 'system: the old version is back' 0.0.2-it "$(cat "$sys/app/VERSION")"
    check 'system: and its service is active' active "$(active)"
    sudo /usr/local/bin/vigil uninstall --yes > /dev/null 2>&1
    check 'system: uninstall succeeds' 0 "$?"
    [ "$(uname -s)" = Linux ] && sudo userdel vigil 2> /dev/null
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
