#!/usr/bin/env bash
#
# Integration test: sources and the fetcher (SPECIFICATION.md 6.8, 6.9,
# 16.5) on Linux and macOS. Scripts come from a Git repository and an HTTPS
# file server (mock-files.py, plain http on this host), a local directory
# and, when sshd is installed, an SFTP server run as this user. Each is
# fetched, verified and run from the cache; a remote configuration is
# fetched and followed; and whatever fails, the last valid configuration
# keeps running.
#
# Needs git and python3 (or python); sshd for the sftp part.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
vigil_cmd=$repo/app/vigil
root=${TMPDIR:-/tmp}/vigil-fetch.$$
pass=0
fail=0
mock_pid=''
sshd_pid=''

check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"
    fi
}

yes_no() { if "$@" > /dev/null 2>&1; then echo yes; else echo no; fi; }

vigil() {
    "$BASH" "$vigil_cmd" --root "$root" "$@"
}

# One supervisor tick, then wait (up to 60s) for the fetcher and sender it
# may have started.
tick() {
    local i=0
    vigil supervise --once > /dev/null 2>&1
    while ls "$root/state/locks" 2>/dev/null | grep '^vigil_\(fetch\|sender\)\.' > /dev/null; do
        i=$((i + 1))
        [ "$i" -ge 120 ] && break
        sleep 0.5
    done
}

# A fetch now, whatever is due, then a tick that loads what it activated.
fetch() {
    rm -f "$root/state/fetch.next"
    tick
    tick
}

revision() { sed -n 's/^revision *= *//p' "$root/state/config.active" 2>/dev/null; }
fetch_status() { sed -n 's/^status *= *//p' "$root/state/jobs/vigil_fetch.state" 2>/dev/null; }
fetch_reason() { sed -n 's/^reason *= *//p' "$root/state/jobs/vigil_fetch.state" 2>/dev/null; }

# Runs job $1 now; prints its outcome and the metric line its script wrote.
run() {
    local out
    out=$(vigil run "$1" 2>&1)
    printf '%s|%s' "${out%% in *}" "$(grep -h ' out metric ' "$root/logs/jobs/$1/"*.log 2>/dev/null | tail -1 | sed 's/.* out //')"
}

# Commits everything in the work tree and publishes it to the mock.
publish() {
    (
        cd "$root/work" &&
            git add -A &&
            git -c user.name=vigil -c user.email=vigil@example.com commit -q -m "$1" &&
            { [ -z "${2-}" ] || git tag "$2"; } &&
            git push -q --tags "$root/mock/www/ops.git" HEAD:main 2>/dev/null &&
            git --git-dir="$root/mock/www/ops.git" update-server-info
    )
}

cleanup() {
    [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null
    [ -n "$sshd_pid" ] && kill "$sshd_pid" 2>/dev/null
    rm -rf "$root"
}
trap cleanup EXIT

printf 'bash %s\n' "$BASH_VERSION"
python=''
for p in python3 python; do
    if "$p" -c 'import http.server' > /dev/null 2>&1; then
        python=$p
        break
    fi
done
[ -n "$python" ] || { echo "needs python3"; exit 1; }
command -v git > /dev/null 2>&1 || { echo "needs git"; exit 1; }
mkdir -p "$root/config" "$root/mock/www/files" "$root/work/checks" "$root/work/hosts" "$root/share"
root=$(cd "$root" && pwd)

case $(uname -s) in
    MINGW* | MSYS* | CYGWIN*) mockdir=$(cygpath -m "$root/mock") ;;
    *) mockdir=$root/mock ;;
esac
"$python" "$here/mock-files.py" "$mockdir" 2> "$root/mock/stderr" &
mock_pid=$!
i=0
while [ ! -s "$root/mock/port" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
port=$(cat "$root/mock/port" 2>/dev/null)
check "mock started" yes "$([ -n "$port" ] && echo yes || echo no)"
if [ -z "$port" ]; then
    cat "$root/mock/stderr"
    exit 1
fi
url=http://127.0.0.1:$port

# The repository: a tag v1, served by Git's dumb HTTP protocol.
(cd "$root/work" && git init -q && git symbolic-ref HEAD refs/heads/main && git config core.autocrlf false)
printf 'echo "metric hello 1"\n' > "$root/work/checks/hello.sh"
(cd "$root/work" && git add -A && git -c user.name=vigil -c user.email=vigil@example.com commit -q -m one && git tag v1)
git clone -q --bare "$root/work" "$root/mock/www/ops.git"
git --git-dir="$root/mock/www/ops.git" update-server-info

# The file server, which wants a token, and the local directory.
token="files-token-$$"
export VIGIL_IT_TOKEN=$token
printf '/files/ X-Token: %s' "$token" > "$root/mock/require"
printf 'echo "metric single 2"\n' > "$root/mock/www/files/single.sh"
printf 'echo "metric local 3"\n' > "$root/share/local.sh"
single_sha=$(sha256sum "$root/mock/www/files/single.sh" 2>/dev/null || shasum -a 256 "$root/mock/www/files/single.sh")
single_sha=${single_sha%% *}
local_sha=$(sha256sum "$root/share/local.sh" 2>/dev/null || shasum -a 256 "$root/share/local.sh")
local_sha=${local_sha%% *}

base_config() {
    cat <<EOF
[vigil]
instance = fe

[scheduler]
tick = 1s

[backend.file]
path = metrics/vigil.prom

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

EOF
}

local_config() {
    base_config
    cat <<EOF
[source.ops]
type = git
url  = ${1:-$url/ops.git}
ref  = ${2:-v1}

[source.files]
type         = https
url          = $url/files/
header_name  = X-Token
header_value = env:VIGIL_IT_TOKEN

[source.share]
type        = local
path        = share
check_every = 1s

[job.from_git]
source    = ops
file      = checks/hello.sh
run_every = 3650d

[job.from_https]
source    = files
file      = single.sh
sha256    = $single_sha
run_every = 3650d

[job.from_local]
source    = share
file      = local.sh
sha256    = $local_sha
run_every = 3650d
EOF
}

local_config > "$root/config/vigil.config"

# Before any fetch: precheck passes, and nothing runs.
check "precheck before the first fetch" 0 "$(vigil precheck > /dev/null 2>&1; echo $?)"
tick
check "waiting for the first fetch" yes "$(yes_no grep -q 'waiting for the first fetch' "$root/logs/supervisor/jobs.log")"
tick

# Fetched, verified and activated.
check "activated" yes "$(yes_no test -f "$root/state/config.active")"
rev1=$(revision)
check "revision is 12 hex digits" yes "$(yes_no expr "$rev1" : '[0-9a-f]\{12\}$')"
check "jobs.log shows the revision" yes "$(yes_no grep -q "revision $rev1 (local)" "$root/logs/supervisor/jobs.log")"
check "git: unpacked at its commit" yes "$(yes_no test -f "$root/cache/ops/$(git --git-dir="$root/mock/www/ops.git" rev-parse v1)/checks/hello.sh")"
check "git: run from the cache" 'from_git: succeeded|metric hello 1' "$(run from_git)"
check "https: run from the cache" 'from_https: succeeded|metric single 2' "$(run from_https)"
check "https: the header was sent" yes "$(yes_no grep -q "\"X-Token\": \"$token\"" "$root/mock/requests.log")"
check "local: run from the cache" 'from_local: succeeded|metric local 3' "$(run from_local)"
check "precheck once fetched" 0 "$(vigil precheck > /dev/null 2>&1; echo $?)"

# A pinned script that changed in its source: the verified copy stays.
printf 'echo "metric local 30"\n' > "$root/share/local.sh"
fetch
check "pinned: revision unchanged" "$rev1" "$(revision)"
check "pinned: the verified copy runs" 'from_local: succeeded|metric local 3' "$(run from_local)"
check "pinned: the change is logged" yes "$(yes_no grep -rq 'local.sh no longer matches its sha256' "$root/logs/jobs/vigil_fetch")"
printf 'echo "metric local 3"\n' > "$root/share/local.sh"

# A new tag: the new version is fetched and runs.
printf 'echo "metric hello 2"\n' > "$root/work/checks/hello.sh"
publish two v2
local_config "$url/ops.git" v2 > "$root/config/vigil.config"
fetch
rev2=$(revision)
check "new tag: new revision" yes "$([ -n "$rev2" ] && [ "$rev2" != "$rev1" ] && echo yes || echo no)"
check "new tag: new version runs" 'from_git: succeeded|metric hello 2' "$(run from_git)"

# A digest mismatch rejects the candidate; the last valid one keeps running.
{
    local_config "$url/ops.git" v2
    printf '\n[job.bad]\nsource    = files\nfile      = single.sh\nsha256    = %s\nrun_every = 3650d\n' "$(printf '%064d' 0)"
} > "$root/config/vigil.config"
fetch
check "mismatch: fetch failed" failed "$(fetch_status)"
check "mismatch: reason" yes "$(fetch_reason | grep -q 'source.files: single.sh does not match its sha256' && echo yes || echo no)"
check "mismatch: revision unchanged" "$rev2" "$(revision)"
check "mismatch: jobs.log says so" yes "$(yes_no grep -q 'last fetch failed' "$root/logs/supervisor/jobs.log")"
check "mismatch: the active configuration runs" 'from_git: succeeded|metric hello 2' "$(run from_git)"
tick
check "mismatch: failure counted" yes "$(yes_no grep -Eq '^vigil_source_failures_total[{].*(reason="digest".*source="files"|source="files".*reason="digest")' "$root/metrics/vigil.prom")"
check "metrics: the active revision" yes "$(yes_no grep -q "^vigil_config_info{.*revision=\"$rev2\"" "$root/metrics/vigil.prom")"
check "metrics: activations counted" yes "$(yes_no grep -q '^vigil_config_activated_total{' "$root/metrics/vigil.prom")"
check "metrics: check age of each source" yes "$(yes_no grep -q '^vigil_source_check_age{.*source="ops"' "$root/metrics/vigil.prom")"

# An unreachable source: nothing changes.
local_config "http://127.0.0.1:1/ops.git" v2 > "$root/config/vigil.config"
fetch
check "unreachable: fetch failed" failed "$(fetch_status)"
check "unreachable: revision unchanged" "$rev2" "$(revision)"
check "unreachable: still runs" 'from_git: succeeded|metric hello 2' "$(run from_git)"

# A symbolic link out of the repository is refused.
blob=$(printf '../../outside' | git --git-dir="$root/work/.git" hash-object -w --stdin)
(
    cd "$root/work" &&
        git update-index --add --cacheinfo "120000,$blob,checks/escape" &&
        git -c user.name=vigil -c user.email=vigil@example.com commit -q -m three &&
        git tag v3 &&
        git push -q --tags "$root/mock/www/ops.git" HEAD:main 2>/dev/null &&
        git --git-dir="$root/mock/www/ops.git" update-server-info
)
local_config "$url/ops.git" v3 > "$root/config/vigil.config"
fetch
check "symlink: refused" yes "$(fetch_reason | grep -q 'symbolic link pointing outside' && echo yes || echo no)"
check "symlink: revision unchanged" "$rev2" "$(revision)"
(cd "$root/work" && git rm -q --cached checks/escape && git -c user.name=vigil -c user.email=vigil@example.com commit -q -m unlink)
local_config "$url/ops.git" v2 > "$root/config/vigil.config"
fetch
check "back to v2" "$rev2" "$(revision)"

# The cache deleted: FILE MISSING until it is fetched again.
rm -rf "$root/cache"
tick
check "cache deleted: FILE MISSING" yes "$(yes_no grep -q 'FILE MISSING' "$root/logs/supervisor/jobs.log")"
fetch
check "cache deleted: fetched again" 'from_git: succeeded|metric hello 2' "$(run from_git)"

# Remote configuration (6.8): a pointer file, following a branch.
cat > "$root/work/hosts/h1.config" <<EOF
$(base_config)
[source.scripts]
type        = git
url         = $url/ops.git
ref         = main
check_every = 1s

[job.remote_hello]
source    = scripts
file      = checks/hello.sh
run_every = 3650d
EOF
publish four
cat > "$root/config/vigil.config" <<EOF
[vigil]
config_source = central
config_file   = hosts/h1.config

[source.central]
type        = git
url         = $url/ops.git
ref         = main
check_every = 1s
EOF
fetch
rev3=$(revision)
check "remote: activated" "source.central hosts/h1.config" "$(sed -n 's/^origin *= *//p' "$root/state/config.active")"
check "remote: job runs" 'remote_hello: succeeded|metric hello 2' "$(run remote_hello)"
check "remote: precheck" 0 "$(vigil precheck > /dev/null 2>&1; echo $?)"
check "remote: branch reported as unpinned" yes "$(yes_no grep -rq 'W_SCRIPT_UNPINNED' "$root/logs/jobs/vigil_fetch")"

# A change on the branch is picked up at the next check.
printf 'echo "metric hello 5"\n' > "$root/work/checks/hello.sh"
publish five
sleep 2
tick
tick
check "branch: new revision" yes "$([ "$(revision)" != "$rev3" ] && echo yes || echo no)"
check "branch: new version runs" 'remote_hello: succeeded|metric hello 5' "$(run remote_hello)"
rev4=$(revision)

# A fetched configuration may not say where configuration comes from.
printf '\n[vigil]\nstate_dir = elsewhere\n' >> "$root/work/hosts/h1.config"
sed -i.bak '1,2d' "$root/work/hosts/h1.config" && rm -f "$root/work/hosts/h1.config.bak"
publish six
fetch
check "not from source: rejected" failed "$(fetch_status)"
check "not from source: reported" yes "$(yes_no grep -rq 'E_NOT_FROM_SOURCE' "$root/logs/jobs/vigil_fetch")"
check "not from source: revision unchanged" "$rev4" "$(revision)"

# sftp: an OpenSSH server run as this user, its host key known only
# through VIGIL_TEST_SSH_CONFIG.
sshd=''
for p in /usr/sbin/sshd /usr/local/sbin/sshd "$(command -v sshd 2>/dev/null)"; do
    [ -n "$p" ] && [ -x "$p" ] && { sshd=$p; break; }
done
if [ -z "$sshd" ] || ! command -v sftp > /dev/null 2>&1 || ! command -v ssh-keygen > /dev/null 2>&1; then
    printf '  SKIP  sftp: no sshd here\n'
else
    s=$root/ssh
    mkdir -p "$s" "$root/sftp"
    chmod 700 "$s"
    ssh-keygen -q -t ed25519 -N '' -f "$s/host" && ssh-keygen -q -t ed25519 -N '' -f "$s/user"
    cp "$s/user.pub" "$s/authorized_keys"
    sport=$((20000 + $$ % 20000))
    cat > "$s/sshd_config" <<EOF
Port $sport
ListenAddress 127.0.0.1
HostKey $s/host
AuthorizedKeysFile $s/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile $s/sshd.pid
Subsystem sftp internal-sftp
EOF
    "$sshd" -D -e -f "$s/sshd_config" 2> "$s/sshd.log" &
    sshd_pid=$!
    printf '[127.0.0.1]:%s %s\n' "$sport" "$(cut -d' ' -f1-2 "$s/host.pub")" > "$s/known_hosts"
    cat > "$s/config" <<EOF
Host 127.0.0.1
    IdentityFile $s/user
    UserKnownHostsFile $s/known_hosts
    IdentitiesOnly yes
EOF
    export VIGIL_TEST_SSH_CONFIG=$s/config
    printf 'echo "metric sftp 4"\n' > "$root/sftp/remote.sh"
    sftp_sha=$(sha256sum "$root/sftp/remote.sh" 2>/dev/null || shasum -a 256 "$root/sftp/remote.sh")
    sftp_sha=${sftp_sha%% *}
    sleep 1
    {
        base_config
        printf '[source.box]\ntype = sftp\nhost = 127.0.0.1\nport = %s\nuser = %s\npath = %s\n\n' "$sport" "$(id -un)" "$root/sftp"
        printf '[job.from_sftp]\nsource    = box\nfile      = remote.sh\nsha256    = %s\nrun_every = 3650d\n' "$sftp_sha"
    } > "$root/config/vigil.config"
    fetch
    check "sftp: activated" succeeded "$(fetch_status)"
    check "sftp: run from the cache" 'from_sftp: succeeded|metric sftp 4' "$(run from_sftp)"
    # An unknown host key is never trusted.
    : > "$s/known_hosts"
    rm -rf "$root/cache/box"
    fetch
    check "sftp: unknown host key refused" failed "$(fetch_status)"
    [ "$fail" -gt 0 ] && cat "$s/sshd.log"
    unset VIGIL_TEST_SSH_CONFIG
fi

if [ "$fail" -gt 0 ]; then
    printf '\nfetch log:\n'
    cat "$root/logs/jobs/vigil_fetch/"*.log 2>/dev/null | tail -40
    printf '\njobs.log:\n'
    cat "$root/logs/supervisor/jobs.log"
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
