# shellcheck shell=bash
#
# Vigil job command line - bash 3.2 compatible.
#
# Builds the program, argument vector and working directory for a job from
# its effective settings (SPECIFICATION.md 6.4), for a given platform and
# install root. Pure: nothing is started and the filesystem is not read.
# Must produce exactly the same result as Command.ps1 -
# tests/conformance/command holds the shared cases.
#
#   vigil_job_command <job id> <windows|posix> <install root>
#     With VIGIL_CMD_FILE set, that path is the job's file: the cached copy
#     of a script from a source (16.5).
#
# Result:
#   VIGIL_CMD_ERROR      empty, or an error code that makes the job INVALID
#   VIGIL_CMD_MESSAGE    the error message
#   VIGIL_CMD_PROGRAM    the program to start
#   VIGIL_CMD_ARGS[i]    its arguments, never passed through a shell
#   VIGIL_CMD_CWD        the working directory
#   VIGIL_CMD_LINE       windows only: the Arguments string for
#                        ProcessStartInfo, encoded for the Microsoft C
#                        runtime's command-line parser
#
# Requires config.sh and effective.sh.

# Characters cmd.exe interprets in a batch file's command line, even inside
# quotes for % and !. An argument containing one is rejected, never escaped:
# escaping for cmd.exe is not reliable (the "BatBadBut" class of flaw).
_vigil_cmd_batch_unsafe='["%!&|<>^]'

# Resolves a path against the install root. Sets _vc_path.
#   _vigil_cmd_path <path> <platform> <root>
_vigil_cmd_path() {
    local p=$1
    if [ "$2" = windows ]; then
        p=${p//\//\\}
        case $p in
            [A-Za-z]:\\* | \\*) ;;
            .) p=$3 ;;
            *) p="$3\\$p" ;;
        esac
    else
        case $p in
            /*) ;;
            .) p=$3 ;;
            *) p="$3/$p" ;;
        esac
    fi
    _vc_path=$p
}

# Encodes one argument for the Microsoft C runtime parser. Sets _vc_quoted.
# Backslashes are literal except before a quote, where each must be doubled
# and the quote escaped; the closing quote doubles any trailing backslashes.
#   _vigil_cmd_quote <arg> <always: 1|0>
_vigil_cmd_quote() {
    local s=$1 out='' c bs=0 i=0 n
    case $s in
        '' | *[\ \	\"]*) ;;
        *)
            if [ "$2" -eq 0 ]; then
                _vc_quoted=$s
                return
            fi
            ;;
    esac
    n=${#s}
    out='"'
    while [ "$i" -lt "$n" ]; do
        c=${s:$i:1}
        i=$((i + 1))
        case $c in
            \\)
                bs=$((bs + 1))
                ;;
            \")
                while [ "$bs" -gt 0 ]; do out="$out\\\\"; bs=$((bs - 1)); done
                out="$out\\\""
                ;;
            *)
                while [ "$bs" -gt 0 ]; do out="$out\\"; bs=$((bs - 1)); done
                out="$out$c"
                ;;
        esac
    done
    while [ "$bs" -gt 0 ]; do out="$out\\\\"; bs=$((bs - 1)); done
    _vc_quoted="$out\""
}

vigil_job_command() {
    local id=$1 platform=$2 root=$3 job="job.$1"
    local runner='' file='' i value substituted=0 batch=0 always=1 lower
    local LC_ALL=C
    VIGIL_CMD_ERROR=''
    VIGIL_CMD_MESSAGE=''
    VIGIL_CMD_PROGRAM=''
    VIGIL_CMD_ARGS=()
    VIGIL_CMD_CWD=''
    VIGIL_CMD_LINE=''

    vigil_config_effective "$id"
    local job_args=()
    i=0
    while [ "$i" -lt "${#VIGIL_EFF_KEY[@]}" ]; do
        case ${VIGIL_EFF_KEY[$i]} in
            file) file=${VIGIL_EFF_VALUE[$i]} ;;
            runner) runner=${VIGIL_EFF_VALUE[$i]} ;;
            arg) job_args[${#job_args[@]}]=${VIGIL_EFF_VALUE[$i]} ;;
            working_dir) _vigil_cmd_path "${VIGIL_EFF_VALUE[$i]}" "$platform" "$root"; VIGIL_CMD_CWD=$_vc_path ;;
        esac
        i=$((i + 1))
    done

    _vigil_cmd_path "$file" "$platform" "$root"
    file=$_vc_path
    # The cached copy of a script from a source, when the caller has it.
    [ -n "${VIGIL_CMD_FILE-}" ] && file=$VIGIL_CMD_FILE

    if [ -n "$runner" ]; then
        _vigil_eff_get "runner.$runner" command
        value=$_ve_value
        # A command with a directory part is a path; a bare name is found on
        # PATH when the job starts.
        case $platform:$value in
            windows:*[\\/]* | posix:*/*)
                _vigil_cmd_path "$value" "$platform" "$root"
                value=$_vc_path
                ;;
        esac
        VIGIL_CMD_PROGRAM=$value
        _vigil_eff_all "runner.$runner" arg
        for value in ${_ve_values[@]+"${_ve_values[@]}"}; do
            case $value in
                *'{file}'*)
                    value=${value//\{file\}/$file}
                    substituted=1
                    ;;
            esac
            VIGIL_CMD_ARGS[${#VIGIL_CMD_ARGS[@]}]=$value
        done
        if [ "$substituted" -eq 0 ]; then
            VIGIL_CMD_ARGS[${#VIGIL_CMD_ARGS[@]}]=$file
        fi
    else
        VIGIL_CMD_PROGRAM=$file
    fi
    for value in ${job_args[@]+"${job_args[@]}"}; do
        VIGIL_CMD_ARGS[${#VIGIL_CMD_ARGS[@]}]=$value
    done

    [ "$platform" = windows ] || return 0

    _vigil_lower "$VIGIL_CMD_PROGRAM"
    lower=$_vigil_lowered
    case $lower in
        *.bat | *.cmd) batch=1; always=0 ;;
    esac
    # cmd.exe parses the batch file's own path too.
    if [ "$batch" -eq 1 ] && [[ $VIGIL_CMD_PROGRAM =~ $_vigil_cmd_batch_unsafe ]]; then
        VIGIL_CMD_ERROR=E_BATCH_PATH
        VIGIL_CMD_MESSAGE="a batch file's path contains a character cmd.exe interprets (\" % ! & | < > ^): $VIGIL_CMD_PROGRAM"
        return 0
    fi
    VIGIL_CMD_LINE=''
    for value in ${VIGIL_CMD_ARGS[@]+"${VIGIL_CMD_ARGS[@]}"}; do
        if [ "$batch" -eq 1 ] && [[ $value =~ $_vigil_cmd_batch_unsafe ]]; then
            VIGIL_CMD_ERROR=E_BATCH_ARG
            VIGIL_CMD_MESSAGE="an argument to a batch file contains a character cmd.exe interprets (\" % ! & | < > ^): $value"
            return 0
        fi
        _vigil_cmd_quote "$value" "$always"
        if [ -n "$VIGIL_CMD_LINE" ]; then
            VIGIL_CMD_LINE="$VIGIL_CMD_LINE $_vc_quoted"
        else
            VIGIL_CMD_LINE=$_vc_quoted
        fi
    done
}

# vigil_job_command_dump <windows|posix> <install root>
# Prints the command of every job that is not INVALID, one row per line:
#   <job> TAB program TAB <path>
#   <job> TAB arg TAB <value>             one per argument
#   <job> TAB cwd TAB <path>
#   <job> TAB cmdline TAB <string>        windows only
#   INVALID TAB <job> TAB <code>          when the command cannot be built
# A rejected configuration prints nothing.
vigil_job_command_dump() {
    local platform=$1 root=$2 s=0 i name id
    i=0
    while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
        [ "${VIGIL_VAL_KIND[$i]}" = ERROR ] && return 0
        i=$((i + 1))
    done
    [ "${#VIGIL_CFG_ERRORS[@]}" -eq 0 ] || return 0

    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        name=${VIGIL_CFG_SEC_NAME[$s]}
        s=$((s + 1))
        case $name in
            job.*) id=${name#job.} ;;
            *) continue ;;
        esac
        i=0
        while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
            if [ "${VIGIL_VAL_KIND[$i]}" = INVALID ] && [ "${VIGIL_VAL_JOB[$i]}" = "$id" ]; then
                continue 2
            fi
            i=$((i + 1))
        done
        vigil_job_command "$id" "$platform" "$root"
        if [ -n "$VIGIL_CMD_ERROR" ]; then
            printf 'INVALID\t%s\t%s\n' "$id" "$VIGIL_CMD_ERROR"
            continue
        fi
        printf '%s\tprogram\t%s\n' "$id" "$VIGIL_CMD_PROGRAM"
        for i in ${VIGIL_CMD_ARGS[@]+"${VIGIL_CMD_ARGS[@]}"}; do
            printf '%s\targ\t%s\n' "$id" "$i"
        done
        printf '%s\tcwd\t%s\n' "$id" "$VIGIL_CMD_CWD"
        if [ "$platform" = windows ]; then
            printf '%s\tcmdline\t%s\n' "$id" "$VIGIL_CMD_LINE"
        fi
    done
}
