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
    run-store.ps1 - tests Vigil's hashicorp_vault secret store against the
    test OpenBao or Vault, on Windows. The twin of run-store.sh, which
    describes the checks.
.DESCRIPTION
        .\scripts\run-store.ps1 openbao      (or vault)

    Needs .secrets\<target>.env and .secrets\tls\ca.pem from the host that
    ran scripts/start.sh, copied to the same paths here, and the store's
    port answering on 127.0.0.1 (an SSH tunnel; see README.md). Rotation
    uses configs/secrets/rotate.sh through Git Bash. The restart checks need
    the store's container on this machine; without it they are reported NOT
    RUN.

    Exit code: 0 when every check that ran passed.
#>

param([Parameter(Mandatory = $true)][string]$Target)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bk = Split-Path -Parent $here
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $bk))
$shell = (Get-Process -Id $PID).Path

if ($Target -cne 'openbao' -and $Target -cne 'vault') { Write-Output 'usage: run-store.ps1 openbao|vault'; exit 1 }
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
$o['VIGIL_ST_BAD_TOKEN'] = & $rnd
$o['VIGIL_ST_BAD_SECRET_ID'] = & $rnd
# Only the credentials reach Vigil's environment.
foreach ($n in 'VIGIL_ST_SECRET_ID', 'VIGIL_ST_TOKEN', 'VIGIL_ST_EXPIRING_TOKEN', 'VIGIL_ST_BAD_TOKEN', 'VIGIL_ST_BAD_SECRET_ID') {
    [Environment]::SetEnvironmentVariable($n, $o[$n], 'Process')
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-store.$PID"
$root = Join-Path $work 'root'
$out = Join-Path $work 'vigil.out'
$script:pass = 0; $script:fail = 0; $script:notRun = 0

# name, store, path, status, reason (- for none), as in run-store.sh.
$jobs = @(
    @('bk_approle', 'st', 'vigil/probe', 'succeeded', '-'),
    @('bk_token', 'st_token', 'vigil/probe', 'succeeded', '-'),
    @('bk_missing', 'st', 'vigil/nosuch', 'failed', 'not found (HTTP 404)'),
    @('bk_denied', 'st', 'other/probe', 'failed', 'permission denied (HTTP 403)'),
    @('bk_untrusted', 'st_untrusted', 'vigil/probe', 'failed', 'is not trusted'),
    @('bk_bad_token', 'st_bad_token', 'vigil/probe', 'failed', 'permission denied (HTTP 403)'),
    @('bk_expired', 'st_expired', 'vigil/probe', 'failed', 'permission denied (HTTP 403)'),
    @('bk_bad_secret_id', 'st_bad_secret_id', 'vigil/probe', 'failed', 'sign-in failed:'),
    @('bk_kv1', 'st_kv1', 'vigil/probe', 'failed', 'not found (HTTP 404)'),
    @('bk_rotating', 'st', 'vigil/rotating', 'succeeded', '-'))

function Write-StoreConfig {
    param([string]$RotatingSha)
    $store = {
        param($Name, $Auth, $Trusted)
        $s = "[secret_store.$Name]`ntype = hashicorp_vault`nurl = $($o['ST_URL'])`n"
        if ($Trusted) { $s += "ca_file = config\store-ca.pem`n" }
        return "$s$Auth`n`n"
    }
    $c = "[vigil]`ninstance = store-test`n`n"
    $c += "[runner.ps]`ncommand = powershell.exe`narg = -NoProfile`narg = -NonInteractive`narg = -ExecutionPolicy`narg = Bypass`narg = -File`n`n[runners]`n.ps1 = ps`n`n"
    $c += "[backend.file]`npath = metrics\vigil.prom`n`n"
    $c += & $store 'st' "auth = approle`nrole_id = $($o['ST_ROLE_ID'])`nsecret_id = env:VIGIL_ST_SECRET_ID" $true
    $c += & $store 'st_token' "auth = token`ntoken = env:VIGIL_ST_TOKEN" $true
    $c += & $store 'st_untrusted' "auth = token`ntoken = env:VIGIL_ST_TOKEN" $false
    $c += & $store 'st_bad_token' "auth = token`ntoken = env:VIGIL_ST_BAD_TOKEN" $true
    $c += & $store 'st_expired' "auth = token`ntoken = env:VIGIL_ST_EXPIRING_TOKEN" $true
    $c += & $store 'st_bad_secret_id' "auth = approle`nrole_id = $($o['ST_ROLE_ID'])`nsecret_id = env:VIGIL_ST_BAD_SECRET_ID" $true
    $c += & $store 'st_kv1' "mount = kv1`nauth = token`ntoken = env:VIGIL_ST_TOKEN" $true
    foreach ($j in $jobs) {
        $want = if ($j[0] -ceq 'bk_rotating') { $RotatingSha } else { & $sha $o['ST_PROBE'] }
        $c += "[job.$($j[0])]`nfile = scripts\secret.ps1`nrun_every = 3650d`nsecret = BK_SECRET=store:$($j[1])/$($j[2])`nenv = BK_SECRET_SHA256=$want`n`n"
    }
    [System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'), $c)
}

function Invoke-Vigil {
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root @args 2>&1 | ForEach-Object { "$_" }
}
function Write-Pass { param([string]$Text) Write-Output "  PASS  $Text"; $script:pass++ }
function Write-Fail { param([string]$Text) Write-Output "  FAIL  $Text"; $script:fail++ }

# Runs job $Name once; it must end with $Status and, unless '-', a reason
# holding $Reason.
function Test-Job {
    param([string]$Name, [string]$Status, [string]$Reason, [string]$Label = $Name)
    Invoke-Vigil run $Name | Add-Content -LiteralPath $out
    $st = ''; $why = ''
    $f = Join-Path $root "state\jobs\$Name.state"
    if (Test-Path -LiteralPath $f) {
        foreach ($l in [System.IO.File]::ReadAllLines($f)) {
            if ($l -cmatch '^status *= *(.*)$') { $st = $Matches[1] } elseif ($l -cmatch '^reason *= *(.*)$') { $why = $Matches[1] }
        }
    }
    $shown = if ($why) { "${st}: $why" } else { $st }
    if ($st -ceq $Status -and ($Reason -ceq '-' -or $why.Contains($Reason))) { Write-Pass ('{0,-34} {1}' -f $Label, $shown) }
    else { Write-Fail ('{0,-34} {1} (wanted {2}{3})' -f $Label, $(if ($shown) { $shown } else { 'no state' }), $Status, $(if ($Reason -cne '-') { ": $Reason" } else { '' })) }
}

try {
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'scripts'), (Join-Path $root 'config'))
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app'), (Join-Path $repo 'vendor') -Destination $root
    Copy-Item -LiteralPath (Join-Path $bk 'workloads\secret.ps1') -Destination (Join-Path $root 'scripts')
    Copy-Item -LiteralPath $caFile -Destination (Join-Path $root 'config\store-ca.pem')
    Write-StoreConfig (& $sha $o['ST_ROTATING'])

    Write-Output "`n$Target, hashicorp_vault store"
    # The expiring token must have expired.
    while ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -le [long]$o['ST_EXPIRES_AT']) { Start-Sleep -Seconds 1 }

    # The rotating secret gets a value of this run's own first: another
    # host's run may have rotated it since provisioning.
    $bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    $rotateSh = (Join-Path $bk 'configs\secrets\rotate.sh').Replace('\', '/')
    # True when it worked; what it says goes to the console, not the result.
    $rotate = { param([string]$Value) $Value | & $bash $rotateSh $envFile.Replace('\', '/') $caFile.Replace('\', '/') 2>&1 | ForEach-Object { Write-Host "        $_" }; $LASTEXITCODE -eq 0 }
    $first = & $rnd
    if (-not (Test-Path -LiteralPath $bash)) { Write-Fail 'rotation: needs Git Bash, for configs/secrets/rotate.sh' }
    elseif (-not (& $rotate $first)) { Write-Fail 'rotation: cannot write the first value' }
    Write-StoreConfig (& $sha $first)

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
        $label = if ($j[0] -ceq 'bk_kv1') { 'bk_kv1 (KV v1: not supported)' } else { $j[0] }
        Test-Job $j[0] $j[3] $j[4] $label
    }

    # Rotation: a new value, and the next run gets it, with nothing restarted.
    $rotated = & $rnd
    if ((Test-Path -LiteralPath $bash) -and (& $rotate $rotated)) {
        Write-StoreConfig (& $sha $rotated)
        Test-Job 'bk_rotating' 'succeeded' '-' 'bk_rotating after rotation (new value)'
    }
    else { Write-Fail 'rotation: cannot write the new value' }

    # Restart: only where this machine runs the store's container.
    $running = $false
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $running = [bool](& docker compose --project-directory $bk -f (Join-Path $bk 'compose.yaml') ps -q --status running $Target 2> $null)
    }
    if ($running) {
        Write-Output "  NOT RUN  restart: run it with run-store.sh on the Docker host, which unseals with provision.sh"
    }
    else { Write-Output "  NOT RUN  restart: $Target does not run here (it needs the Docker host)" }
    $script:notRun++

    # Leaks: every secret value and credential, under the root and in what
    # Vigil printed.
    $values = @($o['ST_PROBE'], $o['ST_ROTATING'], $first, $rotated, $o['ST_KV1'], $o['VIGIL_ST_TOKEN'], $o['VIGIL_ST_SECRET_ID'],
        $o['VIGIL_ST_EXPIRING_TOKEN'], $o['ST_ROTATE_TOKEN'], $o['VIGIL_ST_BAD_TOKEN'], $o['VIGIL_ST_BAD_SECRET_ID'])
    $files = @(Get-ChildItem -LiteralPath $work -Recurse -File)
    $leaks = @(foreach ($f in $files) {
            $text = try { [System.IO.File]::ReadAllText($f.FullName) } catch { '' }
            foreach ($v in $values) { if ($v -and $text.Contains($v)) { $f.FullName.Substring($work.Length + 1); break } }
        })
    if ($leaks.Count -gt 0) { Write-Fail "a secret or credential was written down: $($leaks -join ' ')" }
    else { Write-Pass 'no secret or credential under the Vigil root or in its output' }

    Write-Output "`n$script:pass passed, $script:fail failed, $script:notRun not run"
    exit $(if ($script:fail -eq 0) { 0 } else { 1 })
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
