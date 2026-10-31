#!/usr/bin/env bash
#
# Integration test: HashiCorp Vault and Azure Key Vault over HTTPS with curl
# (SPECIFICATION.md 6.5.3) on Linux and macOS, against mock-store.py and a
# CA made for this run. Jobs receive each store's secrets exactly, a rotated
# value is used by the very next run, failures fail the run with a reason,
# and no value ever travels in a URL or reaches a log, state or spool file.
#
# Needs python3 (or python) and openssl, as GitHub's runners have.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
vigil_cmd=$repo/app/vigil
root=${TMPDIR:-/tmp}/vigil-stores.$$
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

state_value() {
    sed -n "s/^$2 *= \{0,1\}//p" "$root/state/jobs/$1.state"
}

vigil() {
    "$BASH" "$vigil_cmd" --root "$root" "$@"
}

# The value of metric $2 in job $1's latest events.
metric() {
    local f
    f=$(ls "$root/spool/incoming/"*"-$1-"*.events 2>/dev/null | tail -n 1)
    [ -n "$f" ] && sed -n "s/^[0-9]* $1\\.$2 \\([^ ]*\\) .*/\\1/p" "$f"
}

cleanup() {
    [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null
    rm -rf "$root"
}
trap cleanup EXIT

printf 'bash %s\n' "$BASH_VERSION"
# The first Python that runs: on Windows, python3 may be only a placeholder.
python=''
for p in python3 python; do
    if "$p" -c 'import ssl' > /dev/null 2>&1; then
        python=$p
        break
    fi
done
[ -n "$python" ] || { echo "needs python3"; exit 1; }
command -v openssl > /dev/null || { echo "needs openssl"; exit 1; }
mkdir -p "$root/config" "$root/scripts" "$root/expect" "$root/mock" "$root/tls"
root=$(cd "$root" && pwd)

# A CA for this run only, and the mock's certificate from it.
tls=$root/tls
# An openssl configuration of its own, for LibreSSL (macOS) and OpenSSL
# alike. MSYS2_ARG_CONV_EXCL keeps Git Bash from rewriting -subj as a path.
cat > "$tls/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
[dn]
[ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
[server]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,IP:127.0.0.1
EOF
MSYS2_ARG_CONV_EXCL='/CN' openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tls/ca.key" -out "$tls/ca.pem" -days 2 \
    -subj '/CN=Vigil test CA' -config "$tls/openssl.cnf" -extensions ca > /dev/null 2>&1
MSYS2_ARG_CONV_EXCL='/CN' openssl req -new -newkey rsa:2048 -nodes -keyout "$tls/server.key" -out "$tls/server.csr" \
    -subj '/CN=localhost' -config "$tls/openssl.cnf" > /dev/null 2>&1
openssl x509 -req -in "$tls/server.csr" -CA "$tls/ca.pem" -CAkey "$tls/ca.key" -CAcreateserial \
    -out "$tls/server.pem" -days 2 -extfile "$tls/openssl.cnf" -extensions server > /dev/null 2>&1
check "test CA and certificate made" yes "$([ -s "$tls/server.pem" ] && echo yes || echo no)"
# A GCP service account key for this run, and its public key for the mock.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tls/gcp.pem" > /dev/null 2>&1
openssl pkey -in "$tls/gcp.pem" -pubout -out "$tls/gcp.pub" > /dev/null 2>&1
# Git Bash: the mock and its openssl are Windows programs, needing Windows paths.
case $(uname -s) in
    MINGW* | MSYS* | CYGWIN*) unixkey=0; gcp_pub=$(cygpath -m "$tls/gcp.pub") ;;
    *) unixkey=1; gcp_pub=$tls/gcp.pub ;;
esac

# What the mock serves; rewritten to rotate.
mock_data() {
    cat > "$root/mock/data.json" <<EOF
{
  "vault_token": "s.vault-token-$$", "role_id": "role-$$", "secret_id": "sid-$$",
  "approle_token": "s.approle-token-$$",
  "imds_token": "imds-token-$$", "sp_secret": "sp+secret/$$=", "sp_token": "sp-token-$$",
  "aws_key_id": "AKIAVIGILTEST", "aws_secret": "aws-secret-key-$$",
  "imds_session": "imds-session-$$", "aws_ip_key_id": "ASIAVIGILTEST",
  "aws_ip_secret": "aws-ip-secret-$$", "aws_ip_session": "aws-ip-session-$$",
  "vault": {"secret/data/db/password": {"value": "$1"}, "ops/data/app": {"password": "$2"}},
  "kv": {"dd": "$3", "api": "$4"},
  "aws": {"prod/db": "$5", "app/json": "{\"username\": \"app\", \"password\": \"$6\"}"},
  "gcp_md_token": "gcp-md-token-$$", "gcp_sa_token": "gcp-sa-token-$$",
  "gcp_email": "vigil-test@ops.iam.gserviceaccount.com", "gcp_pub": "$gcp_pub", "openssl": "openssl",
  "gcp": {"db-password": "$7", "api_key": "$8"}
}
EOF
    printf '%s' "$1" > "$root/expect/a"
    printf '%s' "$2" > "$root/expect/b"
    printf '%s' "$3" > "$root/expect/c"
    printf '%s' "$4" > "$root/expect/d"
    printf '%s' "$5" > "$root/expect/e"
    printf '%s' "$6" > "$root/expect/f"
    printf '%s' "$7" > "$root/expect/g"
    printf '%s' "$8" > "$root/expect/h"
}
mock_data "vault-pw-1 $$" "approle-pw-1 $$" "kv-mi-1 $$" "kv-sp-1 $$" "aws-keys-1 $$" "aws-role-1 $$" \
    "gcp-md-1 $$" "gcp-key-1 $$"
"$python" "$here/mock-store.py" "$root/mock" "$tls/server.pem" "$tls/server.key" 2> "$root/mock/stderr" &
mock_pid=$!
i=0
while [ ! -f "$root/mock/ports" ] && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
done
if [ ! -f "$root/mock/ports" ]; then
    echo "the mock did not start:"
    cat "$root/mock/stderr"
    exit 1
fi
read -r hport mport < "$root/mock/ports"
export VIGIL_TEST_IMDS=http://127.0.0.1:$mport
export IT_SECRET_ID=sid-$$

# The job reports, for each secret, whether it received exactly the value
# the test expects - never the value itself.
cat > "$root/scripts/show.sh" <<'EOF'
same() { if [ "$1" = "$(cat "$IT_ROOT/expect/$2")" ]; then echo 1; else echo 0; fi; }
echo "metric a_ok $(same "${A-}" a)"
echo "metric b_ok $(same "${B-}" b)"
echo "metric c_ok $(same "${C-}" c)"
echo "metric d_ok $(same "${D-}" d)"
echo "metric e_ok $(same "${E-}" e)"
echo "metric f_ok $(same "${F-}" f)"
echo "metric g_ok $(same "${G-}" g)"
echo "metric h_ok $(same "${H-}" h)"
echo "metric k_ok $(same "${K-}" k)"
echo "metric l_ok $(same "${L-}" l)"
echo "metric m_ok $(same "${M-}" m)"
EOF

# Fake vendor CLIs, first on PATH for the runs that use them (GitHub's
# runners have the real ones). Each logs its arguments, answers from
# <cli>.json, and the aws one answers only when the access key reached it in
# its environment.
mkdir -p "$root/bin" "$root/fake"
export IT_FAKE=$root/fake
for c in az aws gcloud; do
    cat > "$root/bin/$c" <<'EOF'
#!/bin/sh
c=${0##*/}
printf '%s\n' "$c $*" >> "$IT_FAKE/argv.log"
if [ "$c" = aws ] && [ "${AWS_SECRET_ACCESS_KEY-}" != "$(cat "$IT_FAKE/aws-key")" ]; then exit 255; fi
[ -f "$IT_FAKE/$c-slow" ] && sleep 30
cat "$IT_FAKE/$c.json"
EOF
    chmod +x "$root/bin/$c"
done
printf 'aws-cli-key-%s' "$$" > "$IT_FAKE/aws-key"
printf '{"id":"https://cli-kv.vault.azure.net/secrets/dd/1","value":"az-cli-%s"}' "$$" > "$IT_FAKE/az.json"
printf '{"Name":"prod/db","SecretString":"aws-cli-%s"}' "$$" > "$IT_FAKE/aws.json"
# gcloud answers in URL-safe base64, unpadded.
printf '{"payload":{"data":"%s"}}' "$(printf 'gcloud-cli %s ~~?' "$$" | openssl base64 -A | tr '+/' '-_' | tr -d '=')" > "$IT_FAKE/gcloud.json"
printf 'az-cli-%s' "$$" > "$root/expect/k"
printf 'aws-cli-%s' "$$" > "$root/expect/l"
printf 'gcloud-cli %s ~~?' "$$" > "$root/expect/m"

cat > "$root/config/vigil.config" <<EOF
[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[secret_store.hv]
type    = hashicorp_vault
url     = https://127.0.0.1:$hport
auth    = token
token   = secret:VAULT_TOKEN
ca_file = tls/ca.pem

# Only for the slow check: a short timeout would also catch the first,
# cold, request of a busy CI runner.
[secret_store.hv_slow]
type    = hashicorp_vault
url     = https://127.0.0.1:$hport
auth    = token
token   = secret:VAULT_TOKEN
ca_file = tls/ca.pem
timeout = 2s

[secret_store.hv_role]
type      = hashicorp_vault
url       = https://127.0.0.1:$hport/
mount     = ops
field     = password
auth      = approle
role_id   = role-$$
secret_id = env:IT_SECRET_ID
ca_file   = $tls/ca.pem

[secret_store.kv]
type    = azure_keyvault
client = http
vault   = https://127.0.0.1:$hport
auth    = managed_identity
ca_file = tls/ca.pem

[secret_store.kv_sp]
type          = azure_keyvault
client = http
vault         = https://127.0.0.1:$hport
auth          = service_principal
tenant_id     = test-tenant
client_id     = test-client
client_secret = secret:SP_SECRET
authority     = https://127.0.0.1:$hport
ca_file       = tls/ca.pem

[secret_store.untrusted]
type  = hashicorp_vault
url   = https://127.0.0.1:$hport
auth  = token
token = secret:VAULT_TOKEN

[secret_store.aws_keys]
type              = aws_secrets_manager
client = http
region            = eu-west-2
auth              = access_keys
access_key_id     = AKIAVIGILTEST
secret_access_key = secret:AWS_SECRET
endpoint          = https://127.0.0.1:$hport
ca_file           = tls/ca.pem

[secret_store.aws_role]
type     = aws_secrets_manager
client = http
region   = us-east-1
auth     = instance_profile
field    = password
endpoint = https://127.0.0.1:$hport
ca_file  = tls/ca.pem

[secret_store.gcp]
type     = gcp_secret_manager
client = http
project  = test-project
auth     = metadata
endpoint = https://127.0.0.1:$hport
ca_file  = tls/ca.pem

[secret_store.gcp_key]
type                = gcp_secret_manager
client = http
project             = test-project
auth                = service_account_key
service_account_key = secret:GCP_KEY
endpoint            = https://127.0.0.1:$hport
ca_file             = tls/ca.pem

[secret_store.kv_cli]
type  = azure_keyvault
vault = https://cli-kv.vault.azure.net/
auth  = managed_identity

[secret_store.aws_cli]
type              = aws_secrets_manager
region            = eu-west-2
auth              = access_keys
access_key_id     = AKIAVIGILCLI
secret_access_key = secret:AWS_CLI_KEY
client            = cli

[secret_store.gcp_cli]
type    = gcp_secret_manager
project = test-project
auth    = metadata
client  = cli
timeout = 2s

[job.cli]
file      = scripts/show.sh
run_every = 1h
env       = IT_ROOT=$root
secret    = K=store:kv_cli/dd
secret    = L=store:aws_cli/prod/db
secret    = M=store:gcp_cli/db

[job.show]
file      = scripts/show.sh
run_every = 1h
env       = IT_ROOT=$root
secret    = A=store:hv/db/password
secret    = B=store:hv_role/app
secret    = C=store:kv/dd
secret    = D=store:kv_sp/api
secret    = E=store:aws_keys/prod/db
secret    = F=store:aws_role/app/json
secret    = G=store:gcp/db-password

[job.gcp_key]
file      = scripts/show.sh
run_every = 1h
env       = IT_ROOT=$root
secret    = H=store:gcp_key/api_key

[job.gcp_missing]
file      = scripts/show.sh
run_every = 1h
secret    = X=store:gcp/gone

[job.aws_missing]
file      = scripts/show.sh
run_every = 1h
secret    = X=store:aws_keys/gone

[job.missing]
file      = scripts/show.sh
run_every = 1h
secret    = X=store:hv/no/such/secret

[job.untrusted]
file      = scripts/show.sh
run_every = 1h
secret    = X=store:untrusted/db/password

[job.slow]
file      = scripts/show.sh
run_every = 1h
secret    = X=store:hv_slow/slow

[job.kv_missing]
file      = scripts/show.sh
run_every = 1h
secret    = X=store:kv/gone
EOF
printf 's.vault-token-%s' "$$" | vigil secret set VAULT_TOKEN --stdin > /dev/null
printf 'sp+secret/%s=' "$$" | vigil secret set SP_SECRET --stdin > /dev/null
printf 'aws-secret-key-%s' "$$" | vigil secret set AWS_SECRET --stdin > /dev/null
# The service account key file's contents, as Google issues it: JSON with the
# private key's newlines escaped. Its token_uri is the mock's.
gcp_key_json() {
    local line esc=''
    while IFS= read -r line; do esc=$esc$line'\n'; done < "$1"
    printf '{"client_email":"vigil-test@ops.iam.gserviceaccount.com","private_key":"%s","token_uri":"https://127.0.0.1:%s/token"}' "$esc" "$hport"
}
gcp_key_json "$tls/gcp.pem" | vigil secret set GCP_KEY --stdin > /dev/null
printf 'aws-cli-key-%s' "$$" | vigil secret set AWS_CLI_KEY --stdin > /dev/null

# 1. A run receives every store's secret, exactly.
vigil run show > /dev/null 2>&1
check "run with store secrets succeeds" succeeded "$(state_value show status)"
[ "$(state_value show status)" = succeeded ] || printf '        reason: %s\n' "$(state_value show reason)"
check "hashicorp_vault, token: delivered exactly" 1 "$(metric show a_ok)"
check "hashicorp_vault, approle: delivered exactly" 1 "$(metric show b_ok)"
check "azure_keyvault, managed identity: delivered exactly" 1 "$(metric show c_ok)"
check "azure_keyvault, service principal: delivered exactly" 1 "$(metric show d_ok)"
check "aws_secrets_manager, access keys (signature checked): delivered exactly" 1 "$(metric show e_ok)"
check "aws_secrets_manager, instance role, field: delivered exactly" 1 "$(metric show f_ok)"
check "gcp_secret_manager, metadata: delivered exactly" 1 "$(metric show g_ok)"
if [ "$unixkey" -eq 1 ]; then
    vigil run gcp_key > /dev/null 2>&1
    check "gcp_secret_manager, service account key (JWT checked): delivered exactly" 1 "$(metric gcp_key h_ok)"
    [ "$(state_value gcp_key status)" = succeeded ] || printf '        reason: %s\n' "$(state_value gcp_key reason)"
else
    printf '  SKIP  gcp_secret_manager, service account key: Git Bash cannot pass openssl a key through a pipe\n'
fi

# 2. Rotated in the stores: the very next run uses the new values.
mock_data "vault-pw-2 $$" "approle-pw-2 $$" "kv-mi-2 $$" "kv-sp-2 $$" "aws-keys-2 $$" "aws-role-2 $$" \
    "gcp-md-2 $$" "gcp-key-2 $$"
vigil run show > /dev/null 2>&1
check "rotated: hashicorp_vault" 1 "$(metric show a_ok)"
check "rotated: azure_keyvault" 1 "$(metric show c_ok)"
check "rotated: aws_secrets_manager" 1 "$(metric show e_ok)"
check "rotated: gcp_secret_manager" 1 "$(metric show g_ok)"

# 3. Failures fail the run before it starts, with a reason.
vigil run missing > /dev/null 2>&1
check "not in the store" "secret store:hv/no/such/secret unavailable: not found (HTTP 404)" "$(state_value missing reason)"
vigil run kv_missing > /dev/null 2>&1
check "not in the key vault" "secret store:kv/gone unavailable: not found (HTTP 404)" "$(state_value kv_missing reason)"
vigil run untrusted > /dev/null 2>&1
check "a certificate not trusted is refused" "secret store:untrusted/db/password unavailable: the certificate of 127.0.0.1:$hport is not trusted" \
    "$(state_value untrusted reason)"
vigil run slow > /dev/null 2>&1
check "a slow store is given up on" "secret store:hv_slow/slow unavailable: no answer from 127.0.0.1:$hport within 2s" "$(state_value slow reason)"
printf 'wrong' | vigil secret set VAULT_TOKEN --stdin > /dev/null
vigil run missing > /dev/null 2>&1
check "a wrong token" "secret store:hv/no/such/secret unavailable: permission denied (HTTP 403)" "$(state_value missing reason)"
printf 's.vault-token-%s' "$$" | vigil secret set VAULT_TOKEN --stdin > /dev/null
vigil run aws_missing > /dev/null 2>&1
check "not in secrets manager" "secret store:aws_keys/gone unavailable: not found (ResourceNotFoundException)" "$(state_value aws_missing reason)"
printf 'wrong' | vigil secret set AWS_SECRET --stdin > /dev/null
vigil run aws_missing > /dev/null 2>&1
check "a wrong AWS secret key: the signature is refused" "secret store:aws_keys/gone unavailable: permission denied (InvalidSignatureException)" \
    "$(state_value aws_missing reason)"
printf 'aws-secret-key-%s' "$$" | vigil secret set AWS_SECRET --stdin > /dev/null
vigil run gcp_missing > /dev/null 2>&1
check "not in secret manager" "secret store:gcp/gone unavailable: not found (HTTP 404)" "$(state_value gcp_missing reason)"
if [ "$unixkey" -eq 1 ]; then
    # Another account's key: the mock checks the JWT's signature and refuses it.
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tls/other.pem" > /dev/null 2>&1
    gcp_key_json "$tls/other.pem" | vigil secret set GCP_KEY --stdin > /dev/null
    vigil run gcp_key > /dev/null 2>&1
    check "a wrong GCP key: the JWT is refused" "secret store:gcp_key/api_key unavailable: sign-in failed: HTTP 400 from 127.0.0.1:$hport" \
        "$(state_value gcp_key reason)"
fi

# 4. The vendor CLIs: client = auto finds az first on PATH; client = cli.
PATH="$root/bin:$PATH" vigil run cli > /dev/null 2>&1
check "cli: run succeeds" succeeded "$(state_value cli status)"
[ "$(state_value cli status)" = succeeded ] || printf '        reason: %s\n' "$(state_value cli reason)"
check "az (client = auto): delivered exactly" 1 "$(metric cli k_ok)"
check "aws (client = cli, key in its environment): delivered exactly" 1 "$(metric cli l_ok)"
check "gcloud (URL-safe base64): delivered exactly" 1 "$(metric cli m_ok)"
check "az run directly with the secret's id" yes \
    "$(grep -x 'az keyvault secret show --id https://cli-kv.vault.azure.net/secrets/dd --output json' "$IT_FAKE/argv.log" > /dev/null && echo yes || echo no)"
check "no secret in any CLI's arguments" "" "$(grep -e "aws-cli-key-$$" "$IT_FAKE/argv.log")"
printf 'wrong' | vigil secret set AWS_CLI_KEY --stdin > /dev/null
PATH="$root/bin:$PATH" vigil run cli > /dev/null 2>&1
check "the CLI fails" "secret store:aws_cli/prod/db unavailable: the aws CLI failed (exit code 255)" "$(state_value cli reason)"
printf 'aws-cli-key-%s' "$$" | vigil secret set AWS_CLI_KEY --stdin > /dev/null
: > "$IT_FAKE/gcloud-slow"
PATH="$root/bin:$PATH" vigil run cli > /dev/null 2>&1
check "the CLI is stopped at the store's timeout" "secret store:gcp_cli/db unavailable: the gcloud CLI was stopped after 2s" "$(state_value cli reason)"
rm -f "$IT_FAKE/gcloud-slow"

# 5. precheck fetches them too, shows only references, and says which
# client each cloud store uses.
out=$(PATH="$root/bin:$PATH" vigil precheck 2>&1)
check "precheck: the job" yes "$(printf '%s\n' "$out" | grep -x '  ok    job.show' > /dev/null && echo yes || echo no)"
check "precheck: auto with the CLI" yes \
    "$(printf '%s\n' "$out" | grep -x '  ok    secret_store.kv_cli: uses the az CLI (client = auto)' > /dev/null && echo yes || echo no)"
check "precheck: http" yes \
    "$(printf '%s\n' "$out" | grep -x "  ok    secret_store.kv: uses Vigil's own HTTPS client (client = http)" > /dev/null && echo yes || echo no)"

# No value or credential ever in a URL, a log, state or spool file.
values="vault-pw-1 $$|approle-pw-1 $$|kv-mi-1 $$|kv-sp-1 $$|vault-pw-2 $$|kv-mi-2 $$|s.vault-token-$$|sid-$$|s.approle-token-$$|imds-token-$$|sp-token-$$|secret/$$=|secret%2F$$|aws-keys-1 $$|aws-role-1 $$|aws-keys-2 $$|aws-secret-key-$$|imds-session-$$|aws-ip-secret-$$|aws-ip-session-$$|gcp-md-1 $$|gcp-key-1 $$|gcp-md-2 $$|gcp-md-token-$$|gcp-sa-token-$$|PRIVATE KEY|az-cli-$$|aws-cli-$$|aws-cli-key-$$|gcloud-cli $$"
check "no secret in any URL" "" "$(grep -E -e "$values" "$root/mock/urls.log")"
check "no secret in any log, state or spool file" "" \
    "$(grep -r -l -E -e "$values" "$root/logs" "$root/state" "$root/spool" 2>/dev/null)"
check "no secret printed by precheck" "" "$(printf '%s\n' "$out" | grep -E -e "$values")"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
