#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: secrets at run time (SPECIFICATION.md 6.5) on Windows.
.DESCRIPTION
    Sets secrets with vigil secret, runs a job that receives them from
    Vigil's DPAPI store, a helper store and the environment, rotates them and
    sees the very next run use the new values with no restart, and checks the
    failure cases. The env: reference is set in the user's registry only, so
    the run proves it is read fresh rather than inherited. No value may ever
    appear in a log, state or spool file. The twin of secrets.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-sec.$PID"
$shell = (Get-Process -Id $PID).Path
$envName = "VIGIL_IT_REGION_$PID"
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Get-StateValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($Path)) {
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
    return @{ Code = $LASTEXITCODE; Output = ($out | Out-String) }
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

function Get-Reason { param([string]$Job) return Get-StateValue (Join-Path $root "state\jobs\$Job.state") 'reason' }

function Set-Expect {
    param([string]$Name, [string]$Value)
    [System.IO.File]::WriteAllText((Join-Path $root "expect\$Name"), $Value)
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
$scripts = Join-Path $root 'scripts'
[void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'config'), $scripts, (Join-Path $root 'expect'))

# The job reports, for each secret, whether it received exactly the value
# the test expects - never the value itself.
Set-Content -LiteralPath (Join-Path $scripts 'show.ps1') -Value @(
    'function Same($v, $f) { $e = [IO.File]::ReadAllText((Join-Path $env:IT_ROOT "expect\$f")); if ($v -ceq $e) { 1 } else { 0 } }',
    'Write-Output "metric pg_ok $(Same $env:PGPASSWORD pg)"',
    'Write-Output "metric api_ok $(Same $env:API_TOKEN api)"',
    'Write-Output "metric region_ok $(Same $env:REGION_KEY region)"')
# A helper store: prints the value of "api-token" from a file it can rotate.
# A batch file, which starts in milliseconds: the store timeout is short.
Set-Content -LiteralPath (Join-Path $scripts 'helper.cmd') -Value @(
    '@echo off',
    'if not "%1"=="get" exit /b 64',
    'if "%2"=="api-token" type "%~dp0..\helper-value" & exit /b 0',
    'if "%2"=="slow" ping -n 31 127.0.0.1 >nul & exit /b 0',
    'exit /b 2')

Set-Content -LiteralPath (Join-Path $root 'config\vigil.config') -Value @"
[runner.ps]
command = $shell
arg     = -NoProfile
arg     = -ExecutionPolicy
arg     = Bypass
arg     = -File

[runners]
.ps1 = ps

[secret_store.ext]
type    = helper
command = $scripts\helper.cmd
timeout = 2s

[job.show]
file        = scripts\show.ps1
run_every   = 1h
env         = IT_ROOT=$root
secret      = PGPASSWORD=secret:PGPASSWORD
secret      = API_TOKEN=store:ext/api-token
secret      = REGION_KEY=env:$envName
require_env = PGPASSWORD

[job.missing_secret]
file      = scripts\show.ps1
run_every = 1h
secret    = X=secret:NO_SUCH_SECRET

[job.helper_fails]
file      = scripts\show.ps1
run_every = 1h
secret    = X=store:ext/unknown

[job.helper_slow]
file      = scripts\show.ps1
run_every = 1h
secret    = X=store:ext/slow
"@

try {
    # 1. Set secrets; the store is encrypted and owner-only; list shows
    #    names, never values.
    $r = Invoke-Vigil @('secret', 'set', 'PGPASSWORD', '--stdin') "first pg value"
    Test-Equal 'secret set' '0' "$($r.Code)"
    Set-Expect pg 'first pg value'
    [System.IO.File]::WriteAllText((Join-Path $root 'helper-value'), "api-1 $PID")
    Set-Expect api "api-1 $PID"
    Set-Expect region 'eu-west'
    $stored = [System.IO.File]::ReadAllText((Join-Path $root 'config\secrets\PGPASSWORD'))
    Test-Equal 'secret file is encrypted' 'False' "$($stored.Contains('first pg value'))"
    $acl = Get-Acl -LiteralPath (Join-Path $root 'config\secrets')
    Test-Equal 'store folder inherits no access' 'True' "$($acl.AreAccessRulesProtected)"
    Test-Equal 'store folder grants only this account' "$([Security.Principal.WindowsIdentity]::GetCurrent().Name)" `
        (($acl.Access | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique) -join ',')
    $list = (Invoke-Vigil @('secret', 'list')).Output
    Test-Equal 'list shows the name' 'True' "$($list -cmatch '(?m)^PGPASSWORD ')"
    Test-Equal 'list never shows the value' 'False' "$($list.Contains('first pg value'))"

    # 2. A run receives all three, each exactly. The env: variable is only in
    #    the user's registry, set after this process started.
    [Environment]::SetEnvironmentVariable($envName, 'eu-west', 'User')
    $r = Invoke-Vigil @('run', 'show')
    Test-Equal 'run with secrets succeeds' '0' "$($r.Code)"
    Test-Equal 'secret: delivered exactly' '1' (Get-Metric show pg_ok)
    Test-Equal 'store: (helper) delivered exactly' '1' (Get-Metric show api_ok)
    Test-Equal 'env: read fresh from the registry' '1' (Get-Metric show region_ok)

    # 3. Rotate all three: the very next run uses the new values.
    [void](Invoke-Vigil @('secret', 'set', 'PGPASSWORD', '--stdin') 'second, longer pg value')
    Set-Expect pg 'second, longer pg value'
    [System.IO.File]::WriteAllText((Join-Path $root 'helper-value'), "api-2 $PID")
    Set-Expect api "api-2 $PID"
    [Environment]::SetEnvironmentVariable($envName, 'eu-north', 'User')
    Set-Expect region 'eu-north'
    [void](Invoke-Vigil @('run', 'show'))
    Test-Equal 'rotated secret: used by the next run' '1' (Get-Metric show pg_ok)
    Test-Equal 'rotated store: secret used by the next run' '1' (Get-Metric show api_ok)
    Test-Equal 'rotated env: used by the next run, no restart' '1' (Get-Metric show region_ok)

    # 4. Failures fail the run before it starts, naming the reference only.
    [void](Invoke-Vigil @('run', 'missing_secret'))
    Test-Equal 'missing secret fails the run' 'failed' (Get-StateValue (Join-Path $root 'state\jobs\missing_secret.state') 'status')
    Test-Equal 'missing secret reason' "secret secret:NO_SUCH_SECRET unavailable: not found in Vigil's secret store (vigil secret set NO_SUCH_SECRET)" (Get-Reason missing_secret)
    [void](Invoke-Vigil @('run', 'helper_fails'))
    Test-Equal 'failing helper reason' 'secret store:ext/unknown unavailable: the helper failed (exit code 2)' (Get-Reason helper_fails)
    [void](Invoke-Vigil @('run', 'helper_slow'))
    Test-Equal 'slow helper stopped at its timeout' 'secret store:ext/slow unavailable: the helper was stopped after 2s' (Get-Reason helper_slow)
    [Environment]::SetEnvironmentVariable($envName, [NullString]::Value, 'User')
    [void](Invoke-Vigil @('run', 'show'))
    Test-Equal 'unset env: reference reason' "secret env:$envName unavailable: not set in the environment" (Get-Reason show)

    # 5. A secret this account cannot decrypt is refused, not used.
    [Environment]::SetEnvironmentVariable($envName, 'eu-north', 'User')
    $path = Join-Path $root 'config\secrets\PGPASSWORD'
    $good = [System.IO.File]::ReadAllText($path)
    [System.IO.File]::WriteAllText($path, '01000000d08c9ddf0115d1118c7a00c04fc297eb0100000000')
    [void](Invoke-Vigil @('run', 'show'))
    Test-Equal 'undecryptable secret: refused' 'secret secret:PGPASSWORD unavailable: cannot be decrypted by this account on this machine; set it again with vigil secret set as the service account' (Get-Reason show)
    [System.IO.File]::WriteAllText($path, $good)

    # 6. delete removes it.
    [void](Invoke-Vigil @('secret', 'delete', 'PGPASSWORD'))
    Test-Equal 'delete' 'False' "$((Invoke-Vigil @('secret', 'list')).Output -cmatch '(?m)^PGPASSWORD ')"

    # No value ever reached a log, state or spool file.
    $leaks = @(foreach ($d in @('logs', 'state', 'spool')) {
            Get-ChildItem -LiteralPath (Join-Path $root $d) -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
                $t = [System.IO.File]::ReadAllText($_.FullName)
                $t.Contains('first pg value') -or $t.Contains('second, longer pg value') -or $t.Contains("api-1 $PID") -or $t.Contains("api-2 $PID")
            } | ForEach-Object { $_.FullName }
        })
    Test-Equal 'no value in any log, state or spool file' '' ($leaks -join ' ')
}
finally {
    [Environment]::SetEnvironmentVariable($envName, [NullString]::Value, 'User')
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
