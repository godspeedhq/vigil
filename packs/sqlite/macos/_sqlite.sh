# shellcheck shell=bash
#
# _sqlite.sh - what the sqlite pack's scripts share: the list of databases,
# a file's size and age, and a database's header, read as bytes. Each job's
# script sources it; it is never run as a job.
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
# SQLITE_FILES is the databases to watch, their paths separated by ;
# (/var/lib/grafana/grafana.db; /srv/app/data.db). A database's header is its
# first 100 bytes, read as a file like any other: no SQLite library, no lock
# taken, nothing the application using it can notice. Until it is set, the
# jobs report databases 0 (status) and checked 0 (check).

now=$(date +%s)

# The databases, one a line, the spaces around each taken off; nothing when
# SQLITE_FILES is not set.
databases() {
    local IFS=';' f
    set -f
    for f in ${SQLITE_FILES-}; do
        f=${f#"${f%%[![:space:]]*}"}
        f=${f%"${f##*[![:space:]]}"}
        [ -n "$f" ] && printf '%s\n' "$f"
    done
    set +f
}

# tag <path>: the path as a tag's value: no spaces, quotes or control
# characters, and at most 120 characters, its end kept (the file's name).
tag() {
    local t=${1//[^A-Za-z0-9@._:\/+-]/_}
    [ "${#t}" -gt 120 ] && t=${t: -120}
    printf '%s' "$t"
}

# fstat <file>: "<size> <modified, in seconds since 1970>"; nothing when
# there is no such file. GNU's stat, else the BSDs' (macOS).
if stat -c %s / > /dev/null 2>&1; then
    fstat() { [ -e "$1" ] && stat -L -c '%s %Y' -- "$1" 2> /dev/null; }
else
    fstat() { [ -e "$1" ] && stat -L -f '%z %m' -- "$1" 2> /dev/null; }
fi

# header <file>: its first 100 bytes, as numbers, one line.
header() {
    od -An -tu1 -v -N100 -- "$1" 2> /dev/null | tr -s ' \n' '  '
}

# live_journal <file>: true when <file> is a rollback journal in use (or
# left by a writer that died): its header is there. One kept after its
# transaction ended (journal_mode=PERSIST) has its first 28 bytes zeroed;
# one truncated (TRUNCATE) is empty; otherwise it is deleted.
live_journal() {
    od -An -tu1 -v -N28 -- "$1" 2> /dev/null | grep -q '[1-9]'
}
