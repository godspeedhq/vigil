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

_vigil_cfg_error() {
    VIGIL_CFG_ERRORS[${#VIGIL_CFG_ERRORS[@]}]="$1	$2	$3"
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
# Returns 0 when the file parsed without errors, 1 otherwise.
vigil_config_parse() {
    local path=$1
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
    VIGIL_CFG_GENERATION=$((${VIGIL_CFG_GENERATION:-0} + 1))
    VIGIL_CFG_ERRORS=()

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

    local re_section='^\[([a-z0-9_]+(\.[a-z0-9_]+)?)\]$'
    local re_key='^\.?[a-z0-9_]+$'
    local tab='	'
    local bom=$'\xef\xbb\xbf'
    local seen=$'\n'
    local section=''
    local skipping=0
    local n=0
    local line key value i

    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%$'\r'}
        if [ "$n" -eq 1 ]; then
            line=${line#"$bom"}
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
                    case $seen in
                        *$'\n'"$section"$'\n'*)
                            _vigil_cfg_error "$n" E_SECTION_DUPLICATE "section [$section] appears more than once"
                            skipping=1
                            ;;
                        *)
                            seen="$seen$section"$'\n'
                            skipping=0
                            i=${#VIGIL_CFG_SEC_NAME[@]}
                            VIGIL_CFG_SEC_NAME[$i]=$section
                            VIGIL_CFG_SEC_LINE[$i]=$n
                            VIGIL_CFG_SEC_FIRST[$i]=${#VIGIL_CFG_KEY[@]}
                            VIGIL_CFG_SEC_COUNT[$i]=0
                            _vigil_cfg_secvar "$section"
                            printf -v "$_vigil_cfg_secvar" '%s' "$i"
                            ;;
                    esac
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
                VIGIL_CFG_LINE[$i]=$n
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
_vigil_lower() {
    local s=$1 c rest upper=ABCDEFGHIJKLMNOPQRSTUVWXYZ lower=abcdefghijklmnopqrstuvwxyz
    _vigil_lowered=''
    while [ -n "$s" ]; do
        c=${s:0:1}
        s=${s:1}
        case $c in
            [A-Z])
                rest=${upper%%"$c"*}
                c=${lower:${#rest}:1}
                ;;
        esac
        _vigil_lowered=$_vigil_lowered$c
    done
}
