#Requires -Version 5.1

# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

<#
.SYNOPSIS
    run-store.ps1 - tests one of Vigil's secret stores against a test
    service, on Windows. The twin of run-store.sh, which describes the
    checks.
.DESCRIPTION
        .\scripts\run-store.ps1 openbao      (or vault, aws)

    Needs .secrets\<target>.env and .secrets\tls\ca.pem from the host that
    ran scripts/start.sh, copied to the same paths here, and the service's
    port answering on 127.0.0.1 (an SSH tunnel; see README.md). Rotation
    uses configs/secrets/rotate.sh through Git Bash. The restart checks are
    run-store.sh's, on the Docker host; here they are reported NOT RUN.

    Results: PASS, FAIL, NOT RUN, and EMULATOR LIMITATION; only PASS is a
    pass. Exit code: 0 when every check that ran passed.
#>

param([Parameter(Mandatory = $true)][string]$Target)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bk = Split-Path -Parent $here
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $bk))
$shell = (Get-Process -Id $PID).Path

if (@('openbao', 'vault', 'aws') -cnotcontains $Target) { Write-Output 'usage: run-store.ps1 openbao|vault|aws'; exit 1 }
$envFile = Join-Path $bk ".secrets\$Target.env"
$caFile = Join-Path $bk '.secrets\tls\ca.pem'
if (-not (Test-Path -LiteralPath $envFile) -or -not (Test-Path -LiteralPath $caFile)) {
    Write-Output "no .secrets\$Target.env or .secrets\tls\ca.pem: copy them from the host that ran scripts/start.sh $Target"
    exit 1
}
$o = @{}
foreach ($l in [System.IO.File]::ReadAllLines($envFile)) {
    if ($l -cmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $o[$Matches[1]] = $Matches[2] }
}
$rnd = { $b = New-Object byte[] 16; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b | ForEach-Object { $_.ToString('x2') }) }
$sha = { param([string]$s) -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }) }

$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-store.$PID"
$root = Join-Path $work 'root'
$out = Join-Path $work 'vigil.out'
$script:pass = 0; $script:fail = 0; $script:notRun = 0; $script:limits = 0

function Write-Pass { param([string]$Text) Write-Output "  PASS  $Text"; $script:pass++ }
function Write-Fail { param([string]$Text) Write-Output "  FAIL  $Text"; $script:fail++ }
function Write-Limit { param([string]$Text) Write-Output "  EMULATOR LIMITATION  $Text"; $script:limits++ }
function Write-NotRun { param([string]$Text) Write-Output "  NOT RUN  $Text"; $script:notRun++ }

# The suite: its stores (name, keys, trusts the CA), its jobs (name, store,
# path, status, reason or '-', the key of the value it must get or '-'), as
# in run-store.sh.
$labels = @{}
if ($Target -ceq 'aws') {
    $o['VIGIL_ST_BAD_SECRET_KEY'] = (& $rnd) + (& $rnd)
    $a = "type = aws_secrets_manager`nclient = http`nendpoint = $($o['ST_URL'])`nauth = access_keys`naccess_key_id = $($o['ST_ACCESS_KEY_ID'])"
    $k = 'secret_access_key = env:VIGIL_ST_SECRET_KEY'
    $r = "region = $($o['ST_REGION'])"
    $stores = @(
        @('aws', "$a`n$r`n$k", $true),
        @('aws_field', "$a`n$r`n$k`nfield = password", $true),
        @('aws_bad_field', "$a`n$r`n$k`nfield = nosuch", $true),
        @('aws_eu', "$a`nregion = eu-west-2`n$k", $true),
        @('aws_untrusted', "$a`n$r`n$k", $false),
        @('aws_bad_key', "$a`n$r`nsecret_access_key = env:VIGIL_ST_BAD_SECRET_KEY", $true))
    $jobs = @(
        @('bk_probe', 'aws', 'vigil/probe', 'succeeded', '-', 'ST_PROBE'),
        @('bk_field', 'aws_field', 'vigil/json', 'succeeded', '-', 'ST_PASSWORD'),
        @('bk_missing', 'aws', 'vigil/nosuch', 'failed', 'not found (ResourceNotFoundException)', '-'),
        @('bk_bad_field', 'aws_bad_field', 'vigil/json', 'failed', "the secret's value:", '-'),
        @('bk_binary', 'aws', 'vigil/binary', 'failed', 'SecretString', '-'),
        @('bk_other_region', 'aws_eu', 'vigil/probe', 'failed', 'not found (ResourceNotFoundException)', '-'),
        @('bk_untrusted', 'aws_untrusted', 'vigil/probe', 'failed', 'is not trusted', '-'),
        @('bk_rotating', 'aws', 'vigil/rotating', 'succeeded', '-', 'current'))
    $labels['bk_other_region'] = 'bk_other_region (eu-west-2)'
    $secretEnv = @('VIGIL_ST_SECRET_KEY', 'VIGIL_ST_BAD_SECRET_KEY')
    $leakKeys = @('ST_PROBE', 'ST_PASSWORD', 'ST_ROTATING', 'ST_BINARY', 'VIGIL_ST_SECRET_KEY', 'VIGIL_ST_BAD_SECRET_KEY')
}
else {
    $o['VIGIL_ST_BAD_TOKEN'] = & $rnd
    $o['VIGIL_ST_BAD_SECRET_ID'] = & $rnd
    $v = "type = hashicorp_vault`nurl = $($o['ST_URL'])"
    $stores = @(
        @('st', "$v`nauth = approle`nrole_id = $($o['ST_ROLE_ID'])`nsecret_id = env:VIGIL_ST_SECRET_ID", $true),
        @('st_token', "$v`nauth = token`ntoken = env:VIGIL_ST_TOKEN", $true),
        @('st_untrusted', "$v`nauth = token`ntoken = env:VIGIL_ST_TOKEN", $false),
        @('st_bad_token', "$v`nauth = token`ntoken = env:VIGIL_ST_BAD_TOKEN", $true),
        @('st_expired', "$v`nauth = token`ntoken = env:VIGIL_ST_EXPIRING_TOKEN", $true),
        @('st_bad_secret_id', "$v`nauth = approle`nrole_id = $($o['ST_ROLE_ID'])`nsecret_id = env:VIGIL_ST_BAD_SECRET_ID", $true),
        @('st_kv1', "$v`nmount = kv1`nauth = token`ntoken = env:VIGIL_ST_TOKEN", $true))
    $jobs = @(
        @('bk_approle', 'st', 'vigil/probe', 'succeeded', '-', 'ST_PROBE'),
        @('bk_token', 'st_token', 'vigil/probe', 'succeeded', '-', 'ST_PROBE'),
        @('bk_missing', 'st', 'vigil/nosuch', 'failed', 'not found (HTTP 404)', '-'),
        @('bk_denied', 'st', 'other/probe', 'failed', 'permission denied (HTTP 403)', '-'),
        @('bk_untrusted', 'st_untrusted', 'vigil/probe', 'failed', 'is not trusted', '-'),
        @('bk_bad_token', 'st_bad_token', 'vigil/probe', 'failed', 'permission denied (HTTP 403)', '-'),
        @('bk_expired', 'st_expired', 'vigil/probe', 'failed', 'permission denied (HTTP 403)', '-'),
        @('bk_bad_secret_id', 'st_bad_secret_id', 'vigil/probe', 'failed', 'sign-in failed:', '-'),
        @('bk_kv1', 'st_kv1', 'vigil/probe', 'failed', 'not found (HTTP 404)', '-'),
        @('bk_rotating', 'st', 'vigil/rotating', 'succeeded', '-', 'current'))
    $labels['bk_kv1'] = 'bk_kv1 (KV v1: not supported)'
    $secretEnv = @('VIGIL_ST_SECRET_ID', 'VIGIL_ST_TOKEN', 'VIGIL_ST_EXPIRING_TOKEN', 'VIGIL_ST_BAD_TOKEN', 'VIGIL_ST_BAD_SECRET_ID')
    $leakKeys = @('ST_PROBE', 'ST_ROTATING', 'ST_KV1', 'VIGIL_ST_TOKEN', 'VIGIL_ST_SECRET_ID', 'VIGIL_ST_EXPIRING_TOKEN', 'ST_ROTATE_TOKEN', 'VIGIL_ST_BAD_TOKEN', 'VIGIL_ST_BAD_SECRET_ID')
}
# Only the credentials reach Vigil's environment.
foreach ($n in $secretEnv) { [Environment]::SetEnvironmentVariable($n, $o[$n], 'Process') }

function Write-StoreConfig {
    $c = "[vigil]`ninstance = store-test`n`n"
    $c += "[runner.ps]`ncommand = powershell.exe`narg = -NoProfile`narg = -NonInteractive`narg = -ExecutionPolicy`narg = Bypass`narg = -File`n`n[runners]`n.ps1 = ps`n`n"
    $c += "[backend.file]`npath = metrics\vigil.prom`n`n"
    foreach ($s in $stores) {
        $c += "[secret_store.$($s[0])]`n$($s[1])`n"
        if ($s[2]) { $c += "ca_file = config\store-ca.pem`n" }
        $c += "`n"
    }
    foreach ($j in $jobs) {
        $c += "[job.$($j[0])]`nfile = scripts\secret.ps1`nrun_every = 3650d`nsecret = BK_SECRET=store:$($j[1])/$($j[2])`n"
        if ($j[5] -cne '-') { $c += "env = BK_SECRET_SHA256=$(& $sha $o[$j[5]])`n" }
        $c += "`n"
    }
    [System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'), $c)
}

function Invoke-Vigil {
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root @args 2>&1 | ForEach-Object { "$_" }
}
# Job $Name's status and reason after one run.
function Get-JobEnd {
    param([string]$Name)
    Invoke-Vigil run $Name | Add-Content -LiteralPath $out
    $e = @{ Status = ''; Reason = '' }
    $f = Join-Path $root "state\jobs\$Name.state"
    if (Test-Path -LiteralPath $f) {
        foreach ($l in [System.IO.File]::ReadAllLines($f)) {
            if ($l -cmatch '^status *= *(.*)$') { $e.Status = $Matches[1] } elseif ($l -cmatch '^reason *= *(.*)$') { $e.Reason = $Matches[1] }
        }
    }
    $e.Shown = if ($e.Reason) { "$($e.Status): $($e.Reason)" } elseif ($e.Status) { $e.Status } else { 'no state' }
    return $e
}
# Runs job $Name once; it must end with $Status and, unless '-', a reason
# holding $Reason.
function Test-Job {
    param([string]$Name, [string]$Status, [string]$Reason, [string]$Label = $Name)
    $e = Get-JobEnd $Name
    if ($e.Status -ceq $Status -and ($Reason -ceq '-' -or $e.Reason.Contains($Reason))) { Write-Pass ('{0,-36} {1}' -f $Label, $e.Shown) }
    else { Write-Fail ('{0,-36} {1} (wanted {2}{3})' -f $Label, $e.Shown, $Status, $(if ($Reason -cne '-') { ": $Reason" } else { '' })) }
}

$bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
$rotateSh = (Join-Path $bk 'configs\secrets\rotate.sh').Replace('\', '/')
# True when the rotation worked; what it says goes to the console.
$rotate = { param([string]$Value) $Value | & $bash $rotateSh $Target $envFile.Replace('\', '/') $caFile.Replace('\', '/') 2>&1 | ForEach-Object { Write-Host "        $_" }; $LASTEXITCODE -eq 0 }

try {
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'scripts'), (Join-Path $root 'config'))
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app'), (Join-Path $repo 'vendor') -Destination $root
    Copy-Item -LiteralPath (Join-Path $bk 'workloads\secret.ps1') -Destination (Join-Path $root 'scripts')
    Copy-Item -LiteralPath $caFile -Destination (Join-Path $root 'config\store-ca.pem')

    Write-Output "`n$Target, $(if ($Target -ceq 'aws') { 'aws_secrets_manager' } else { 'hashicorp_vault' }) store"
    # The expiring token must have expired.
    if ($o['ST_EXPIRES_AT']) { while ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -le [long]$o['ST_EXPIRES_AT']) { Start-Sleep -Seconds 1 } }

    # The rotating secret gets a value of this run's own first: another
    # host's run may have rotated it since provisioning.
    $first = & $rnd
    if (-not (Test-Path -LiteralPath $bash)) { Write-Fail 'rotation: needs Git Bash, for configs/secrets/rotate.sh' }
    elseif (-not (& $rotate $first)) { Write-Fail 'rotation: cannot write the first value' }
    $o['current'] = $first
    Write-StoreConfig

    # Precheck fetches every secret too, and must say the same.
    $pre = @(Invoke-Vigil precheck)
    $pre | Add-Content -LiteralPath $out
    foreach ($j in $jobs) {
        if ($j[3] -ceq 'succeeded') {
            if (@($pre | Where-Object { $_.Contains("ok    job.$($j[0])") }).Count -gt 0) { Write-Pass "precheck $($j[0]): fetched" } else { Write-Fail "precheck $($j[0]): not fetched" }
        }
        elseif (@($pre | Where-Object { $_.Contains("job.$($j[0]): ") -and $_.Contains($j[4]) }).Count -gt 0) { Write-Pass "precheck $($j[0]): $($j[4])" }
        else { Write-Fail "precheck $($j[0]): wanted $($j[4])" }
    }
    foreach ($j in $jobs) {
        $label = if ($labels.ContainsKey($j[0])) { $labels[$j[0]] } else { $j[0] }
        Test-Job $j[0] $j[3] $j[4] $label
    }

    # Rotation: a new value, and the next run gets it, with nothing restarted.
    $rotated = & $rnd
    if ((Test-Path -LiteralPath $bash) -and (& $rotate $rotated)) {
        $o['current'] = $rotated
        Write-StoreConfig
        Test-Job 'bk_rotating' 'succeeded' '-' 'bk_rotating after rotation (new value)'
    }
    else { Write-Fail 'rotation: cannot write the new value' }

    if ($Target -ceq 'aws') {
        # A wrong secret key: AWS refuses it. An emulator that doesn't check
        # signatures accepts it, and is reported so.
        $jobs += , @('bk_bad_key', 'aws_bad_key', 'vigil/probe', 'failed', 'permission denied', 'ST_PROBE')
        Write-StoreConfig
        $e = Get-JobEnd 'bk_bad_key'
        if ($e.Status -ceq 'failed' -and $e.Reason.Contains('permission denied')) { Write-Pass ('{0,-36} {1}' -f 'bk_bad_key (wrong secret key)', $e.Shown) }
        elseif ($e.Status -ceq 'succeeded') { Write-Limit 'bk_bad_key (wrong secret key): accepted; the emulator does not check signatures' }
        else { Write-Fail ('{0,-36} {1}' -f 'bk_bad_key (wrong secret key)', $e.Shown) }
    }

    Write-NotRun "restart: $Target does not run here (run-store.sh does it on the Docker host)"

    # Leaks: every secret value and credential, under the root and in what
    # Vigil printed.
    $vals = @(foreach ($n in $leakKeys) { $o[$n] }) + @($first, $rotated)
    $leaks = @(foreach ($f in @(Get-ChildItem -LiteralPath $work -Recurse -File)) {
            $text = try { [System.IO.File]::ReadAllText($f.FullName) } catch { '' }
            foreach ($x in $vals) { if ($x -and $text.Contains($x)) { $f.FullName.Substring($work.Length + 1); break } }
        })
    if ($leaks.Count -gt 0) { Write-Fail "a secret or credential was written down: $($leaks -join ' ')" }
    else { Write-Pass 'no secret or credential under the Vigil root or in its output' }

    Write-Output "`n$script:pass passed, $script:fail failed, $script:notRun not run, $script:limits emulator limitations"
    exit $(if ($script:fail -eq 0) { 0 } else { 1 })
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
