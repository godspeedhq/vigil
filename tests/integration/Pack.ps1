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
    Integration test: vigil pack (SPECIFICATION.md 18.10) on Windows.
.DESCRIPTION
    Runs against mock-files.py as the pack repository, signed with a key for
    this run. The twin of pack.sh.

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

# Writes pack base at $Version with these jobs in a folder.
function New-TestPack {
    param([string]$To, [string]$Version, [string[]]$Jobs, [string]$Min = '0.0.1', [string]$Every = '1h', [string]$About = 'For the test')
    [void](New-Item -ItemType Directory -Force -Path $To)
    $m = "[pack]`nversion = $Version`nvigil = $Min`ndescription = $About`n`n"
    foreach ($j in $Jobs) {
        $m += "[job.$j]`nmetric_name = it.$j`nmetrics = up`nrun_every = $Every`nmax_runtime = 30s`n`n"
        [System.IO.File]::WriteAllText("$To\$j.ps1", "Write-Output 'metric up 1' # $Version`n")
    }
    [System.IO.File]::WriteAllText("$To\pack.config", $m)
}

# Adds pack $Name at $Version with these jobs to packs release $Tag, and
# makes $Tag the newest: its index carries every version published before.
function Publish-Pack {
    param([string]$Tag, [string]$Name, [string]$Version, [string[]]$Jobs, [string]$Key = "$work/release.key", [string]$Min = '0.0.1', [string]$About = 'For the test')
    $d = "$www\releases\download\$Tag"
    $stage = "$work\stage"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    [void](New-Item -ItemType Directory -Force -Path $d)
    New-TestPack "$stage\$Name" $Version $Jobs -Min $Min -About $About
    $f = "vigil-pack-$Name-$Version-windows.zip"
    Compress-Archive -LiteralPath "$stage\$Name" -DestinationPath "$d\$f" -Force
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath "$d\$f").Hash.ToLowerInvariant()
    [System.IO.File]::AppendAllText("$work\entries", "pack`t$Name`t$Version`t$Min`t$Tag`tdigest`t$About`nfile`t$Name`t$Version`twindows`t$f`t$h`n")
    Publish-Index $Tag -Key $Key
}

# Packs release $Tag, the newest, with an index of every version so far.
function Publish-Index {
    param([string]$Tag, [string]$Key = "$work/release.key")
    $d = "$www\releases\download\$Tag"
    [void](New-Item -ItemType Directory -Force -Path $d, "$www\api\releases")
    [System.IO.File]::WriteAllText("$d\packs.index", "format`t1`nrelease`t$Tag`n" + (Get-Text "$work\entries"))
    $b = $d.Replace('\', '/')
    Invoke-Openssl "dgst -sha256 -sign '$($Key.Replace('\', '/'))' -out '$b/packs.index.sig' '$b/packs.index'"
    [System.IO.File]::WriteAllText("$www\api\releases\all", "[{`"tag_name`": `"$Tag`"}, {`"tag_name`": `"v0.3.0`"}]`n")
}

function Join-Lines { param([string]$Text) ($Text.Split("`n") | ForEach-Object { $_.TrimEnd() }) -join '|' }

function Get-JobState { param([string]$Job) foreach ($l in (Invoke-Vigil pack list).Text.Split("`n")) { if ($l.Trim() -cmatch "^$Job +(\S+)$") { return $Matches[1] } } }

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
    [System.IO.File]::WriteAllText("$work\entries", '')
    [System.IO.File]::WriteAllText("$root\app\VERSION", "0.3.0`n")
    $kw = $work.Replace('\', '/')
    Invoke-Openssl "genrsa -out '$kw/release.key' 2048"
    Invoke-Openssl "genrsa -out '$kw/other.key' 2048"
    Invoke-Openssl "rsa -in '$kw/release.key' -pubout -out '$kw/release.pem'"
    $env:VIGIL_TEST_RELEASE_KEY = "$work\release.pem"
    $mock = Start-Process -FilePath $python -ArgumentList @("`"$here\mock-files.py`"", "`"$work\mock`"") -PassThru -NoNewWindow -RedirectStandardError "$work\mock\stderr"
    for ($i = 0; $i -lt 600 -and -not (Test-Path -LiteralPath "$work\mock\port"); $i++) { Start-Sleep -Milliseconds 100 }
    $env:VIGIL_TEST_RELEASE_URL = "http://127.0.0.1:$([System.IO.File]::ReadAllText("$work\mock\port").Trim())"

    [void](Invoke-Vigil init --instance pk --backend file --no-pack)
    [System.IO.File]::WriteAllText("$root\scripts\mine.ps1", "Write-Output 'metric mine 1'`n")
    [System.IO.File]::AppendAllText($cfg, "`n[job.mine]`nfile = scripts/mine.ps1`nrun_every = 1h`n")
    $mine = Get-Text "$root\scripts\mine.ps1"

    # As the installer leaves them.
    New-TestPack "$root\packs\base" '1.0.0' @('cpu', 'disk')

    Write-Host 'Turning on'
    Test-Equal 'listed, off' 'off' (Get-JobState 'base_cpu')
    # The file is held open across the change: replaced, it still reads as it
    # was; written over, it would read as the new one (46).
    $old = [System.IO.File]::ReadAllText($cfg)
    $held = New-Object System.IO.FileStream -ArgumentList $cfg, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read), ([System.IO.FileShare]'ReadWrite, Delete')
    $r = Invoke-Vigil pack enable base
    $reader = New-Object System.IO.StreamReader -ArgumentList $held
    $was = $reader.ReadToEnd()
    $reader.Dispose()
    Test-Equal 'enables' '0' ([string]$r.Code)
    Test-Equal 'replaced, not written over: the old file is as it was' $old $was
    Test-Equal 'says what' "on: base_cpu`non: base_disk" $r.Text
    Test-Equal 'the jobs are in the configuration' '2' (Get-Count '^\[job\.base_')
    Test-Equal 'precheck is happy' '0' (Invoke-Precheck)
    Test-Equal 'a job runs' '0' ([string](Invoke-Vigil run base_cpu).Code)
    Test-Equal 'listed, on' 'on' (Get-JobState 'base_cpu')
    Test-Equal 'enabling twice changes nothing, and a pack that needs nothing says no more' 'base is already on' (Invoke-Vigil pack enable base).Text
    Test-Equal 'an unknown name is refused' 'vigil: no pack or job called nosuch: vigil pack list' (Invoke-Vigil pack enable nosuch).Text
    Test-Equal 'an unknown job is refused' 'vigil: no job called base_nosuch: vigil pack list' (Invoke-Vigil pack enable base_nosuch).Text
    Test-Equal 'a bad name is refused' 'vigil: not a pack or job name: ../x' (Invoke-Vigil pack enable '../x').Text

    # A pack whose pack.config is here but whose scripts are not, as nginx on
    # Windows: nothing to turn on, not "already on" (46).
    [void](New-Item -ItemType Directory -Force -Path "$root\packs\elsewhere")
    [System.IO.File]::WriteAllText("$root\packs\elsewhere\pack.config", "[pack]`nversion = 1.0.0`nvigil = 0.0.1`ndescription = Elsewhere only`n`n[job.x]`nmetric_name = it.x`nmetrics = up`nrun_every = 1h`n")
    $sum = (Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash
    $r = Invoke-Vigil pack enable elsewhere
    Test-Equal 'a pack with no scripts here is refused' '1' ([string]$r.Code)
    Test-Equal 'saying so, not "already on"' 'vigil: pack elsewhere has no scripts for Windows' $r.Text
    Test-Equal 'and the configuration is unchanged' $sum (Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash
    $list = @((Invoke-Vigil pack list).Text.Split("`n"))
    $at = [array]::IndexOf($list, 'elsewhere 1.0.0: Elsewhere only')
    Test-Equal 'listed as not available here' '  not available here: no scripts for Windows' $(if ($at -ge 0) { $list[$at + 1] } else { '' })
    Remove-Item -Recurse -Force -LiteralPath "$root\packs\elsewhere"

    Write-Host 'Updating'
    Publish-Pack 'packs-2026.01.01' base '1.0.0' @('cpu', 'disk')
    Test-Equal 'nothing to do' 'pack base 1.0.0 is here: nothing to do' (Invoke-Vigil pack update).Text
    $t = Get-Text $cfg
    $at = $t.IndexOf('[job.base_cpu]')
    $t = $t.Substring(0, $at) + ([regex]'run_every = 1h').Replace($t.Substring($at), 'run_every = 5m', 1)
    [System.IO.File]::WriteAllText($cfg, $t)
    Publish-Pack 'packs-2026.01.02' base '1.1.0' @('cpu', 'load')
    Publish-Pack 'packs-2026.01.02' web '1.0.0' @('status') -About 'A web server'
    Test-Equal 'the check says so' 'pack base 1.0.0 is here; 1.1.0 is available: vigil pack update' (Invoke-Vigil pack update --check).Text
    Test-Equal 'the check changes nothing' '1.0.0' (Get-PackVersion)
    $was = Get-Text $cfg
    $r = Invoke-Vigil pack update
    Test-Equal 'updates' '0' ([string]$r.Code)
    Test-Equal 'to the new version' '1.1.0' (Get-PackVersion)
    Test-Equal 'installs nothing it was not asked for' 'False' ([string](Test-Path -LiteralPath "$root\packs\web"))
    Test-Equal 'the configuration is not touched' $was (Get-Text $cfg)
    Test-Equal 'a job on runs the new script' 'True' ([string](Get-Text "$root\packs\base\cpu.ps1").Contains('1.1.0'))
    Test-Equal 'says what changed' 'True' ([string]($r.Text -cmatch '(?m)^changed: base_cpu'))
    Test-Equal 'says what is new' 'True' ([string]($r.Text -cmatch '(?m)^new, not running: base_load\. To turn it on: vigil pack enable base_load\s*$'))
    Test-Equal 'a new script stays off' '0' (Get-Count '^\[job\.base_load\]')
    Test-Equal 'but is there' 'True' ([string](Test-Path -LiteralPath "$root\packs\base\load.ps1"))
    Test-Equal 'says what was dropped' 'True' ([string]($r.Text -cmatch '(?m)^dropped from the pack, still running: base_disk'))
    Test-Equal 'a dropped script stays while a job uses it' 'True' ([string](Test-Path -LiteralPath "$root\packs\base\disk.ps1"))
    Test-Equal 'and the job still runs' '0' ([string](Invoke-Vigil run base_disk).Code)
    Test-Equal 'precheck is still happy' '0' (Invoke-Precheck)
    Test-Equal 'your own script is untouched' $mine (Get-Text "$root\scripts\mine.ps1")
    Test-Equal 'the index is kept for searching' 'True' ([string](Test-Path -LiteralPath "$root\packs\.index"))

    Write-Host 'On and off'
    Test-Equal 'a new script turns on' 'on: base_load' (Invoke-Vigil pack enable base_load).Text
    Test-Equal 'an edit is kept' 'True' ([string]((Get-Text $cfg) -cmatch '(?s)\[job\.base_cpu\].*?run_every = 5m'))
    Test-Equal 'one job turns off' 'off: base_disk' (Invoke-Vigil pack disable base_disk).Text
    Test-Equal 'it leaves the configuration' '0' (Get-Count 'base_disk|packs/base/disk')
    Test-Equal 'turning off twice changes nothing' 'base_disk is already off' (Invoke-Vigil pack disable base_disk).Text
    Test-Equal 'precheck is happy with that' '0' (Invoke-Precheck)
    Publish-Pack 'packs-2026.01.03' base '1.2.0' @('cpu', 'load')
    [void](Invoke-Vigil pack update)
    Test-Equal 'a dropped script goes once no job uses it' 'False' ([string](Test-Path -LiteralPath "$root\packs\base\disk.ps1"))

    Write-Host 'Searching'
    $last = { param([string]$Text) @($Text.Split("`n"))[-1] }
    Test-Equal 'by a word, as a table' 'Packs in packs-2026.01.03:||Name Version Here About|---- ------- ---- -----|web  1.0.0        A web server' (Join-Lines (Invoke-Vigil pack search web).Text)
    Test-Equal 'every word, in any case' 'web  1.0.0        A web server' (& $last (Invoke-Vigil pack search SERVER a).Text)
    Test-Equal 'all, with none' 'base 1.2.0   installed For the test|web  1.0.0             A web server' ((@((Invoke-Vigil pack search).Text.Split("`n")) | Select-Object -Last 2) -join '|')
    Test-Equal 'nothing found' 'no pack matches: nosuch' (Invoke-Vigil pack search nosuch).Text
    Test-Equal 'what is not installed' 'Packs in packs-2026.01.03 not installed here:||Name Version Here About|---- ------- ---- -----|web  1.0.0        A web server' (Join-Lines (Invoke-Vigil pack list --available).Text)
    Test-Equal 'one pack' 'Name       : web|About      : A web server|Here       : not installed: vigil pack install web|Platforms  : Windows||Version Platforms Needs Vigil Release|------- --------- ----------- -------|1.0.0   Windows   0.0.1       packs-2026.01.02' (Join-Lines (Invoke-Vigil pack info web).Text)
    Test-Equal 'an unknown one' 'vigil: no pack called nosuch: vigil pack search' (Invoke-Vigil pack info nosuch).Text
    # Released after the index here was saved: found, as search fetches the
    # newest index rather than read the saved one.
    Publish-Pack 'packs-2026.01.03.1' db '1.0.0' @('status') -About 'A database'
    [System.IO.File]::AppendAllText("$work\entries", "info`tdb`t1.0.0`tworks_with`tDB 1 or later`ninfo`tdb`t1.0.0`tprograms_windows`tdbcli`ninfo`tdb`t1.0.0`tsecret`tDB_PW`ninfo`tdb`t1.0.0`tneeds`ta role, as an administrator: CREATE ROLE it`ninfo`tdb`t1.0.0`tneeds`tits log on`ninfo`tdb`t1.0.0`tsetting`tDB_HOST=localhost`ninfo`tdb`t1.0.0`tsetting`tDB_PORT=1`ninfo`tdb`t1.0.0`tdocs`thttps://example.com/packs/README.md#db`n")
    # One with no scripts here, and what it needs on the platform it has.
    [System.IO.File]::AppendAllText("$work\entries", "pack`telsewhere`t1.0.0`t0.0.1`tpacks-2026.01.03.1`tdigest`tElsewhere only`nfile`telsewhere`t1.0.0`tlinux`tvigil-pack-elsewhere-1.0.0-linux.tar.gz`t$('0' * 64)`ninfo`telsewhere`t1.0.0`tprograms_linux`tthat`n")
    Publish-Index 'packs-2026.01.03.1'
    Test-Equal 'a pack released since the index here was saved' 'db   1.0.0        A database' (& $last (Invoke-Vigil pack search database).Text)
    Test-Equal 'and the new index is saved' 'True' ([string]((Get-Text "$root\packs\.index") -cmatch "(?m)^release`tpacks-2026\.01\.03\.1$"))
    # The newest release's index is the one saved here: not downloaded again
    # (backlog 65). Gone from the release, it still answers, and says nothing
    # of a repository it could not reach.
    $relIndex = "$www\releases\download\packs-2026.01.03.1\packs.index"
    Move-Item -LiteralPath $relIndex -Destination "$work\keep.rel.index"
    $o = @((Invoke-Vigil pack search database).Text.Split("`n"))
    Test-Equal 'the newest index, saved here, is not downloaded again' 'db   1.0.0        A database|' ($o[-1] + '|' + (@($o | Where-Object { $_ -clike 'vigil:*' }) -join ' '))
    Move-Item -LiteralPath "$work\keep.rel.index" -Destination $relIndex
    Test-Equal 'a pack with no scripts here' 'elsewhere 1.0.0   not for Windows Elsewhere only' (& $last (Invoke-Vigil pack search elsewhere).Text)
    $card = @((Invoke-Vigil pack info db).Text.Split("`n"))
    Test-Equal 'what a pack needs, from its info records' 'Name       : db|About      : A database|Here       : not installed: vigil pack install db|Platforms  : Windows|Works with : DB 1 or later|Programs   : dbcli|Secrets    : DB_PW|Needs      : a role, as an administrator:|             CREATE ROLE it|             its log on|Settings   : DB_HOST=localhost DB_PORT=1 (the env lines in vigil.config, once|             enabled)|Docs       : https://example.com/packs/README.md#db' (($card[0..($card.IndexOf('') - 1)]) -join '|')
    Test-Equal 'and on a platform it has no scripts for' 'Here       : not for Windows|Platforms  : Linux|Programs   : that (on Linux)|Secrets    : none' ((@((Invoke-Vigil pack info elsewhere).Text.Split("`n"))[2..5]) -join '|')
    $url = $env:VIGIL_TEST_RELEASE_URL
    $env:VIGIL_TEST_RELEASE_URL = 'http://127.0.0.1:9'
    $off = @((Invoke-Vigil pack search database).Text.Split("`n"))
    $saved = "$root\packs\.index"
    Move-Item -LiteralPath $saved -Destination "$work\keep.saved"
    $none = (Invoke-Vigil pack info db).Text
    Move-Item -LiteralPath "$work\keep.saved" -Destination $saved
    $env:VIGIL_TEST_RELEASE_URL = $url
    Test-Equal 'offline, from the index saved here' 'db   1.0.0        A database' $off[-1]
    Test-Equal 'saying so' 'vigil: cannot find the latest packs release on GitHub: no network, or its API refused (it allows 60 requests an hour); showing the index saved here, of packs-2026.01.03.1' (@($off | Where-Object { $_ -clike 'vigil:*' }) -join '|')
    Test-Equal 'offline, with none saved' 'vigil: cannot find the latest packs release on GitHub: no network, or its API refused (it allows 60 requests an hour)' $none

    Write-Host 'Installing'
    $was = Get-Text $cfg
    $r = Invoke-Vigil pack install web
    Test-Equal 'installs' '0' ([string]$r.Code)
    Test-Equal 'says what, and that it is off' 'installed pack web 1.0.0|off until enabled: web_status|To turn them all on: vigil pack enable web' (Join-Lines $r.Text)
    Test-Equal 'its scripts are here' 'True' ([string](Test-Path -LiteralPath "$root\packs\web\status.ps1"))
    Test-Equal 'the configuration is not touched' $was (Get-Text $cfg)
    Test-Equal 'twice: nothing to do' 'pack web 1.0.0 is here: nothing to do' (Invoke-Vigil pack install web).Text
    Test-Equal 'listed, off' 'off' (Get-JobState 'web_status')
    Test-Equal 'an unknown pack' 'vigil: no pack called nosuch: vigil pack search' (Invoke-Vigil pack install nosuch).Text
    Test-Equal 'an unknown version' 'vigil: pack web has no version 9.9.9: vigil pack info web' (Invoke-Vigil pack install web@9.9.9).Text
    Test-Equal 'a bad name' 'vigil: not a pack name: ../x' (Invoke-Vigil pack install ../x).Text
    Publish-Pack 'packs-2026.01.04' web '2.0.0' @('status') -Min '99.0.0' -About 'A web server'
    Test-Equal 'one too new for this Vigil: asked for, refused' 'vigil: pack web 2.0.0 needs Vigil 99.0.0 or later: vigil self update' (Invoke-Vigil pack install web@2.0.0).Text
    Test-Equal 'and update says so, keeping what runs here' 'pack web 1.0.0 is here: nothing to do|  web 2.0.0 needs Vigil 99.0.0 or later: vigil self update' (@((Invoke-Vigil pack update).Text.Split("`n") | Where-Object { $_ -cmatch 'web' } | ForEach-Object { $_.TrimEnd() }) -join '|')
    Test-Equal 'an older version, when asked' 'pack base went back from 1.2.0 to 1.1.0' @((Invoke-Vigil pack install base@1.1.0).Text.Split("`n"))[0].TrimEnd()
    # One pack by name: the others are left as they are.
    Test-Equal 'update by name: that pack only' 'pack web 1.0.0 is here: nothing to do|  web 2.0.0 needs Vigil 99.0.0 or later: vigil self update' (@((Invoke-Vigil pack update web).Text.Split("`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ }) -join '|')
    Test-Equal 'and the other pack is left behind' '1.1.0' (Get-PackVersion)
    Test-Equal 'the check, by name' 'pack base 1.1.0 is here; 1.2.0 is available: vigil pack update' (Invoke-Vigil pack update --check base).Text.TrimEnd()
    $r = Invoke-Vigil pack update nosuch
    Test-Equal 'a pack not installed, by name' 'vigil: pack nosuch is not installed: vigil pack install nosuch|1' "$($r.Text.TrimEnd())|$($r.Code)"
    $r = Invoke-Vigil pack update base@1.0.0
    Test-Equal 'a version, by name' 'vigil: pack update takes the newest version; for another: vigil pack install base@1.0.0|1' "$($r.Text.TrimEnd())|$($r.Code)"
    Test-Equal 'an option it does not know' '64' ([string](Invoke-Vigil pack update --all).Code)
    Test-Equal 'update takes it forward again' 'updated pack base 1.1.0 to 1.2.0' (@((Invoke-Vigil pack update base).Text.Split("`n") | Where-Object { $_.StartsWith('updated') }) -join '|').TrimEnd()
    $wc = "$root\packs\web\pack.config"
    [System.IO.File]::WriteAllText($wc, (Get-Text $wc).Replace('version = 1.0.0', 'version = 5.0.0'))
    Test-Equal 'never back a version on its own' 'pack web 5.0.0 is here: nothing to do' (@((Invoke-Vigil pack update).Text.Split("`n") | Where-Object { $_.StartsWith('pack web') }) -join '|').TrimEnd()
    [System.IO.File]::WriteAllText($wc, (Get-Text $wc).Replace('version = 5.0.0', 'version = 1.0.0'))

    Write-Host 'Removing'
    [void](Invoke-Vigil pack enable web)
    Test-Equal 'refused while on' 'vigil: pack web is in use by: web_status. Turn them off first: vigil pack disable web' (Invoke-Vigil pack remove web).Text
    Test-Equal 'and kept' 'True' ([string](Test-Path -LiteralPath "$root\packs\web\status.ps1"))
    [void](Invoke-Vigil pack disable web)
    Test-Equal 'removes once off' 'removed pack web 1.0.0' (Invoke-Vigil pack remove web).Text
    Test-Equal 'its scripts go' 'False' ([string](Test-Path -LiteralPath "$root\packs\web"))
    Test-Equal 'one not here' 'vigil: pack web is not installed: vigil pack list' (Invoke-Vigil pack remove web).Text
    Test-Equal 'precheck is happy after' '0' (Invoke-Precheck)

    Write-Host 'Offline'
    $usb = "$work\usb"
    Test-Equal 'downloads' 'downloaded web 1.0.0 for Windows: vigil-pack-web-1.0.0-windows.zip|with the signed index. There: vigil pack install <name> --from <this folder>' (Join-Lines (Invoke-Vigil pack download web --to $usb).Text)
    Test-Equal 'the index and its signature too' 'packs.index packs.index.sig vigil-pack-web-1.0.0-windows.zip' ((Get-ChildItem -LiteralPath $usb | Sort-Object Name | ForEach-Object { $_.Name }) -join ' ')
    Test-Equal 'any version, for another Vigil' 'downloaded web 2.0.0 for Windows: vigil-pack-web-2.0.0-windows.zip' @((Invoke-Vigil pack download web@2.0.0 --to $usb).Text.Split("`n"))[0].TrimEnd()
    Test-Equal 'a platform it has no scripts for' 'vigil: pack web has no scripts for Linux' (Invoke-Vigil pack download web --os linux --to $usb).Text
    Test-Equal 'not a platform' 'vigil: not a platform: beos (linux, macos or windows)' (Invoke-Vigil pack download web --os beos --to $usb).Text
    # Nothing to reach: only the folder.
    $url = $env:VIGIL_TEST_RELEASE_URL
    $env:VIGIL_TEST_RELEASE_URL = 'http://127.0.0.1:9'
    try {
        Test-Equal 'installs from the folder, with no network' 'installed pack web 1.0.0' @((Invoke-Vigil pack install web --from $usb).Text.Split("`n"))[0].TrimEnd()
        [void](Invoke-Vigil pack remove web)
        Test-Equal 'a pack not in the folder' "vigil: vigil-pack-base-1.2.0-windows.zip is not in ${usb}: vigil pack download base@1.2.0 there" (Invoke-Vigil pack install base@1.2.0 --from $usb).Text
        $z = "$usb\vigil-pack-web-1.0.0-windows.zip"
        Copy-Item -LiteralPath $z -Destination "$work\keep.zip"
        [System.IO.File]::AppendAllText($z, 'x')
        Test-Equal 'a tampered archive' 'vigil: vigil-pack-web-1.0.0-windows.zip does not match the pack index; nothing was changed' (Invoke-Vigil pack install web --from $usb).Text
        Copy-Item -LiteralPath "$work\keep.zip" -Destination $z -Force
        Copy-Item -LiteralPath "$usb\packs.index" -Destination "$work\keep.index"
        [System.IO.File]::AppendAllText("$usb\packs.index", "pack`tweb`t9.0.0`t0.0.1`tpacks-x`tdigest`tAdded`n")
        Test-Equal 'an index changed after signing' "vigil: the pack index of $usb is not signed by the Vigil release key; nothing was changed" (Invoke-Vigil pack install web --from $usb).Text
        Copy-Item -LiteralPath "$work\keep.index" -Destination "$usb\packs.index" -Force
        Test-Equal 'nothing was installed' 'False' ([string](Test-Path -LiteralPath "$root\packs\web"))
    }
    finally { $env:VIGIL_TEST_RELEASE_URL = $url }

    Write-Host 'Refused'
    $was = Get-Snapshot
    Publish-Pack 'packs-2026.02.01' base '1.3.0' @('cpu') -Key "$work/other.key"
    $r = Invoke-Vigil pack update
    Test-Equal 'a bad signature is refused' '1' ([string]$r.Code)
    Test-Equal 'saying so' 'vigil: the pack index of packs-2026.02.01 is not signed by the Vigil release key; nothing was changed' $r.Text
    Publish-Index 'packs-2026.02.02'
    $a = "$www\releases\download\packs-2026.02.01\vigil-pack-base-1.3.0-windows.zip"
    Copy-Item -LiteralPath $a -Destination "$work\keep.zip" -Force
    [System.IO.File]::AppendAllText($a, 'x')
    Test-Equal 'a tampered archive is refused' 'vigil: vigil-pack-base-1.3.0-windows.zip does not match the pack index; nothing was changed' (@((Invoke-Vigil pack update).Text.Split("`n") | Where-Object { $_.StartsWith('vigil:') }) -join '|')
    Copy-Item -LiteralPath "$work\keep.zip" -Destination $a -Force
    Publish-Index 'packs-2026.02.03'
    Remove-Item -LiteralPath "$www\releases\download\packs-2026.02.03\packs.index.sig"
    Test-Equal 'a missing signature is refused' 'vigil: cannot download packs.index.sig of packs-2026.02.03' (Invoke-Vigil pack update).Text
    Test-Equal 'and nothing changed' $was (Get-Snapshot)
    [System.IO.File]::WriteAllText("$www\api\releases\all", "[]`n")
    Test-Equal 'no packs release' 'vigil: cannot find the latest packs release on GitHub: no network, or its API refused (it allows 60 requests an hour)' (Invoke-Vigil pack update).Text
    Publish-Pack 'packs-2026.02.04' base '1.4.0' @('cpu') -Min '99.0.0'
    $r = Invoke-Vigil pack update
    Test-Equal 'takes the newest this Vigil runs' 'updated pack base 1.2.0 to 1.3.0' (@($r.Text.Split("`n") | Where-Object { $_.StartsWith('updated') }) -join '|').TrimEnd()
    Test-Equal 'and names the one it cannot' '  base 1.4.0 needs Vigil 99.0.0 or later: vigil self update' (@($r.Text.Split("`n") | Where-Object { $_ -cmatch 'needs Vigil' }) -join '|').TrimEnd()

    # A job Vigil cannot accept: the configuration goes back.
    New-TestPack "$work\bad" '1.7.0' @('extra') -Every 'soon'
    Copy-Item -LiteralPath "$work\bad\extra.ps1" -Destination "$root\packs\base"
    $extra = (Get-Text "$work\bad\pack.config")
    [System.IO.File]::AppendAllText("$root\packs\base\pack.config", $extra.Substring($extra.IndexOf('[job.')))
    $was = Get-Text $cfg
    $r = Invoke-Vigil pack enable base_extra
    Test-Equal 'a job that would not be valid is refused' '1' ([string]$r.Code)
    Test-Equal 'saying why' 'True' ([string]$r.Text.Contains('would not be valid'))
    Test-Equal 'and goes back' $was (Get-Text $cfg)

    Write-Host 'A configuration from a source'
    $keep = Get-Text $cfg
    [System.IO.File]::WriteAllText($cfg, "[vigil]`nconfig_source = remote`nconfig_file = vigil.config`n`n[source.remote]`ntype = local`npath = C:\Windows`n")
    Test-Equal 'is not edited' '1' ([string](Invoke-Vigil pack disable base).Code)
    [System.IO.File]::WriteAllText($cfg, $keep)

    Write-Host 'What a pack needs'
    $svc = "$root\packs\svc"
    [void](New-Item -ItemType Directory -Force -Path $svc)
    $m = "[pack]`nversion = 1.0.0`nvigil = 0.0.1`ndescription = A service`nneeds = a role: CREATE ROLE it`nneeds = its page on`n`n"
    foreach ($j in 'a', 'b') {
        $m += "[job.$j]`nmetric_name = svc.$j`nmetrics = up`nrun_every = 1h`nmax_runtime = 30s`nenv = SVC_HOST=localhost`nenv = SVC_PORT=1`nsecret = SVC_PASSWORD=secret:SVC_PW`n`n"
        [System.IO.File]::WriteAllText("$svc\$j.ps1", "Write-Output 'metric up 1'`n")
    }
    [System.IO.File]::WriteAllText("$svc\pack.config", $m)
    $r = Invoke-Vigil pack enable svc
    Test-Equal 'turns on, and says what it needs' 'on: svc_a|on: svc_b|needs secret:SVC_PW: not set: vigil secret set SVC_PW, as the account Vigil runs as (an elevated prompt for a system install)|needs a role: CREATE ROLE it|needs its page on|settings in vigil.config: SVC_HOST=localhost SVC_PORT=1' ($r.Text.Split("`n") -join '|')
    [void]('x' | & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root secret set SVC_PW --stdin 2>&1)
    Test-Equal 'a secret set' 'needs secret:SVC_PW: set' (@((Invoke-Vigil pack enable svc_a).Text.Split("`n") | Where-Object { $_.StartsWith('needs secret') }) -join '|')
    [System.IO.File]::WriteAllText($cfg, (Get-Text $cfg).Replace('secret = SVC_PASSWORD=secret:SVC_PW', 'secret = SVC_PASSWORD=env:SVC_ENV_PW'))
    Test-Equal 'a reference changed to env:' 'needs env:SVC_ENV_PW: from the environment Vigil runs in' (@((Invoke-Vigil pack enable svc).Text.Split("`n") | Where-Object { $_.StartsWith('needs env') }) -join '|')
    [System.IO.File]::WriteAllText($cfg, (Get-Text $cfg).Replace('secret = SVC_PASSWORD=env:SVC_ENV_PW', 'secret = SVC_PASSWORD=store:vault/svc#pw'))
    Test-Equal 'or to store:, not asked' 'needs store:vault/svc#pw: from a secret store: vigil precheck checks it' (@((Invoke-Vigil pack enable svc).Text.Split("`n") | Where-Object { $_.StartsWith('needs store') }) -join '|')
    $lines = @((Invoke-Vigil pack list).Text.Split("`n") | ForEach-Object { $_.Trim() -replace ' +', ' ' })
    $at = [array]::IndexOf($lines, ($lines | Where-Object { $_.StartsWith('svc ') } | Select-Object -First 1))
    Test-Equal 'listed under the pack' 'svc_b on|needs store:vault/svc#pw: from a secret store: vigil precheck checks it|needs a role: CREATE ROLE it|needs its page on|settings in vigil.config: SVC_HOST=localhost SVC_PORT=1' (($lines[($at + 2)..($lines.Count - 1)] | Where-Object { $_ }) -join '|')
    [void](Invoke-Vigil pack disable svc)
    Test-Equal 'and off again' '0' (Get-Count 'svc')
    Remove-Item -Recurse -Force -LiteralPath $svc

    Write-Host 'Turning off'
    Test-Equal 'a whole pack' 'off: base' (Invoke-Vigil pack disable base).Text
    Test-Equal 'the jobs go' '0' (Get-Count 'base')
    Test-Equal 'the scripts stay' 'True' ([string](Test-Path -LiteralPath "$root\packs\base\cpu.ps1"))
    Test-Equal 'your own job stays' '1' (Get-Count '^\[job\.mine\]')
    Test-Equal 'precheck is happy after' '0' (Invoke-Precheck)

    Write-Host 'Packs this account cannot read'
    $base = "$root\packs\base"
    $had = Get-PackVersion
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    [void](& icacls.exe $base /deny "${me}:(OI)(CI)(R)" 2>&1)
    try {
        $r = Invoke-Vigil pack update --check
        Test-Equal 'the check is refused' '1' ([string]$r.Code)
        Test-Equal 'saying why, not that the pack is missing' "vigil: cannot read $root\packs from this account: run this from an elevated prompt for a system install" $r.Text
        Test-Equal 'and so is the update' '1' ([string](Invoke-Vigil pack update).Code)
    }
    finally { [void](& icacls.exe $base /remove:d $me 2>&1) }
    Test-Equal 'nothing was changed' $had (Get-PackVersion)
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
