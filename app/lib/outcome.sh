# shellcheck shell=bash
#
# Vigil run outcomes - bash 3.2 compatible.
#
# Classifies a finished job's exit code by its exit_codes setting
# (SPECIFICATION.md 10.2). A pure function of its inputs. Must produce
# exactly the same result as Outcome.ps1 - tests/conformance/outcome holds
# the shared table.
#
#   vigil_outcome <exit_codes> <exit code>
#     exit_codes  standard, nagios, or a list such as 0,24 or 0-7 (already
#                 validated, so every item is a code or a range of codes)
#     exit code   a whole number; may be negative or above 255, as Windows
#                 exit codes can be
#   Sets VIGIL_OUTCOME: succeeded, warning, failed, unknown, or error for
#   malformed input.
#
# bash 3.2: no associative arrays.

_vigil_out_re_exit='^-?[0-9]{1,10}$'
_vigil_out_re_code='^([0-9]{1,3})(-([0-9]{1,3}))?$'

vigil_outcome() {
    local spec=$1 code=$2 rest item lo hi
    local LC_ALL=C
    VIGIL_OUTCOME=error
    if ! [[ $code =~ $_vigil_out_re_exit ]]; then
        return 1
    fi
    # Without leading zeros, so 010 is ten and not octal.
    case $code in
        -*) code=-$((10#${code#-})) ;;
        *) code=$((10#$code)) ;;
    esac

    case $spec in
        standard)
            if [ "$code" -eq 0 ]; then VIGIL_OUTCOME=succeeded; else VIGIL_OUTCOME=failed; fi
            return 0
            ;;
        nagios)
            case $code in
                0) VIGIL_OUTCOME=succeeded ;;
                1) VIGIL_OUTCOME=warning ;;
                2) VIGIL_OUTCOME=failed ;;
                *) VIGIL_OUTCOME=unknown ;;
            esac
            return 0
            ;;
    esac

    # A list: succeeded when the code is listed, failed otherwise.
    rest=$spec
    VIGIL_OUTCOME=failed
    while :; do
        item=${rest%%,*}
        # Items may carry spaces around the comma.
        item=${item//[ 	]/}
        if ! [[ $item =~ $_vigil_out_re_code ]]; then
            VIGIL_OUTCOME=error
            return 1
        fi
        lo=$((10#${BASH_REMATCH[1]}))
        hi=$lo
        if [ -n "${BASH_REMATCH[3]}" ]; then hi=$((10#${BASH_REMATCH[3]})); fi
        if [ "$code" -ge "$lo" ] && [ "$code" -le "$hi" ]; then
            VIGIL_OUTCOME=succeeded
        fi
        case $rest in
            *,*) rest=${rest#*,} ;;
            *) break ;;
        esac
    done
    return 0
}
