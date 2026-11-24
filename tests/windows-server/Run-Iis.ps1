<#
.SYNOPSIS
    Run-Iis.ps1 - the iis pack against IIS in trouble on purpose, on a Windows Server.
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Run from a checkout's tests\windows-server, as an account that is NOT an
    administrator (vigil-test, over SSH), on a Windows Server that
    Enable-IIS.ps1 set up (its owner runs it once, elevated; -Reset puts its
    sites back as they started, after this test crashed one). It sends one
    minute of traffic of every kind (200, 404, 500, the 503 of a stopped
    pool, https), runs every job of the iis pack on the minute its logs are
    written, with slow requests in flight, and checks what they read; then a
    log it may not read; then the page that crashes its worker, three times,
    until rapid-fail protection stops its pool, and the events that say so.
    Then tests\integration\Service-Packs.ps1 runs the pack through Vigil.
    What it printed is the evidence: the caller keeps it.
#>
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$pack = Join-Path $repo 'packs\iis\windows'
$work = Join-Path ([IO.Path]::GetTempPath()) ("vigil-iis-it-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $work)
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
"host     $env:COMPUTERNAME, $([Environment]::OSVersion.VersionString), Windows PowerShell $($PSVersionTable.PSVersion)"
"account  $env:USERNAME, administrator: $($me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
"commit   $(Get-Content (Join-Path $repo '..\commit.txt') -ErrorAction SilentlyContinue)"
$pass = 0; $fail = 0
function Check($name, $want, $got) { if ("$want" -ceq "$got") { $script:pass++; "  PASS  $name" } else { $script:fail++; "  FAIL  ${name}: expected [$want] actual [$got]" } }
function Val($lines, $metric, $tag) {
    foreach ($l in $lines) { if ("$l" -match "^metric $metric (\S+)(.*)$") { $v = $Matches[1]; $rest = $Matches[2]; if ($rest -match $tag) { return $v } } }
    return ''
}
function Least($lines, $metric, $tag, $min) { $v = Val $lines $metric $tag; if ($v -ne '' -and [double]$v -ge $min) { 'yes' } else { "no [$v]" } }
function Has($lines, $metric, $re) { if (@($lines | Where-Object { "$_" -match "^metric $metric( |$).*$re" }).Count) { 'yes' } else { 'no' } }
$out = @{}
function Run-Job([string]$j, [string]$name, [hashtable]$envs) {
    if (-not $name) { $name = $j }
    foreach ($k in @($envs.Keys)) { [Environment]::SetEnvironmentVariable($k, $envs[$k]) }
    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pack "$j.ps1") 2>&1 | ForEach-Object { "$_" })
    $rc = $LASTEXITCODE
    foreach ($k in @($envs.Keys)) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue }
    ""; "> powershell packs\iis\windows\$j.ps1$(if ($envs.Count) { '   (' + (@($envs.Keys | ForEach-Object { "$_=..." }) -join ' ') + ')' })"
    $o | ForEach-Object { Write-Output $_ }
    $script:out[$name] = $o
    Check "iis: $name runs" 0 $rc
}
# Requests that do not wait for their answer: slow ones run while the jobs read.
Add-Type -AssemblyName System.Net.Http
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(60)
function Send([string]$u, [int]$n, [string]$method = 'GET') {
    $tasks = @()
    foreach ($i in 1..$n) {
        $m = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($method)), $u)
        if ($method -eq 'POST') { $m.Content = New-Object System.Net.Http.StringContent('x=1') }
        $tasks += $client.SendAsync($m)
    }
    return $tasks
}
function Wait-All($tasks) { foreach ($t in $tasks) { try { [void]$t.Wait(60000) } catch { } } }
function Code([string]$u) { try { [int]$client.GetAsync($u).Result.StatusCode } catch { 0 } }
# https, to a certificate that signed itself, for this test's own requests:
# a check compiled, as .NET calls it on a thread where a PowerShell script
# block cannot run ("There is no Runspace available").
Add-Type -TypeDefinition 'public static class VigilTestTrust { public static bool Any(object s, System.Security.Cryptography.X509Certificates.X509Certificate c, System.Security.Cryptography.X509Certificates.X509Chain ch, System.Net.Security.SslPolicyErrors e) { return true; } }'
[Net.ServicePointManager]::ServerCertificateValidationCallback = [Delegate]::CreateDelegate([Net.Security.RemoteCertificateValidationCallback], [VigilTestTrust].GetMethod('Any'))
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Get-Https([string]$u) { try { [int](Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 20).StatusCode } catch { if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 } } }

$crashRunning = (Get-Counter '\APP_POOL_WAS(vigil-crash)\Current Application Pool State' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue -eq 3
if (-not $crashRunning) { '  note  vigil-crash is not running (a test before stopped it): the crash checks are left out; Enable-IIS.ps1 -Reset puts it back' }

# The minute of traffic: from second 2, so the minute IIS logs holds it.
""; '# One minute of traffic, of every kind.'
while (([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % 60) -ne 2) { Start-Sleep -Milliseconds 300 }
$minute = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Wait-All (Send 'http://localhost:8081/' 40)
Wait-All (Send 'http://localhost:8081/missing' 10)
Wait-All (Send 'http://localhost:8081/' 5 'POST')
Wait-All (Send 'http://localhost:8082/boom.aspx' 6)
Wait-All (Send 'http://localhost:8083/' 6)
foreach ($i in 1..10) { [void](Get-Https 'https://localhost:8443/') }
"  sent: 8081 $(Code 'http://localhost:8081/') $(Code 'http://localhost:8081/missing'); 8082 $(Code 'http://localhost:8082/boom.aspx'); 8083 $(Code 'http://localhost:8083/'); 8443 $(Get-Https 'https://localhost:8443/')"
# Two minutes on, the logs hold that minute (IIS writes them out once a
# minute); slow requests, sent just before, run while the jobs read.
while ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt $minute + 118 + 5) { Start-Sleep -Seconds 1 }
$slow = Send 'http://localhost:8081/slow.aspx' 4
Start-Sleep -Seconds 3

""; '# IIS on Windows Server: every job, as the pack ships it, as an account that is not an administrator.'
# The certificate the https binding serves, its public half only, as the CA
# that checks it (it signed itself).
$hash = ((netsh http show sslcert ipport=0.0.0.0:8443) -match 'Certificate Hash' -replace '.*:\s*', '').Trim()
$cer = Join-Path $work 'binding.cer'
try { [IO.File]::WriteAllBytes($cer, (Get-Item "Cert:\LocalMachine\My\$hash").Export('Cert')) } catch { "  note  the binding's certificate could not be read: $($_.Exception.Message)" }
Run-Job 'workers' '' @{}
Run-Job 'sites' '' @{}
Run-Job 'pools' '' @{}
Run-Job 'log' '' @{}
Run-Job 'tls' '' @{ IIS_CACERT = $cer }
Run-Job 'events' '' @{}
Wait-All $slow
Check 'iis: up' 1 (Val $out['sites'] 'up' '')
Check 'iis: five sites, IIS''s own and four for the test' 'yes' (Least $out['sites'] 'sites' '' 5)
Check 'iis: the requests of vigil-ok counted' 'yes' (Least $out['sites'] 'site_requests_count' 'site=vigil-ok$' 55)
Check 'iis: and its 404s' 'yes' (Least $out['sites'] 'site_not_found_count' 'site=vigil-ok$' 10)
Check 'iis: and its POSTs' 'yes' (Least $out['sites'] 'site_method_count' 'site=vigil-ok method=post' 5)
Check 'iis: the stopped pool, stopped' 5 (Val $out['pools'] 'state' 'pool=vigil-stopped ')
Check 'iis: the pools not running first' 'True' ([string]((@($out['pools'] | Where-Object { $_ -match '^metric state ' })[0]) -match '^metric state 5 '))
Check 'iis: its requests turned away by HTTP.sys' 'yes' (Least $out['pools'] 'rejected_count' 'pool=vigil-stopped$' 6)
Check 'iis: the others running' 3 (Val $out['pools'] 'state' 'pool=vigil-ok ')
Check 'iis: slow requests running in a worker' 'yes' (Least $out['workers'] 'active_requests' 'pool=vigil-ok ' 1)
Check 'iis: the whole minute read' 1 (Val $out['log'] 'window_complete' '')
Check 'iis: the requests vigil-ok logged (W3SVC2)' 'yes' (Least $out['log'] 'requests' 'site=W3SVC2$' 55)
Check 'iis: its 404s, with their sub-status' 'yes' (Least $out['log'] 'status' 'site=W3SVC2 code=404.0' 10)
Check 'iis: the 500s of vigil-fail (W3SVC3)' 'yes' (Least $out['log'] 'status' 'site=W3SVC3 code=500.0' 6)
Check 'iis: and their share' 'yes' (Least $out['log'] 'errors_5xx_pct' 'site=W3SVC3$' 50)
Check 'iis: times taken' 'yes' (Has $out['log'] 'time_p99_ms' 'site=W3SVC2')
Check 'iis: what HTTP.sys turned away, and why' 'yes' (Least $out['log'] 'rejected' 'reason=Disabled status=503 queue=vigil-stopped' 6)
Check 'iis: the binding found in HTTP.sys' 1 (Val $out['tls'] 'bindings_found' '')
Check 'iis: its certificate, days left' 'yes' (Least $out['tls'] 'cert_expires_days' 'endpoint=127.0.0.1:8443/localhost' 1)
Check 'iis: and it checks, against its own public half' 1 (Val $out['tls'] 'cert_verified' 'endpoint=127.0.0.1:8443/localhost')
Check 'iis: the event logs readable' 1 (Val $out['events'] 'readable' '')
Check 'iis: the https requests logged too (W3SVC2)' 'yes' (Least $out['log'] 'requests' 'site=W3SVC2$' 65)

""; '# A log this account may not read.'
$deny = Join-Path $work 'logs\W3SVC9'
[void](New-Item -ItemType Directory -Force -Path $deny)
Set-Content -Path (Join-Path $deny 'u_ex000101.log') -Value '#Fields: date time cs-method sc-status'
[void](& icacls (Join-Path $deny 'u_ex000101.log') /deny "${env:USERNAME}:(R)")
Run-Job 'log' 'log-denied' @{ IIS_LOG_DIR = (Join-Path $work 'logs') }
Check 'iis: a log it may not read' 0 (Val $out['log-denied'] 'log_readable' '')

if ($crashRunning) {
    ""; '# A page that crashes its worker, three times: rapid-fail protection stops the pool.'
    foreach ($i in 1..4) { "  crash.aspx: HTTP $(Code 'http://localhost:8084/crash.aspx')"; Start-Sleep -Seconds 4 }
    Start-Sleep -Seconds 5
    Run-Job 'pools' 'pools-crashed' @{}
    Run-Job 'events' 'events-crashed' @{}
    Check 'iis: the pool stopped by rapid-fail protection' 5 (Val $out['pools-crashed'] 'state' 'pool=vigil-crash ')
    Check 'iis: its worker failures counted' 'yes' (Least $out['pools-crashed'] 'worker_failures_count' 'pool=vigil-crash$' 3)
    Check 'iis: the crashes, from the events' 'yes' (Least $out['events-crashed'] 'crashes_count' '' 3)
    Check 'iis: and the pool rapid-fail protection stopped' 'yes' (Least $out['events-crashed'] 'rapid_fail_count' '' 1)
    Check 'iis: named' 'yes' (Has $out['events-crashed'] 'event' 'id=5002 pool=vigil-crash')
}

$client.Dispose()
Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
""; "directly: $pass passed, $fail failed"

$env:VIGIL_IT_WEB_IIS = 'IIS_LOG_MAX_MB=32'
$env:VIGIL_IT_WEB_IIS_DOWN = ''
""; '== powershell tests\integration\Service-Packs.ps1'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests\integration\Service-Packs.ps1') 2>&1 | ForEach-Object { "$_" }
$code = $LASTEXITCODE
if ($fail -gt 0) { $code = 1 }
exit $code
