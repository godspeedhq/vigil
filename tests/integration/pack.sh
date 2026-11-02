#!/usr/bin/env bash
#
# Integration test: vigil pack (SPECIFICATION.md 18.10) on Linux and macOS,
# against mock-files.py as the releases of vigil-packs, signed with a key for
# this run. The twin of Pack.ps1.
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

# Publishes vigil-packs $1 with pack base at version $2 and jobs $3..., each
# reporting one metric, signed with the key named by $KEY.
publish() {
    local v=$1 pv=$2 d=$work/mock/www/packs/releases/download/v$1 s=$work/stage/vigil-packs-$1 j
    shift 2
    rm -rf "$work/stage"
    mkdir -p "$d" "$s/base" "$work/mock/www/packs/releases/tag"
    printf '[pack]\nversion = %s\nvigil = %s\ndescription = For the test\n\n' "$pv" "${MIN:-0.0.1}" > "$s/base/pack.config"
    for j in "$@"; do
        printf '[job.%s]\nmetric_name = it.%s\nmetrics = up\nrun_every = %s\nmax_runtime = 30s\n\n' "$j" "$j" "${EVERY:-1h}" >> "$s/base/pack.config"
        printf 'echo "metric up %s"\n' "$pv" > "$s/base/$j.sh"
        printf 'Write-Output "metric up 1"\n' > "$s/base/$j.ps1"
    done
    (cd "$work/stage" && tar -czf "$d/vigil-packs-$v.tar.gz" "vigil-packs-$v")
    (cd "$d" && sha "vigil-packs-$v.tar.gz" > SHA256SUMS)
    openssl dgst -sha256 -sign "${KEY:-$work/release.key}" -out "$d/SHA256SUMS.sig" "$d/SHA256SUMS"
    : > "$work/mock/www/packs/releases/tag/v$v"
    printf '/packs/releases/latest /packs/releases/tag/v%s\n' "$v" > "$work/mock/redirects"
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

vigil init --instance pk --backend file --no-sample > /dev/null 2>&1
cfg=$root/config/vigil.config
printf 'echo "metric mine 1"\n' > "$root/scripts/mine.sh"
printf '\n[job.mine]\nfile = scripts/mine.sh\nrun_every = 1h\n' >> "$cfg"
before=$(cksum < "$root/scripts/mine.sh")

printf 'Adding\n'
check 'nothing added' 'no packs added: vigil pack add base' "$(vigil pack list)"
publish 1.0.0 1.0.0 cpu disk
out=$(vigil pack add base 2>&1)
check 'adds' 0 "$?"
check 'says what' 'pack base 1.0.0: jobs base_cpu base_disk' "$out"
check 'the scripts are in place' yes "$(yes_no test -f "$root/packs/base/cpu.sh")"
check 'the jobs are in the configuration' 2 "$(grep -c '^\[job\.base_' "$cfg")"
check 'precheck is happy' 0 "$(precheck)"
vigil run base_cpu > /dev/null 2>&1
check 'a job runs' 0 "$?"
check 'listed' 'base         1.0.0      For the test' "$(vigil pack list)"
out=$(vigil pack add base 2>&1)
check 'adding twice is refused' 1 "$?"
check 'saying so' yes "$(printf '%s' "$out" | grep -q 'already added' && echo yes || echo no)"
out=$(vigil pack add nosuch 2>&1)
check 'an unknown pack is refused' 'vigil: no pack called nosuch in the packs 1.0.0' "$out"
out=$(vigil pack add '../x' 2>&1)
check 'a bad name is refused' 'vigil: not a pack name: ../x' "$out"

printf 'Updating\n'
check 'nothing to do' 'pack base 1.0.0 is added: nothing to do' "$(vigil pack update)"
sed -i.bak '/job.base_cpu/,/end of pack/s/^run_every = 1h$/run_every = 5m/' "$cfg" && rm -f "$cfg.bak"
publish 1.1.0 1.1.0 cpu load
check 'the check says so' 'pack base 1.0.0 is added; 1.1.0 is available: vigil pack update' "$(vigil pack update --check)"
check 'the check changes nothing' 1.0.0 "$(sed -n 's/^version = //p' "$root/packs/base/pack.config")"
out=$(vigil pack update 2>&1)
check 'updates' 0 "$?"
check 'to the new version' 1.1.0 "$(sed -n 's/^version = //p' "$root/packs/base/pack.config")"
check 'the scripts are the new ones' yes "$(yes_no grep -q 'metric up 1.1.0' "$root/packs/base/cpu.sh")"
check 'an edit is kept' 5m "$(sed -n '/job.base_cpu/,/^$/s/^run_every = //p' "$cfg")"
check 'a new job is added' 1 "$(grep -c '^\[job\.base_load\]' "$cfg")"
check 'a dropped job goes' 0 "$(grep -c '^\[job\.base_disk\]' "$cfg")"
check 'its keys too' 0 "$(grep -c 'packs/base/disk' "$cfg")"
check 'your own job stays' 1 "$(grep -c '^\[job\.mine\]' "$cfg")"
check 'your own script is untouched' "$before" "$(cksum < "$root/scripts/mine.sh")"
check 'precheck is still happy' 0 "$(precheck)"

printf 'Refused\n'
snapshot() { cksum < "$cfg"; cksum < "$root/packs/base/pack.config"; }
was=$(snapshot)
KEY=$work/other.key publish 1.2.0 1.2.0 cpu
out=$(vigil pack update 2>&1)
check 'a bad signature is refused' 1 "$?"
check 'saying so' 'vigil: the packs 1.2.0 are not signed by the Vigil release key; nothing was changed' "$out"
check 'and changing nothing' "$was" "$(snapshot)"
publish 1.3.0 1.3.0 cpu
printf 'x' >> "$work/mock/www/packs/releases/download/v1.3.0/vigil-packs-1.3.0.tar.gz"
out=$(vigil pack update 2>&1)
check 'a tampered archive is refused' 'vigil: the packs 1.3.0 do not match their SHA256SUMS; nothing was changed' "$out"
rm -f "$work/mock/www/packs/releases/download/v1.4.0/SHA256SUMS.sig"
publish 1.4.0 1.4.0 cpu
rm -f "$work/mock/www/packs/releases/download/v1.4.0/SHA256SUMS.sig"
out=$(vigil pack update 2>&1)
check 'a missing signature is refused' 'vigil: cannot download the packs 1.4.0' "$out"
MIN=99.0.0 publish 1.5.0 1.5.0 cpu
out=$(vigil pack update 2>&1)
check 'too old a Vigil is refused' 'vigil: pack base needs Vigil 99.0.0 or later: vigil self update' "$out"
check 'and nothing changed' "$was" "$(snapshot)"

# A job Vigil cannot accept: all of it goes back.
EVERY=soon publish 1.6.0 1.6.0 cpu extra
was=$(snapshot)
out=$(vigil pack update 2>&1)
check 'a pack that would not be valid is refused' 1 "$?"
check 'saying why' yes "$(printf '%s' "$out" | grep -q 'would not be valid here' && echo yes || echo no)"
check 'and goes back' "$was" "$(snapshot)"
check 'the old scripts are back' yes "$(yes_no grep -q 'metric up 1.1.0' "$root/packs/base/cpu.sh")"

printf 'A configuration from a source\n'
cp "$cfg" "$work/cfg.keep"
printf '\n[source.remote]\ntype = local\npath = /tmp\n' >> "$cfg"
sed -i.bak '1i\
[vigil]\
config_source = remote\
config_file = vigil.config\
' "$cfg" && rm -f "$cfg.bak"
out=$(vigil pack remove base 2>&1)
check 'is not edited' 1 "$?"
cp "$work/cfg.keep" "$cfg"

printf 'Removing\n'
out=$(vigil pack remove base 2>&1)
check 'removes' 'removed pack base' "$out"
check 'the scripts go' no "$(yes_no test -d "$root/packs/base")"
check 'the jobs go' 0 "$(grep -c 'base' "$cfg")"
check 'your own job stays too' 1 "$(grep -c '^\[job\.mine\]' "$cfg")"
check 'precheck is happy after' 0 "$(precheck)"
out=$(vigil pack remove base 2>&1)
check 'removing twice is refused' 'vigil: pack base is not added' "$out"

printf 'Init\n'
publish 2.0.0 2.0.0 cpu
rm -rf "$root/config" "$root/scripts"
vigil init --instance pk --backend file --pack base > "$work/out" 2>&1
check 'init adds a pack' 0 "$?"
check 'in place of the sample' 0 "$(grep -c '^\[job\.disk\]' "$cfg")"
check 'with its jobs' 1 "$(grep -c '^\[job\.base_cpu\]' "$cfg")"
rm -rf "$root/config" "$root/scripts" "$root/packs"
vigil init --instance pk --backend file --pack nosuch > /dev/null 2>&1
check 'a pack asked for and missing fails init' 1 "$?"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
