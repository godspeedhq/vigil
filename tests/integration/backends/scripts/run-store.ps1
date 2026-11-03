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
    run-store.ps1 - proves Vigil's hashicorp_vault secret store against the
    test OpenBao, on Windows. The twin of run-store.sh, which lists the
    checks.
.DESCRIPTION
        .\scripts\run-store.ps1 openbao

    Needs .openbao.env and .openbao-ca.pem from the host that ran
    scripts/start.sh openbao, copied next to compose.yaml, and OpenBao's
    port 8200 answering on 127.0.0.1 here (an SSH tunnel; see README.md).
    Vigil is copied into a temporary folder; nothing is installed.

    Exit code: 0 when every check passes.
#>

param([Parameter(Mandatory = $true)][string]$Target)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bk = Split-Path -Parent $here
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $bk))
$shell = (Get-Process -Id $PID).Path

if ($Target -cne 'openbao') { Write-Output 'usage: run-store.ps1 openbao'; exit 1 }
$envFile = Join-Path $bk '.openbao.env'
$caFile = Join-Path $bk '.openbao-ca.pem'
if (-not (Test-Path -LiteralPath $envFile) -or -not (Test-Path -LiteralPath $caFile)) {
    Write-Output 'no .openbao.env or .openbao-ca.pem: copy them from the host that ran scripts/start.sh openbao'
    exit 1
}
$o = @{}
foreach ($l in [System.IO.File]::ReadAllLines($envFile)) {
    if ($l -cmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $o[$Matches[1]] = $Matches[2] }
}
# Only the credentials reach Vigil's environment; the probe's value is kept
# here, for the leak check.
foreach ($n in 'VIGIL_BAO_SECRET_ID', 'VIGIL_BAO_TOKEN') { [Environment]::SetEnvironmentVariable($n, $o[$n], 'Process') }
$probe = $o['BK_SECRET_VALUE']

$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-store.$PID"
$root = Join-Path $work 'root'
$fail = 0

function Invoke-Vigil {
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root @args 2>&1 | ForEach-Object { "$_" }
}

try {
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'scripts'), (Join-Path $root 'config'))
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app'), (Join-Path $repo 'vendor') -Destination $root
    Copy-Item -LiteralPath (Join-Path $bk 'workloads\secret.ps1') -Destination (Join-Path $root 'scripts')
    Copy-Item -LiteralPath $caFile -Destination (Join-Path $root 'config\openbao-ca.pem')

    $job = { param($Name, $Path, $Store) "[job.$Name]`nfile = scripts\secret.ps1`nrun_every = 3650d`nsecret = BK_SECRET=store:$Store/$Path`nenv = BK_SECRET_SHA256=$($o['BK_SECRET_SHA256'])`n`n" }
    $c = "[vigil]`ninstance = store-test`n`n"
    $c += "[runner.ps]`ncommand = powershell.exe`narg = -NoProfile`narg = -NonInteractive`narg = -ExecutionPolicy`narg = Bypass`narg = -File`n`n[runners]`n.ps1 = ps`n`n"
    $c += "[backend.file]`npath = metrics\vigil.prom`n`n"
    $c += "[secret_store.bao]`ntype = hashicorp_vault`nurl = https://127.0.0.1:8200`nca_file = config\openbao-ca.pem`nauth = approle`nrole_id = $($o['VIGIL_BAO_ROLE_ID'])`nsecret_id = env:VIGIL_BAO_SECRET_ID`n`n"
    $c += "[secret_store.bao_token]`ntype = hashicorp_vault`nurl = https://127.0.0.1:8200`nca_file = config\openbao-ca.pem`nauth = token`ntoken = env:VIGIL_BAO_TOKEN`n`n"
    $c += "[secret_store.bao_untrusted]`ntype = hashicorp_vault`nurl = https://127.0.0.1:8200`nauth = token`ntoken = env:VIGIL_BAO_TOKEN`n`n"
    $c += & $job 'bk_secret_approle' 'vigil/probe' 'bao'
    $c += & $job 'bk_secret_token' 'vigil/probe' 'bao_token'
    $c += & $job 'bk_secret_missing' 'vigil/nosuch' 'bao'
    $c += & $job 'bk_secret_denied' 'other/probe' 'bao'
    $c += & $job 'bk_secret_untrusted' 'vigil/probe' 'bao_untrusted'
    [System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'), $c)

    Write-Output "`nopenbao, hashicorp_vault store"
    # Precheck fetches every secret too: the first two must be fetched, and
    # the other three fail, each for its own reason.
    $pre = (@(Invoke-Vigil precheck) -join "`n")
    foreach ($p in @(
            @('bk_secret_approle', 'ok    job.bk_secret_approle', 'fetched'),
            @('bk_secret_token', 'ok    job.bk_secret_token', 'fetched'),
            @('bk_secret_missing', 'job.bk_secret_missing: secret store:bao/vigil/nosuch unavailable: not found (HTTP 404)', 'not found (HTTP 404)'),
            @('bk_secret_denied', 'job.bk_secret_denied: secret store:bao/other/probe unavailable: permission denied', 'permission denied'),
            @('bk_secret_untrusted', 'job.bk_secret_untrusted: secret store:bao_untrusted/vigil/probe unavailable: the certificate of', 'not trusted'))) {
        if ($pre.Contains($p[1])) { Write-Output ('  PASS  precheck {0,-20} {1}' -f $p[0], $p[2]) }
        else { Write-Output ('  FAIL  precheck {0,-20} (wanted: {1})' -f $p[0], $p[1]); $fail = 1 }
    }
    if ($fail) { $pre.Split("`n") | ForEach-Object { "        $_" } }

    foreach ($p in @(
            @('bk_secret_approle', 'succeeded', ''),
            @('bk_secret_token', 'succeeded', ''),
            @('bk_secret_missing', 'failed', 'not found (HTTP 404)'),
            @('bk_secret_denied', 'failed', 'permission denied'),
            @('bk_secret_untrusted', 'failed', 'not trusted'))) {
        $out = @(Invoke-Vigil run $p[0])
        $status = ''; $reason = ''
        $st = Join-Path $root "state\jobs\$($p[0]).state"
        if (Test-Path -LiteralPath $st) {
            foreach ($l in [System.IO.File]::ReadAllLines($st)) {
                if ($l -cmatch '^status *= *(.*)$') { $status = $Matches[1] }
                elseif ($l -cmatch '^reason *= *(.*)$') { $reason = $Matches[1] }
            }
        }
        $shown = if ($reason) { "${status}: $reason" } else { $status }
        if ($status -ceq $p[1] -and (-not $p[2] -or $reason.Contains($p[2]))) { Write-Output ('  PASS  {0,-20} {1}' -f $p[0], $shown) }
        else {
            Write-Output ('  FAIL  {0,-20} {1} (wanted {2} {3})' -f $p[0], $(if ($shown) { $shown } else { 'no state' }), $p[1], $p[2])
            $out | ForEach-Object { "        $_" }
            $fail = 1
        }
    }

    $leaks = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
            try { [System.IO.File]::ReadAllText($_.FullName).Contains($probe) } catch { $false }
        })
    if ($leaks.Count -gt 0) {
        Write-Output '  FAIL  the probe value was written down:'
        $leaks | ForEach-Object { "        $($_.FullName.Substring($root.Length + 1))" }
        $fail = 1
    }
    else { Write-Output '  PASS  the probe value appears nowhere under the Vigil root' }
    exit $fail
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
