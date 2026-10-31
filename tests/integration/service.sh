#!/usr/bin/env bash
#
# Integration test: service registration (SPECIFICATION.md 18) with
# systemd on Linux and launchd on macOS, in system mode (needs sudo
# without a password, as on CI runners) and, where the account has a
# service manager of its own, user mode. Registers a real service, checks
# that a running job outlives "vigil stop" and "vigil service remove", and
# that failing pre-flight checks register nothing.
#
# It changes the machine: run it on a CI runner or a throwaway VM.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
pass=0
fail=0

check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"
    fi
}

# The service state from the first line of vigil status: active or inactive.
svc_state() {
    "$@" status 2> /dev/null | sed -n '1s/^service: \([a-z ]*\).*/\1/p' | sed 's/ *$//'
}

# Waits up to $2 seconds for file $1.
wait_file() {
    local i=0
    while [ "$i" -lt $(($2 * 2)) ]; do
        $sudo test -s "$1" && return 0
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

# Writes an install root at $1: the app, a job that holds on for five
# minutes, recording its pid, and a configuration.
make_root() {
    $sudo mkdir -p "$1/config" "$1/scripts"
    $sudo cp -R "$repo/app" "$1/"
    printf '%s\n' 'echo $$ > "$IT_STATE/hold.pid"' 'exec sleep 300' | $sudo tee "$1/scripts/hold.sh" > /dev/null
    $sudo tee "$1/config/vigil.config" > /dev/null <<EOF
[vigil]
instance = service-it

[scheduler]
tick = 1s

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[job.hold]
file      = scripts/hold.sh
env       = IT_STATE=$1/state
run_every = 2s
EOF
}

# The lifecycle in one mode. $1 is the mode, $2 the root, $3 the command
# prefix (sudo or nothing).
lifecycle() {
    local mode=$1 root=$2 sudo=$3 vigil pid rc
    vigil="$sudo /bin/bash $root/app/vigil --root $root"
    printf '%s mode, root %s\n' "$mode" "$root"

    $vigil service install "--$mode" > "$work/install.out" 2>&1
    rc=$?
    check "$mode: service install succeeds" 0 "$rc"
    [ "$rc" -eq 0 ] || sed 's/^/        /' "$work/install.out"
    check "$mode: the service is active" active "$(svc_state $vigil)"
    if ! wait_file "$root/state/hold.pid" 60; then
        check "$mode: the supervisor started the job" yes no
        $vigil status
        $sudo cat "$root/logs/supervisor/service.log" 2> /dev/null
        $vigil service remove > /dev/null 2>&1
        return
    fi
    pid=$($sudo cat "$root/state/hold.pid")
    check "$mode: the supervisor started the job" yes yes

    $vigil stop > /dev/null 2>&1
    check "$mode: stop succeeds" 0 "$?"
    check "$mode: the service is inactive after stop" inactive "$(svc_state $vigil)"
    check "$mode: the job outlives stop" 0 "$($sudo kill -0 "$pid" 2> /dev/null; echo $?)"

    $vigil start > /dev/null 2>&1
    check "$mode: start succeeds" 0 "$?"
    check "$mode: the service is active after start" active "$(svc_state $vigil)"
    $vigil restart > /dev/null 2>&1
    check "$mode: restart succeeds" 0 "$?"
    check "$mode: the service is active after restart" active "$(svc_state $vigil)"

    $vigil service install "--$mode" > /dev/null 2>&1
    check "$mode: installing again succeeds" 0 "$?"

    $vigil service remove > /dev/null 2>&1
    check "$mode: service remove succeeds" 0 "$?"
    check "$mode: the service is gone" 'not registered' "$(svc_state $vigil)"
    check "$mode: the job outlives remove" 0 "$($sudo kill -0 "$pid" 2> /dev/null; echo $?)"
    $vigil service remove > /dev/null 2>&1
    check "$mode: removing again changes nothing" 0 "$?"

    $sudo kill "$pid" 2> /dev/null
}

work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-svc.XXXXXX")
os=$(uname -s)
printf 'bash %s on %s\n' "$BASH_VERSION" "$os"

if ! sudo -n true 2> /dev/null; then
    printf 'SKIP system mode: needs sudo without a password\n'
else
    sudo=sudo
    root=/opt/vigil-it-$$

    # Failing pre-flight checks register nothing.
    bad=/opt/vigil-it-bad-$$
    make_root "$bad"
    printf '[job.broken]\nrun_every = 1h\n' | sudo tee -a "$bad/config/vigil.config" > /dev/null
    sudo /bin/bash "$bad/app/vigil" --root "$bad" service install --system > /dev/null 2>&1
    check "system: install with failing pre-flight checks is refused" 1 "$?"
    check "system: and registers nothing" 'not registered' "$(svc_state sudo /bin/bash "$bad/app/vigil" --root "$bad")"
    sudo rm -rf "$bad"

    # A root a unit file cannot carry unquoted.
    mkdir "$work/a root"
    sudo /bin/bash "$repo/app/vigil" --root "$work/a root" service install --system > /dev/null 2>&1
    check "system: a root with a space is refused" 1 "$?"

    make_root "$root"
    lifecycle system "$root" sudo
    if [ "$os" = Linux ]; then
        check "system: the vigil account exists" 0 "$(id vigil > /dev/null 2>&1; echo $?)"
        check "system: state belongs to the vigil account" vigil "$(stat -c %U "$root/state")"
        check "system: app belongs to root" root "$(stat -c %U "$root/app")"
        sudo userdel vigil 2> /dev/null
    fi
    sudo rm -rf "$root"
fi

# User mode: the account's own systemd manager or launchd GUI domain.
sudo=''
if [ "$os" = Linux ] && ! systemctl --user show-environment > /dev/null 2>&1; then
    printf 'SKIP user mode: this account has no systemd user manager\n'
elif [ "$os" = Darwin ] && ! launchctl print "gui/$(id -u)" > /dev/null 2>&1; then
    printf 'SKIP user mode: this account has no launchd GUI session\n'
else
    root=$work/root
    make_root "$root"
    lifecycle user "$root" ''
fi

rm -rf "$work"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
