# shellcheck shell=bash
#
# Vigil recovery conclusions - bash 3.2 compatible.
#
# Decides, from the evidence the supervisor gathered about a job's latest
# run, what that run is (SPECIFICATION.md 11.3). A pure function of its
# inputs: the probes that gather the evidence live in the supervisor. Must
# produce exactly the same result as Recovery.ps1 -
# tests/conformance/recovery holds the shared table.
#
#   vigil_recovery_conclude <launch> <token> <process> <boot> <state> <spool>
#     launch   none, held (a worker is claiming it), young (not held, within
#              the 120 second launch grace), old (not held, past the grace)
#              or prevboot (written during an earlier boot)
#     token    none, held or free (exists, not held)
#     process  yes (a process carries the run id), no, or error (the probe
#              failed); - when it was not needed
#     boot     same or changed: the boot the run started in, against now
#     state    running, final (succeeded ... crashed), unreadable or missing
#     spool    yes when a spool file holds the run's outcome, else no
#   Sets VIGIL_RECOVERY to one of:
#     idle       no run to account for: schedule normally
#     alive      a run is active: never start another
#     launching  a launch is in progress: hold the job, start nothing
#     abandon    abandon the launch (11.2); if that fails, it is alive
#     finished   the run is over and its outcome is known: record it
#     crashed    the run is over with no outcome: record crashed
#     uncertain  the evidence conflicts or a probe failed: hold, never kill
#
# The order matters: a launch record is checked before anything else, and
# nothing is concluded over while any evidence says the run may be alive.

vigil_recovery_conclude() {
    local launch=$1 token=$2 process=$3 boot=$4 state=$5 spool=$6
    case $launch in
        held) VIGIL_RECOVERY=alive; return 0 ;;
        prevboot) VIGIL_RECOVERY=abandon; return 0 ;;
        young) VIGIL_RECOVERY=launching; return 0 ;;
        old)
            case $process in
                yes) VIGIL_RECOVERY=launching ;;
                no) VIGIL_RECOVERY=abandon ;;
                *) VIGIL_RECOVERY=uncertain ;;
            esac
            return 0
            ;;
    esac

    # No launch in progress. Without a token, a final or missing state
    # leaves nothing to account for.
    if [ "$token" = none ]; then
        case $state in final | missing) VIGIL_RECOVERY=idle; return 0 ;; esac
    fi

    # Nothing from an earlier boot can still be alive.
    if [ "$boot" = changed ]; then
        if [ "$state" = final ] || [ "$spool" = yes ]; then
            VIGIL_RECOVERY=finished
        else
            VIGIL_RECOVERY=crashed
        fi
        return 0
    fi

    if [ "$token" = held ] || [ "$process" = yes ]; then
        VIGIL_RECOVERY=alive
    elif [ "$process" = error ]; then
        VIGIL_RECOVERY=uncertain
    elif [ "$state" = final ] || [ "$spool" = yes ]; then
        VIGIL_RECOVERY=finished
    else
        VIGIL_RECOVERY=crashed
    fi
    return 0
}

# vigil_recovery_table_dump <table file>
# Reads a conclusions table - one row per case, whitespace-separated:
#   <launch> <token> <process> <boot> <state> <spool> <conclusion>
# blank lines and # comments ignored - and prints each row with the last
# column computed, single-space separated.
vigil_recovery_table_dump() {
    local launch token process boot state spool rest
    while read -r launch token process boot state spool rest || [ -n "$launch" ]; do
        case $launch in '' | '#'*) continue ;; esac
        vigil_recovery_conclude "$launch" "$token" "$process" "$boot" "$state" "$spool"
        printf '%s %s %s %s %s %s %s\n' "$launch" "$token" "$process" "$boot" "$state" "$spool" "$VIGIL_RECOVERY"
    done < "$1"
}
