#!/usr/bin/env bash
#
# crashdumps.sh - the crash dumps Erlang VMs left behind, and why they died
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
# An Erlang VM that dies writes a crash dump (erl_crash.dump, or where
# ERL_CRASH_DUMP says), whose first lines say why: its slogan, such as
# "eheap_alloc: Cannot allocate 2545496 bytes of memory (of type "heap")."
# This script finds them and reports each, newest first. It looks in each
# folder or file in BEAM_CRASH_DUMPS (separated by ;, set by the job), in
# the folder each running VM was started in (from lsof: root, or the VM's
# own account), and in Homebrew's RabbitMQ folders (/opt/homebrew/var/log/
# rabbitmq, /usr/local/var/log/rabbitmq and their lib). A file is a dump
# when its first line says so; it reads a dump's first lines only, however
# large it is.
#
# Metrics:
#   dumps               the crash dumps found
#   dump                always 1, tagged file=<its path>, node=<the node
#                       that died, when the dump names it> and
#                       slogan=<why it died>
#   age_seconds         how long ago it was written, tagged file=<the same>
#   newest_age_seconds  how long ago the newest was written
#   dumps_not_shown     past the first 20, newest first, how many were left
#                       out
#
# Example output:
#   metric dump 1 file=/private/var/folders/92/4btgbn9d6453tlvqwyrbgqt40000gq/T/vigil-beam-mac.5gUild/dumps/atoms.dump node=deadm@Bankoles-MacBook-Air slogan=no_more_index_entries_in_atom_tab_(max=20000)
#   metric age_seconds 60 file=/private/var/folders/92/4btgbn9d6453tlvqwyrbgqt40000gq/T/vigil-beam-mac.5gUild/dumps/atoms.dump
#   metric dumps 1
#   metric newest_age_seconds 60
#   metric dumps_not_shown 0
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  dumps 0, or only old ones you have read and kept.
#   Watch    newest_age_seconds under a day: a VM died since yesterday;
#            read its slogan, then move or delete the dump (one dump file,
#            erl_crash.dump, is overwritten by the next).
#   Act      newest_age_seconds under an hour: a VM died just now. Its
#            slogan says why: "Cannot allocate": out of memory (beam.vm
#            memory_bytes); "no more index entries in atom_tab": the atom
#            limit (beam.vm atom_pct); "Kernel pid terminated": an
#            application it could not run without stopped.
#
# Requires: bash; lsof, for each VM's folder
# Exit code: 0 on success, dumps or none

set -u

now=$(date +%s)
places=()
while IFS= read -r p; do
    p=$(printf '%s' "$p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$p" ] && places+=("$p")
done << EOF
$(printf '%s' "${BEAM_CRASH_DUMPS-}" | tr ';' '\n')
EOF
# Each running VM's folder, as lsof gives it.
if command -v lsof > /dev/null 2>&1; then
    while read -r pid comm; do
        [ "${comm##*/}" = beam.smp ] || continue
        cwd=$(lsof -a -n -p "$pid" -d cwd -Fn 2> /dev/null | sed -n 's/^n//p' | head -1)
        [ -n "$cwd" ] && places+=("$cwd")
    done << EOF
$(ps -axww -o pid=,comm= 2> /dev/null)
EOF
fi
for b in /opt/homebrew /usr/local; do places+=("$b/var/log/rabbitmq" "$b/var/lib/rabbitmq"); done

# The candidates: erl_crash.dump and *.dump in each folder, or the file.
found=()
for p in "${places[@]}"; do
    if [ -f "$p" ]; then
        found+=("$p")
    elif [ -d "$p" ] && [ -r "$p" ]; then
        for f in "$p"/erl_crash*.dump "$p"/*.dump; do [ -f "$f" ] && found+=("$f"); done
    fi
done

# A dump starts =erl_crash_dump:; the same file found twice counts once.
rows=$(for f in "${found[@]+"${found[@]}"}"; do
    real=$(cd "$(dirname "$f")" 2> /dev/null && printf '%s/%s' "$(pwd -P)" "${f##*/}") || real=$f
    head -c 16 "$real" 2> /dev/null | grep -q '^=erl_crash_dump:' || continue
    printf '%s\t%s\n' "$(stat -f %m "$real" 2> /dev/null || echo "$now")" "$real"
done | sort -u -t "$(printf '\t')" -k2,2 | sort -rn)

count=0
newest=''
while IFS="$(printf '\t')" read -r mtime f; do
    [ -n "$f" ] || continue
    count=$((count + 1))
    age=$((now - mtime))
    [ "$age" -ge 0 ] || age=0
    [ -n "$newest" ] || newest=$age
    [ "$count" -le 20 ] || continue
    head=$(head -c 65536 "$f" 2> /dev/null | head -n 40)
    slogan=$(printf '%s\n' "$head" | sed -n 's/^Slogan: //p' | head -1)
    # The node that died: its =node: line, past its processes (in the
    # first 16 MB, as a dump can be gigabytes).
    node=$(head -c 16000000 "$f" 2> /dev/null | grep -a -m 1 "^=node:'" | sed "s/^=node:'\(.*\)'.*/\1/")
    file=$(printf '%s' "$f" | tr -c 'A-Za-z0-9@._:/+=,-' '_')
    slogan=$(printf '%s' "${slogan:-unknown}" | tr -d '"'"'"'`' | tr -c 'A-Za-z0-9@._:/+=,()-' '_' | sed 's/_*$//' | cut -c1-120)
    node=$(printf '%s' "$node" | tr -c 'A-Za-z0-9@._-' '_' | cut -c1-120)
    echo "metric dump 1 file=$file${node:+ node=$node} slogan=$slogan"
    echo "metric age_seconds $age file=$file"
done << EOF
$rows
EOF

echo "metric dumps $count"
[ -n "$newest" ] && echo "metric newest_age_seconds $newest"
echo "metric dumps_not_shown $((count > 20 ? count - 20 : 0))"
exit 0
