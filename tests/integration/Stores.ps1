#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: HashiCorp Vault and Azure Key Vault over HTTPS with
    .NET (SPECIFICATION.md 6.5.3) on Windows. The twin of stores.sh.
.DESCRIPTION
    Runs against mock-store.py with a CA made for this run, trusted only
    through ca_file: nothing is added to the machine's certificate stores.
    Jobs receive each store's secrets exactly, a rotated value is used by the
    very next run, failures fail the run with a reason, and no value ever
    travels in a URL or reaches a log, state or spool file.

    Needs Python and openssl (Git for Windows has one), as GitHub's runners
    have.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-stores.$PID"
$shell = (Get-Process -Id $PID).Path
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Get-StateValue {
    param([string]$Job, [string]$Key)
    $path = Join-Path $root "state\jobs\$Job.state"
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($path)) {
        if ($l -cmatch "^$Key *=( (.*))?$") { return $Matches[2] }
    }
    return ''
}

function Invoke-Vigil {
    param([string[]]$Arguments, [string]$InputText)
    $ErrorActionPreference = 'Continue'
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $out = $InputText | & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root @Arguments 2>&1
    }
    else { $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root @Arguments 2>&1 }
    return @{ Code = $LASTEXITCODE; Output = @($out | ForEach-Object { "$_" }) }
}

# The value of metric $Name in job $Job's latest events.
function Get-Metric {
    param([string]$Job, [string]$Name)
    $f = Get-ChildItem -LiteralPath (Join-Path $root 'spool\incoming') -Filter "*-$Job-*.events" -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -Last 1
    if (-not $f) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($f.FullName)) {
        $m = [regex]::Match($l, "^[0-9]+ $Job\.$Name ([^ ]+) ")
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

# What the mock serves; written again to rotate.
function Set-MockData {
    param([string]$A, [string]$B, [string]$C, [string]$D, [string]$E, [string]$F, [string]$G, [string]$H)
    $pub = "$tls\gcp.pub".Replace('\', '/')
    $ssl = $openssl.Replace('\', '/')
    $data = @"
{
  "vault_token": "s.vault-token-$PID", "role_id": "role-$PID", "secret_id": "sid-$PID",
  "approle_token": "s.approle-token-$PID",
  "imds_token": "imds-token-$PID", "sp_secret": "sp+secret/$PID=", "sp_token": "sp-token-$PID",
  "aws_key_id": "AKIAVIGILTEST", "aws_secret": "aws-secret-key-$PID",
  "imds_session": "imds-session-$PID", "aws_ip_key_id": "ASIAVIGILTEST",
  "aws_ip_secret": "aws-ip-secret-$PID", "aws_ip_session": "aws-ip-session-$PID",
  "vault": {"secret/data/db/password": {"value": "$A"}, "ops/data/app": {"password": "$B"}},
  "kv": {"dd": "$C", "api": "$D"},
  "aws": {"prod/db": "$E", "app/json": "{\"username\": \"app\", \"password\": \"$F\"}"},
  "gcp_md_token": "gcp-md-token-$PID", "gcp_sa_token": "gcp-sa-token-$PID",
  "gcp_email": "vigil-test@ops.iam.gserviceaccount.com", "gcp_pub": "$pub", "openssl": "$ssl",
  "gcp": {"db-password": "$G", "api_key": "$H"}
}
"@
    [System.IO.File]::WriteAllText((Join-Path $root 'mock\data.json'), $data)
    foreach ($p in @(@('a', $A), @('b', $B), @('c', $C), @('d', $D), @('e', $E), @('f', $F), @('g', $G), @('h', $H))) {
        [System.IO.File]::WriteAllText((Join-Path $root "expect\$($p[0])"), $p[1])
    }
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
# The first Python that runs: python3 may be only a placeholder.
$python = $null
foreach ($p in @('python3', 'python', 'py')) {
    if (Get-Command $p -CommandType Application -ErrorAction SilentlyContinue) {
        & $p -c 'import ssl' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $python = (Get-Command $p -CommandType Application | Select-Object -First 1).Source; break }
    }
}
if (-not $python) { Write-Host 'needs Python'; exit 1 }
$openssl = (Get-Command openssl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $openssl) {
    foreach ($p in @("$env:ProgramFiles\Git\usr\bin\openssl.exe", "$env:ProgramFiles\Git\mingw64\bin\openssl.exe")) {
        if (Test-Path -LiteralPath $p) { $openssl = $p; break }
    }
}
if (-not $openssl) { Write-Host 'needs openssl'; exit 1 }

$scripts = Join-Path $root 'scripts'
$tls = Join-Path $root 'tls'
foreach ($d in @('config', 'scripts', 'expect', 'mock', 'tls')) { [void](New-Item -ItemType Directory -Force -Path (Join-Path $root $d)) }
$root = (Resolve-Path -LiteralPath $root).ProviderPath
$tls = Join-Path $root 'tls'
$scripts = Join-Path $root 'scripts'
$mock = $null

try {
    # A CA for this run only, and the mock's certificate from it.
    [System.IO.File]::WriteAllText((Join-Path $tls 'openssl.cnf'), @"
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
"@)
    $cnf = Join-Path $tls 'openssl.cnf'
    & $openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tls\ca.key" -out "$tls\ca.pem" -days 2 -subj '/CN=Vigil test CA' -config $cnf -extensions ca 2>&1 | Out-Null
    & $openssl req -new -newkey rsa:2048 -nodes -keyout "$tls\server.key" -out "$tls\server.csr" -subj '/CN=localhost' -config $cnf 2>&1 | Out-Null
    & $openssl x509 -req -in "$tls\server.csr" -CA "$tls\ca.pem" -CAkey "$tls\ca.key" -CAcreateserial -out "$tls\server.pem" -days 2 -extfile $cnf -extensions server 2>&1 | Out-Null
    Test-Equal 'test CA and certificate made' 'True' "$(Test-Path -LiteralPath "$tls\server.pem")"
    # A GCP service account key for this run, and its public key for the mock.
    & $openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tls\gcp.pem" 2>&1 | Out-Null
    & $openssl pkey -in "$tls\gcp.pem" -pubout -out "$tls\gcp.pub" 2>&1 | Out-Null

    Set-MockData "vault-pw-1 $PID" "approle-pw-1 $PID" "kv-mi-1 $PID" "kv-sp-1 $PID" "aws-keys-1 $PID" "aws-role-1 $PID" "gcp-md-1 $PID" "gcp-key-1 $PID"
    $mockArgs = @("$here\mock-store.py", "$root\mock", "$tls\server.pem", "$tls\server.key") | ForEach-Object { "`"$_`"" }
    $mock = Start-Process -FilePath $python -ArgumentList $mockArgs -PassThru -NoNewWindow -RedirectStandardError "$root\mock\stderr"
    $ports = Join-Path $root 'mock\ports'
    for ($i = 0; $i -lt 300 -and -not (Test-Path -LiteralPath $ports); $i++) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $ports)) {
        Write-Host 'the mock did not start:'
        Get-Content -LiteralPath "$root\mock\stderr"
        exit 1
    }
    $hport, $mport = [System.IO.File]::ReadAllText($ports).Trim().Split(' ')
    $env:VIGIL_TEST_IMDS = "http://127.0.0.1:$mport"
    $env:IT_SECRET_ID = "sid-$PID"

    # The job reports, for each secret, whether it received exactly the value
    # the test expects - never the value itself.
    Set-Content -LiteralPath (Join-Path $scripts 'show.ps1') -Value @(
        'function Same($v, $f) { $e = [IO.File]::ReadAllText((Join-Path $env:IT_ROOT "expect\$f")); if ($v -ceq $e) { 1 } else { 0 } }',
        'Write-Output "metric a_ok $(Same $env:A a)"',
        'Write-Output "metric b_ok $(Same $env:B b)"',
        'Write-Output "metric c_ok $(Same $env:C c)"',
        'Write-Output "metric d_ok $(Same $env:D d)"',
        'Write-Output "metric e_ok $(Same $env:E e)"',
        'Write-Output "metric f_ok $(Same $env:F f)"',
        'Write-Output "metric g_ok $(Same $env:G g)"',
        'Write-Output "metric h_ok $(Same $env:H h)"',
        'Write-Output "metric k_ok $(Same $env:K k)"',
        'Write-Output "metric l_ok $(Same $env:L l)"',
        'Write-Output "metric m_ok $(Same $env:M m)"')

    # Fake vendor CLIs, first on PATH for the runs that use them (GitHub's
    # runners have the real ones), as .cmd files like the real az and
    # gcloud. Each logs its arguments, answers from <cli>.json, and the aws
    # one answers only when the access key reached it in its environment.
    $bin = Join-Path $root 'bin'
    $fake = Join-Path $root 'fake'
    [void](New-Item -ItemType Directory -Force -Path $bin, $fake)
    $env:IT_FAKE = $fake
    foreach ($c in @('az', 'aws', 'gcloud')) {
        Set-Content -LiteralPath (Join-Path $bin "$c.cmd") -Encoding ASCII -Value @(
            '@echo off',
            'echo %~n0 %*>>"%IT_FAKE%\argv.log"',
            "if /i `"%~n0`"==`"aws`" if not `"%AWS_SECRET_ACCESS_KEY%`"==`"aws-cli-key-$PID`" exit /b 255",
            'if exist "%IT_FAKE%\%~n0-slow" ping -n 31 127.0.0.1 >nul',
            'type "%IT_FAKE%\%~n0.json"')
    }
    $utf8 = [System.Text.Encoding]::UTF8
    [System.IO.File]::WriteAllText("$fake\az.json", "{`"id`":`"https://cli-kv.vault.azure.net/secrets/dd/1`",`"value`":`"az-cli-$PID`"}")
    [System.IO.File]::WriteAllText("$fake\aws.json", "{`"Name`":`"prod/db`",`"SecretString`":`"aws-cli-$PID`"}")
    # gcloud answers in URL-safe base64, unpadded.
    $b64 = [Convert]::ToBase64String($utf8.GetBytes("gcloud-cli $PID ~~?")).Replace('+', '-').Replace('/', '_').TrimEnd('=')
    [System.IO.File]::WriteAllText("$fake\gcloud.json", "{`"payload`":{`"data`":`"$b64`"}}")
    [System.IO.File]::WriteAllText((Join-Path $root 'expect\k'), "az-cli-$PID")
    [System.IO.File]::WriteAllText((Join-Path $root 'expect\l'), "aws-cli-$PID")
    [System.IO.File]::WriteAllText((Join-Path $root 'expect\m'), "gcloud-cli $PID ~~?")
    $plainPath = $env:PATH
    $fakePath = "$bin;$env:PATH"

    Set-Content -LiteralPath (Join-Path $root 'config\vigil.config') -Value @"
[runner.ps]
command = $shell
arg     = -NoProfile
arg     = -ExecutionPolicy
arg     = Bypass
arg     = -File

[runners]
.ps1 = ps

[secret_store.hv]
type    = hashicorp_vault
url     = https://127.0.0.1:$hport
auth    = token
token   = secret:VAULT_TOKEN
ca_file = tls\ca.pem

# Only for the slow check: a short timeout would also catch the first,
# cold, request of a busy CI runner.
[secret_store.hv_slow]
type    = hashicorp_vault
url     = https://127.0.0.1:$hport
auth    = token
token   = secret:VAULT_TOKEN
ca_file = tls\ca.pem
timeout = 2s

[secret_store.hv_role]
type      = hashicorp_vault
url       = https://127.0.0.1:$hport/
mount     = ops
field     = password
auth      = approle
role_id   = role-$PID
secret_id = env:IT_SECRET_ID
ca_file   = $tls\ca.pem

[secret_store.kv]
type    = azure_keyvault
client = http
vault   = https://127.0.0.1:$hport
auth    = managed_identity
ca_file = tls\ca.pem

[secret_store.kv_sp]
type          = azure_keyvault
client = http
vault         = https://127.0.0.1:$hport
auth          = service_principal
tenant_id     = test-tenant
client_id     = test-client
client_secret = secret:SP_SECRET
authority     = https://127.0.0.1:$hport
ca_file       = tls\ca.pem

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
ca_file           = tls\ca.pem

[secret_store.aws_role]
type     = aws_secrets_manager
client = http
region   = us-east-1
auth     = instance_profile
field    = password
endpoint = https://127.0.0.1:$hport
ca_file  = tls\ca.pem

[secret_store.gcp]
type     = gcp_secret_manager
client = http
project  = test-project
auth     = metadata
endpoint = https://127.0.0.1:$hport
ca_file  = tls\ca.pem

[secret_store.gcp_key]
type                = gcp_secret_manager
client = http
project             = test-project
auth                = service_account_key
service_account_key = secret:GCP_KEY
endpoint            = https://127.0.0.1:$hport
ca_file             = tls\ca.pem

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
file      = scripts\show.ps1
run_every = 1h
env       = IT_ROOT=$root
secret    = K=store:kv_cli/dd
secret    = L=store:aws_cli/prod/db
secret    = M=store:gcp_cli/db

[job.show]
file      = scripts\show.ps1
run_every = 1h
env       = IT_ROOT=$root
secret    = A=store:hv/db/password
secret    = B=store:hv_role/app
secret    = C=store:kv/dd
secret    = D=store:kv_sp/api
secret    = E=store:aws_keys/prod/db
secret    = F=store:aws_role/app/json
secret    = G=store:gcp/db-password
secret    = H=store:gcp_key/api_key

[job.gcp_key]
file      = scripts\show.ps1
run_every = 1h
secret    = H=store:gcp_key/api_key

[job.gcp_missing]
file      = scripts\show.ps1
run_every = 1h
secret    = X=store:gcp/gone

[job.aws_missing]
file      = scripts\show.ps1
run_every = 1h
secret    = X=store:aws_keys/gone

[job.missing]
file      = scripts\show.ps1
run_every = 1h
secret    = X=store:hv/no/such/secret

[job.untrusted]
file      = scripts\show.ps1
run_every = 1h
secret    = X=store:untrusted/db/password

[job.slow]
file      = scripts\show.ps1
run_every = 1h
secret    = X=store:hv_slow/slow

[job.kv_missing]
file      = scripts\show.ps1
run_every = 1h
secret    = X=store:kv/gone
"@
    [void](Invoke-Vigil @('secret', 'set', 'VAULT_TOKEN', '--stdin') "s.vault-token-$PID")
    [void](Invoke-Vigil @('secret', 'set', 'SP_SECRET', '--stdin') "sp+secret/$PID=")
    [void](Invoke-Vigil @('secret', 'set', 'AWS_SECRET', '--stdin') "aws-secret-key-$PID")
    # The service account key file's contents, as Google issues it: JSON with
    # the private key's newlines escaped. Its token_uri is the mock's.
    $gcpKeyJson = {
        param([string]$Pem)
        $esc = (([System.IO.File]::ReadAllText($Pem) -replace "`r", '').TrimEnd("`n") -split "`n" | ForEach-Object { "$_\n" }) -join ''
        return '{"client_email":"vigil-test@ops.iam.gserviceaccount.com","private_key":"' + $esc + '","token_uri":"https://127.0.0.1:' + $hport + '/token"}'
    }
    [void](Invoke-Vigil @('secret', 'set', 'GCP_KEY', '--stdin') (& $gcpKeyJson "$tls\gcp.pem"))

    # 1. A run receives every store's secret, exactly.
    [void](Invoke-Vigil @('run', 'show'))
    Test-Equal 'run with store secrets succeeds' 'succeeded' (Get-StateValue 'show' 'status')
    if ((Get-StateValue 'show' 'status') -cne 'succeeded') { Write-Host "        reason: $(Get-StateValue 'show' 'reason')" }
    Test-Equal 'hashicorp_vault, token: delivered exactly' '1' (Get-Metric 'show' 'a_ok')
    Test-Equal 'hashicorp_vault, approle: delivered exactly' '1' (Get-Metric 'show' 'b_ok')
    Test-Equal 'azure_keyvault, managed identity: delivered exactly' '1' (Get-Metric 'show' 'c_ok')
    Test-Equal 'azure_keyvault, service principal: delivered exactly' '1' (Get-Metric 'show' 'd_ok')
    Test-Equal 'aws_secrets_manager, access keys (signature checked): delivered exactly' '1' (Get-Metric 'show' 'e_ok')
    Test-Equal 'aws_secrets_manager, instance role, field: delivered exactly' '1' (Get-Metric 'show' 'f_ok')
    Test-Equal 'gcp_secret_manager, metadata: delivered exactly' '1' (Get-Metric 'show' 'g_ok')
    Test-Equal 'gcp_secret_manager, service account key (JWT checked): delivered exactly' '1' (Get-Metric 'show' 'h_ok')

    # 2. Rotated in the stores: the very next run uses the new values.
    Set-MockData "vault-pw-2 $PID" "approle-pw-2 $PID" "kv-mi-2 $PID" "kv-sp-2 $PID" "aws-keys-2 $PID" "aws-role-2 $PID" "gcp-md-2 $PID" "gcp-key-2 $PID"
    [void](Invoke-Vigil @('run', 'show'))
    Test-Equal 'rotated: hashicorp_vault' '1' (Get-Metric 'show' 'a_ok')
    Test-Equal 'rotated: azure_keyvault' '1' (Get-Metric 'show' 'c_ok')
    Test-Equal 'rotated: aws_secrets_manager' '1' (Get-Metric 'show' 'e_ok')
    Test-Equal 'rotated: gcp_secret_manager' '1' (Get-Metric 'show' 'g_ok')

    # 3. Failures fail the run before it starts, with a reason.
    [void](Invoke-Vigil @('run', 'missing'))
    Test-Equal 'not in the store' 'secret store:hv/no/such/secret unavailable: not found (HTTP 404)' (Get-StateValue 'missing' 'reason')
    [void](Invoke-Vigil @('run', 'kv_missing'))
    Test-Equal 'not in the key vault' 'secret store:kv/gone unavailable: not found (HTTP 404)' (Get-StateValue 'kv_missing' 'reason')
    [void](Invoke-Vigil @('run', 'untrusted'))
    Test-Equal 'a certificate not trusted is refused' "secret store:untrusted/db/password unavailable: the certificate of 127.0.0.1:$hport is not trusted" (Get-StateValue 'untrusted' 'reason')
    [void](Invoke-Vigil @('run', 'slow'))
    Test-Equal 'a slow store is given up on' "secret store:hv_slow/slow unavailable: no answer from 127.0.0.1:$hport within 2s" (Get-StateValue 'slow' 'reason')
    [void](Invoke-Vigil @('secret', 'set', 'VAULT_TOKEN', '--stdin') 'wrong')
    [void](Invoke-Vigil @('run', 'missing'))
    Test-Equal 'a wrong token' 'secret store:hv/no/such/secret unavailable: permission denied (HTTP 403)' (Get-StateValue 'missing' 'reason')
    [void](Invoke-Vigil @('secret', 'set', 'VAULT_TOKEN', '--stdin') "s.vault-token-$PID")
    [void](Invoke-Vigil @('run', 'aws_missing'))
    Test-Equal 'not in secrets manager' 'secret store:aws_keys/gone unavailable: not found (ResourceNotFoundException)' (Get-StateValue 'aws_missing' 'reason')
    [void](Invoke-Vigil @('secret', 'set', 'AWS_SECRET', '--stdin') 'wrong')
    [void](Invoke-Vigil @('run', 'aws_missing'))
    Test-Equal 'a wrong AWS secret key: the signature is refused' 'secret store:aws_keys/gone unavailable: permission denied (InvalidSignatureException)' (Get-StateValue 'aws_missing' 'reason')
    [void](Invoke-Vigil @('secret', 'set', 'AWS_SECRET', '--stdin') "aws-secret-key-$PID")
    [void](Invoke-Vigil @('run', 'gcp_missing'))
    Test-Equal 'not in secret manager' 'secret store:gcp/gone unavailable: not found (HTTP 404)' (Get-StateValue 'gcp_missing' 'reason')
    # Another account's key: the mock checks the JWT's signature and refuses it.
    & $openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tls\other.pem" 2>&1 | Out-Null
    [void](Invoke-Vigil @('secret', 'set', 'GCP_KEY', '--stdin') (& $gcpKeyJson "$tls\other.pem"))
    [void](Invoke-Vigil @('run', 'gcp_key'))
    Test-Equal 'a wrong GCP key: the JWT is refused' "secret store:gcp_key/api_key unavailable: sign-in failed: HTTP 400 from 127.0.0.1:$hport" (Get-StateValue 'gcp_key' 'reason')
    [void](Invoke-Vigil @('secret', 'set', 'GCP_KEY', '--stdin') (& $gcpKeyJson "$tls\gcp.pem"))

    # 4. The vendor CLIs: client = auto finds az first on PATH; client = cli.
    [void](Invoke-Vigil @('secret', 'set', 'AWS_CLI_KEY', '--stdin') "aws-cli-key-$PID")
    $env:PATH = $fakePath
    [void](Invoke-Vigil @('run', 'cli'))
    Test-Equal 'cli: run succeeds' 'succeeded' (Get-StateValue 'cli' 'status')
    if ((Get-StateValue 'cli' 'status') -cne 'succeeded') { Write-Host "        reason: $(Get-StateValue 'cli' 'reason')" }
    Test-Equal 'az (client = auto): delivered exactly' '1' (Get-Metric 'cli' 'k_ok')
    Test-Equal 'aws (client = cli, key in its environment): delivered exactly' '1' (Get-Metric 'cli' 'l_ok')
    Test-Equal 'gcloud (URL-safe base64): delivered exactly' '1' (Get-Metric 'cli' 'm_ok')
    $argv = [System.IO.File]::ReadAllLines("$fake\argv.log")
    Test-Equal 'az run directly with the secret''s id' 'True' "$($argv -ccontains 'az keyvault secret show --id https://cli-kv.vault.azure.net/secrets/dd --output json')"
    Test-Equal 'no secret in any CLI''s arguments' '' (@($argv | Where-Object { $_.Contains("aws-cli-key-$PID") }) -join ' ')
    $env:PATH = $plainPath
    [void](Invoke-Vigil @('secret', 'set', 'AWS_CLI_KEY', '--stdin') 'wrong')
    $env:PATH = $fakePath
    [void](Invoke-Vigil @('run', 'cli'))
    Test-Equal 'the CLI fails' 'secret store:aws_cli/prod/db unavailable: the aws CLI failed (exit code 255)' (Get-StateValue 'cli' 'reason')
    $env:PATH = $plainPath
    [void](Invoke-Vigil @('secret', 'set', 'AWS_CLI_KEY', '--stdin') "aws-cli-key-$PID")
    [System.IO.File]::WriteAllText("$fake\gcloud-slow", '')
    $env:PATH = $fakePath
    [void](Invoke-Vigil @('run', 'cli'))
    Test-Equal 'the CLI is stopped at the store''s timeout' 'secret store:gcp_cli/db unavailable: the gcloud CLI was stopped after 2s' (Get-StateValue 'cli' 'reason')
    [System.IO.File]::Delete("$fake\gcloud-slow")

    # 5. precheck fetches them too, shows only references, and says which
    # client each cloud store uses.
    $pre = Invoke-Vigil @('precheck')
    $env:PATH = $plainPath
    Test-Equal 'precheck: the job' 'True' "$(@($pre.Output | Where-Object { $_ -ceq '  ok    job.show' }).Count -gt 0)"
    Test-Equal 'precheck: auto with the CLI' 'True' "$(@($pre.Output | Where-Object { $_ -ceq '  ok    secret_store.kv_cli: uses the az CLI (client = auto)' }).Count -gt 0)"
    Test-Equal 'precheck: http' 'True' "$(@($pre.Output | Where-Object { $_ -ceq '  ok    secret_store.kv: uses Vigil''s own HTTPS client (client = http)' }).Count -gt 0)"

    # No value or credential ever in a URL, a log, state or spool file.
    $values = @("vault-pw-1 $PID", "approle-pw-1 $PID", "kv-mi-1 $PID", "kv-sp-1 $PID", "vault-pw-2 $PID", "kv-mi-2 $PID",
        "s.vault-token-$PID", "sid-$PID", "s.approle-token-$PID", "imds-token-$PID", "sp-token-$PID", "secret/$PID=", "secret%2F$PID",
        "aws-keys-1 $PID", "aws-role-1 $PID", "aws-keys-2 $PID", "aws-secret-key-$PID", "imds-session-$PID", "aws-ip-secret-$PID", "aws-ip-session-$PID",
        "gcp-md-1 $PID", "gcp-key-1 $PID", "gcp-md-2 $PID", "gcp-md-token-$PID", "gcp-sa-token-$PID", "PRIVATE KEY",
        "az-cli-$PID", "aws-cli-$PID", "aws-cli-key-$PID", "gcloud-cli $PID")
    $urls = [System.IO.File]::ReadAllText("$root\mock\urls.log")
    Test-Equal 'no secret in any URL' '' (($values | Where-Object { $urls.Contains($_) }) -join ' ')
    $leaks = foreach ($d in @('logs', 'state', 'spool')) {
        Get-ChildItem -LiteralPath (Join-Path $root $d) -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $t = [System.IO.File]::ReadAllText($_.FullName)
            @($values | Where-Object { $t.Contains($_) }).Count -gt 0
        } | ForEach-Object { $_.FullName }
    }
    Test-Equal 'no secret in any log, state or spool file' '' ($leaks -join ' ')
    $printed = ($pre.Output -join "`n")
    Test-Equal 'no secret printed by precheck' '' (($values | Where-Object { $printed.Contains($_) }) -join ' ')
}
finally {
    if ($mock) { try { Stop-Process -Id $mock.Id -Force -ErrorAction Stop } catch { } }
    if ($plainPath) { $env:PATH = $plainPath }
    Remove-Item Env:\VIGIL_TEST_IMDS, Env:\IT_SECRET_ID, Env:\IT_FAKE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
