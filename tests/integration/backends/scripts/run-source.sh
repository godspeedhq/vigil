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
#   https-nginx  Vigil's https source: scripts pinned by SHA-256, an
#              authentication header, the failures nginx gives on purpose
#   sftp-openssh Vigil's sftp source: a key, known_hosts, scripts pinned by
#              SHA-256
#   local      Vigil's local source: a directory (its path has spaces), pinned
#              and followed; no server, and no .sources/ needed
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
case $t in git-gitea | https-nginx | sftp-openssh | local) ;; *) die 'usage: run-source.sh git-gitea|https-nginx|sftp-openssh|local' ;; esac
src=$bk_dir/.sources
ca=$bk_dir/.secrets/tls/ca.pem
fx=$bk_dir/fixtures/sources
# local needs no server, so nothing from start.sh.
if [ "$t" != local ]; then
    envf=$src/${t#*-}.env
    [ -f "$envf" ] && [ -f "$ca" ] || die "no .sources/${t#*-}.env or .secrets/tls/ca.pem: run scripts/start.sh $t first, or copy them from the host that did"
    set -a
    # shellcheck disable=SC1090
    . "$envf"
    set +a
fi
[ "$t" != git-gitea ] || command -v git > /dev/null 2>&1 || die 'needs git'
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

# ---- https-nginx ----------------------------------------------------------
https_suite() {
    local v1_sha v2_sha rev
    v1_sha=$SRC_SHA_V1_SH v2_sha=$SRC_SHA_V2_SH
    # curl trusts the test CA as it would a private CA: its own variable.
    export CURL_CA_BUNDLE=$ca VIGIL_SRC_TOKEN=$SRC_TOKEN
    # A source of type https at $1 (its lines), job file $2, pinned by $3;
    # the source is named $4, by default web. A verified copy in the cache is
    # never fetched again (spec 16.5), so a failure case gets a source of its
    # own, with nothing cached, to make Vigil really fetch.
    https_config() {
        {
            base
            printf '[source.%s]\ntype        = https\n%b\ncheck_every = 1s\ntimeout     = 5s\n\n' "${4:-web}" "$1"
            printf '[job.check]\nsource    = %s\nfile      = %s\nsha256    = %s\nrun_every = 3650d\n' "${4:-web}" "$2" "$3"
        } > "$root/config/vigil.config"
    }

    printf '\n%s, scripts over HTTPS\n' "$t"
    https_config "url = $SRC_URL/files/" check-v1.sh "$v1_sha"
    fetch
    check 'a pinned script: fetched and activated' succeeded "$(fetch_status)"
    check 'a pinned script: the job runs version 1' 'source_check 1' "$(run check)"
    check 'a pinned script: the cached file is the fixture' "$v1_sha" "$(cached_sha check-v1.sh)"
    https_config "url = $SRC_URL/files/" check-v2.sh "$v2_sha"
    fetch
    check 'a new version, pinned by its digest: the job runs version 2' 'source_check 2' "$(run check)"
    check 'a new version: the cached file is the fixture' "$v2_sha" "$(cached_sha check-v2.sh)"
    https_config "url = $SRC_HTTP_URL/files/" check-v1.sh "$v1_sha" plain
    fetch
    check 'plain http to this host (allowed): the job runs version 1' 'source_check 1' "$(run check)"

    printf '\n%s, failures: nothing changes\n' "$t"
    https_config "url = $SRC_URL/files/" check-v1.sh "$v1_sha"
    fetch
    rev=$(revision)
    failure() {
        fetch
        check "$1: the fetch fails" failed "$(fetch_status)"
        contains "$1: says why" "$2" "$(fetch_reason)"
        check "$1: the last good configuration stays active" "$rev" "$(revision)"
        check "$1: and its job still runs" 'source_check 1' "$(run check)"
    }
    https_config "url = $SRC_URL/files/" check-v2.sh "$v1_sha" fail1
    failure 'a digest that does not match' 'does not match its sha256'
    https_config "url = $SRC_URL/files/" corrupt.txt "$v1_sha" fail2
    failure 'corrupted content, never run' 'does not match its sha256'
    https_config "url = $SRC_URL/files/" nosuch.sh "$v1_sha" fail3
    failure 'HTTP 404' 'not found (HTTP 404)'
    https_config "url = $SRC_URL/forbidden/" check-v1.sh "$v1_sha" fail4
    failure 'HTTP 403' 'permission denied (HTTP 403)'
    https_config "url = $SRC_URL/broken/" check-v1.sh "$v1_sha" fail5
    failure 'HTTP 500' 'HTTP 500 from'
    https_config "url = $SRC_URL/busy/" check-v1.sh "$v1_sha" fail6
    failure 'HTTP 503' 'HTTP 503 from'
    https_config "url = $SRC_URL/moved/" check-v1.sh "$v1_sha" fail7
    failure 'a redirect (never followed)' 'HTTP 301 from'
    https_config "url = $SRC_URL/drop/" check-v1.sh "$v1_sha" fail8
    failure 'the connection dropped' 'failed (curl exit code'
    https_config "url = $SRC_URL/slow/" check-v1.sh "$v1_sha" fail9
    failure 'a transfer too slow (timeout 5s)' 'timed out after 5s'
    https_config "url = https://127.0.0.1:9444/files/" check-v1.sh "$v1_sha" fail10
    failure 'a refused connection' 'cannot connect to'
    unset CURL_CA_BUNDLE
    https_config "url = $SRC_URL/files/" check-v2.sh "$v2_sha" untrusted
    failure 'a certificate not trusted (no test CA)' 'is not trusted'
    export CURL_CA_BUNDLE=$ca

    printf '\n%s, an authentication header\n' "$t"
    https_config "url = $SRC_URL/auth/\nheader_name  = X-Vigil-Token\nheader_value = env:VIGIL_SRC_TOKEN" check-v1.sh "$v1_sha" authok
    fetch
    check 'the right token: the job runs version 1' 'source_check 1' "$(run check)"
    rev=$(revision)
    https_config "url = $SRC_URL/auth/" check-v2.sh "$v2_sha" noheader
    failure 'no header' 'permission denied (HTTP 401)'
    export VIGIL_SRC_TOKEN=wrong-token
    https_config "url = $SRC_URL/auth/\nheader_name  = X-Vigil-Token\nheader_value = env:VIGIL_SRC_TOKEN" check-v2.sh "$v2_sha" wrongtoken
    failure 'a wrong token' 'permission denied (HTTP 403)'
    export VIGIL_SRC_TOKEN=$SRC_TOKEN

    printf '\n%s, the configuration from the server (remote mode)\n' "$t"
    pointer() {
        printf '[vigil]\nconfig_source = central\nconfig_file   = posix.config\n\n[source.central]\ntype        = https\nurl         = %s/configs/%s/\ncheck_every = 1s\n' \
            "$SRC_URL" "$1" > "$root/config/vigil.config"
    }
    pointer v1
    fetch
    check 'configs/v1: activated' succeeded "$(fetch_status)"
    check 'configs/v1: its job runs version 1' 'source_check 1' "$(run remote_check)"
    rev=$(revision)
    pointer broken
    fetch
    check 'a configuration invalid outside any job: refused' failed "$(fetch_status)"
    check 'invalid outside any job: the last good one stays active' "$rev" "$(revision)"
    check 'invalid outside any job: and its job still runs version 1' 'source_check 1' "$(run remote_check)"
    pointer v2
    fetch
    check 'configs/v2: the update is activated' 'source_check 2' "$(run remote_check)"

    printf '\n%s, the server down, then back\n' "$t"
    rev=$(revision)
    if dc ps -q --status running nginx-sources 2> /dev/null | grep -q .; then
        dc stop nginx-sources > /dev/null 2>&1
        pointer v1
        fetch
        check 'server stopped: the fetch fails' failed "$(fetch_status)"
        check 'server stopped: the last good configuration stays active' "$rev" "$(revision)"
        check 'server stopped: and its job still runs version 2' 'source_check 2' "$(run remote_check)"
        dc start nginx-sources > /dev/null 2>&1
        local i=0
        until curl -q -s -m 3 --cacert "$ca" -o /dev/null "$SRC_URL/healthz" || [ "$i" -ge 30 ]; do sleep 1; i=$((i + 1)); done
        fetch
        check 'server back: recovered, the change is activated' 'source_check 1' "$(run remote_check)"
    else
        printf '  NOT RUN  server down and back: nginx does not run here (it needs the Docker host)\n'
        notrun=$((notrun + 1))
    fi
    leak_values=$SRC_TOKEN
}

# ---- sftp-openssh ---------------------------------------------------------
sftp_suite() {
    local v1_sha v2_sha rev
    v1_sha=$SRC_SHA_V1_SH v2_sha=$SRC_SHA_V2_SH
    # Vigil's own test switch for its ssh configuration (fetch.sh): the key
    # and known_hosts, StrictHostKeyChecking still on (Vigil sets it).
    ssh_config() {
        printf 'Host 127.0.0.1\n  IdentityFile %s\n  IdentitiesOnly yes\n  UserKnownHostsFile %s\n' "$1" "$2" > "$work/ssh_config"
    }
    export VIGIL_TEST_SSH_CONFIG=$work/ssh_config
    ssh_config "$src/ssh/vigil_sources" "$src/sftp_known_hosts"
    # A source of type sftp with path $1, job file $2, pinned by $3, named $4
    # (by default files; a failure case gets its own, with nothing cached).
    sftp_config() {
        {
            base
            printf '[source.%s]\ntype        = sftp\nhost        = %s\nport        = %s\nuser        = %s\npath        = %s\ncheck_every = 1s\ntimeout     = 10s\n\n' \
                "${4:-files}" "$SRC_HOST" "$SRC_PORT" "$SRC_USER" "$1"
            printf '[job.check]\nsource    = %s\nfile      = %s\nsha256    = %s\nrun_every = 3650d\n' "${4:-files}" "$2" "$3"
        } > "$root/config/vigil.config"
    }

    printf '\n%s, scripts over SFTP, with a key\n' "$t"
    sftp_config /files check-v1.sh "$v1_sha"
    fetch
    check 'a pinned script: fetched and activated' succeeded "$(fetch_status)"
    check 'a pinned script: the job runs version 1' 'source_check 1' "$(run check)"
    check 'a pinned script: the cached file is the fixture' "$v1_sha" "$(cached_sha check-v1.sh)"
    sftp_config /files nested/deep/check-v1.sh "$v1_sha" nested
    fetch
    check 'a nested path: the job runs version 1' 'source_check 1' "$(run check)"
    sftp_config /files check-v2.sh "$v2_sha"
    fetch
    check 'a new version, pinned by its digest: the job runs version 2' 'source_check 2' "$(run check)"
    printf '  NOT SUPPORTED  password authentication: Vigil signs in to sftp with a key only (spec 6.9)\n'
    printf '  NOT RUN  an interrupted transfer: this server gives no reliable way to cut one\n'
    notrun=$((notrun + 1))

    printf '\n%s, failures: nothing changes\n' "$t"
    sftp_config /files check-v1.sh "$v1_sha"
    fetch
    rev=$(revision)
    failure() {
        fetch
        check "$1: the fetch fails" failed "$(fetch_status)"
        contains "$1: says why" "$2" "$(fetch_reason)"
        check "$1: the last good configuration stays active" "$rev" "$(revision)"
        check "$1: and its job still runs" 'source_check 1' "$(run check)"
    }
    sftp_config /files nosuch.sh "$v1_sha" fail1
    failure 'a missing file' 'sftp failed'
    sftp_config /nosuch check-v1.sh "$v1_sha" fail2
    failure 'a missing directory' 'sftp failed'
    sftp_config /files locked.sh "$v1_sha" fail3
    failure 'a file the account may not read' 'sftp failed'
    sftp_config /files check-v2.sh "$v1_sha" fail4
    failure 'a digest that does not match' 'does not match its sha256'
    sftp_config /files corrupt.txt "$v1_sha" fail5
    failure 'corrupted content, never run' 'does not match its sha256'
    ssh_config "$src/ssh/vigil_sources_wrong" "$src/sftp_known_hosts"
    sftp_config /files check-v1.sh "$v1_sha" fail6
    failure 'a key the server does not know' 'Permission denied'
    : > "$work/empty_known_hosts"
    ssh_config "$src/ssh/vigil_sources" "$work/empty_known_hosts"
    sftp_config /files check-v1.sh "$v1_sha" fail7
    failure 'a host key not in known_hosts' 'sftp failed'
    printf '[127.0.0.1]:%s %s\n' "$SRC_PORT" "$(cut -d' ' -f1,2 "$src/ssh/vigil_sources_wrong.pub")" > "$work/changed_known_hosts"
    ssh_config "$src/ssh/vigil_sources" "$work/changed_known_hosts"
    sftp_config /files check-v1.sh "$v1_sha" fail8
    failure 'a changed host key' 'sftp failed'
    ssh_config "$src/ssh/vigil_sources" "$src/sftp_known_hosts"

    printf '\n%s, the configuration from the server (remote mode)\n' "$t"
    pointer() {
        printf '[vigil]\nconfig_source = central\nconfig_file   = posix.config\n\n[source.central]\ntype        = sftp\nhost        = %s\nport        = %s\nuser        = %s\npath        = /files/configs/%s\ncheck_every = 1s\n' \
            "$SRC_HOST" "$SRC_PORT" "$SRC_USER" "$1" > "$root/config/vigil.config"
    }
    pointer v1
    fetch
    check 'configs/v1: activated' succeeded "$(fetch_status)"
    check 'configs/v1: its job runs version 1' 'source_check 1' "$(run remote_check)"
    rev=$(revision)
    pointer broken
    fetch
    check 'a configuration invalid outside any job: refused' failed "$(fetch_status)"
    check 'invalid outside any job: the last good one stays active' "$rev" "$(revision)"
    check 'invalid outside any job: and its job still runs version 1' 'source_check 1' "$(run remote_check)"
    pointer v2
    fetch
    check 'configs/v2: the update is activated' 'source_check 2' "$(run remote_check)"

    printf '\n%s, the server down, then back\n' "$t"
    rev=$(revision)
    if dc ps -q --status running sftp-openssh 2> /dev/null | grep -q .; then
        dc stop sftp-openssh > /dev/null 2>&1
        pointer v1
        fetch
        check 'server stopped: the fetch fails' failed "$(fetch_status)"
        check 'server stopped: the last good configuration stays active' "$rev" "$(revision)"
        check 'server stopped: and its job still runs version 2' 'source_check 2' "$(run remote_check)"
        dc start sftp-openssh > /dev/null 2>&1
        local i=0
        until ssh-keyscan -p "$SRC_PORT" 127.0.0.1 2> /dev/null | grep -q ed25519 || [ "$i" -ge 30 ]; do sleep 1; i=$((i + 1)); done
        fetch
        check 'server back: recovered, the change is activated' 'source_check 1' "$(run remote_check)"
    else
        printf '  NOT RUN  server down and back: the SFTP server does not run here (it needs the Docker host)\n'
        notrun=$((notrun + 1))
    fi
    leak_values="$(sed -n '2p' "$src/ssh/vigil_sources") $(sed -n '2p' "$src/ssh/vigil_sources_wrong")"
}

# ---- local ----------------------------------------------------------------
local_suite() {
    local v1_sha v2_sha rev share="$work/a share with spaces"
    v1_sha=$(sha "$fx/scripts/check-v1.sh")
    v2_sha=$(sha "$fx/scripts/check-v2.sh")
    mkdir -p "$share/nested" "$share/configs" || exit 1
    cp "$fx/scripts/check-v1.sh" "$share/check.sh" && cp "$fx/scripts/check-v1.sh" "$share/nested/check.sh" &&
        cp "$fx/scripts/corrupt.txt" "$share/" || exit 1
    # A source of type local at path $1, job file $2, pinned by $3 (or -,
    # followed), named $4.
    local_config() {
        {
            base
            printf '[source.%s]\ntype        = local\npath        = %s\ncheck_every = 1s\n\n' "${4:-share}" "$1"
            printf '[job.check]\nsource    = %s\nfile      = %s\n' "${4:-share}" "$2"
            [ "$3" != - ] && printf 'sha256    = %s\n' "$3"
            printf 'run_every = 3650d\n'
        } > "$root/config/vigil.config"
    }

    printf '\n%s, scripts from a local directory (its path has spaces)\n' "$t"
    local_config "$share" check.sh "$v1_sha"
    fetch
    check 'pinned: fetched and activated' succeeded "$(fetch_status)"
    check 'pinned: the job runs version 1' 'source_check 1' "$(run check)"
    rev=$(revision)
    # Spec 6.9: a job's sha256 always wins; new content is refused and the
    # last verified copy keeps running.
    cp "$fx/scripts/check-v2.sh" "$share/check.sh"
    fetch
    contains 'pinned, the file changed: the new content is refused, logged' 'check.sh no longer matches its sha256; the last verified copy stays in use' \
        "$(cat "$root/logs/jobs/vigil_fetch/"*.log 2> /dev/null | grep -o 'check.sh no longer matches its sha256; the last verified copy stays in use' | tail -1)"
    check 'pinned, the file changed: the configuration is unchanged' "$rev" "$(revision)"
    check 'pinned, the file changed: the last verified copy keeps running' 'source_check 1' "$(run check)"
    local_config "$share" check.sh "$v2_sha"
    fetch
    check 'pinned to the new digest: the job runs version 2' 'source_check 2' "$(run check)"
    # Followed: no sha256, so a change is picked up at the next check.
    cp "$fx/scripts/check-v1.sh" "$share/check.sh"
    local_config "$share" check.sh - followed
    fetch
    check 'followed: the job runs version 1' 'source_check 1' "$(run check)"
    # Reported by validation (precheck), as a git branch is by the fetcher.
    contains 'followed: reported unpinned' W_SCRIPT_UNPINNED "$(vigil precheck 2>&1 | grep -o 'W_SCRIPT_UNPINNED' | head -1)"
    cp "$fx/scripts/check-v2.sh" "$share/check.sh"
    fetch
    check 'followed, the file changed: the job runs version 2' 'source_check 2' "$(run check)"
    local_config "$share" nested/check.sh "$v1_sha" nested
    fetch
    check 'a nested path: the job runs version 1' 'source_check 1' "$(run check)"
    mkdir -p "$root/relative share" && cp "$fx/scripts/check-v1.sh" "$root/relative share/check.sh"
    local_config 'relative share' check.sh "$v1_sha" relative
    fetch
    check 'a relative path (against the install root): the job runs version 1' 'source_check 1' "$(run check)"

    printf '\n%s, failures: nothing changes\n' "$t"
    rev=$(revision)
    failure() {
        fetch
        check "$1: the fetch fails" failed "$(fetch_status)"
        contains "$1: says why" "$2" "$(fetch_reason)"
        check "$1: the last good configuration stays active" "$rev" "$(revision)"
        check "$1: and its job still runs" 'source_check 1' "$(run check)"
    }
    local_config "$share" nosuch.sh "$v1_sha" fail1
    failure 'a missing file' 'nosuch.sh'
    local_config "$work/no such dir" check.sh "$v1_sha" fail2
    failure 'a missing directory' 'not a directory'
    local_config "$share" corrupt.txt "$v1_sha" fail3
    failure 'invalid content, never run' 'does not match its sha256'
    if [ "$(id -u)" -ne 0 ]; then
        mkdir -p "$work/locked share" && cp "$fx/scripts/check-v1.sh" "$work/locked share/check.sh" && chmod 000 "$work/locked share/check.sh"
        local_config "$work/locked share" check.sh "$v1_sha" fail4
        failure 'a file this account may not read' 'cannot copy'
        chmod 600 "$work/locked share/check.sh"
    else
        printf '  NOT RUN  permission denied: root reads every file\n'
        notrun=$((notrun + 1))
    fi

    printf '\n%s, the configuration from a local directory (remote mode)\n' "$t"
    local cfg="$work/central config"
    mkdir -p "$cfg" || exit 1
    # The fixtures of the HTTPS suite, with the scripts as a local source.
    remote_cfg() {
        sed -n '/^\[vigil\]/,/^\[source/p' "$fx/https/$1/posix.config" | sed '$d'
        printf '[source.files]\ntype = local\npath = %s\n\n' "$share"
        sed -n '/^\[job/,$p' "$fx/https/$1/posix.config"
    }
    cp "$fx/scripts/check-v1.sh" "$share/check-v1.sh" && cp "$fx/scripts/check-v2.sh" "$share/check-v2.sh"
    pointer() {
        remote_cfg "$1" > "$cfg/posix.config"
        printf '[vigil]\nconfig_source = central\nconfig_file   = posix.config\n\n[source.central]\ntype        = local\npath        = %s\ncheck_every = 1s\n' "$cfg" > "$root/config/vigil.config"
    }
    pointer v1
    fetch
    check 'a configuration, v1: activated' succeeded "$(fetch_status)"
    check 'a configuration, v1: its job runs version 1' 'source_check 1' "$(run remote_check)"
    rev=$(revision)
    pointer broken
    fetch
    check 'a configuration invalid outside any job: refused' failed "$(fetch_status)"
    check 'invalid outside any job: the last good one stays active' "$rev" "$(revision)"
    check 'invalid outside any job: and its job still runs version 1' 'source_check 1' "$(run remote_check)"
    pointer v2
    fetch
    check 'a configuration, v2: the update is activated' 'source_check 2' "$(run remote_check)"
    leak_values=''
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
    https-nginx) https_suite ;;
    sftp-openssh) sftp_suite ;;
    local) local_suite ;;
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
