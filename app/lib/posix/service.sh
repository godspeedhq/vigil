# shellcheck shell=bash
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

# Sets _vs_file (the unit or plist) and _vs_target (the launchd service
# target) for mode $1.
_vigil_svc_paths() {
    if [ "$_vs_os" = systemd ]; then
        if [ "$1" = system ]; then
            _vs_file=/etc/systemd/system/vigil.service
        else
            _vs_file=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/vigil.service
        fi
    else
        if [ "$1" = system ]; then
            _vs_file=/Library/LaunchDaemons/vigil.plist
            _vs_target=system/vigil
        else
            _vs_file=$HOME/Library/LaunchAgents/vigil.plist
            _vs_target=gui/$(id -u)/vigil
        fi
    fi
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
    else
        grep -F -- "<key>WorkingDirectory</key><string>$1</string>" "$_vs_file" > /dev/null 2>&1
    fi
}

# Finds this root's registration: sets _vs_mode to system or user, or
# empty when there is none. Root's registration is looked for first.
# _vs_other names a registration that belongs to another root.
_vigil_svc_find() {
    local root=$1 m
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
        _vigil_svc_err "this root is already registered in $_vs_mode mode: run vigil service remove first"
        return 1
    fi
    _vs_mode=$mode
    _vigil_svc_paths "$mode"
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
        launchctl bootout "$_vs_target" > /dev/null 2>&1
    fi
    _vigil_svc_write "$root" "$app" "$account" || {
        _vigil_svc_err "could not write $_vs_file"
        return 1
    }
    printf 'registered %s\n' "$_vs_file"

    if [ "$_vs_os" = systemd ]; then
        _vigil_svc_systemctl daemon-reload || return 1
        _vigil_svc_systemctl enable vigil > /dev/null 2>&1 || {
            _vigil_svc_err 'systemctl enable vigil failed'
            return 1
        }
        if [ "$start" = 1 ]; then
            _vigil_svc_systemctl restart vigil || return 1
            printf 'started vigil\n'
        fi
        if [ "$mode" = user ] && command -v loginctl > /dev/null 2>&1 &&
            [ "$(loginctl show-user "$(id -un)" -p Linger --value 2> /dev/null)" != yes ]; then
            printf 'note: Vigil runs only while you are logged in; for unattended use run: loginctl enable-linger %s\n' "$(id -un)"
        fi
    elif [ "$start" = 1 ]; then
        # Loading starts it (RunAtLoad); without --no-start it loads at the
        # next boot or login.
        if ! launchctl bootstrap "${_vs_target%/vigil}" "$_vs_file"; then
            _vigil_svc_err "launchctl bootstrap ${_vs_target%/vigil} failed"
            return 1
        fi
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
    if [ "$_vs_mode" = system ] && [ "$(id -u)" -ne 0 ]; then
        _vigil_svc_err 'the service is registered in system mode: run it with sudo'
        return 1
    fi
    _vigil_svc_paths "$_vs_mode"
    if [ "$_vs_os" = systemd ]; then
        # Stopping leaves workers running (18.3).
        _vigil_svc_systemctl disable --now vigil > /dev/null 2>&1
        rm -f "$_vs_file" || return 1
        _vigil_svc_systemctl daemon-reload
    else
        _vigil_svc_loaded && launchctl bootout "$_vs_target" > /dev/null 2>&1
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
        _vigil_svc_systemctl "$action" vigil || return 1
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
                launchctl bootstrap "${_vs_target%/vigil}" "$_vs_file" || return 1
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
                state=$(_vigil_svc_systemctl is-active vigil 2> /dev/null)
                pid=$(_vigil_svc_systemctl show -p MainPID --value vigil 2> /dev/null)
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
    if _vw_root=$root _vw_job=vigil_sender _vigil_wk_config 2> /dev/null; then logdir=$_vw_logdir; fi
    if [ -f "$logdir/supervisor/jobs.log" ]; then
        printf '\n'
        cat "$logdir/supervisor/jobs.log"
    else
        printf '\nno jobs.log yet: the supervisor writes it every tick\n'
    fi
    return 0
}
