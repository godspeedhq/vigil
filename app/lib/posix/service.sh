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
# service.sh - registering the supervisor with the OS service manager
# (SPECIFICATION.md 18): systemd on Linux, launchd on macOS, in user mode
# (no admin) or system mode (root).
#
#   vigil_service_install <root> <app> <mode> <account> <start>
#   vigil_service_remove  <root>
#   vigil_service_control <root> start|stop|restart
#   vigil_service_status  <root>
#
# Stopping the service stops only the supervisor (18.3): systemd
# KillMode=process, launchd AbandonProcessGroup. Running workers carry on.
#
# One service per machine and mode, named vigil. Its definition names the
# install root, which may hold only letters, digits and . _ - + @ / so it
# needs no quoting in a unit file or plist.

_vigil_svc_err() {
    printf 'vigil: %s\n' "$1" >&2
}

# Sets _vs_os to systemd or launchd, or fails.
_vigil_svc_os() {
    case $(uname -s) in
        Darwin) _vs_os=launchd ;;
        Linux)
            if ! command -v systemctl > /dev/null 2>&1; then
                _vigil_svc_err 'systemd is required to run Vigil as a service (systemctl was not found)'
                return 1
            fi
            _vs_os=systemd
            ;;
        *)
            _vigil_svc_err "no service manager support on $(uname -s)"
            return 1
            ;;
    esac
}

# Sets _vs_file (the unit or plist), _vs_name (the unit or launchd label)
# and _vs_target (the launchd service target) for mode $1. Vigil's own
# registration comes first; else a package's: the .deb or .rpm unit, the
# one brew services writes (sh.brew.vigil in Homebrew 7, earlier
# homebrew.mxcl.vigil, or homebrew.vigil with systemd), or MacPorts's
# LaunchDaemon (org.macports.vigil). Once _vigil_svc_find has set _vs_root,
# the first that is that root's wins, so two installs on one machine each
# find their own.
_vigil_svc_paths() {
    local mode=$1 f d target='' first=''
    if [ "$_vs_os" = systemd ]; then
        if [ "$mode" = system ]; then
            set -- /etc/systemd/system/vigil.service /usr/lib/systemd/system/vigil.service \
                /etc/systemd/system/sh.brew.vigil.service /usr/lib/systemd/system/sh.brew.vigil.service \
                /etc/systemd/system/homebrew.vigil.service /usr/lib/systemd/system/homebrew.vigil.service
        else
            d=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
            set -- "$d/vigil.service" "$d/sh.brew.vigil.service" "$d/homebrew.vigil.service"
        fi
    else
        if [ "$mode" = system ]; then
            d=/Library/LaunchDaemons
            target=system
        else
            d=$HOME/Library/LaunchAgents
            target=gui/$(id -u)
        fi
        set -- "$d/vigil.plist" "$d/sh.brew.vigil.plist" "$d/homebrew.mxcl.vigil.plist" "$d/org.macports.vigil.plist"
    fi
    for f in "$@"; do
        [ -f "$f" ] || continue
        [ -n "$first" ] || first=$f
        [ -n "${_vs_root-}" ] || break
        _vigil_svc_at "$f" "$target"
        _vigil_svc_mine "$_vs_root" && return 0
    done
    _vigil_svc_at "${first:-$1}" "$target"
}

# Sets _vs_file to $1, and _vs_name and _vs_target from it ($2 is the
# launchd domain).
_vigil_svc_at() {
    _vs_file=$1
    _vs_name=${1##*/}
    _vs_name=${_vs_name%.service}
    _vs_name=${_vs_name%.plist}
    [ "$_vs_os" = systemd ] || _vs_target=$2/$_vs_name
    return 0
}

# True when _vs_file is a package's registration, which the package manager
# owns: vigil service install and remove leave it to systemctl, brew
# services or port load, and the package.
_vigil_svc_packaged() {
    case $_vs_file in /usr/lib/* | */homebrew.* | */sh.brew.* | */org.macports.*) return 0 ;; esac
    return 1
}

# Who owns a package's registration, and how it is started ($1 = start) or
# stopped ($1 = stop): into _vs_who and _vs_how.
_vigil_svc_package_how() {
    local sudo=''
    [ "$_vs_mode" = system ] && sudo='sudo '
    case $_vs_name in
        homebrew.* | sh.brew.*)
            _vs_who=Homebrew
            _vs_how="${sudo}brew services $1 vigil"
            ;;
        org.macports.*)
            _vs_who=MacPorts
            if [ "$1" = start ]; then _vs_how='sudo port load vigil'; else _vs_how='sudo port unload vigil'; fi
            ;;
        *)
            _vs_who='the vigil package'
            if [ "$1" = start ]; then _vs_how='sudo systemctl enable --now vigil'; else _vs_how='sudo systemctl disable --now vigil'; fi
            ;;
    esac
}

# systemctl, for the user's own manager in user mode.
_vigil_svc_systemctl() {
    if [ "$_vs_mode" = user ]; then
        systemctl --user "$@"
    else
        systemctl "$@"
    fi
}

# True when _vs_file is the registration of root $1: its working
# directory is the root.
_vigil_svc_mine() {
    if [ "$_vs_os" = systemd ]; then
        grep -Fx -- "WorkingDirectory=$1" "$_vs_file" > /dev/null 2>&1
    elif [ "$_vs_name" != vigil ]; then
        # brew services writes each key and value on lines of their own.
        grep -F -- "<string>$1</string>" "$_vs_file" > /dev/null 2>&1
    else
        grep -F -- "<key>WorkingDirectory</key><string>$1</string>" "$_vs_file" > /dev/null 2>&1
    fi
}

# Finds this root's registration: sets _vs_mode to system or user, or
# empty when there is none. Root's registration is looked for first.
# _vs_other names a registration that belongs to another root.
_vigil_svc_find() {
    local root=$1 m
    _vs_root=$root
    _vs_mode=''
    _vs_other=''
    for m in system user; do
        _vigil_svc_paths "$m"
        [ -f "$_vs_file" ] || continue
        if _vigil_svc_mine "$root"; then
            _vs_mode=$m
            return 0
        fi
        [ -n "$_vs_other" ] || _vs_other=$_vs_file
    done
    return 0
}

# Writes the unit or plist for _vs_mode to _vs_file.
_vigil_svc_write() {
    local root=$1 app=$2 account=$3 tmp
    mkdir -p "$(dirname "$_vs_file")" || return 1
    tmp="$_vs_file.tmp.$$"
    if [ "$_vs_os" = systemd ]; then
        {
            printf '# Written by vigil service install. Change the environment with\n'
            printf '# systemctl%s edit vigil, which survives a reinstall.\n' "$([ "$_vs_mode" = user ] && printf ' --user')"
            printf '[Unit]\nDescription=Vigil job scheduler and supervisor\n'
            printf 'After=network-online.target\nWants=network-online.target\n'
            # Restart throttling (18.4): at most 5 starts in 5 minutes.
            printf 'StartLimitIntervalSec=300\nStartLimitBurst=5\n\n'
            printf '[Service]\nType=simple\n'
            [ "$_vs_mode" = system ] && printf 'User=%s\n' "$account"
            printf 'WorkingDirectory=%s\n' "$root"
            printf 'ExecStart=%s %s/vigil --root %s supervise\n' "$BASH" "$app" "$root"
            # Stop only the supervisor; workers survive (18.3).
            printf 'KillMode=process\nRestart=on-failure\nRestartSec=10\nTimeoutStopSec=30\n\n'
            printf '[Install]\nWantedBy=%s\n' "$([ "$_vs_mode" = user ] && printf default.target || printf multi-user.target)"
        } > "$tmp" || return 1
    else
        {
            printf '<?xml version="1.0" encoding="UTF-8"?>\n'
            printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            printf '<plist version="1.0">\n<dict>\n'
            printf '  <key>Label</key><string>vigil</string>\n'
            printf '  <key>ProgramArguments</key>\n  <array>\n'
            printf '    <string>%s</string>\n' "$BASH" "$app/vigil" --root "$root" supervise
            printf '  </array>\n'
            printf '  <key>WorkingDirectory</key><string>%s</string>\n' "$root"
            [ "$_vs_mode" = system ] && [ "$account" != root ] && printf '  <key>UserName</key><string>%s</string>\n' "$account"
            printf '  <key>RunAtLoad</key><true/>\n'
            # Restart on failure, not after a clean stop (18.4).
            printf '  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>\n'
            printf '  <key>ThrottleInterval</key><integer>10</integer>\n'
            # Stop only the supervisor; workers survive (18.3).
            printf '  <key>AbandonProcessGroup</key><true/>\n'
            printf '  <key>StandardOutPath</key><string>%s/logs/supervisor/service.log</string>\n' "$root"
            printf '  <key>StandardErrorPath</key><string>%s/logs/supervisor/service.log</string>\n' "$root"
            printf '</dict>\n</plist>\n'
        } > "$tmp" || return 1
    fi
    chmod 644 "$tmp" && mv -f "$tmp" "$_vs_file"
}

# Linux system mode runs as a dedicated account, created when it is the
# default and missing.
_vigil_svc_account() {
    local account=$1 root=$2 nologin
    id "$account" > /dev/null 2>&1 && return 0
    if [ "$_vs_os" != systemd ] || [ "$account" != vigil ]; then
        _vigil_svc_err "the account $account does not exist"
        return 1
    fi
    nologin=$(command -v nologin 2> /dev/null)
    [ -n "$nologin" ] || nologin=/usr/sbin/nologin
    if ! useradd --system --user-group --no-create-home --home-dir "$root" --shell "$nologin" vigil; then
        _vigil_svc_err 'could not create the vigil account'
        return 1
    fi
    printf 'created the system account vigil\n'
}

# Runs vigil as the service account (system mode), or as the caller.
_vigil_svc_as() {
    local account=$1
    shift
    if [ "$_vs_mode" = user ] || [ "$account" = "$(id -un)" ]; then
        "$BASH" "$@"
    elif [ "$_vs_os" = systemd ] && command -v runuser > /dev/null 2>&1; then
        runuser -u "$account" -- "$BASH" "$@"
    else
        sudo -u "$account" "$BASH" "$@"
    fi
}

# True when the launchd service is loaded.
_vigil_svc_loaded() {
    launchctl print "$_vs_target" > /dev/null 2>&1
}

# True when the launchd service's process is running.
_vigil_svc_running() {
    launchctl print "$_vs_target" 2> /dev/null | grep -q '^[[:space:]]*state = running'
}

# Loads the launchd service. A user's LaunchAgent goes into the login's GUI
# domain, which only a desktop login has: from an SSH login it cannot, and
# says so, and what to do.
_vigil_svc_bootstrap() {
    local out
    if out=$(launchctl bootstrap "${_vs_target%/*}" "$_vs_file" 2>&1); then return 0; fi
    if [ "$_vs_mode" = user ] && [ "$(launchctl managername 2> /dev/null)" != Aqua ]; then
        _vigil_svc_err 'not started: this login has no desktop session (an SSH login, for one), and a LaunchAgent runs only in one'
        printf '  it starts at the next desktop login; until then, vigil supervise runs it in this session; a LaunchDaemon (--system) runs unattended\n' >&2
    else
        _vigil_svc_err "launchctl bootstrap ${_vs_target%/*} failed: $out"
    fi
    return 1
}

# Unloads the launchd service and waits for it to be gone: bootout returns
# before launchd has finished, and a bootstrap meanwhile fails.
_vigil_svc_unload() {
    local i=0
    launchctl bootout "$_vs_target" > /dev/null 2>&1
    while _vigil_svc_loaded && [ "$i" -lt 60 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    if _vigil_svc_loaded; then
        _vigil_svc_err "launchd did not unload $_vs_target within 30s"
        return 1
    fi
}

vigil_service_install() {
    local root=$1 app=$2 mode=$3 account=$4 start=$5 d
    case $root in
        *[!A-Za-z0-9._/@+-]*)
            _vigil_svc_err "the install root $root may contain only letters, digits and . _ - + @ /"
            return 1
            ;;
    esac
    _vigil_svc_os || return 1
    if [ -z "$mode" ]; then
        if [ "$(id -u)" -eq 0 ]; then mode=system; else mode=user; fi
    fi
    if [ "$mode" = system ] && [ "$(id -u)" -ne 0 ]; then
        _vigil_svc_err 'system mode needs root: run it with sudo, or use --user'
        return 1
    fi
    if [ "$mode" = user ] && [ "$(id -u)" -eq 0 ]; then
        _vigil_svc_err 'user mode runs as the account that installs it, not root: use --system'
        return 1
    fi
    if [ "$mode" = user ]; then
        if [ -n "$account" ] && [ "$account" != "$(id -un)" ]; then
            _vigil_svc_err '--account applies to system mode only'
            return 1
        fi
        account=$(id -un)
    elif [ -z "$account" ]; then
        if [ "$_vs_os" = systemd ]; then account=vigil; else account=root; fi
    fi

    _vigil_svc_find "$root"
    if [ -n "$_vs_mode" ] && [ "$_vs_mode" != "$mode" ]; then
        # A package's registration is not one to remove first.
        _vigil_svc_paths "$_vs_mode"
        if _vigil_svc_packaged; then
            _vigil_svc_package_how start
            _vigil_svc_err "$_vs_who installed this service: start it with $_vs_how"
            return 1
        fi
        _vigil_svc_err "this root is already registered in $_vs_mode mode: run vigil service remove first"
        return 1
    fi
    _vs_mode=$mode
    _vigil_svc_paths "$mode"
    if _vigil_svc_packaged && _vigil_svc_mine "$root"; then
        _vigil_svc_package_how start
        _vigil_svc_err "$_vs_who installed this service: start it with $_vs_how"
        return 1
    fi
    # A package that runs the service itself says how in PACKAGED, before
    # it has registered anything: a registration of Vigil's own would name
    # a program path the next upgrade replaces.
    if vigil_packaged "$app" && [ -n "$_vp_service" ]; then
        _vigil_svc_err "Vigil was installed by $_vp_manager, which runs its service: $_vp_service"
        return 1
    fi
    if [ -f "$_vs_file" ] && ! _vigil_svc_mine "$root"; then
        _vigil_svc_err "$_vs_file belongs to another Vigil install: remove that one first"
        return 1
    fi

    # The folders the supervisor writes, owned by the service account.
    for d in config scripts state spool logs logs/supervisor cache metrics; do
        mkdir -p "$root/$d" || return 1
    done
    if [ "$mode" = system ] && [ "$account" != root ]; then
        _vigil_svc_account "$account" "$root" || return 1
        for d in config scripts state spool logs cache metrics; do
            chown -R "$account:$(id -gn "$account")" "$root/$d" || return 1
        done
    fi

    # Nothing is registered unless pre-flight passes (18.7), checked as the
    # account the service runs as.
    printf 'pre-flight checks, as %s:\n' "$account"
    if ! _vigil_svc_as "$account" "$app/vigil" --root "$root" precheck; then
        _vigil_svc_err 'pre-flight checks failed; the service was not registered'
        return 1
    fi

    if [ "$_vs_os" = launchd ] && _vigil_svc_loaded; then
        _vigil_svc_unload || return 1
    fi
    _vigil_svc_write "$root" "$app" "$account" || {
        _vigil_svc_err "could not write $_vs_file"
        return 1
    }
    printf 'registered %s\n' "$_vs_file"

    if [ "$_vs_os" = systemd ]; then
        _vigil_svc_systemctl daemon-reload || return 1
        _vigil_svc_systemctl enable "$_vs_name" > /dev/null 2>&1 || {
            _vigil_svc_err "systemctl enable $_vs_name failed"
            return 1
        }
        if [ "$start" = 1 ]; then
            _vigil_svc_systemctl restart "$_vs_name" || return 1
            printf 'started vigil\n'
        fi
        if [ "$mode" = user ] && command -v loginctl > /dev/null 2>&1 &&
            [ "$(loginctl show-user "$(id -un)" -p Linger --value 2> /dev/null)" != yes ]; then
            printf 'note: Vigil runs only while you are logged in; for unattended use run: loginctl enable-linger %s\n' "$(id -un)"
        fi
    elif [ "$start" = 1 ]; then
        # Loading starts it (RunAtLoad); without --no-start it loads at the
        # next boot or login.
        _vigil_svc_bootstrap || return 1
        printf 'started vigil\n'
    fi
    if [ "$mode" = user ] && [ "$_vs_os" = launchd ]; then
        printf 'note: Vigil runs only while you are logged in; a LaunchDaemon (--system) runs unattended\n'
    fi
    return 0
}

vigil_service_remove() {
    local root=$1
    _vigil_svc_os || return 1
    _vigil_svc_find "$root"
    if [ -z "$_vs_mode" ]; then
        printf 'vigil is not registered as a service for %s; nothing to do\n' "$root"
        return 0
    fi
    _vigil_svc_paths "$_vs_mode"
    if _vigil_svc_packaged; then
        _vigil_svc_package_how stop
        _vigil_svc_err "$_vs_who installed this service: stop it with $_vs_how, or remove the package"
        return 1
    fi
    if [ "$_vs_mode" = system ] && [ "$(id -u)" -ne 0 ]; then
        _vigil_svc_err 'the service is registered in system mode: run it with sudo'
        return 1
    fi
    if [ "$_vs_os" = systemd ]; then
        # Stopping leaves workers running (18.3).
        _vigil_svc_systemctl disable --now "$_vs_name" > /dev/null 2>&1
        rm -f "$_vs_file" || return 1
        _vigil_svc_systemctl daemon-reload
    else
        if _vigil_svc_loaded; then _vigil_svc_unload || return 1; fi
        rm -f "$_vs_file" || return 1
    fi
    printf 'removed %s; running workers continue\n' "$_vs_file"
}

vigil_service_control() {
    local root=$1 action=$2 i
    _vigil_svc_os || return 1
    _vigil_svc_find "$root"
    if [ -z "$_vs_mode" ]; then
        _vigil_svc_err "vigil is not registered as a service for $root: run vigil service install"
        return 1
    fi
    if [ "$_vs_mode" = system ] && [ "$(id -u)" -ne 0 ]; then
        _vigil_svc_err 'the service runs in system mode: run it with sudo'
        return 1
    fi
    _vigil_svc_paths "$_vs_mode"
    if [ "$_vs_os" = systemd ]; then
        _vigil_svc_systemctl "$action" "$_vs_name" || return 1
    else
        if [ "$action" != start ] && _vigil_svc_running; then
            # TERM: the supervisor finishes its tick and exits 0, which
            # launchd does not restart (KeepAlive SuccessfulExit).
            launchctl kill TERM "$_vs_target" > /dev/null 2>&1
            i=0
            while _vigil_svc_running && [ "$i" -lt 60 ]; do
                sleep 0.5
                i=$((i + 1))
            done
            if _vigil_svc_running; then
                _vigil_svc_err 'the supervisor did not stop within 30s'
                return 1
            fi
        fi
        if [ "$action" != stop ]; then
            if _vigil_svc_loaded; then
                launchctl kickstart "$_vs_target" > /dev/null || return 1
            else
                _vigil_svc_bootstrap || return 1
            fi
        fi
    fi
    case $action in
        start) printf 'started vigil\n' ;;
        stop) printf 'stopped vigil; running workers continue\n' ;;
        restart) printf 'restarted vigil; running workers continue\n' ;;
    esac
}

# The service's state, then jobs.log (13.2).
vigil_service_status() {
    local root=$1 state='not registered' logdir=$root/logs pid
    if _vigil_svc_os 2> /dev/null; then
        _vigil_svc_find "$root"
        if [ -n "$_vs_mode" ]; then
            _vigil_svc_paths "$_vs_mode"
            if [ "$_vs_os" = systemd ]; then
                state=$(_vigil_svc_systemctl is-active "$_vs_name" 2> /dev/null)
                pid=$(_vigil_svc_systemctl show -p MainPID --value "$_vs_name" 2> /dev/null)
            elif _vigil_svc_running; then
                state=active
                pid=$(launchctl print "$_vs_target" 2> /dev/null | sed -n 's/^[[:space:]]*pid = //p' | head -n 1)
            elif _vigil_svc_loaded; then
                state=inactive
            else
                state='inactive (not loaded)'
            fi
            [ -n "$state" ] || state=unknown
            [ "$state" = active ] && [ -n "${pid-}" ] && [ "$pid" != 0 ] && state="active, pid $pid"
            state="$state ($_vs_os, $_vs_mode mode)"
        fi
    fi
    printf 'service: %s\n' "$state"
    # The backends of the configuration in effect: the active one when it is
    # fetched (6.8, 16.5). Before the first fetch there is nothing to say.
    local known=0
    if vigil_config_parse "$root/config/vigil.config" 2> /dev/null; then
        known=1
        _vw_root=$root
        if vigil_fetch_mode; then
            _vigil_wk_dir vigil state_dir state
            known=0
            vigil_active_read "$_vw_dir" && vigil_config_parse "$VIGIL_ACT_CONFIG" 2> /dev/null && known=1
        fi
    fi
    if [ "$known" = 1 ]; then
        case " ${VIGIL_CFG_SEC_NAME[*]-} " in
            *' backend.'*) ;;
            *) printf 'metrics: no backend, so they go nowhere until you add one\n' ;;
        esac
    fi
    if _vw_root=$root _vw_job=vigil_sender _vigil_wk_config 2> /dev/null; then logdir=$_vw_logdir; fi
    # Never "no jobs.log yet" for a log folder this account cannot see into
    # (backlog 40).
    local denied
    if denied=$(_vigil_svc_unreadable "$root" "$logdir" "$logdir/supervisor" "$logdir/supervisor/jobs.log"); then
        _vigil_svc_err "cannot read $denied from this account: run vigil status as the account that installed Vigil (sudo for a system install)"
        return 1
    fi
    if [ -f "$logdir/supervisor/jobs.log" ]; then
        printf '\n'
        cat "$logdir/supervisor/jobs.log"
    else
        printf '\nno jobs.log yet: the supervisor writes it every tick\n'
    fi
    return 0
}

# Prints the first of these folders and files this account cannot look into
# or read, and succeeds; fails when it can read them all. Checked from the
# top down: a folder that cannot be entered hides what is inside it.
_vigil_svc_unreadable() {
    local p
    for p in "$@"; do
        if [ -d "$p" ]; then
            if [ ! -r "$p" ] || [ ! -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
        elif [ -e "$p" ] && [ ! -r "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

# A value from a state file.
_vigil_svc_state_value() {
    sed -n "s/^$2 *= \{0,1\}//p" "$1" 2> /dev/null | head -n 1
}

# The runs in progress, proven to be this root's: for each token in
# locks/, the job process holding the token and the worker whose command
# line names the run (11.5). Sets _vs_pids (proven) and _vs_unproven.
_vigil_svc_runs() {
    local statedir=$1 t base job rid st wpid jpid args
    _vs_pids=''
    _vs_unproven=''
    case $(uname -s) in
        Darwin) _su_platform=macos ;;
        *) _su_platform=linux ;;
    esac
    for t in "$statedir"/locks/*.token; do
        [ -e "$t" ] || continue
        base=${t##*/}
        base=${base%.token}
        rid=${base##*.}
        job=${base%.*}
        st=$statedir/jobs/$job.state
        wpid=$(_vigil_svc_state_value "$st" worker_pid)
        jpid=$(_vigil_svc_state_value "$st" job_pid)
        if [ -n "$jpid" ] && [ "$(_vigil_svc_state_value "$st" run_id)" = "$rid" ]; then
            _vigil_sup_holds "$jpid" "$t"
            if [ "$_su_held" = yes ]; then _vs_pids="$_vs_pids $jpid"; else _vs_unproven="$_vs_unproven $jpid"; fi
        fi
        if [ -n "$wpid" ]; then
            args=$(ps -o args= -p "$wpid" 2> /dev/null)
            case $args in
                *" worker $job --run-id $rid"*) _vs_pids="$_vs_pids $wpid" ;;
                '') ;;
                *) _vs_unproven="$_vs_unproven $wpid" ;;
            esac
        fi
    done
}

# vigil uninstall (18.8): the service, the proven workers, then the root
# (all of it, or all but config/ and scripts/), and the command link.
vigil_uninstall() {
    local root=$1 yes=$2 keep=$3 statedir=$root/state n link answer p i alive
    if [ ! -f "$root/app/vigil" ] || [ "$root" = / ] || [ "$root" = "$HOME" ]; then
        _vigil_svc_err "$root does not look like a Vigil install root (no app/vigil); nothing removed"
        return 1
    fi
    if _vw_root=$root _vw_job=vigil_sender _vigil_wk_config 2> /dev/null; then statedir=$_vw_statedir; fi
    _vigil_svc_runs "$statedir"
    link=''
    for p in /usr/local/bin/vigil "$HOME/.local/bin/vigil"; do
        if [ -L "$p" ] && [ "$(readlink "$p")" = "$root/app/vigil" ]; then link="$link $p"; fi
    done
    n=$(find "$root/scripts" -type f 2> /dev/null | wc -l | tr -d ' ')

    printf 'vigil uninstall will remove:\n'
    _vigil_svc_os 2> /dev/null && _vigil_svc_find "$root" && [ -n "$_vs_mode" ] &&
        printf '  the %s service registration (%s mode)\n' "$_vs_os" "$_vs_mode"
    [ -n "$_vs_pids" ] && printf '  running Vigil processes:%s\n' "$_vs_pids"
    if [ "$keep" = 1 ]; then
        printf '  %s, except config/ and scripts/ (%s scripts kept)\n' "$root" "$n"
    else
        printf '  %s, including config/ and scripts/ (%s scripts)\n' "$root" "$n"
    fi
    [ -n "$link" ] && printf '  the vigil command:%s\n' "$link"
    [ -n "$_vs_unproven" ] && printf 'and leave running, since they cannot be proven to be Vigil'"'"'s:%s\n' "$_vs_unproven"
    if [ "$yes" != 1 ]; then
        if [ ! -t 0 ]; then
            _vigil_svc_err 'not a terminal: confirm with --yes'
            return 1
        fi
        printf 'Remove? [y/N] '
        IFS= read -r answer
        case $answer in
            y | Y | yes | YES) ;;
            *)
                printf 'nothing removed\n'
                return 1
                ;;
        esac
    fi

    vigil_service_remove "$root" > /dev/null || return 1
    if [ -n "$_vs_pids" ]; then
        # TERM, then KILL whatever is still alive after 10 seconds.
        for p in $_vs_pids; do kill -TERM -- "-$p" 2> /dev/null || kill -TERM "$p" 2> /dev/null; done
        i=0
        while [ "$i" -lt 20 ]; do
            alive=''
            for p in $_vs_pids; do kill -0 "$p" 2> /dev/null && alive="$alive $p"; done
            [ -z "$alive" ] && break
            sleep 0.5
            i=$((i + 1))
        done
        for p in $alive; do kill -KILL -- "-$p" 2> /dev/null || kill -KILL "$p" 2> /dev/null; done
    fi
    for p in $link; do rm -f "$p"; done
    # The sudo rule of install --update-by, if it is this install's.
    if [ -f /etc/sudoers.d/vigil ] && grep -qF " $root/app/vigil self update" /etc/sudoers.d/vigil 2> /dev/null; then
        rm -f /etc/sudoers.d/vigil
    fi
    if [ "$keep" = 1 ]; then
        for p in "$root"/* "$root"/.[!.]*; do
            [ -e "$p" ] || continue
            case ${p##*/} in config | scripts | packs) ;; *) rm -rf "$p" ;; esac
        done
        printf 'removed Vigil; kept %s/config and %s/scripts\n' "$root" "$root"
    else
        rm -rf "$root" || return 1
        printf 'removed Vigil\n'
    fi
    return 0
}
