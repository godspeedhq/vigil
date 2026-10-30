# shellcheck shell=bash
#
# Vigil configuration parser - bash 3.2 compatible.
#
# Parses the Vigil INI dialect (SPECIFICATION.md 6.1) into parallel arrays:
#   VIGIL_CFG_SECTION[i]  VIGIL_CFG_KEY[i]  VIGIL_CFG_VALUE[i]  VIGIL_CFG_LINE[i]
# Accepted section headers, including empty ones, in file order:
#   VIGIL_CFG_SEC_NAME[j]  VIGIL_CFG_SEC_LINE[j]
#   VIGIL_CFG_SEC_FIRST[j]  VIGIL_CFG_SEC_COUNT[j]  its entries - a section's keys
#                           are contiguous, so lookups scan only that range
#   vigil_config_section <name>  finds a section's j without a loop or pattern match
#   VIGIL_CFG_GENERATION    incremented by every parse, so callers can cache
# Errors are collected in VIGIL_CFG_ERRORS[i] as "<line><TAB><code><TAB><message>".
# vigil_config_parse_files reads several files as one configuration; lines
# are then locations, "<label>:<line>" in any file but the main one.
#
# The parser is deliberately dumb: it records every "key = value" in file
# order, repeated keys included, and leaves meaning (allowed keys, duplicate
# keys, value types) to validation. It must produce exactly the same result
# as Config.ps1 - tests/conformance/parser holds the shared cases.
#
# Rules enforced here:
#   - A trailing CR is stripped (CRLF files are accepted); a UTF-8 BOM on the
#     first line is stripped.
#   - Only TAB and printable ASCII (space to ~) are allowed - E_INVALID_CHAR.
#   - Leading and trailing spaces/tabs are trimmed from lines, keys and values.
#   - Blank lines and lines starting with # or ; are ignored.
#   - [name] or [name.name], lowercase a-z 0-9 _ only - E_SECTION_SYNTAX.
#     A repeated header is E_SECTION_DUPLICATE. Keys after a bad or repeated
#     header are skipped until the next good header, so one mistake is
#     reported once instead of once per key.
#   - key = value, split on the first "=". Keys are lowercase a-z 0-9 _,
#     optionally starting with "." (for [runners]) - E_KEY_SYNTAX.
#   - A key before any section is E_KEY_OUTSIDE_SECTION; a line that is none
#     of the above is E_NO_EQUALS.
#
# bash 3.2: no associative arrays, no ${var,,}, no mapfile - keep it that way.

VIGIL_CFG_MAX_BYTES=1048576
VIGIL_CFG_MAX_FILES=256

# Records an error at line $1 of the file being read. Locations are plain
# line numbers in the main file and "<label>:<line>" in any other (spec 6.8).
_vigil_cfg_error() {
    local loc=$1
    if [ -n "${_vc_label-}" ]; then loc="$_vc_label:$1"; fi
    VIGIL_CFG_ERRORS[${#VIGIL_CFG_ERRORS[@]}]="$loc	$2	$3"
}

# Trims leading and trailing spaces and tabs. Result in _vigil_cfg_trimmed
# (a variable, not stdout, to avoid a subshell per call).
_vigil_cfg_trim() {
    local s=$1
    s=${s#"${s%%[!	 ]*}"}
    s=${s%"${s##*[!	 ]}"}
    _vigil_cfg_trimmed=$s
}

# vigil_config_parse <path>
# Parses one file as the main configuration file. Returns 0 when it parsed
# without errors, 1 otherwise.
vigil_config_parse() {
    _vigil_cfg_reset
    _vigil_cfg_read main '' "$1"
    [ "${#VIGIL_CFG_ERRORS[@]}" -eq 0 ]
}

# vigil_config_parse_files <role> <label> <path> [<role> <label> <path> ...]
# Parses several files as one configuration (spec 6.8), in the order given.
# role is main, dropin or fetched; label names the file in locations, and
# is - for the main file, whose locations are plain line numbers. Each
# section may be defined once across all files. Also sets, per file:
#   VIGIL_CFG_FILE_ROLE[k]  VIGIL_CFG_FILE_LABEL[k]
# and per section VIGIL_CFG_SEC_FILE[j], the k of the file defining it.
vigil_config_parse_files() {
    _vigil_cfg_reset
    if [ $(($# / 3)) -gt "$VIGIL_CFG_MAX_FILES" ]; then
        _vigil_cfg_error 0 E_TOO_MANY_FILES "$(($# / 3)) configuration files; the limit is $VIGIL_CFG_MAX_FILES"
        return 1
    fi
    while [ "$#" -ge 3 ]; do
        if [ "$2" = - ]; then
            _vigil_cfg_read "$1" '' "$3"
        else
            _vigil_cfg_read "$1" "$2" "$3"
        fi
        shift 3
    done
    [ "${#VIGIL_CFG_ERRORS[@]}" -eq 0 ]
}

_vigil_cfg_reset() {
    # Clear the previous parse's section variables (none on the first parse).
    local j=0
    while [ -n "${VIGIL_CFG_SEC_NAME[$j]+set}" ]; do
        _vigil_cfg_secvar "${VIGIL_CFG_SEC_NAME[$j]}"
        unset "$_vigil_cfg_secvar"
        j=$((j + 1))
    done
    VIGIL_CFG_SECTION=()
    VIGIL_CFG_KEY=()
    VIGIL_CFG_VALUE=()
    VIGIL_CFG_LINE=()
    VIGIL_CFG_SEC_NAME=()
    VIGIL_CFG_SEC_LINE=()
    VIGIL_CFG_SEC_FIRST=()
    VIGIL_CFG_SEC_COUNT=()
    VIGIL_CFG_SEC_FILE=()
    VIGIL_CFG_FILE_ROLE=()
    VIGIL_CFG_FILE_LABEL=()
    VIGIL_CFG_GENERATION=$((${VIGIL_CFG_GENERATION:-0} + 1))
    VIGIL_CFG_ERRORS=()
    _vc_label=''
}

# _vigil_cfg_read <role> <label> <path>
# Appends one file to the current parse.
_vigil_cfg_read() {
    local path=$3 k=${#VIGIL_CFG_FILE_ROLE[@]}
    VIGIL_CFG_FILE_ROLE[$k]=$1
    VIGIL_CFG_FILE_LABEL[$k]=$2
    _vc_label=$2

    if [ ! -f "$path" ]; then
        _vigil_cfg_error 0 E_FILE_NOT_FOUND "config file not found: $path"
        return 1
    fi
    if [ ! -r "$path" ]; then
        _vigil_cfg_error 0 E_FILE_UNREADABLE "config file not readable: $path"
        return 1
    fi

    local size
    size=$(wc -c < "$path")
    size=${size//[!0-9]/}
    if [ "${size:-0}" -gt "$VIGIL_CFG_MAX_BYTES" ]; then
        _vigil_cfg_error 0 E_FILE_TOO_LARGE "config file is $size bytes; the limit is $VIGIL_CFG_MAX_BYTES"
        return 1
    fi

    # Byte-wise matching for the character check, whatever the caller's locale.
    local LC_ALL=C
    # Prefix that turns a line number into a location.
    local loc=''
    if [ -n "$2" ]; then loc="$2:"; fi

    local re_section='^\[([a-z0-9_]+(\.[a-z0-9_]+)?)\]$'
    local re_key='^\.?[a-z0-9_]+$'
    local tab='	'
    local bom=$'\xef\xbb\xbf'
    local section=''
    local skipping=0
    local n=0
    local line key value i

    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        # Fixed-length substring tests, not ${line%$'\r'} / ${line#"$bom"}:
        # bash removes a pattern by trying every split point, which is
        # quadratic - over a minute for one 1 MiB line.
        if [ "${line: -1}" = $'\r' ]; then
            line=${line:0:${#line}-1}
        fi
        if [ "$n" -eq 1 ] && [ "${line:0:3}" = "$bom" ]; then
            line=${line:3}
        fi

        case $line in
            *[!"$tab"\ -~]*)
                _vigil_cfg_error "$n" E_INVALID_CHAR "only printable ASCII and tab are allowed"
                continue
                ;;
        esac

        _vigil_cfg_trim "$line"
        line=$_vigil_cfg_trimmed

        case $line in
            '' | '#'* | ';'*)
                continue
                ;;
            '['*)
                if [[ $line =~ $re_section ]]; then
                    section=${BASH_REMATCH[1]}
                    vigil_config_section "$section"
                    if [ "$VIGIL_CFG_SEC" -ge 0 ]; then
                        # Repeated in this file or defined by an earlier one.
                        _vigil_cfg_error "$n" E_SECTION_DUPLICATE "section [$section] appears more than once; first at ${VIGIL_CFG_SEC_LINE[$VIGIL_CFG_SEC]}"
                        skipping=1
                    else
                        skipping=0
                        i=${#VIGIL_CFG_SEC_NAME[@]}
                        VIGIL_CFG_SEC_NAME[$i]=$section
                        VIGIL_CFG_SEC_LINE[$i]=$loc$n
                        VIGIL_CFG_SEC_FIRST[$i]=${#VIGIL_CFG_KEY[@]}
                        VIGIL_CFG_SEC_COUNT[$i]=0
                        VIGIL_CFG_SEC_FILE[$i]=$k
                        _vigil_cfg_secvar "$section"
                        printf -v "$_vigil_cfg_secvar" '%s' "$i"
                    fi
                else
                    _vigil_cfg_error "$n" E_SECTION_SYNTAX "invalid section header: $line"
                    skipping=1
                fi
                ;;
            *=*)
                if [ "$skipping" -eq 1 ]; then
                    continue
                fi
                _vigil_cfg_trim "${line%%=*}"
                key=$_vigil_cfg_trimmed
                _vigil_cfg_trim "${line#*=}"
                value=$_vigil_cfg_trimmed
                if [ -z "$section" ]; then
                    _vigil_cfg_error "$n" E_KEY_OUTSIDE_SECTION "key '$key' appears before any [section]"
                    continue
                fi
                if ! [[ $key =~ $re_key ]]; then
                    _vigil_cfg_error "$n" E_KEY_SYNTAX "invalid key: '$key'"
                    continue
                fi
                i=${#VIGIL_CFG_KEY[@]}
                VIGIL_CFG_SECTION[$i]=$section
                VIGIL_CFG_KEY[$i]=$key
                VIGIL_CFG_VALUE[$i]=$value
                VIGIL_CFG_LINE[$i]=$loc$n
                i=$((${#VIGIL_CFG_SEC_COUNT[@]} - 1))
                VIGIL_CFG_SEC_COUNT[$i]=$((VIGIL_CFG_SEC_COUNT[$i] + 1))
                ;;
            *)
                if [ "$skipping" -eq 1 ]; then
                    continue
                fi
                _vigil_cfg_error "$n" E_NO_EQUALS "expected 'key = value', a [section] or a comment"
                ;;
        esac
    done < "$path"

    [ "${#VIGIL_CFG_ERRORS[@]}" -eq 0 ]
}

# vigil_config_dump
# Prints the last parse in the conformance format, one record per line:
#   <section> TAB <key> TAB <value>      for each entry, in file order
#   ERROR TAB <line> TAB <code>          for each error, in file order
vigil_config_dump() {
    local i e
    i=0
    while [ "$i" -lt "${#VIGIL_CFG_KEY[@]}" ]; do
        printf '%s\t%s\t%s\n' "${VIGIL_CFG_SECTION[$i]}" "${VIGIL_CFG_KEY[$i]}" "${VIGIL_CFG_VALUE[$i]}"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "${#VIGIL_CFG_ERRORS[@]}" ]; do
        e=${VIGIL_CFG_ERRORS[$i]}
        printf 'ERROR\t%s\n' "$(printf '%s' "$e" | cut -f1,2)"
        i=$((i + 1))
    done
}

# Name of the variable holding a section's index. Section names are
# [a-z0-9_.]; "_" -> "_u" and "." -> "_d" keeps the mapping one-to-one.
# Result in _vigil_cfg_secvar.
_vigil_cfg_secvar() {
    local s=${1//_/_u}
    _vigil_cfg_secvar=_VIGIL_SEC_${s//./_d}
}

# vigil_config_section <name>
# Sets VIGIL_CFG_SEC to the section's index in VIGIL_CFG_SEC_NAME, or -1.
# Uses one variable per section: bash 3.2 has no associative arrays, and
# matching a pattern against a list of names is slow in bash.
vigil_config_section() {
    _vigil_cfg_secvar "$1"
    VIGIL_CFG_SEC=${!_vigil_cfg_secvar:--1}
}

# Lowercases ASCII letters without starting a process (tr costs a fork,
# which is slow on Windows bash). Result in _vigil_lowered.
# The letters are listed, not [A-Z]: in bash 3.2 a range follows the locale's
# collation order, where [A-Z] also matches lowercase letters.
_vigil_lower() {
    local s=$1 c rest upper=ABCDEFGHIJKLMNOPQRSTUVWXYZ lower=abcdefghijklmnopqrstuvwxyz
    _vigil_lowered=''
    while [ -n "$s" ]; do
        c=${s:0:1}
        s=${s:1}
        case $c in
            [ABCDEFGHIJKLMNOPQRSTUVWXYZ])
                rest=${upper%%"$c"*}
                c=${lower:${#rest}:1}
                ;;
        esac
        _vigil_lowered=$_vigil_lowered$c
    done
}
