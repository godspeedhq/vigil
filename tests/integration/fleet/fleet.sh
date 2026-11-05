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
# The fleet of backlog 31 (SPECIFICATION.md 18.11), on one Docker host:
# a git server over SSH, an SFTP server and an HTTPS server, holding the
# same configuration files, and seven Debian hosts that each follow one of
# them, plus a local folder. Every host is moved by the version line of the
# file it follows. Releases are this checkout, packaged and signed with a
# key made for the run, and served to each host on its own 127.0.0.1, the
# one address the test release override accepts.
#
#   fleet.sh up                       keys, CA, releases 99.1.0 and 99.2.0,
#                                     every file at 99.1.0, containers up
#   fleet.sh version <file> <v>       set version in one file, in every source
#   fleet.sh release <v>              package and publish release <v>
#   fleet.sh broken <from> <v>        publish <v>: <from> with app/vigil
#                                     that exits 1, signed
#   fleet.sh status                   each host: release, supervisor, last
#                                     update, and the supervisor's log of it
#   fleet.sh refuse <host>            vigil self update on that host
#   fleet.sh down                     containers and everything made, gone
#
# Files: groups/{git,https,sftp,local}.config for h2-h7, hosts/h1.config
# for the canary, and mac.config, windows-https.config and
# windows-sftp.config for hosts reaching the servers through SSH tunnels
# on 127.0.0.1 (2222 git, 2223 sftp, 8080 http).
#
# Test only. Runs as an ordinary account with Docker; needs openssl,
# ssh-keygen, git and sha256sum.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$(dirname "$here")")")
share=$here/share
data=$here/data
tree=$data/tree
compose() { docker compose -f "$here/compose.yml" "$@"; }

die() { printf 'fleet: %s\n' "$*" >&2; exit 1; }

# Publishes release $1, built from this checkout.
release() {
    local d="$share/www/releases/download/v$1"
    mkdir -p "$d" "$share/www/releases/tag"
    VIGIL_SIGN_KEY=$data/release.key bash "$repo/tools/release/package.sh" "$1" "$d" > /dev/null || die "packaging $1 failed"
    : > "$share/www/releases/tag/v$1"
    printf 'published %s\n' "$1"
}

# Publishes release $2: release $1 with an app/vigil that exits 1, signed.
broken() {
    local from=$1 to=$2 w="$data/variant" d="$share/www/releases/download/v$2"
    rm -rf "$w" && mkdir -p "$w" "$d"
    tar -xzf "$share/www/releases/download/v$from/vigil-$from.tar.gz" -C "$w"
    mv "$w/vigil-$from" "$w/vigil-$to"
    printf '%s\n' "$to" > "$w/vigil-$to/app/VERSION"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$w/vigil-$to/app/vigil"
    printf 'exit 1\n' > "$w/vigil-$to/app/vigil.ps1"
    tar -czf "$d/vigil-$to.tar.gz" -C "$w" "vigil-$to"
    (cd "$w" && python3 -I -m zipfile -c "$d/vigil-$to.zip" "vigil-$to")
    cp "$repo/install.sh" "$repo/install.ps1" "$d/"
    (cd "$d" && sha256sum -- * | grep -v SHA256SUMS > SHA256SUMS)
    openssl dgst -sha256 -sign "$data/release.key" -out "$d/SHA256SUMS.sig" "$d/SHA256SUMS"
    : > "$share/www/releases/tag/v$to"
    printf 'published %s (broken)\n' "$to"
}

# The [source.scripts] section for source type $1, as seen from a container
# (or, with a second argument, through the tunnels on 127.0.0.1).
source_section() {
    case $1:${2-} in
        git:) printf '[source.scripts]\ntype = git\nurl  = git@fleet-git:fleet.git\nref  = main\n' ;;
        git:tunnel) printf '[source.scripts]\ntype = git\nurl  = ssh://git@127.0.0.1:2222/home/git/fleet.git\nref  = main\n' ;;
        https:) printf '[source.scripts]\ntype = https\nurl  = https://fleet-https/fleet/\n' ;;
        https:tunnel) printf '[source.scripts]\ntype = https\nurl  = http://127.0.0.1:8080/fleet/\n' ;;
        sftp:) printf '[source.scripts]\ntype = sftp\nhost = fleet-sftp\nuser = files\npath = /home/files/fleet\n' ;;
        sftp:tunnel) printf '[source.scripts]\ntype = sftp\nhost = 127.0.0.1\nport = 2223\nuser = files\npath = /home/files/fleet\n' ;;
        local:) printf '[source.scripts]\ntype = local\npath = /fleet/local\n' ;;
    esac
    printf 'check_every = 10s\n'
}

# Writes configuration file $1 (in the tree) for source type $2, instance
# $3, version $4, platform $5 (linux, mac or windows) and access $6.
render() {
    local file=$1 type=$2 instance=$3 version=$4 os=$5 via=${6-} script sum
    case $os in windows) script=scripts/beat.cmd ;; *) script=scripts/beat.sh ;; esac
    sum=$(sha256sum "$tree/$script" | cut -c1-64)
    mkdir -p "$(dirname "$tree/$file")"
    {
        printf '# Rendered by fleet.sh: the fleet of SPECIFICATION.md 18.11.\n'
        printf '[vigil]\ninstance = %s\nversion  = %s\n\n' "$instance" "$version"
        printf '[scheduler]\ntick = 5s\n\n[backend.file]\npath = metrics/vigil.prom\n\n'
        if [ "$os" != windows ]; then printf '[runner.bash]\ncommand = /bin/bash\n\n[runners]\n.sh = bash\n\n'; fi
        source_section "$type" "$via"
        printf '\n[job.beat]\nsource    = scripts\nfile      = %s\nsha256    = %s\nrun_every = 10s\n' "$script" "$sum"
    } > "$tree/$file"
}

# Every file the fleet reads, at version $1.
render_all() {
    render hosts/h1.config git fleet-git "$1" linux
    render groups/git.config git fleet-git "$1" linux
    render groups/https.config https fleet-https "$1" linux
    render groups/sftp.config sftp fleet-sftp "$1" linux
    render groups/local.config local fleet-local "$1" linux
    render mac.config git fleet-mac "$1" mac tunnel
    render windows-https.config https fleet-windows "$1" windows tunnel
    render windows-sftp.config sftp fleet-windows "$1" windows tunnel
}

# The tree into every source: a commit to git, copies to the others.
publish_tree() {
    local w="$data/git-work"
    git -C "$w" rm -rq --cached . > /dev/null 2>&1 || true
    find "$w" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    cp -R "$tree/." "$w/"
    git -C "$w" add -A
    git -C "$w" -c user.name=fleet -c user.email=fleet@localhost commit -qm "${1:-fleet}" || true
    git -C "$w" push -q origin HEAD:main
    for d in "$data/https" "$data/sftp" "$share/local"; do
        # Emptied, not removed: the folders are mounted into running containers.
        mkdir -p "$d" && find "$d" -mindepth 1 -delete && cp -R "$tree/." "$d/"
    done
    chmod -R a+rX "$data" "$share"
}

up() {
    command -v docker > /dev/null || die 'needs docker'
    [ ! -d "$data" ] || die "$data exists: fleet.sh down first"
    mkdir -p "$share/keys" "$share/ca" "$share/www" "$tree/scripts"
    # Keys made for the run: SSH (client and host), the CA, the release key.
    ssh-keygen -q -t ed25519 -N '' -C fleet -f "$share/keys/fleet"
    ssh-keygen -q -t ed25519 -N '' -C fleet-host -f "$share/keys/host"
    {
        printf 'fleet-git,fleet-sftp %s\n' "$(cut -d' ' -f1-2 "$share/keys/host.pub")"
        printf '[127.0.0.1]:2222,[127.0.0.1]:2223 %s\n' "$(cut -d' ' -f1-2 "$share/keys/host.pub")"
    } > "$share/keys/known_hosts"
    openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj '/CN=Vigil fleet test CA' \
        -keyout "$data/ca.key" -out "$share/ca/ca.pem" 2> /dev/null
    openssl req -newkey rsa:2048 -nodes -subj '/CN=fleet-https' -keyout "$share/ca/https.key" -out "$data/https.csr" 2> /dev/null
    printf 'subjectAltName=DNS:fleet-https\n' > "$data/san"
    openssl x509 -req -in "$data/https.csr" -CA "$share/ca/ca.pem" -CAkey "$data/ca.key" -CAcreateserial -days 7 \
        -extfile "$data/san" -out "$share/ca/https.pem" 2> /dev/null
    openssl genrsa -out "$data/release.key" 2048 2> /dev/null
    openssl rsa -in "$data/release.key" -pubout -out "$share/release.pem" 2> /dev/null
    cp "$repo/tests/integration/mock-files.py" "$share/"
    release 99.1.0
    release 99.2.0
    # The job every host runs, from its own source.
    printf 'echo "metric beats 1"\n' > "$tree/scripts/beat.sh"
    printf '@echo off\r\necho metric beats 1\r\n' > "$tree/scripts/beat.cmd"
    render_all 99.1.0
    git init -q --bare -b main "$data/git/fleet.git"
    git clone -q "$data/git/fleet.git" "$data/git-work" 2> /dev/null
    publish_tree 'every file at 99.1.0'
    compose up -d --build --quiet-pull 2>&1 | tail -n 3
}

# Sets version in configuration file $1 to $2, in every source.
version() {
    [ -f "$tree/$1" ] || die "no $1"
    sed -i "s/^version  = .*/version  = $2/" "$tree/$1"
    publish_tree "$1: version $2"
    printf '%s: version = %s\n' "$1" "$2"
}

# One line per host: release on disk, release the supervisor runs, and the
# last update the configuration asked for.
status() {
    local h
    printf '%-4s %-8s %-10s %-10s %-11s %s\n' host source app supervisor update result
    for h in h1 h2 h3 h4 h5 h6 h7; do
        compose exec -T -u vigil "$h" bash -c '
            r=$HOME/vigil
            u() { sed -n "s/^$1 *= *//p" "$r/state/update.state" 2> /dev/null; }
            printf "%-4s %-8s %-10s %-10s %-11s %s\n" "$(hostname)" "$FLEET_SOURCE" "$(cat "$r/app/VERSION")" \
                "$(cat "$r/state/supervisor.version" 2> /dev/null)" "$(u version)" "$(u result)$(u reason | sed "s/^/: /;s/^: $//")"
        ' 2> /dev/null || printf '%-4s (not running)\n' "$h"
    done
}

# The supervisor log lines about updates, on every host.
log() {
    local h
    for h in h1 h2 h3 h4 h5 h6 h7; do
        compose exec -T -u vigil "$h" bash -c 'cat $HOME/vigil/logs/supervisor/2*.log 2> /dev/null' |
            grep -E 'as the configuration asks|could not be|reloading|staying on|configuration revision' | sed "s/^/$h  /"
    done
}

case ${1-} in
    up) up ;;
    version) [ "$#" -eq 3 ] || die 'version <file> <v>'; version "$2" "$3" ;;
    release) [ "$#" -eq 2 ] || die 'release <v>'; release "$2" ;;
    broken) [ "$#" -eq 3 ] || die 'broken <from> <v>'; broken "$2" "$3" ;;
    status) status ;;
    log) log ;;
    refuse)
        [ "$#" -eq 2 ] || die 'refuse <host>'
        compose exec -T -u vigil "$2" bash -c 'bash $HOME/vigil/app/vigil --root $HOME/vigil self update; echo "exit $?"'
        ;;
    down)
        compose down -v --rmi local > /dev/null 2>&1 || true
        rm -rf "$data" "$share"
        ;;
    *) sed -n '/^#   fleet.sh/,/^$/p' "$0"; exit 64 ;;
esac
