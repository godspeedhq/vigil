#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: vigil pack (SPECIFICATION.md 18.10) on Windows.
.DESCRIPTION
    Runs against mock-files.py as the releases of vigil-packs, signed with a
    key for this run. The twin of pack.sh.

    Needs Python, and Git Bash for openssl.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$shell = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil pack.$PID"
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Invoke-Vigil {
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root @args 2>&1
    return @{ Code = $LASTEXITCODE; Text = (@($out | ForEach-Object { "$_" }) -join "`n") }
}

# Precheck refuses the test override (22.4.4).
function Invoke-Precheck {
    $url = $env:VIGIL_TEST_RELEASE_URL
    Remove-Item Env:\VIGIL_TEST_RELEASE_URL
    $r = Invoke-Vigil precheck
    $env:VIGIL_TEST_RELEASE_URL = $url
    return [string]$r.Code
}

function Invoke-Openssl {
    param([string]$Line)
    & $bash -c "openssl $Line" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "openssl $Line failed" }
}

function Get-Text { param([string]$Path) if ([System.IO.File]::Exists($Path)) { [System.IO.File]::ReadAllText($Path) } else { '' } }
function Get-Count { param([string]$Pattern) [string]([regex]::Matches((Get-Text $cfg), $Pattern, 'Multiline')).Count }
function Get-PackVersion { if ((Get-Text "$root\packs\base\pack.config") -cmatch '(?m)^version = (\S+)') { $Matches[1] } }
function Get-Snapshot { (Get-Text $cfg) + (Get-Text "$root\packs\base\pack.config") }

# Publishes vigil-packs $Version with pack base at $Version and these jobs.
function Publish-Packs {
    param([string]$Version, [string[]]$Jobs, [string]$Key = "$work/release.key", [string]$Min = '0.0.1', [string]$Every = '1h')
    $d = "$www\packs\releases\download\v$Version"
    $stage = "$work\stage"
    $s = "$stage\vigil-packs-$Version"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    [void](New-Item -ItemType Directory -Force -Path $d, "$s\base", "$www\packs\releases\tag")
    $m = "[pack]`nversion = $Version`nvigil = $Min`ndescription = For the test`n`n"
    foreach ($j in $Jobs) {
        $m += "[job.$j]`nmetric_name = it.$j`nmetrics = up`nrun_every = $Every`nmax_runtime = 30s`n`n"
        [System.IO.File]::WriteAllText("$s\base\$j.ps1", "Write-Output 'metric up 1' # $Version`n")
        [System.IO.File]::WriteAllText("$s\base\$j.sh", "echo 'metric up 1'`n")
    }
    [System.IO.File]::WriteAllText("$s\base\pack.config", $m)
    Compress-Archive -LiteralPath $s -DestinationPath "$d\vigil-packs-$Version.zip" -Force
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath "$d\vigil-packs-$Version.zip").Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText("$d\SHA256SUMS", "$h  vigil-packs-$Version.zip`n")
    $b = $d.Replace('\', '/')
    Invoke-Openssl "dgst -sha256 -sign '$($Key.Replace('\', '/'))' -out '$b/SHA256SUMS.sig' '$b/SHA256SUMS'"
    [System.IO.File]::WriteAllText("$www\packs\releases\tag\v$Version", '')
    [System.IO.File]::WriteAllText("$work\mock\redirects", "/packs/releases/latest /packs/releases/tag/v$Version`n")
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
$python = $null
foreach ($p in @('python3', 'python', 'py')) {
    if (Get-Command $p -CommandType Application -ErrorAction SilentlyContinue) {
        & $p -c 'import http.server' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $python = (Get-Command $p -CommandType Application | Select-Object -First 1).Source; break }
    }
}
if (-not $python) { Write-Host 'needs Python'; exit 1 }
$bash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $bash) { Write-Host 'needs Git Bash, for openssl'; exit 1 }
[void](New-Item -ItemType Directory -Force -Path "$work\mock\www", "$work\root")
$work = (Resolve-Path -LiteralPath $work).ProviderPath
$www = "$work\mock\www"
$root = "$work\root"
$cfg = "$root\config\vigil.config"
$mock = $null

try {
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app'), (Join-Path $repo 'vendor') -Destination $root
    [System.IO.File]::WriteAllText("$root\app\VERSION", "0.3.0`n")
    $kw = $work.Replace('\', '/')
    Invoke-Openssl "genrsa -out '$kw/release.key' 2048"
    Invoke-Openssl "genrsa -out '$kw/other.key' 2048"
    Invoke-Openssl "rsa -in '$kw/release.key' -pubout -out '$kw/release.pem'"
    $env:VIGIL_TEST_RELEASE_KEY = "$work\release.pem"
    $mock = Start-Process -FilePath $python -ArgumentList @("`"$here\mock-files.py`"", "`"$work\mock`"") -PassThru -NoNewWindow -RedirectStandardError "$work\mock\stderr"
    for ($i = 0; $i -lt 600 -and -not (Test-Path -LiteralPath "$work\mock\port"); $i++) { Start-Sleep -Milliseconds 100 }
    $env:VIGIL_TEST_RELEASE_URL = "http://127.0.0.1:$([System.IO.File]::ReadAllText("$work\mock\port").Trim())"

    [void](Invoke-Vigil init --instance pk --backend file --no-sample)
    [System.IO.File]::WriteAllText("$root\scripts\mine.ps1", "Write-Output 'metric mine 1'`n")
    [System.IO.File]::AppendAllText($cfg, "`n[job.mine]`nfile = scripts/mine.ps1`nrun_every = 1h`n")
    $mine = Get-Text "$root\scripts\mine.ps1"

    Write-Host 'Adding'
    Test-Equal 'nothing added' 'no packs added: vigil pack add base' (Invoke-Vigil pack list).Text
    Publish-Packs '1.0.0' @('cpu', 'disk')
    $r = Invoke-Vigil pack add base
    Test-Equal 'adds' '0' ([string]$r.Code)
    Test-Equal 'says what' 'pack base 1.0.0: jobs base_cpu base_disk' $r.Text
    Test-Equal 'the scripts are in place' 'True' ([string](Test-Path -LiteralPath "$root\packs\base\cpu.ps1"))
    Test-Equal 'the jobs are in the configuration' '2' (Get-Count '^\[job\.base_')
    Test-Equal 'precheck is happy' '0' (Invoke-Precheck)
    Test-Equal 'a job runs' '0' ([string](Invoke-Vigil run base_cpu).Code)
    Test-Equal 'listed' 'base         1.0.0      For the test' (Invoke-Vigil pack list).Text
    $r = Invoke-Vigil pack add base
    Test-Equal 'adding twice is refused' '1' ([string]$r.Code)
    Test-Equal 'saying so' 'True' ([string]$r.Text.Contains('already added'))
    Test-Equal 'an unknown pack is refused' 'vigil: no pack called nosuch in the packs 1.0.0' (Invoke-Vigil pack add nosuch).Text
    Test-Equal 'a bad name is refused' 'vigil: not a pack name: ../x' (Invoke-Vigil pack add '../x').Text

    Write-Host 'Updating'
    Test-Equal 'nothing to do' 'pack base 1.0.0 is added: nothing to do' (Invoke-Vigil pack update).Text
    $t = Get-Text $cfg
    $at = $t.IndexOf('[job.base_cpu]')
    $t = $t.Substring(0, $at) + ([regex]'run_every = 1h').Replace($t.Substring($at), 'run_every = 5m', 1)
    [System.IO.File]::WriteAllText($cfg, $t)
    Publish-Packs '1.1.0' @('cpu', 'load')
    Test-Equal 'the check says so' 'pack base 1.0.0 is added; 1.1.0 is available: vigil pack update' (Invoke-Vigil pack update --check).Text
    Test-Equal 'the check changes nothing' '1.0.0' (Get-PackVersion)
    $r = Invoke-Vigil pack update
    Test-Equal 'updates' '0' ([string]$r.Code)
    Test-Equal 'to the new version' '1.1.0' (Get-PackVersion)
    Test-Equal 'the scripts are the new ones' 'True' ([string](Get-Text "$root\packs\base\cpu.ps1").Contains('1.1.0'))
    Test-Equal 'an edit is kept' 'True' ([string]((Get-Text $cfg) -cmatch '(?s)\[job\.base_cpu\].*?run_every = 5m'))
    Test-Equal 'a new job is added' '1' (Get-Count '^\[job\.base_load\]')
    Test-Equal 'a dropped job goes' '0' (Get-Count '^\[job\.base_disk\]')
    Test-Equal 'its keys too' '0' (Get-Count 'packs/base/disk')
    Test-Equal 'your own job stays' '1' (Get-Count '^\[job\.mine\]')
    Test-Equal 'your own script is untouched' $mine (Get-Text "$root\scripts\mine.ps1")
    Test-Equal 'precheck is still happy' '0' (Invoke-Precheck)

    Write-Host 'Refused'
    $was = Get-Snapshot
    Publish-Packs '1.2.0' @('cpu') -Key "$work/other.key"
    $r = Invoke-Vigil pack update
    Test-Equal 'a bad signature is refused' '1' ([string]$r.Code)
    Test-Equal 'saying so' 'vigil: the packs 1.2.0 are not signed by the Vigil release key; nothing was changed' $r.Text
    Test-Equal 'and changing nothing' $was (Get-Snapshot)
    Publish-Packs '1.3.0' @('cpu')
    [System.IO.File]::AppendAllText("$www\packs\releases\download\v1.3.0\vigil-packs-1.3.0.zip", 'x')
    Test-Equal 'a tampered archive is refused' 'vigil: the packs 1.3.0 do not match their SHA256SUMS; nothing was changed' (Invoke-Vigil pack update).Text
    Publish-Packs '1.4.0' @('cpu')
    Remove-Item -LiteralPath "$www\packs\releases\download\v1.4.0\SHA256SUMS.sig"
    Test-Equal 'a missing signature is refused' 'vigil: cannot download the packs 1.4.0' (Invoke-Vigil pack update).Text
    Publish-Packs '1.5.0' @('cpu') -Min '99.0.0'
    Test-Equal 'too old a Vigil is refused' 'vigil: pack base needs Vigil 99.0.0 or later: vigil self update' (Invoke-Vigil pack update).Text
    Test-Equal 'and nothing changed' $was (Get-Snapshot)

    # A job Vigil cannot accept: all of it goes back.
    Publish-Packs '1.6.0' @('cpu', 'extra') -Every 'soon'
    $r = Invoke-Vigil pack update
    Test-Equal 'a pack that would not be valid is refused' '1' ([string]$r.Code)
    Test-Equal 'saying why' 'True' ([string]$r.Text.Contains('would not be valid here'))
    Test-Equal 'and goes back' $was (Get-Snapshot)
    Test-Equal 'the old scripts are back' 'True' ([string](Get-Text "$root\packs\base\cpu.ps1").Contains('1.1.0'))

    Write-Host 'A configuration from a source'
    $keep = Get-Text $cfg
    [System.IO.File]::WriteAllText($cfg, "[vigil]`nconfig_source = remote`nconfig_file = vigil.config`n`n[source.remote]`ntype = local`npath = C:\Windows`n")
    Test-Equal 'is not edited' '1' ([string](Invoke-Vigil pack remove base).Code)
    [System.IO.File]::WriteAllText($cfg, $keep)

    Write-Host 'Removing'
    Test-Equal 'removes' 'removed pack base' (Invoke-Vigil pack remove base).Text
    Test-Equal 'the scripts go' 'False' ([string](Test-Path -LiteralPath "$root\packs\base"))
    Test-Equal 'the jobs go' '0' (Get-Count 'base')
    Test-Equal 'your own job stays too' '1' (Get-Count '^\[job\.mine\]')
    Test-Equal 'precheck is happy after' '0' (Invoke-Precheck)
    Test-Equal 'removing twice is refused' 'vigil: pack base is not added' (Invoke-Vigil pack remove base).Text

    Write-Host 'Init'
    Publish-Packs '2.0.0' @('cpu')
    Remove-Item -LiteralPath "$root\config", "$root\scripts" -Recurse -Force
    Test-Equal 'init adds a pack' '0' ([string](Invoke-Vigil init --instance pk --backend file --pack base).Code)
    Test-Equal 'in place of the sample' '0' (Get-Count '^\[job\.disk\]')
    Test-Equal 'with its jobs' '1' (Get-Count '^\[job\.base_cpu\]')
    Remove-Item -LiteralPath "$root\config", "$root\scripts", "$root\packs" -Recurse -Force
    Test-Equal 'a pack asked for and missing fails init' '1' ([string](Invoke-Vigil init --instance pk --backend file --pack nosuch).Code)
}
finally {
    if ($mock) { try { Stop-Process -Id $mock.Id -Force -ErrorAction Stop } catch { } }
    Remove-Item Env:\VIGIL_TEST_RELEASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:\VIGIL_TEST_RELEASE_KEY -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
