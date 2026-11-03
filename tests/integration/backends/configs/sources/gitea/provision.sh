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
# provision.sh - the test Gitea's users, repository and fixed history, for
# Vigil's git sources. scripts/start.sh git-gitea runs it after every
# start. Safe to run again: the history is pushed again, the same.
#
#   bash configs/sources/gitea/provision.sh
#
# In Gitea (https://127.0.0.1:3443, SSH on 2222):
#   vigil-admin   pushes the fixtures, and moves a branch for the update test
#   vigil-reader  a read-only collaborator: Vigil's login over HTTPS
#   a deploy key  read-only, .sources/ssh/vigil_sources: Vigil's over SSH
#   vigil-admin/vigil-sources, private, from fixtures/sources/, with fixed
#   dates, so the same commits every time:
#     v1      checks/check.{sh,ps1} version 1; hosts/{posix,windows}.config at ref v1
#     v2      the same, version 2, ref v2
#     bad     v1 with a hosts config whose job is invalid (run_every with
#             run_at): activated, that job skipped (spec 16.3)
#     broken  v1 with a hosts config invalid outside any job: refused whole
#     link    v1 with checks/escape, a symbolic link out of the tree
#     branches: main (v2), test (v1), moving (v1; the tests move it)
#
# The passwords are random, made once, in .sources/gitea.env (0600) with
# what else the tests need: the URLs, the commits, and known_hosts for its
# SSH server. They are set inside the container by Gitea's own CLI, and
# reach curl and git on standard input or through a credential file.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/../../../scripts/common.sh"

src=$bk_dir/.sources
ca=$bk_dir/.secrets/tls/ca.pem
fx=$bk_dir/fixtures/sources
url=https://127.0.0.1:3443
repo=vigil-admin/vigil-sources
out=$src/gitea.env
mkdir -p "$src" && chmod 700 "$src" || exit 1

gitea() { docker compose --project-directory "$bk_dir" -f "$bk_dir/compose.yaml" exec -T -u git gitea gitea "$@"; }
rnd() { openssl rand -hex 16; }
# The API as vigil-admin: method $1, path $2, JSON body $3. Prints the status.
api() {
    printf 'user = "vigil-admin:%s"\n' "$admin_pw" |
        curl -q -sS -K - --cacert "$ca" -o /dev/null -w '%{http_code}' -X "$1" \
            -H 'Content-Type: application/json' --data "$3" "$url/api/v1$2"
}

i=0
until curl -q -s -m 3 --cacert "$ca" -o /dev/null "$url/api/healthz" || [ "$i" -ge 60 ]; do sleep 1; i=$((i + 1)); done

# The passwords, once.
if [ -f "$out" ]; then
    admin_pw=$(sed -n 's/^SRC_ADMIN_PW=//p' "$out")
    reader_pw=$(sed -n 's/^SRC_READER_PW=//p' "$out")
fi
[ -n "${admin_pw-}" ] || admin_pw=$(rnd)
[ -n "${reader_pw-}" ] || reader_pw=$(rnd)

users=$(gitea admin user list 2> /dev/null)
case $users in
    *vigil-admin*) gitea admin user change-password --username vigil-admin --password "$admin_pw" --must-change-password=false > /dev/null ;;
    *) gitea admin user create --admin --username vigil-admin --password "$admin_pw" --email admin@vigil.test --must-change-password=false > /dev/null ;;
esac || die 'cannot set up vigil-admin'
case $users in
    *vigil-reader*) gitea admin user change-password --username vigil-reader --password "$reader_pw" --must-change-password=false > /dev/null ;;
    *) gitea admin user create --username vigil-reader --password "$reader_pw" --email reader@vigil.test --must-change-password=false > /dev/null ;;
esac || die 'cannot set up vigil-reader'

code=$(api POST /user/repos '{"name":"vigil-sources","private":true,"default_branch":"main"}')
case $code in 201 | 409) ;; *) die "cannot create $repo (HTTP $code)" ;; esac
code=$(api PUT "/repos/$repo/collaborators/vigil-reader" '{"permission":"read"}')
case $code in 204) ;; *) die "cannot add vigil-reader (HTTP $code)" ;; esac
key=$(cat "$src/ssh/vigil_sources.pub") || die 'no .sources/ssh/vigil_sources.pub: run configs/sources/keys.sh'
code=$(api POST "/repos/$repo/keys" "{\"title\":\"vigil-source-tests\",\"key\":\"$key\",\"read_only\":true}")
case $code in 201 | 422) ;; *) die "cannot add the deploy key (HTTP $code)" ;; esac

# The history, built from the fixtures with fixed dates and pushed whole.
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=vigil GIT_AUTHOR_EMAIL=vigil@vigil.test GIT_COMMITTER_NAME=vigil GIT_COMMITTER_EMAIL=vigil@vigil.test
g() { git -C "$work/tree" -c core.autocrlf=false "$@"; }
commit() {
    GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" g commit -q -m "$2" && g tag -f "$3" > /dev/null
}
tree() {
    rm -rf "$work/tree/checks" "$work/tree/hosts"
    mkdir -p "$work/tree/checks" "$work/tree/hosts"
    cp "$fx/scripts/check-v$1.sh" "$work/tree/checks/check.sh"
    cp "$fx/scripts/check-v$1.ps1" "$work/tree/checks/check.ps1"
    cp "$fx/git/$2/hosts/"*.config "$work/tree/hosts/"
    g add -A
}
mkdir -p "$work/tree"
g init -q && g symbolic-ref HEAD refs/heads/main || exit 1
tree 1 v1 && commit '2026-01-01T00:00:00Z' 'Version 1' v1
tree 2 v2 && commit '2026-01-02T00:00:00Z' 'Version 2' v2
g checkout -q -b side v1 &&
    tree 1 bad && commit '2026-01-03T00:00:00Z' 'A configuration with an invalid job' bad
g checkout -q -B side v1 &&
    tree 1 broken && commit '2026-01-05T00:00:00Z' 'A configuration Vigil must refuse' broken
g checkout -q v1 2> /dev/null && g checkout -q -B side v1 &&
    ln -s ../../../../etc/hostname "$work/tree/checks/escape" && g add -A &&
    commit '2026-01-04T00:00:00Z' 'A symbolic link out of the tree' link
g branch -f main v2 && g branch -f test v1 && g branch -f moving v1 || exit 1

printf '[http]\n\tsslCAInfo = %s\n[credential]\n\thelper = store --file=%s\n' "$ca" "$work/creds" > "$work/gitconfig"
(umask 077 && printf 'https://vigil-admin:%s@127.0.0.1%%3a3443\n' "$admin_pw" > "$work/creds")
GIT_CONFIG_GLOBAL=$work/gitconfig GIT_TERMINAL_PROMPT=0 g push -q --force "$url/$repo.git" main test moving \
    'refs/tags/*:refs/tags/*' || die "cannot push the fixtures to $repo"

v1=$(g rev-parse v1^{commit}) v2=$(g rev-parse v2^{commit})
ssh-keyscan -p 2222 -t ed25519 127.0.0.1 2> /dev/null | grep -v '^#' > "$src/gitea_known_hosts.tmp" &&
    [ -s "$src/gitea_known_hosts.tmp" ] && mv -f "$src/gitea_known_hosts.tmp" "$src/gitea_known_hosts" ||
    die 'cannot read the SSH host key of Gitea'

(umask 077 && {
    printf '# Written by configs/sources/gitea/provision.sh at %s; test values for a test server.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'SRC_HTTPS=%s/%s.git\nSRC_SSH=ssh://git@127.0.0.1:2222/%s.git\n' "$url" "$repo" "$repo"
    printf 'SRC_READER=vigil-reader\nSRC_READER_PW=%s\nSRC_ADMIN_PW=%s\n' "$reader_pw" "$admin_pw"
    printf 'SRC_V1=%s\nSRC_V2=%s\n' "$v1" "$v2"
} > "$out.tmp") && mv -f "$out.tmp" "$out" || die "cannot write $out"
echo "git-gitea provisioned: $repo (v1, v2, bad, broken, link; main, test, moving); see .sources/gitea.env"
