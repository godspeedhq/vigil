#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: sources and the fetcher (SPECIFICATION.md 6.8, 6.9,
    16.5) on Windows.
.DESCRIPTION
    Scripts come from a Git repository and an HTTPS file server
    (mock-files.py, plain http on this host), a local directory and, when an
    OpenSSH server is installed, an SFTP server run as this user. Each is
    fetched, verified and run from the cache; a remote configuration is
    fetched and followed; and whatever fails, the last valid configuration
    keeps running. The twin of fetch.sh.

    Needs git and Python; sshd for the sftp part.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
# Empty arguments reach native programs the same way on both editions.
$PSNativeCommandArgumentPassing = 'Legacy'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-fetch.$PID"
$shell = (Get-Process -Id $PID).Path
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Invoke-Vigil {
    param([string[]]$Arguments)
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root @Arguments 2>&1
    return @{ Code = $LASTEXITCODE; Output = @($out | ForEach-Object { "$_" }) }
}

# One supervisor tick, then wait (up to 60s) for the fetcher and sender it
# may have started.
function Invoke-Tick {
    [void](Invoke-Vigil @('supervise', '--once'))
    $locks = Join-Path $root 'state\locks'
    for ($i = 0; $i -lt 120; $i++) {
        if (-not (Get-ChildItem -LiteralPath $locks -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^vigil_(fetch|sender)\.' })) { return }
        Start-Sleep -Milliseconds 500
    }
}

# A fetch now, whatever is due, then a tick that loads what it activated.
function Invoke-Fetch {
    Remove-Item -LiteralPath (Join-Path $root 'state\fetch.next') -ErrorAction SilentlyContinue
    Invoke-Tick
    Invoke-Tick
}

function Get-Field {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($Path)) { if ($l -cmatch "^$Key +=( (.*))?$") { return $Matches[2] } }
    return ''
}
function Get-Revision { Get-Field (Join-Path $root 'state\config.active') 'revision' }
function Get-FetchStatus { Get-Field (Join-Path $root 'state\jobs\vigil_fetch.state') 'status' }
function Get-FetchReason { Get-Field (Join-Path $root 'state\jobs\vigil_fetch.state') 'reason' }
function Test-InFiles {
    param([string]$Dir, [string]$Text)
    if (-not (Test-Path -LiteralPath $Dir)) { return 'no' }
    foreach ($f in Get-ChildItem -LiteralPath $Dir -Recurse -File) {
        if ([System.IO.File]::ReadAllText($f.FullName).Contains($Text)) { return 'yes' }
    }
    return 'no'
}

# Runs a job now; returns its outcome and the metric line its script wrote.
function Invoke-Run {
    param([string]$Job)
    $r = Invoke-Vigil @('run', $Job)
    $line = ($r.Output -join ' ')
    $line = $line.Substring(0, [Math]::Max(0, $line.IndexOf(' in ')))
    $metric = ''
    $logs = Join-Path $root "logs\jobs\$Job"
    if (Test-Path -LiteralPath $logs) {
        $m = @(Get-ChildItem -LiteralPath $logs -Filter '*.log' | ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } | Where-Object { $_ -match ' out metric ' })
        if ($m.Count -gt 0) { $metric = $m[-1] -replace '^.* out ', '' }
    }
    return "$line|$metric"
}

function Invoke-Git {
    param([string[]]$Arguments)
    $out = & git -c user.name=vigil -c user.email=vigil@example.com @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "git $($Arguments -join ' '): $out" }
    return ($out | ForEach-Object { "$_" }) -join "`n"
}

# Commits everything in the work tree and publishes it to the mock.
function Publish-Work {
    param([string]$Message, [string]$Tag)
    $work = Join-Path $root 'work'
    [void](Invoke-Git @('-C', $work, 'add', '-A'))
    [void](Invoke-Git @('-C', $work, 'commit', '-q', '-m', $Message))
    if ($Tag) { [void](Invoke-Git @('-C', $work, 'tag', $Tag)) }
    Send-Work
}
function Send-Work {
    $work = Join-Path $root 'work'
    $bare = Join-Path $root 'mock\www\ops.git'
    [void](Invoke-Git @('-C', $work, 'push', '-q', '--tags', $bare, 'HEAD:main'))
    [void](Invoke-Git @("--git-dir=$bare", 'update-server-info'))
}

function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-Text {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"))
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
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { Write-Host 'needs git'; exit 1 }
foreach ($d in @('config', 'mock\www\files', 'work\checks', 'work\hosts', 'share')) { [void](New-Item -ItemType Directory -Force -Path (Join-Path $root $d)) }
$root = (Resolve-Path -LiteralPath $root).ProviderPath
$mock = $null
$sshd = $null

try {
    $mock = Start-Process -FilePath $python -ArgumentList @("`"$here\mock-files.py`"", "`"$root\mock`"") -PassThru -NoNewWindow -RedirectStandardError "$root\mock\stderr"
    $portFile = Join-Path $root 'mock\port'
    for ($i = 0; $i -lt 600 -and -not (Test-Path -LiteralPath $portFile); $i++) { Start-Sleep -Milliseconds 100 }
    $port = if (Test-Path -LiteralPath $portFile) { [System.IO.File]::ReadAllText($portFile).Trim() } else { '' }
    Test-Equal 'mock started' 'True' ([string][bool]$port)
    if (-not $port) { Get-Content -LiteralPath "$root\mock\stderr"; throw 'the mock did not start' }
    $url = "http://127.0.0.1:$port"
    $work = Join-Path $root 'work'

    # The repository: a tag v1, served by Git's dumb HTTP protocol.
    [void](Invoke-Git @('-C', $work, 'init', '-q'))
    [void](Invoke-Git @('-C', $work, 'symbolic-ref', 'HEAD', 'refs/heads/main'))
    [void](Invoke-Git @('-C', $work, 'config', 'core.autocrlf', 'false'))
    Write-Text "$work\checks\hello.cmd" "@echo off`necho metric hello 1`n"
    [void](Invoke-Git @('-C', $work, 'add', '-A'))
    [void](Invoke-Git @('-C', $work, 'commit', '-q', '-m', 'one'))
    [void](Invoke-Git @('-C', $work, 'tag', 'v1'))
    [void](Invoke-Git @('clone', '-q', '--bare', $work, "$root\mock\www\ops.git"))
    [void](Invoke-Git @("--git-dir=$root\mock\www\ops.git", 'update-server-info'))

    # The file server, which wants a token, and the local directory.
    $token = "files-token-$PID"
    $env:VIGIL_IT_TOKEN = $token
    Write-Text "$root\mock\require" "/files/ X-Token: $token"
    Write-Text "$root\mock\www\files\single.cmd" "@echo off`necho metric single 2`n"
    Write-Text "$root\share\local.cmd" "@echo off`necho metric local 3`n"
    $singleSha = Get-Sha "$root\mock\www\files\single.cmd"
    $localSha = Get-Sha "$root\share\local.cmd"

    $base = "[vigil]`ninstance = fe`n`n[scheduler]`ntick = 1s`n`n[backend.file]`npath = metrics\vigil.prom`n`n"
    $localConfig = {
        param([string]$GitUrl, [string]$Ref)
        if (-not $GitUrl) { $GitUrl = "$url/ops.git" }
        if (-not $Ref) { $Ref = 'v1' }
        return $base + @"
[source.ops]
type = git
url  = $GitUrl
ref  = $Ref

[source.files]
type         = https
url          = $url/files/
header_name  = X-Token
header_value = env:VIGIL_IT_TOKEN

[source.share]
type        = local
path        = share
check_every = 1s

[job.from_git]
source    = ops
file      = checks/hello.cmd
run_every = 3650d

[job.from_https]
source    = files
file      = single.cmd
sha256    = $singleSha
run_every = 3650d

[job.from_local]
source    = share
file      = local.cmd
sha256    = $localSha
run_every = 3650d
"@
    }
    $cfg = Join-Path $root 'config\vigil.config'
    Write-Text $cfg (& $localConfig)

    # Before any fetch: precheck passes, and nothing runs.
    Test-Equal 'precheck before the first fetch' '0' ([string](Invoke-Vigil @('precheck')).Code)
    Invoke-Tick
    Test-Equal 'waiting for the first fetch' 'True' ([string]([System.IO.File]::ReadAllText("$root\logs\supervisor\jobs.log").Contains('waiting for the first fetch')))
    Invoke-Tick

    # Fetched, verified and activated.
    Test-Equal 'activated' 'True' ([string](Test-Path -LiteralPath "$root\state\config.active"))
    $rev1 = Get-Revision
    Test-Equal 'revision is 12 hex digits' 'True' ([string]($rev1 -cmatch '^[0-9a-f]{12}$'))
    Test-Equal 'jobs.log shows the revision' 'True' ([string]([System.IO.File]::ReadAllText("$root\logs\supervisor\jobs.log").Contains("revision $rev1 (local)")))
    $c1 = (Invoke-Git @("--git-dir=$root\mock\www\ops.git", 'rev-parse', 'v1')).Trim()
    Test-Equal 'git: unpacked at its commit' 'True' ([string](Test-Path -LiteralPath "$root\cache\ops\$c1\checks\hello.cmd"))
    Test-Equal 'git: run from the cache' 'from_git: succeeded|metric hello 1' (Invoke-Run 'from_git')
    Test-Equal 'https: run from the cache' 'from_https: succeeded|metric single 2' (Invoke-Run 'from_https')
    Test-Equal 'https: the header was sent' 'True' ([string]([System.IO.File]::ReadAllText("$root\mock\requests.log").Contains("`"X-Token`": `"$token`"")))
    Test-Equal 'local: run from the cache' 'from_local: succeeded|metric local 3' (Invoke-Run 'from_local')
    Test-Equal 'precheck once fetched' '0' ([string](Invoke-Vigil @('precheck')).Code)

    # A pinned script that changed in its source: the verified copy stays.
    Write-Text "$root\share\local.cmd" "@echo off`necho metric local 30`n"
    Invoke-Fetch
    Test-Equal 'pinned: revision unchanged' $rev1 (Get-Revision)
    Test-Equal 'pinned: the verified copy runs' 'from_local: succeeded|metric local 3' (Invoke-Run 'from_local')
    Test-Equal 'pinned: the change is logged' 'yes' (Test-InFiles "$root\logs\jobs\vigil_fetch" 'local.cmd no longer matches its sha256')
    Write-Text "$root\share\local.cmd" "@echo off`necho metric local 3`n"

    # A new tag: the new version is fetched and runs.
    Write-Text "$work\checks\hello.cmd" "@echo off`necho metric hello 2`n"
    Publish-Work 'two' 'v2'
    Write-Text $cfg (& $localConfig "$url/ops.git" 'v2')
    Invoke-Fetch
    $rev2 = Get-Revision
    Test-Equal 'new tag: new revision' 'True' ([string]($rev2 -and $rev2 -cne $rev1))
    Test-Equal 'new tag: new version runs' 'from_git: succeeded|metric hello 2' (Invoke-Run 'from_git')

    # A digest mismatch rejects the candidate; the last valid one keeps running.
    Write-Text $cfg ((& $localConfig "$url/ops.git" 'v2') + "`n[job.bad]`nsource    = files`nfile      = single.cmd`nsha256    = $('0' * 64)`nrun_every = 3650d`n")
    Invoke-Fetch
    Test-Equal 'mismatch: fetch failed' 'failed' (Get-FetchStatus)
    Test-Equal 'mismatch: reason' 'True' ([string]((Get-FetchReason).Contains('source.files: single.cmd does not match its sha256')))
    Test-Equal 'mismatch: revision unchanged' $rev2 (Get-Revision)
    Test-Equal 'mismatch: jobs.log says so' 'True' ([string]([System.IO.File]::ReadAllText("$root\logs\supervisor\jobs.log").Contains('last fetch failed')))
    Test-Equal 'mismatch: the active configuration runs' 'from_git: succeeded|metric hello 2' (Invoke-Run 'from_git')
    Invoke-Tick
    $prom = [System.IO.File]::ReadAllText("$root\metrics\vigil.prom")
    Test-Equal 'mismatch: failure counted' 'True' ([string]($prom -cmatch '(?m)^vigil_source_failures_total\{.*(reason="digest".*source="files"|source="files".*reason="digest")'))
    Test-Equal 'metrics: the active revision' 'True' ([string]($prom -cmatch "(?m)^vigil_config_info\{.*revision=`"$rev2`""))
    Test-Equal 'metrics: activations counted' 'True' ([string]($prom -cmatch '(?m)^vigil_config_activated_total\{'))
    Test-Equal 'metrics: check age of each source' 'True' ([string]($prom -cmatch '(?m)^vigil_source_check_age\{.*source="ops"'))

    # An unreachable source: nothing changes.
    Write-Text $cfg (& $localConfig 'http://127.0.0.1:1/ops.git' 'v2')
    Invoke-Fetch
    Test-Equal 'unreachable: fetch failed' 'failed' (Get-FetchStatus)
    Test-Equal 'unreachable: revision unchanged' $rev2 (Get-Revision)
    Test-Equal 'unreachable: still runs' 'from_git: succeeded|metric hello 2' (Invoke-Run 'from_git')

    # A symbolic link out of the repository is refused.
    $blobFile = Join-Path $root 'link-target'
    Write-Text $blobFile '../../outside'
    $blob = (Invoke-Git @('-C', $work, 'hash-object', '-w', $blobFile)).Trim()
    [void](Invoke-Git @('-C', $work, 'update-index', '--add', '--cacheinfo', "120000,$blob,checks/escape"))
    [void](Invoke-Git @('-C', $work, 'commit', '-q', '-m', 'three'))
    [void](Invoke-Git @('-C', $work, 'tag', 'v3'))
    Send-Work
    Write-Text $cfg (& $localConfig "$url/ops.git" 'v3')
    Invoke-Fetch
    Test-Equal 'symlink: refused' 'True' ([string]((Get-FetchReason).Contains('symbolic link pointing outside')))
    Test-Equal 'symlink: revision unchanged' $rev2 (Get-Revision)
    [void](Invoke-Git @('-C', $work, 'rm', '-q', '--cached', 'checks/escape'))
    [void](Invoke-Git @('-C', $work, 'commit', '-q', '-m', 'unlink'))
    Write-Text $cfg (& $localConfig "$url/ops.git" 'v2')
    Invoke-Fetch
    Test-Equal 'back to v2' $rev2 (Get-Revision)

    # The cache deleted: FILE MISSING until it is fetched again.
    Remove-Item -Recurse -Force -LiteralPath "$root\cache"
    Invoke-Tick
    Test-Equal 'cache deleted: FILE MISSING' 'True' ([string]([System.IO.File]::ReadAllText("$root\logs\supervisor\jobs.log").Contains('FILE MISSING')))
    Invoke-Fetch
    Test-Equal 'cache deleted: fetched again' 'from_git: succeeded|metric hello 2' (Invoke-Run 'from_git')

    # Remote configuration (6.8): a pointer file, following a branch.
    $h1 = $base + "[source.scripts]`ntype        = git`nurl         = $url/ops.git`nref         = main`ncheck_every = 1s`n`n" +
        "[job.remote_hello]`nsource    = scripts`nfile      = checks/hello.cmd`nrun_every = 3650d`n"
    Write-Text "$work\hosts\h1.config" $h1
    Publish-Work 'four' ''
    Write-Text $cfg "[vigil]`nconfig_source = central`nconfig_file   = hosts/h1.config`n`n[source.central]`ntype        = git`nurl         = $url/ops.git`nref         = main`ncheck_every = 1s`n"
    Invoke-Fetch
    $rev3 = Get-Revision
    Test-Equal 'remote: activated' 'source.central hosts/h1.config' (Get-Field "$root\state\config.active" 'origin')
    Test-Equal 'remote: job runs' 'remote_hello: succeeded|metric hello 2' (Invoke-Run 'remote_hello')
    Test-Equal 'remote: precheck' '0' ([string](Invoke-Vigil @('precheck')).Code)
    Test-Equal 'remote: branch reported as unpinned' 'yes' (Test-InFiles "$root\logs\jobs\vigil_fetch" 'W_SCRIPT_UNPINNED')

    # A change on the branch is picked up at the next check.
    Write-Text "$work\checks\hello.cmd" "@echo off`necho metric hello 5`n"
    Publish-Work 'five' ''
    Start-Sleep -Seconds 2
    Invoke-Tick
    Invoke-Tick
    Test-Equal 'branch: new revision' 'True' ([string]((Get-Revision) -cne $rev3))
    Test-Equal 'branch: new version runs' 'remote_hello: succeeded|metric hello 5' (Invoke-Run 'remote_hello')
    $rev4 = Get-Revision

    # A fetched configuration may not say where configuration comes from.
    Write-Text "$work\hosts\h1.config" ($h1.Replace("[vigil]`ninstance = fe`n", "[vigil]`ninstance = fe`nstate_dir = elsewhere`n"))
    Publish-Work 'six' ''
    Invoke-Fetch
    Test-Equal 'not from source: rejected' 'failed' (Get-FetchStatus)
    Test-Equal 'not from source: reported' 'yes' (Test-InFiles "$root\logs\jobs\vigil_fetch" 'E_NOT_FROM_SOURCE')
    Test-Equal 'not from source: revision unchanged' $rev4 (Get-Revision)

    # sftp: an OpenSSH server run as this user, its host key known only
    # through VIGIL_TEST_SSH_CONFIG.
    $sshdExe = @("$env:SystemRoot\System32\OpenSSH\sshd.exe", "$env:ProgramFiles\OpenSSH\sshd.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $keygen = @(Get-Command ssh-keygen -CommandType Application -ErrorAction SilentlyContinue)[0]
    if (-not $sshdExe -or -not $keygen -or -not (Get-Command sftp -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host '  SKIP  sftp: no sshd here'
    }
    else {
        $s = Join-Path $root 'ssh'
        [void](New-Item -ItemType Directory -Force -Path $s, "$root\sftp")
        & $keygen.Source -q -t ed25519 -N '""' -f "$s\host" | Out-Null
        & $keygen.Source -q -t ed25519 -N '""' -f "$s\user" | Out-Null
        Copy-Item "$s\user.pub" "$s\authorized_keys"
        $sport = 20000 + $PID % 20000
        $fwd = $s.Replace('\', '/')
        Write-Text "$s\sshd_config" "Port $sport`nListenAddress 127.0.0.1`nHostKey $fwd/host`nAuthorizedKeysFile $fwd/authorized_keys`nPasswordAuthentication no`nStrictModes no`nPidFile $fwd/sshd.pid`nSubsystem sftp $((Split-Path -Parent $sshdExe).Replace('\', '/'))/sftp-server.exe`n"
        $sshd = Start-Process -FilePath $sshdExe -ArgumentList @('-D', '-e', '-f', "`"$s\sshd_config`"") -PassThru -NoNewWindow -RedirectStandardError "$s\sshd.log"
        $hostKey = ([System.IO.File]::ReadAllText("$s\host.pub").Split(' ')[0..1]) -join ' '
        Write-Text "$s\known_hosts" "[127.0.0.1]:$sport $hostKey`n"
        Write-Text "$s\config" "Host 127.0.0.1`n    IdentityFile $fwd/user`n    UserKnownHostsFile $fwd/known_hosts`n    IdentitiesOnly yes`n"
        $env:VIGIL_TEST_SSH_CONFIG = "$s\config"
        Write-Text "$root\sftp\remote.cmd" "@echo off`necho metric sftp 4`n"
        $sftpSha = Get-Sha "$root\sftp\remote.cmd"
        Start-Sleep -Seconds 1
        Write-Text $cfg ($base + "[source.box]`ntype = sftp`nhost = 127.0.0.1`nport = $sport`nuser = $env:USERNAME`npath = /$($root.Replace('\', '/'))/sftp`n`n" +
            "[job.from_sftp]`nsource    = box`nfile      = remote.cmd`nsha256    = $sftpSha`nrun_every = 3650d`n")
        Invoke-Fetch
        Test-Equal 'sftp: activated' 'succeeded' (Get-FetchStatus)
        Test-Equal 'sftp: run from the cache' 'from_sftp: succeeded|metric sftp 4' (Invoke-Run 'from_sftp')
        # An unknown host key is never trusted.
        Write-Text "$s\known_hosts" ''
        Remove-Item -Recurse -Force -LiteralPath "$root\cache\box"
        Invoke-Fetch
        Test-Equal 'sftp: unknown host key refused' 'failed' (Get-FetchStatus)
        if ($script:fail -gt 0) { Get-Content -LiteralPath "$s\sshd.log" -ErrorAction SilentlyContinue }
        Remove-Item Env:\VIGIL_TEST_SSH_CONFIG
    }

    if ($script:fail -gt 0) {
        Write-Host "`nfetch log:"
        Get-ChildItem -LiteralPath "$root\logs\jobs\vigil_fetch" -Filter '*.log' -ErrorAction SilentlyContinue |
            ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } | Select-Object -Last 40
        Write-Host "`njobs.log:"
        Get-Content -LiteralPath "$root\logs\supervisor\jobs.log" -ErrorAction SilentlyContinue
    }
}
finally {
    foreach ($p in @($mock, $sshd)) { if ($p) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } } }
    Remove-Item Env:\VIGIL_IT_TOKEN -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
