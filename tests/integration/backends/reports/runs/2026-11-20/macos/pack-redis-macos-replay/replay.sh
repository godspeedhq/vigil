#!/bin/bash
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
# The redis pack's scripts for this OS against replies captured from real
# servers, replayed by a stand-in redis-cli: each job, on each reply, and
# the failures as the real clients print them. Then through Vigil itself.
#   r62_replay.sh <repo copy> <fixtures> <out file>
# Everything in a temporary folder, removed after.
set -u
repo=$1 fix=$2 out=$3
case $(uname -s) in Darwin) os=macos ;; *) os=linux ;; esac
w=$(mktemp -d "${TMPDIR:-/tmp}/r62replay.XXXXXX")
trap 'rm -rf "$w"' EXIT
mkdir -p "$w/bin"
cat > "$w/bin/redis-cli" <<'CLI'
#!/bin/bash
# Stand-in redis-cli: replies captured from real servers, chosen by port;
# failures as the real clients print them. Records its arguments.
printf '%s\n' "$*" >> "$R62_SET/args.log"
for a in "$@"; do [ "$a" = --help ] && { cat "$R62_SET/help"; exit 0; }; done
port=6379 prev=''
for a in "$@"; do [ "$prev" = -p ] && port=$a; prev=$a; done
case $port in
    16479) cat "$R62_SET/primary.info" ;;
    16480) cat "$R62_SET/replica.info" ;;
    16481) cat "$R62_SET/sentinel.info" ;;
    1) echo "Could not connect to Redis at 127.0.0.1:1: Connection refused" >&2; exit 1 ;;
    2) echo "AUTH failed: WRONGPASS invalid username-password pair or user is disabled." >&2; echo "NOAUTH Authentication required." ;;
    3) echo "NOPERM User vigil_noinfo has no permissions to run the 'info' command"; echo ;;
    4) echo "Could not connect to Redis at 127.0.0.1:4: SSL_connect failed: certificate verify failed" >&2; exit 1 ;;
esac
CLI
chmod +x "$w/bin/redis-cli"
export PATH="$w/bin:/usr/bin:/bin" REDIS_HOST=127.0.0.1 REDIS_USER=vigil_monitor REDISCLI_AUTH=r62-never-on-a-command-line
{
    printf '== %s, bash %s, awk: %s\n' "$(uname -s)" "$BASH_VERSION" "$(awk --version 2>&1 | head -n 1 || true)"
    for set in valkey9 redis62; do
        export R62_SET=$w/$set
        mkdir -p "$R62_SET" && cp "$fix/$set"/* "$R62_SET/"
        for port in 16479 16480 16481 1 2 3 4; do
            [ "$port" = 16481 ] && [ ! -s "$R62_SET/sentinel.info" ] && continue
            for job in status memory replication persistence keyspace; do
                printf '\n# %s, port %s: %s.sh\n' "$set" "$port" "$job"
                REDIS_PORT=$port bash "$repo/packs/redis/$os/$job.sh" 2>&1
                printf '[exit %s]\n' "$?"
            done
        done
        printf '\n# %s: what the client was given (a connect timeout only where its --help has one)\n' "$set"
        sort -u "$R62_SET/args.log"
        printf 'the password on a command line: %s\n' "$(grep -c "$REDISCLI_AUTH" "$R62_SET/args.log")"
    done
} > "$out"

# Through Vigil: a throwaway root, the pack enabled, the secret set, each
# job run against the Valkey 9.2 primary's reply.
export R62_SET=$w/valkey9
root=$w/root
mkdir -p "$root"
cp -R "$repo/app" "$repo/vendor" "$root/"
v() { bash "$root/app/vigil" --root "$root" "$@"; }
{
    printf '\n# Through Vigil, on %s\n' "$os"
    v init --instance replay --backend file --no-pack > /dev/null 2>&1; echo "init: $?"
    mkdir -p "$root/packs/redis" && cp "$repo/packs/redis/pack.config" "$repo/packs/redis/$os"/* "$root/packs/redis/"
    v pack enable redis 2>&1
    printf '%s' "$REDISCLI_AUTH" | v secret set REDIS_MONITOR_PASSWORD --stdin > /dev/null; echo "secret set: $?"
    sed -i.bak 's/^env\( *\)= REDIS_PORT=.*/env\1= REDIS_PORT=16479/' "$root/config/vigil.config" && rm -f "$root/config/vigil.config.bak"
    for job in status memory replication persistence keyspace; do v run "redis_$job" 2>&1 | sed 's/, run [0-9TZ-]*$//; s/in [0-9]*s/in Ns/'; done
    grep -h ' out metric ' "$root"/logs/jobs/redis_*/*.log | sed 's/^[^ ]* [^ ]* out //' | sort
    v supervise --once > /dev/null 2>&1; sleep 3; v supervise --once > /dev/null 2>&1
    for i in 1 2 3 4 5; do [ -s "$root/metrics/vigil.prom" ] && break; sleep 1; done
    printf 'reach the backend: %s lines of redis_\n' "$(grep -c '^redis_' "$root/metrics/vigil.prom" 2> /dev/null)"
    printf 'the password, anywhere in the root: %s\n' "$(grep -rlF -- "$REDISCLI_AUTH" "$root/logs" "$root/state" "$root/spool" "$root/metrics" "$root/config/vigil.config" 2> /dev/null | wc -l | tr -d ' ')"
} >> "$out" 2>&1
echo "done: $out"
