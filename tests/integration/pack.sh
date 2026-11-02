#!/usr/bin/env bash
#
# Integration test: vigil pack (SPECIFICATION.md 18.10) on Linux and macOS,
# against mock-files.py as the Vigil releases, signed with a key for this
# run. The twin of Pack.ps1.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-pack-it.XXXXXX")
work=$(cd "$work" && pwd)
root=$work/root
pass=0
fail=0
mock_pid=''

check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"
    fi
}

cleanup() {
    [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

vigil() { bash "$root/app/vigil" --root "$root" "$@"; }
yes_no() { if "$@" > /dev/null 2>&1; then echo yes; else echo no; fi; }
# Precheck refuses the test override (22.4.4).
precheck() { env -u VIGIL_TEST_RELEASE_URL bash "$root/app/vigil" --root "$root" precheck > /dev/null 2>&1; echo $?; }
sha() { if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi; }

# Publishes release $1 with pack base at its version and jobs $2..., each
# reporting one metric, signed with the key named by $KEY.
publish() {
    local v=$1 d=$work/mock/www/releases/download/v$1 s=$work/stage/vigil-packs-$1 j f=vigil-packs-$1-$os.tar.gz
    shift
    rm -rf "$work/stage"
    mkdir -p "$d" "$s/base" "$work/mock/www/releases/tag"
    make_pack "$s/base" "$v" "$@"
    (cd "$work/stage" && tar -czf "$d/$f" "vigil-packs-$v")
    (cd "$d" && sha "$f" > SHA256SUMS)
    openssl dgst -sha256 -sign "${KEY:-$work/release.key}" -out "$d/SHA256SUMS.sig" "$d/SHA256SUMS"
    : > "$work/mock/www/releases/tag/v$v"
    printf '/releases/latest /releases/tag/v%s\n' "$v" > "$work/mock/redirects"
}

# Writes pack base version $2 and jobs $3... in folder $1.
make_pack() {
    local to=$1 pv=$2 j
    shift 2
    mkdir -p "$to"
    printf '[pack]\nversion = %s\nvigil = %s\ndescription = For the test\n\n' "$pv" "${MIN:-0.0.1}" > "$to/pack.config"
    for j in "$@"; do
        printf '[job.%s]\nmetric_name = it.%s\nmetrics = up\nrun_every = %s\nmax_runtime = 30s\n\n' "$j" "$j" "${EVERY:-1h}" >> "$to/pack.config"
        printf 'echo "metric up 1" # %s\n' "$pv" > "$to/$j.sh"
    done
}

printf 'bash %s on %s\n' "$BASH_VERSION" "$(uname -s)"
python=''
for p in python3 python; do
    if "$p" -c 'import http.server' > /dev/null 2>&1; then
        python=$p
        break
    fi
done
[ -n "$python" ] || { echo "needs python3"; exit 1; }
mkdir -p "$root" "$work/mock/www"
cp -R "$repo/app" "$repo/vendor" "$root/"
printf '0.3.0\n' > "$root/app/VERSION"
export HOME=$work
openssl genrsa -out "$work/release.key" 2048 2> /dev/null
openssl genrsa -out "$work/other.key" 2048 2> /dev/null
openssl rsa -in "$work/release.key" -pubout -out "$work/release.pem" 2> /dev/null
"$python" "$here/mock-files.py" "$work/mock" 2> "$work/mock/stderr" &
mock_pid=$!
i=0
while [ ! -s "$work/mock/port" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
export VIGIL_TEST_RELEASE_URL=http://127.0.0.1:$(cat "$work/mock/port") VIGIL_TEST_RELEASE_KEY=$work/release.pem

vigil init --instance pk --backend file --no-pack > /dev/null 2>&1
cfg=$root/config/vigil.config
printf 'echo "metric mine 1"\n' > "$root/scripts/mine.sh"
printf '\n[job.mine]\nfile = scripts/mine.sh\nrun_every = 1h\n' >> "$cfg"
before=$(cksum < "$root/scripts/mine.sh")
case $(uname -s) in Darwin) os=macos ;; *) os=linux ;; esac

# As the installer leaves them.
make_pack "$root/packs/base" 1.0.0 cpu disk

printf 'Turning on\n'
check 'listed, off' 'off' "$(vigil pack list | awk '$1 == "base_cpu" { print $2 }')"
out=$(vigil pack enable base 2>&1)
check 'enables' 0 "$?"
check 'says what' 'on: base_cpu|on: base_disk' "$(printf '%s' "$out" | tr '\n' '|')"
check 'the jobs are in the configuration' 2 "$(grep -c '^\[job\.base_' "$cfg")"
check 'precheck is happy' 0 "$(precheck)"
vigil run base_cpu > /dev/null 2>&1
check 'a job runs' 0 "$?"
check 'listed, on' 'on' "$(vigil pack list | awk '$1 == "base_cpu" { print $2 }')"
check 'enabling twice changes nothing' 'base is already on' "$(vigil pack enable base 2>&1)"
check 'an unknown name is refused' 'vigil: no pack or job called nosuch: vigil pack list' "$(vigil pack enable nosuch 2>&1)"
check 'an unknown job is refused' 'vigil: no job called base_nosuch: vigil pack list' "$(vigil pack enable base_nosuch 2>&1)"
check 'a bad name is refused' 'vigil: not a pack or job name: ../x' "$(vigil pack enable '../x' 2>&1)"

printf 'Updating\n'
publish 1.0.0 cpu disk
check 'nothing to do' 'pack base 1.0.0 is here: nothing to do' "$(vigil pack update)"
sed -i.bak '/job.base_cpu/,/job.base_disk/s/^run_every = 1h$/run_every = 5m/' "$cfg" && rm -f "$cfg.bak"
publish 1.1.0 cpu load
check 'the check says so' 'pack base 1.0.0 is here; 1.1.0 is available: vigil pack update' "$(vigil pack update --check)"
check 'the check changes nothing' 1.0.0 "$(sed -n 's/^version = //p' "$root/packs/base/pack.config")"
was=$(cksum < "$cfg")
out=$(vigil pack update 2>&1)
check 'updates' 0 "$?"
check 'to the new version' 1.1.0 "$(sed -n 's/^version = //p' "$root/packs/base/pack.config")"
check 'the configuration is not touched' "$was" "$(cksum < "$cfg")"
check 'a job on runs the new script' yes "$(yes_no grep -q '1.1.0' "$root/packs/base/cpu.sh")"
check 'says what changed' yes "$(printf '%s' "$out" | grep -q '^changed: base_cpu' && echo yes || echo no)"
check 'says what is new' yes "$(printf '%s' "$out" | grep -q '^new, not running: base_load. To turn it on: vigil pack enable base_load$' && echo yes || echo no)"
check 'a new script stays off' 0 "$(grep -c '^\[job\.base_load\]' "$cfg")"
check 'but is there' yes "$(yes_no test -f "$root/packs/base/load.sh")"
check 'says what was dropped' yes "$(printf '%s' "$out" | grep -q '^dropped from the pack, still running: base_disk' && echo yes || echo no)"
check 'a dropped script stays while a job uses it' yes "$(yes_no test -f "$root/packs/base/disk.sh")"
vigil run base_disk > /dev/null 2>&1
check 'and the job still runs' 0 "$?"
check 'precheck is still happy' 0 "$(precheck)"
check 'your own script is untouched' "$before" "$(cksum < "$root/scripts/mine.sh")"

printf 'On and off\n'
check 'a new script turns on' 'on: base_load' "$(vigil pack enable base_load 2>&1)"
check 'an edit is kept' 5m "$(sed -n '/job.base_cpu/,/^$/s/^run_every = //p' "$cfg")"
check 'one job turns off' 'off: base_disk' "$(vigil pack disable base_disk 2>&1)"
check 'it leaves the configuration' 0 "$(grep -c 'base_disk\|packs/base/disk' "$cfg")"
check 'turning off twice changes nothing' 'base_disk is already off' "$(vigil pack disable base_disk 2>&1)"
check 'precheck is happy with that' 0 "$(precheck)"
publish 1.2.0 cpu load
out=$(vigil pack update 2>&1)
check 'a dropped script goes once no job uses it' no "$(yes_no test -f "$root/packs/base/disk.sh")"

printf 'Refused\n'
snapshot() { cksum < "$cfg"; cksum < "$root/packs/base/pack.config"; }
was=$(snapshot)
KEY=$work/other.key publish 1.3.0 cpu
out=$(vigil pack update 2>&1)
check 'a bad signature is refused' 1 "$?"
check 'saying so' 'vigil: release 1.3.0 is not signed by the Vigil release key; nothing was changed' "$out"
publish 1.4.0 cpu
printf 'x' >> "$work/mock/www/releases/download/v1.4.0/vigil-packs-1.4.0-$os.tar.gz"
check 'a tampered archive is refused' 'vigil: the packs of release 1.4.0 do not match its SHA256SUMS; nothing was changed' "$(vigil pack update 2>&1)"
publish 1.5.0 cpu
rm -f "$work/mock/www/releases/download/v1.5.0/SHA256SUMS.sig"
check 'a missing signature is refused' 'vigil: cannot download the packs of release 1.5.0' "$(vigil pack update 2>&1)"
MIN=99.0.0 publish 1.6.0 cpu
check 'too old a Vigil is refused' 'vigil: pack base needs Vigil 99.0.0 or later: vigil self update' "$(vigil pack update 2>&1)"
check 'and nothing changed' "$was" "$(snapshot)"

# A job Vigil cannot accept: the configuration goes back.
EVERY=soon make_pack "$work/bad" 1.7.0 extra
cp "$work/bad/extra.sh" "$root/packs/base/"
cat "$work/bad/pack.config" | sed -n '/^\[job/,$p' >> "$root/packs/base/pack.config"
was=$(cksum < "$cfg")
out=$(vigil pack enable base_extra 2>&1)
check 'a job that would not be valid is refused' 1 "$?"
check 'saying why' yes "$(printf '%s' "$out" | grep -q 'would not be valid' && echo yes || echo no)"
check 'and goes back' "$was" "$(cksum < "$cfg")"

printf 'A configuration from a source\n'
cp "$cfg" "$work/cfg.keep"
printf '[vigil]\nconfig_source = remote\nconfig_file = vigil.config\n\n[source.remote]\ntype = local\npath = /tmp\n' > "$cfg"
vigil pack disable base > /dev/null 2>&1
check 'is not edited' 1 "$?"
cp "$work/cfg.keep" "$cfg"

printf 'Turning off\n'
check 'a whole pack' 'off: base' "$(vigil pack disable base 2>&1)"
check 'the jobs go' 0 "$(grep -c 'base' "$cfg")"
check 'the scripts stay' yes "$(yes_no test -f "$root/packs/base/cpu.sh")"
check 'your own job stays' 1 "$(grep -c '^\[job\.mine\]' "$cfg")"
check 'precheck is happy after' 0 "$(precheck)"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
