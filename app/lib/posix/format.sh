# shellcheck shell=bash
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
# Vigil data format - bash 3.2 compatible (SPECIFICATION.md 18.7).
#
# state/format holds one number for everything under state/ and spool/,
# cursors and checkpoints included. An install from before it has none, which
# is format 1. A format change is a numbered script in app/migrations: N.sh
# moves the data from N-1 to N, and the highest N is the format this version
# writes. The twin of this file is Format.ps1.

_vigil_format_current() {
    local f n
    _vf_current=1
    for f in "$1"/migrations/*.sh; do
        n=${f##*/}
        n=${n%.sh}
        case $n in
            '' | *[!0-9]*) continue ;;
        esac
        if [ "$((10#$n))" -gt "$_vf_current" ]; then _vf_current=$((10#$n)); fi
    done
    return 0
}

_vigil_format_stamp() {
    printf '%s\n' "$2" > "$1/format.tmp.$$" && mv -f "$1/format.tmp.$$" "$1/format"
}

# Sets _vf_stored and _vf_current. Refuses data it cannot read, or that a
# newer version wrote: guessing at it is how a downgrade would corrupt it.
vigil_format_check() {
    _vigil_format_current "$1"
    _vf_stored=1
    _vf_error=''
    [ -f "$2/format" ] || return 0
    _vf_stored=''
    read -r _vf_stored < "$2/format"
    case $_vf_stored in
        '' | *[!0-9]*)
            _vf_error="$2/format is not a format number"
            return 1
            ;;
    esac
    _vf_stored=$((10#$_vf_stored))
    if [ "$_vf_stored" -gt "$_vf_current" ]; then
        _vf_error="the data is format $_vf_stored, newer than the format $_vf_current this version reads; nothing was changed"
        return 1
    fi
    return 0
}

# Brings the data to this version's format, one step at a time. The number
# moves after each step, so a failed step is the one retried. The caller
# holds the supervisor lock.
vigil_format_migrate() {
    local app=$1 state=$2 spool=$3 logs=$4 n
    vigil_format_check "$app" "$state" || return 1
    n=$_vf_stored
    if [ ! -f "$state/format" ] && ! _vigil_format_stamp "$state" "$n"; then
        _vf_error="cannot write $state/format"
        return 1
    fi
    while [ "$n" -lt "$_vf_current" ]; do
        n=$((n + 1))
        if [ ! -f "$app/migrations/$n.sh" ]; then
            _vf_error="migration $n is missing; the data stays at format $((n - 1))"
            return 1
        fi
        if ! "$BASH" "$app/migrations/$n.sh" "$state" "$spool" "$logs" < /dev/null > /dev/null 8>&-; then
            _vf_error="migration $n failed; the data stays at format $((n - 1))"
            return 1
        fi
        if ! _vigil_format_stamp "$state" "$n"; then
            _vf_error="cannot write $state/format"
            return 1
        fi
    done
    return 0
}
