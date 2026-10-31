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
    param([string]$A, [string]$B, [string]$C, [string]$D)
    $data = @"
{
  "vault_token": "s.vault-token-$PID", "role_id": "role-$PID", "secret_id": "sid-$PID",
  "approle_token": "s.approle-token-$PID",
  "imds_token": "imds-token-$PID", "sp_secret": "sp+secret/$PID=", "sp_token": "sp-token-$PID",
  "vault": {"secret/data/db/password": {"value": "$A"}, "ops/data/app": {"password": "$B"}},
  "kv": {"dd": "$C", "api": "$D"}
}
"@
    [System.IO.File]::WriteAllText((Join-Path $root 'mock\data.json'), $data)
    foreach ($p in @(@('a', $A), @('b', $B), @('c', $C), @('d', $D))) {
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

    Set-MockData "vault-pw-1 $PID" "approle-pw-1 $PID" "kv-mi-1 $PID" "kv-sp-1 $PID"
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
        'Write-Output "metric d_ok $(Same $env:D d)"')

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
vault   = https://127.0.0.1:$hport
auth    = managed_identity
ca_file = tls\ca.pem

[secret_store.kv_sp]
type          = azure_keyvault
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

[job.show]
file      = scripts\show.ps1
run_every = 1h
env       = IT_ROOT=$root
secret    = A=store:hv/db/password
secret    = B=store:hv_role/app
secret    = C=store:kv/dd
secret    = D=store:kv_sp/api

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
secret    = X=store:hv/slow

[job.kv_missing]
file      = scripts\show.ps1
run_every = 1h
secret    = X=store:kv/gone
"@
    [void](Invoke-Vigil @('secret', 'set', 'VAULT_TOKEN', '--stdin') "s.vault-token-$PID")
    [void](Invoke-Vigil @('secret', 'set', 'SP_SECRET', '--stdin') "sp+secret/$PID=")

    # 1. A run receives every store's secret, exactly.
    [void](Invoke-Vigil @('run', 'show'))
    Test-Equal 'run with store secrets succeeds' 'succeeded' (Get-StateValue 'show' 'status')
    Test-Equal 'hashicorp_vault, token: delivered exactly' '1' (Get-Metric 'show' 'a_ok')
    Test-Equal 'hashicorp_vault, approle: delivered exactly' '1' (Get-Metric 'show' 'b_ok')
    Test-Equal 'azure_keyvault, managed identity: delivered exactly' '1' (Get-Metric 'show' 'c_ok')
    Test-Equal 'azure_keyvault, service principal: delivered exactly' '1' (Get-Metric 'show' 'd_ok')

    # 2. Rotated in the stores: the very next run uses the new values.
    Set-MockData "vault-pw-2 $PID" "approle-pw-2 $PID" "kv-mi-2 $PID" "kv-sp-2 $PID"
    [void](Invoke-Vigil @('run', 'show'))
    Test-Equal 'rotated: hashicorp_vault' '1' (Get-Metric 'show' 'a_ok')
    Test-Equal 'rotated: azure_keyvault' '1' (Get-Metric 'show' 'c_ok')

    # 3. Failures fail the run before it starts, with a reason.
    [void](Invoke-Vigil @('run', 'missing'))
    Test-Equal 'not in the store' 'secret store:hv/no/such/secret unavailable: not found (HTTP 404)' (Get-StateValue 'missing' 'reason')
    [void](Invoke-Vigil @('run', 'kv_missing'))
    Test-Equal 'not in the key vault' 'secret store:kv/gone unavailable: not found (HTTP 404)' (Get-StateValue 'kv_missing' 'reason')
    [void](Invoke-Vigil @('run', 'untrusted'))
    Test-Equal 'a certificate not trusted is refused' "secret store:untrusted/db/password unavailable: the certificate of 127.0.0.1:$hport is not trusted" (Get-StateValue 'untrusted' 'reason')
    [void](Invoke-Vigil @('run', 'slow'))
    Test-Equal 'a slow store is given up on' "secret store:hv/slow unavailable: no answer from 127.0.0.1:$hport within 2s" (Get-StateValue 'slow' 'reason')
    [void](Invoke-Vigil @('secret', 'set', 'VAULT_TOKEN', '--stdin') 'wrong')
    [void](Invoke-Vigil @('run', 'missing'))
    Test-Equal 'a wrong token' 'secret store:hv/no/such/secret unavailable: permission denied (HTTP 403)' (Get-StateValue 'missing' 'reason')
    [void](Invoke-Vigil @('secret', 'set', 'VAULT_TOKEN', '--stdin') "s.vault-token-$PID")

    # 4. precheck fetches them too, and shows only references.
    $pre = Invoke-Vigil @('precheck', 'show')
    Test-Equal 'precheck: the job' 'True' "$(@($pre.Output | Where-Object { $_ -ceq '  ok    job.show' }).Count -gt 0)"

    # No value or credential ever in a URL, a log, state or spool file.
    $values = @("vault-pw-1 $PID", "approle-pw-1 $PID", "kv-mi-1 $PID", "kv-sp-1 $PID", "vault-pw-2 $PID", "kv-mi-2 $PID",
        "s.vault-token-$PID", "sid-$PID", "s.approle-token-$PID", "imds-token-$PID", "sp-token-$PID", "secret/$PID=", "secret%2F$PID")
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
    Remove-Item Env:\VIGIL_TEST_IMDS, Env:\IT_SECRET_ID -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
