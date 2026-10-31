#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: vigil precheck (SPECIFICATION.md 16.3, 16.4) on
    Windows, and the supervisor refusing to start with the full list of
    problems. The twin of precheck.sh.
.DESCRIPTION
    Precheck must change nothing and never print a secret's value.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-pre.$PID"
$shell = (Get-Process -Id $PID).Path
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Invoke-Vigil {
    param([string[]]$Arguments, [string]$InputText)
    $ErrorActionPreference = 'Continue'
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $o = $InputText | & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root @Arguments 2>&1
    }
    else { $o = & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root @Arguments 2>&1 }
    $script:lines = @($o | ForEach-Object { "$_" })
    return $LASTEXITCODE
}

# Whether the last output has the line $Line exactly.
function Test-Has { param([string]$Line) return "$(@($script:lines | Where-Object { $_ -ceq $Line }).Count -gt 0)" }

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
$scripts = Join-Path $root 'scripts'
[void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'config'), $scripts)
$root = (Resolve-Path -LiteralPath $root).ProviderPath
Set-Content -LiteralPath (Join-Path $scripts 'ok.ps1') -Value 'Write-Output "metric ok 1"'
$cfg = Join-Path $root 'config\vigil.config'

Set-Content -LiteralPath $cfg -Value @"
[runner.ps]
command = $shell
arg     = -NoProfile
arg     = -File

[runners]
.ps1 = ps

[secret_store.vault]
type  = hashicorp_vault
url   = https://vault.example.com
auth  = token
token = secret:VAULT_TOKEN

[job.show]
file        = scripts\ok.ps1
run_every   = 1h
secret      = PGPASSWORD=secret:PGPASSWORD
require_env = PGPASSWORD
require_env = PATH
"@

try {
    # 1. Everything in place: passes, and changes nothing.
    [void](Invoke-Vigil @('secret', 'set', 'PGPASSWORD', '--stdin') "pg value $PID")
    [void](Invoke-Vigil @('secret', 'set', 'VAULT_TOKEN', '--stdin') "vault value $PID")
    $rc = Invoke-Vigil @('precheck')
    Test-Equal 'passes: exit code' '0' "$rc"
    Test-Equal 'passes: no configuration problems' 'True' (Test-Has '  no problems')
    Test-Equal 'passes: the job' 'True' (Test-Has '  ok    job.show')
    Test-Equal 'passes: a store credential, by reference' 'True' (Test-Has '  ok    secret_store.vault: token secret:VAULT_TOKEN')
    Test-Equal 'passes: result' 'True' (Test-Has 'precheck passed')
    Test-Equal 'changes nothing' 'config scripts' ((Get-ChildItem -LiteralPath $root | ForEach-Object { $_.Name } | Sort-Object) -join ' ')

    # 2. With a job: its effective settings and their sources.
    $rc = Invoke-Vigil @('precheck', 'show')
    Test-Equal 'job: exit code' '0' "$rc"
    Test-Equal 'job: header' 'True' (Test-Has 'job.show')
    Test-Equal 'job: runner from the extension map' 'True' (Test-Has '  runner            = ps                     (runners)')
    Test-Equal 'job: secret by reference' 'True' (Test-Has '  secret            = PGPASSWORD=secret:PGPASSWORD (job)')
    $rc = Invoke-Vigil @('precheck', 'nosuch')
    Test-Equal 'unknown job: exit code' '1' "$rc"
    Test-Equal 'unknown job: result' 'True' (Test-Has 'precheck failed: no job nosuch in the configuration')

    # 3. What a run would trip on, each reported, nothing else stopped.
    Add-Content -LiteralPath $cfg -Value @"

[runner.gone]
command = C:\nonexistent\bin\tool.exe

[job.broken]
file        = scripts\missing.ps1
runner      = gone
run_every   = 1h
working_dir = no\such\dir
secret      = X=secret:NO_SUCH_SECRET
require_env = VIGIL_IT_SURELY_UNSET
"@
    [void](Invoke-Vigil @('secret', 'delete', 'VAULT_TOKEN'))
    $env:VIGIL_FAULT = 'crash'
    $rc = Invoke-Vigil @('precheck')
    Remove-Item Env:\VIGIL_FAULT
    Test-Equal 'fails: exit code' '1' "$rc"
    Test-Equal 'fails: the good job still passes' 'True' (Test-Has '  ok    job.show')
    Test-Equal 'fails: working directory' 'True' (Test-Has "  FAIL  job.broken: working directory not found: $root\no\such\dir")
    Test-Equal 'fails: runner command' 'True' (Test-Has '  FAIL  job.broken: not found: C:\nonexistent\bin\tool.exe')
    Test-Equal 'fails: job file' 'True' (Test-Has "  FAIL  job.broken: file not found: $root\scripts\missing.ps1")
    Test-Equal 'fails: secret' 'True' (Test-Has "  FAIL  job.broken: secret secret:NO_SUCH_SECRET unavailable: not found in Vigil's secret store (vigil secret set NO_SUCH_SECRET)")
    Test-Equal 'fails: require_env' 'True' (Test-Has '  FAIL  job.broken: missing environment variable VIGIL_IT_SURELY_UNSET')
    Test-Equal 'fails: store credential' 'True' (Test-Has "  FAIL  secret_store.vault: token secret:VAULT_TOKEN unavailable: not found in Vigil's secret store (vigil secret set VAULT_TOKEN)")
    Test-Equal 'fails: VIGIL_FAULT' 'True' (Test-Has '  FAIL  VIGIL_FAULT is set: fault injection is for tests only (22.4.1)')
    Test-Equal 'fails: result' 'True' (Test-Has 'precheck failed: 7 problem(s)')
    Test-Equal 'no secret value printed' '' (@($script:lines | Where-Object { $_.Contains("pg value $PID") -or $_.Contains("vault value $PID") }) -join ' ')

    # 4. A rejected configuration: every problem, in file order, and nothing else.
    [System.IO.File]::WriteAllText($cfg, "[vigil]`nmax_concurrent = 0`n`n[job.x]`nfile = a.ps1`n`n[weird]`n")
    $rc = Invoke-Vigil @('precheck')
    Test-Equal 'rejected: exit code' '1' "$rc"
    Test-Equal 'rejected: first problem' 'True' (Test-Has "  ERROR    line 2: 'max_concurrent' must be at least 1 (E_INTEGER)")
    Test-Equal 'rejected: invalid job' 'True' (Test-Has '  INVALID  job.x, line 4: [job.x] needs run_every or run_at (E_SCHEDULE_NONE)')
    Test-Equal 'rejected: last problem' 'True' (Test-Has '  ERROR    line 7: unknown section [weird] (E_SECTION_UNKNOWN)')
    Test-Equal 'rejected: result' 'True' (Test-Has 'precheck failed: the configuration is rejected; nothing else was checked')

    # 5. The supervisor will not start, and says why, in full.
    $rc = Invoke-Vigil @('supervise', '--once')
    Test-Equal 'supervisor refuses: exit code' '1' "$rc"
    Test-Equal 'supervisor refuses: summary' 'True' (Test-Has 'vigil: the configuration has errors; run vigil precheck')
    Test-Equal 'supervisor refuses: every problem' 'True' (Test-Has "  ERROR    line 2: 'max_concurrent' must be at least 1 (E_INTEGER)")
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
