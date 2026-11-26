#!/usr/bin/env bash
#
# status.sh - SQLite databases: found, their size, free pages, the WAL and
# the rollback journal
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
# Reports each database in SQLITE_FILES: whether it is there, how big it is,
# how much of it is free pages (space a VACUUM would give back), its
# write-ahead log (a WAL that keeps growing is a reader that never lets a
# checkpoint finish), and a rollback journal still there long after a
# transaction should have ended (a writer that died in the middle of one,
# or a transaction left open).
#
# Reads only each database's first 100 bytes (its header) and the sizes and
# times of it and its -wal and -journal files, as files like any other: no
# SQLite library, no lock taken, nothing the application can notice. In WAL
# mode the header is as of the last checkpoint, so pages and free_pages may
# lag the WAL by a few. Needs read access to each database file. What the
# scripts share is in _sqlite.sh, beside this one.
#
# Metrics:
#   databases            the databases in SQLITE_FILES
#   missing              of those, how many are not there
#   found                1 when the file is there, else 0, tagged
#                        db=<path>; the rest only for one found
#   valid                1 when it starts as a SQLite database does (or is
#                        empty), else 0: not a database, damaged, or
#                        encrypted (SQLCipher)
#   info                 always 1, tagged mode=<wal, rollback>,
#                        version=<the SQLite that last wrote it, 3.45.1>
#                        and vacuum=<none, full, incremental>
#   size_bytes           the file's size
#   page_size            its page size, in bytes
#   pages                its pages
#   free_pages           pages on its free list: kept by the file, holding
#                        no data
#   free_pct             free_pages, of pages
#   free_bytes           the space a VACUUM would give back
#   wal_bytes            its write-ahead log's size (0 when it has none):
#                        the largest it has been since the last connection
#                        closed, as SQLite reuses it
#   journal_bytes        a rollback journal in use (0 when none)
#   journal_seconds      how long that journal has been in use, by when it
#                        was last written
#   last_write_seconds   since the database or its WAL was last written
#
# Example output (the rest are in the same form):
#   metric databases 2
#   metric missing 0
#   metric found 1 db=/var/lib/grafana/grafana.db
#   metric valid 1 db=/var/lib/grafana/grafana.db
#   metric info 1 db=/var/lib/grafana/grafana.db mode=rollback version=3.45.1 vacuum=none
#   metric size_bytes 1658880 db=/var/lib/grafana/grafana.db
#   metric free_pct 3.21 db=/var/lib/grafana/grafana.db
#   metric wal_bytes 0 db=/var/lib/grafana/grafana.db
#
# Reading the results (starting points: tune them to the application):
#   Healthy  missing 0; valid 1; wal_bytes a few MB (SQLite checkpoints at
#            about 4 MB); journal_bytes 0 most of the time; free_pct low,
#            or steady.
#   Watch    wal_bytes past 64 MB, or higher every day; free_pct past 25 on
#            a large database (a VACUUM would give space back);
#            last_write_seconds far longer than the application's habit.
#   Act      missing above 0 or valid 0; wal_bytes past 1 GB and growing (a
#            reader holds an old snapshot: checkpoints cannot finish, reads
#            slow down); journal_seconds past 10 minutes (a writer died in a
#            transaction, or holds one open: other writers wait or fail with
#            "database is locked").
#
# Requires: bash, od and awk (every Linux and macOS has them)
# Exit code: 0 on success, databases there or not; 1 if a database cannot be
#   read by this account, or a folder is named (it says which)
#
# Example (vigil.config):
#   [job.sqlite_status]
#   file        = packs/sqlite/status.sh
#   metric_name = sqlite
#   run_every   = 5m
#   env         = SQLITE_FILES=/var/lib/grafana/grafana.db; /srv/app/data.db

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_sqlite.sh"

n=0
missing=0
denied=''
folders=''
while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    t=$(tag "$f")
    if [ ! -e "$f" ]; then
        missing=$((missing + 1))
        echo "metric found 0 db=$t"
        continue
    fi
    if [ -d "$f" ]; then
        folders="$folders${folders:+, }$f"
        continue
    fi
    if [ ! -r "$f" ]; then
        denied="$denied${denied:+, }$f"
        continue
    fi
    echo "metric found 1 db=$t"
    read -r size mtime <<< "$(fstat "$f")"
    last=$mtime
    wal=0
    if s=$(fstat "$f-wal"); then
        read -r wal wtime <<< "$s"
        [ "$wtime" -gt "$last" ] && last=$wtime
    fi
    jbytes=0
    jage=''
    if s=$(fstat "$f-journal"); then
        read -r js jtime <<< "$s"
        if [ "$js" -gt 0 ] && live_journal "$f-journal"; then
            jbytes=$js
            jage=$((now - jtime))
            [ "$jage" -lt 0 ] && jage=0
        fi
    fi
    echo "metric size_bytes $size db=$t"
    if [ "$size" -eq 0 ]; then
        # An empty file is an empty database: SQLite writes the header
        # with the first table.
        echo "metric valid 1 db=$t"
    else
        header "$f" | awk -v t="$t" -v size="$size" '
            function u16(i) { return $(i + 1) * 256 + $(i + 2) }
            function u32(i) { return ((($(i + 1) * 256 + $(i + 2)) * 256 + $(i + 3)) * 256) + $(i + 4) }
            {
                split("83 81 76 105 116 101 32 102 111 114 109 97 116 32 51 0", magic, " ")
                ok = NF >= 100
                for (i = 1; ok && i <= 16; i++) if ($i != magic[i]) ok = 0
                if (!ok) { printf "metric valid 0 db=%s\n", t; exit }
                printf "metric valid 1 db=%s\n", t
                ps = u16(16); if (ps == 1) ps = 65536
                mode = $(18 + 1) == 2 ? "wal" : "rollback"
                v = u32(96)
                version = sprintf("%d.%d.%d", int(v / 1000000), int(v / 1000) % 1000, v % 1000)
                vacuum = u32(52) == 0 ? "none" : (u32(64) == 0 ? "full" : "incremental")
                printf "metric info 1 db=%s mode=%s version=%s vacuum=%s\n", t, mode, version, vacuum
                # The page count in the header when it is current (its
                # version-valid-for is its change counter); else by size.
                pages = (u32(92) == u32(24) && u32(28) > 0) ? u32(28) : int(size / ps)
                free = u32(36)
                printf "metric page_size %d db=%s\n", ps, t
                printf "metric pages %.0f db=%s\n", pages, t
                printf "metric free_pages %.0f db=%s\n", free, t
                if (pages > 0) {
                    p = 100 * free / pages
                    if (p == int(p)) printf "metric free_pct %d db=%s\n", p, t
                    else printf "metric free_pct %.2f db=%s\n", p, t
                }
                printf "metric free_bytes %.0f db=%s\n", free * ps, t
            }'
    fi
    echo "metric wal_bytes $wal db=$t"
    echo "metric journal_bytes $jbytes db=$t"
    [ -n "$jage" ] && echo "metric journal_seconds $jage db=$t"
    age=$((now - last))
    [ "$age" -lt 0 ] && age=0
    echo "metric last_write_seconds $age db=$t"
done <<< "$(databases)"
echo "metric databases $n"
echo "metric missing $missing"
[ -n "$folders" ] && echo "$job: SQLITE_FILES names a folder, not a database file: $folders" >&2
if [ -n "$denied" ]; then
    echo "$job: this account ($(id -un)) cannot read $denied: give it read access (packs/sqlite/README.md shows how)" >&2
fi
[ -n "$denied$folders" ] && exit 1
exit 0
