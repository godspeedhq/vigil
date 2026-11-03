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
# run-source.sh - tests Vigil's sources (spec 6.8, 6.9, 16.5) against a test
# server from compose.sources.yaml (backlog task 25).
#
#   scripts/start.sh git-gitea
#   scripts/run-source.sh git-gitea
#
#   git-gitea  Vigil's git source, over HTTPS (a read-only collaborator,
#              through a Git credential helper) and SSH (a read-only deploy
#              key)
#
# Needs .sources/ and .secrets/tls/ca.pem, which start.sh makes; on another
# host, copy them, keeping their paths, and reach the server's ports on
# 127.0.0.1 there (SSH tunnels; see README.md). Needs git.
#
# Vigil is set up in a temporary folder and driven as fetch.sh drives it:
# supervisor ticks, which start the fetcher. Nothing counts as passed on a
# connection or a download alone: each check reads Vigil's own evidence,
# that is the fetcher's status and reason, the activation record, the cached
# file's SHA-256 against the fixture's, and the job's run.
#
# The test CA is trusted as an operator trusts a private CA, since a source
# has no ca_file: git's http.sslCAInfo, in a Git configuration of the
# test's own (GIT_CONFIG_GLOBAL), with the credential helper. Over SSH, the
# key and known_hosts come through GIT_SSH_COMMAND, StrictHostKeyChecking on.
#
# Results: PASS, FAIL, NOT RUN (with why). Linux and macOS. Exit code: 0
# when every check that ran passed.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

t=${1-}
case $t in git-gitea) ;; *) die 'usage: run-source.sh git-gitea' ;; esac
src=$bk_dir/.sources
ca=$bk_dir/.secrets/tls/ca.pem
fx=$bk_dir/fixtures/sources
envf=$src/${t#*-}.env
[ -f "$envf" ] && [ -f "$ca" ] || die "no .sources/${t#*-}.env or .secrets/tls/ca.pem: run scripts/start.sh $t first, or copy them from the host that did"
command -v git > /dev/null 2>&1 || die 'needs git'
set -a
# shellcheck disable=SC1090
. "$envf"
set +a
sha() { if command -v sha256sum > /dev/null 2>&1; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi | cut -d' ' -f1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-source.XXXXXX") || exit 1
root=$work/root
trap 'rm -rf "$work"' EXIT
trap 'exit 1' TERM INT HUP
mkdir -p "$root/config" && cp -R "$bk_repo/app" "$root/" || exit 1

pass=0 fail=0 notrun=0
ok() { printf '  PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi; }
contains() { case $3 in *"$2"*) ok "$1: $3" ;; *) bad "$1: expected [$2] in [$3]" ;; esac; }

vigil() { bash "$root/app/vigil" --root "$root" "$@" < /dev/null; }
# One supervisor tick, then wait (up to 60 s) for the fetcher it started.
tick() {
    local i=0
    vigil supervise --once >> "$work/vigil.out" 2>&1
    while ls "$root/state/locks" 2> /dev/null | grep -q '^vigil_fetch\.'; do
        i=$((i + 1))
        [ "$i" -ge 120 ] && break
        sleep 0.5
    done
}
# A fetch now, whatever is due, then a tick that loads what it activated.
fetch() { rm -f "$root/state/fetch.next"; tick; tick; }
revision() { sed -n 's/^revision *= *//p' "$root/state/config.active" 2> /dev/null; }
fetch_status() { sed -n 's/^status *= *//p' "$root/state/jobs/vigil_fetch.state" 2> /dev/null; }
fetch_reason() { sed -n 's/^reason *= *//p' "$root/state/jobs/vigil_fetch.state" 2> /dev/null; }
# Runs job $1 now; prints the metric line its script wrote, or what went wrong.
run() {
    local out
    out=$(vigil run "$1" 2>&1)
    printf '%s\n' "$out" >> "$work/vigil.out"
    grep -h ' out metric ' "$root/logs/jobs/$1/"*.log 2> /dev/null | tail -1 | sed 's/.* out metric //' | grep . || printf '%s' "${out%% in *}"
}
# The SHA-256 of the cached copy the activation record names for $1, the
# job's file; empty when none.
cached_sha() {
    local line f
    line=$(grep "^script *= *[^ ]* [^ ]* [^ ]* $1\$" "$root/state/config.active" 2> /dev/null | tail -1)
    [ -n "$line" ] || return 0
    set -- $line
    f=$(ls -d "$root/cache/$3/$4/$6" 2> /dev/null || true)
    [ -f "$f" ] && sha "$f"
}

base() {
    printf '[vigil]\ninstance = source-test\n\n[scheduler]\ntick = 1s\n\n[backend.file]\npath = metrics/vigil.prom\n\n'
    printf '[runner.sh]\ncommand = /bin/sh\n\n[runners]\n.sh = sh\n\n'
}
# A local configuration with one source $1 (its lines, \n between) and one
# job running file $2 from it.
scripts_config() {
    {
        base
        printf '[source.repo]\n%b\ncheck_every = 1s\n\n' "$1"
        printf '[job.check]\nsource    = repo\nfile      = %s\nrun_every = 3650d\n' "$2"
    } > "$root/config/vigil.config"
}

# ---- git-gitea ------------------------------------------------------------
git_suite() {
    local v1_sha v2_sha rev before
    v1_sha=$(sha "$fx/scripts/check-v1.sh")
    v2_sha=$(sha "$fx/scripts/check-v2.sh")
    # Git trusts the test CA, and logs in as the reader, through a
    # configuration of the test's own.
    export GIT_CONFIG_GLOBAL=$work/gitconfig
    printf '[http]\n\tsslCAInfo = %s\n[credential]\n\thelper = store --file=%s\n' "$ca" "$work/creds" > "$GIT_CONFIG_GLOBAL"
    creds() { (umask 077 && printf 'https://%s:%s@127.0.0.1%%3a3443\n' "$1" "$2" > "$work/creds"); }
    creds "$SRC_READER" "$SRC_READER_PW"

    printf '\n%s, git over HTTPS\n' "$t"
    scripts_config "type = git\nurl  = $SRC_HTTPS\nref  = v1" checks/check.sh
    fetch
    check 'tag v1: fetched and activated' succeeded "$(fetch_status)"
    check 'tag v1: the job runs version 1' 'source_check 1' "$(run check)"
    check 'tag v1: the cached file is the fixture' "$v1_sha" "$(cached_sha checks/check.sh)"
    rev=$(revision)

    scripts_config "type = git\nurl  = $SRC_HTTPS\nref  = $SRC_V2" checks/check.sh
    fetch
    check 'a commit id (v2): the job runs version 2' 'source_check 2' "$(run check)"
    check 'a commit id (v2): the cached file is the fixture' "$v2_sha" "$(cached_sha checks/check.sh)"

    scripts_config "type = git\nurl  = $SRC_HTTPS\nref  = test" checks/check.sh
    fetch
    check 'branch test: the job runs version 1' 'source_check 1' "$(run check)"
    contains 'branch test: reported unpinned' W_SCRIPT_UNPINNED "$(cat "$root/logs/jobs/vigil_fetch/"*.log 2> /dev/null | grep -o 'W_SCRIPT_UNPINNED' | head -1)"

    # A branch that moves: the update is found at the next check.
    scripts_config "type = git\nurl  = $SRC_HTTPS\nref  = moving" checks/check.sh
    fetch
    check 'branch moving at v1: the job runs version 1' 'source_check 1' "$(run check)"
    before=$(revision)
    move moving "$SRC_V2"
    fetch
    check 'branch moving to v2: the update is found and the job runs version 2' 'source_check 2' "$(run check)"
    check 'branch moving to v2: a new revision' yes "$([ -n "$(revision)" ] && [ "$(revision)" != "$before" ] && echo yes || echo no)"
    move moving "$SRC_V1"

    # Failures: nothing changes, and the last good configuration keeps running.
    scripts_config "type = git\nurl  = $SRC_HTTPS\nref  = v1" checks/check.sh
    fetch
    rev=$(revision)
    failure() {
        fetch
        check "$1: the fetch fails" failed "$(fetch_status)"
        contains "$1: says why" "$2" "$(fetch_reason)"
        check "$1: the last good configuration stays active" "$rev" "$(revision)"
        check "$1: and its job still runs" 'source_check 1' "$(run check)"
    }
    scripts_config "type = git\nurl  = $SRC_HTTPS\nref  = nosuch" checks/check.sh
    failure 'a missing ref' "ref 'nosuch' not found"
    scripts_config "type = git\nurl  = $SRC_HTTPS\nref  = v1" checks/nosuch.sh
    failure 'a missing file' 'nosuch.sh'
    scripts_config "type = git\nurl  = https://127.0.0.1:3443/vigil-admin/no-such-repo.git\nref  = v1" checks/check.sh
    failure 'a missing repository' 'git fetch failed'
    scripts_config "type = git\nurl  = $SRC_HTTPS\nref  = link" checks/check.sh
    failure 'a symbolic link out of the tree' 'symbolic link pointing outside'
    creds "$SRC_READER" wrong-password
    scripts_config "type = git\nurl  = $SRC_HTTPS\nref  = v2" checks/check.sh
    failure 'a wrong password' 'git fetch failed'
    creds "$SRC_READER" "$SRC_READER_PW"

    printf '\n%s, git over SSH\n' "$t"
    ssh_with() { export GIT_SSH_COMMAND="ssh -i $1 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$2"; }
    ssh_with "$src/ssh/vigil_sources" "$src/gitea_known_hosts"
    scripts_config "type = git\nurl  = $SRC_SSH\nref  = v1" checks/check.sh
    fetch
    check 'deploy key, tag v1: fetched and activated' succeeded "$(fetch_status)"
    check 'deploy key, tag v1: the job runs version 1' 'source_check 1' "$(run check)"
    rev=$(revision)
    ssh_with "$src/ssh/vigil_sources_wrong" "$src/gitea_known_hosts"
    scripts_config "type = git\nurl  = $SRC_SSH\nref  = v2" checks/check.sh
    failure 'a key the server does not know' 'git fetch failed'
    : > "$work/empty_known_hosts"
    ssh_with "$src/ssh/vigil_sources" "$work/empty_known_hosts"
    failure 'a host key not in known_hosts' 'git fetch failed'
    unset GIT_SSH_COMMAND

    printf '\n%s, the configuration from the repository (remote mode)\n' "$t"
    pointer() {
        printf '[vigil]\nconfig_source = central\nconfig_file   = hosts/posix.config\n\n[source.central]\ntype        = git\nurl         = %s\nref         = %s\ncheck_every = 1s\n' \
            "$SRC_HTTPS" "$1" > "$root/config/vigil.config"
    }
    pointer v1
    fetch
    check 'hosts/posix.config at v1: activated' succeeded "$(fetch_status)"
    check 'hosts/posix.config at v1: its job runs version 1' 'source_check 1' "$(run remote_check)"
    rev=$(revision)
    # Spec 16.3: a fault outside any job refuses the whole configuration; a
    # fault in a job skips only that job.
    pointer broken
    fetch
    check 'a configuration invalid outside any job (tick = soon): refused' failed "$(fetch_status)"
    check 'invalid outside any job: the last good one stays active' "$rev" "$(revision)"
    check 'invalid outside any job: and its job still runs version 1' 'source_check 1' "$(run remote_check)"
    pointer bad
    fetch
    check 'a configuration with an invalid job (run_every with run_at): activated' succeeded "$(fetch_status)"
    contains 'an invalid job: skipped and shown INVALID' remote_check "$(sed -n '/^INVALID/,/^$/p' "$root/logs/supervisor/jobs.log" 2> /dev/null | tr '\n' ' ')"
    contains 'an invalid job: not run' 'invalid' "$(vigil run remote_check 2>&1 | tr 'A-Z' 'a-z')"
    pointer v2
    fetch
    check 'hosts/posix.config at v2: the update is activated' 'source_check 2' "$(run remote_check)"

    printf '\n%s, the server down, then back\n' "$t"
    pointer v2
    fetch
    rev=$(revision)
    if dc ps -q --status running gitea 2> /dev/null | grep -q .; then
        dc stop gitea > /dev/null 2>&1
        pointer v1
        fetch
        check 'server stopped: the fetch fails' failed "$(fetch_status)"
        check 'server stopped: the last good configuration stays active' "$rev" "$(revision)"
        check 'server stopped: and its job still runs version 2' 'source_check 2' "$(run remote_check)"
        dc start gitea > /dev/null 2>&1
        local i=0
        until curl -q -s -m 3 --cacert "$ca" -o /dev/null https://127.0.0.1:3443/api/healthz || [ "$i" -ge 60 ]; do sleep 1; i=$((i + 1)); done
        fetch
        check 'server back: recovered, the change is activated' 'source_check 1' "$(run remote_check)"
    else
        printf '  NOT RUN  server down and back: gitea does not run here (it needs the Docker host)\n'
        notrun=$((notrun + 1))
    fi

    leak_values="$SRC_READER_PW $SRC_ADMIN_PW $(sed -n '2p' "$src/ssh/vigil_sources")"
}

# Moves branch $1 of the test repository to commit $2, as vigil-admin.
move() {
    local g=$work/move
    rm -rf "$g" && git init -q --bare "$g" || return 1
    (umask 077 && printf 'https://vigil-admin:%s@127.0.0.1%%3a3443\n' "$SRC_ADMIN_PW" > "$work/admin-creds")
    printf '[http]\n\tsslCAInfo = %s\n[credential]\n\thelper = store --file=%s\n' "$ca" "$work/admin-creds" > "$work/admin-gitconfig"
    GIT_CONFIG_GLOBAL=$work/admin-gitconfig GIT_TERMINAL_PROMPT=0 git -C "$g" fetch -q "$SRC_HTTPS" "+refs/tags/*:refs/tags/*" &&
        GIT_CONFIG_GLOBAL=$work/admin-gitconfig GIT_TERMINAL_PROMPT=0 git -C "$g" push -q --force "$SRC_HTTPS" "$2:refs/heads/$1" ||
        bad "cannot move branch $1"
    rm -f "$work/admin-creds"
}
dc() { docker compose --project-directory "$bk_dir" -f "$bk_dir/compose.yaml" "$@"; }

case $t in
    git-gitea) git_suite ;;
esac

# Leaks: no password or private key under the Vigil root or in its output.
leaked=''
for v in $leak_values; do
    [ -n "$v" ] || continue
    if grep -rqF -- "$v" "$root" "$work/vigil.out"; then leaked="$leaked $(grep -rlF -- "$v" "$root" "$work/vigil.out" | sed "s|^$work/||" | tr '\n' ' ')"; fi
done
if [ -n "$leaked" ]; then bad "a credential was written down:$leaked"; else ok 'no password or private key under the Vigil root or in its output'; fi

printf '\n%s passed, %s failed, %s not run\n' "$pass" "$fail" "$notrun"
[ "$fail" -eq 0 ]
