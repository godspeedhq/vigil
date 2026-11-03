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
    run-source.ps1 - tests Vigil's sources against a test server, on
    Windows. The twin of run-source.sh, which describes the checks.
.DESCRIPTION
        .\scripts\run-source.ps1 git-gitea    (or https-nginx, sftp-openssh, local)

    Needs .sources\ and .secrets\tls\ca.pem from the Docker host, copied to
    the same paths here, and the server's ports answering on 127.0.0.1 (SSH
    tunnels; see README.md). git-gitea needs Git for Windows; sftp-openssh
    the OpenSSH client (built into Windows 10 1809 and later).

    Trust, as an operator would give it:
      git    http.sslCAInfo in a Git configuration of the test's own
             (GIT_CONFIG_GLOBAL), with the OpenSSL backend
      https  Vigil's https source uses Windows' own certificate store, and
             Windows adds a root certificate only interactively. Without the
             test CA in this account's store, the https checks are reported
             NOT RUN, with why; plain http to this host is tested anyway.
      sftp   the key and known_hosts through Vigil's VIGIL_TEST_SSH_CONFIG

    Results: PASS, FAIL, NOT RUN, NOT SUPPORTED. The server-restart checks
    are run-source.sh's, on the Docker host. Exit code: 0 when every check
    that ran passed.
#>

param([Parameter(Mandatory = $true)][string]$Target)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bk = Split-Path -Parent $here
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $bk))
$shell = (Get-Process -Id $PID).Path

if (@('git-gitea', 'https-nginx', 'sftp-openssh', 'local') -cnotcontains $Target) { Write-Output 'usage: run-source.ps1 git-gitea|https-nginx|sftp-openssh|local'; exit 1 }
$src = Join-Path $bk '.sources'
$ca = Join-Path $bk '.secrets\tls\ca.pem'
$fx = Join-Path $bk 'fixtures\sources'
$o = @{}
if ($Target -cne 'local') {
    $envFile = Join-Path $src "$($Target.Substring($Target.IndexOf('-') + 1)).env"
    if (-not (Test-Path -LiteralPath $envFile) -or -not (Test-Path -LiteralPath $ca)) {
        Write-Output "no $envFile or .secrets\tls\ca.pem: copy them from the Docker host that ran scripts/start.sh $Target"
        exit 1
    }
    foreach ($l in [System.IO.File]::ReadAllLines($envFile)) { if ($l -cmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $o[$Matches[1]] = $Matches[2] } }
}
$sha = { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-source.$PID"
$root = Join-Path $work 'root'
$out = Join-Path $work 'vigil.out'
$script:pass = 0; $script:fail = 0; $script:notRun = 0
function Write-Pass { param([string]$Text) Write-Output "  PASS  $Text"; $script:pass++ }
function Write-Fail { param([string]$Text) Write-Output "  FAIL  $Text"; $script:fail++ }
function Write-NotRun { param([string]$Text) Write-Output "  NOT RUN  $Text"; $script:notRun++ }
function Test-Equal { param([string]$Name, [string]$Expected, [string]$Actual) if ($Expected -ceq $Actual) { Write-Pass $Name } else { Write-Fail "${Name}: expected [$Expected], got [$Actual]" } }
function Test-Contains { param([string]$Name, [string]$Part, [string]$Actual) if ($Actual.Contains($Part)) { Write-Pass "${Name}: $Actual" } else { Write-Fail "${Name}: expected [$Part] in [$Actual]" } }

function Invoke-Vigil {
    $r = @(& $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root @args 2>&1 | ForEach-Object { "$_" })
    $r | Add-Content -LiteralPath $out
    return , $r
}
# One supervisor tick, then wait (up to 60 s) for the fetcher it started.
function Invoke-Tick {
    [void](Invoke-Vigil supervise --once)
    $locks = Join-Path $root 'state\locks'
    for ($i = 0; $i -lt 120; $i++) {
        if (-not (Get-ChildItem -LiteralPath $locks -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^vigil_fetch\.' })) { return }
        Start-Sleep -Milliseconds 500
    }
}
# A fetch now, whatever is due, then a tick that loads what it activated.
function Invoke-Fetch { Remove-Item -LiteralPath (Join-Path $root 'state\fetch.next') -ErrorAction SilentlyContinue; Invoke-Tick; Invoke-Tick }
function Get-Field {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($Path)) { if ($l -cmatch "^$Key +=( (.*))?$") { return $Matches[2] } }
    return ''
}
function Get-Revision { Get-Field (Join-Path $root 'state\config.active') 'revision' }
function Get-FetchStatus { Get-Field (Join-Path $root 'state\jobs\vigil_fetch.state') 'status' }
function Get-FetchReason { Get-Field (Join-Path $root 'state\jobs\vigil_fetch.state') 'reason' }
function Get-FetchLog { (Get-ChildItem -LiteralPath (Join-Path $root 'logs\jobs\vigil_fetch') -Filter '*.log' -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n" }
# $Part when the fetcher's log holds it, empty otherwise: short for a result.
function Find-InFetchLog { param([string]$Part) if ((Get-FetchLog).Contains($Part)) { $Part } else { '' } }
# Runs job $Job now; the metric line its script wrote, or what went wrong.
function Invoke-Run {
    param([string]$Job)
    $r = Invoke-Vigil run $Job
    $logs = Join-Path $root "logs\jobs\$Job"
    if (Test-Path -LiteralPath $logs) {
        $m = @(Get-ChildItem -LiteralPath $logs -Filter '*.log' | ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } | Where-Object { $_ -match ' out metric ' })
        if ($m.Count -gt 0) { return ($m[-1] -replace '^.* out metric ', '') }
    }
    $t = $r -join ' '
    if ($t.IndexOf(' in ') -gt 0) { $t = $t.Substring(0, $t.IndexOf(' in ')) }
    return $t
}
# The SHA-256 of the cached copy the activation record names for $File.
function Get-CachedSha {
    param([string]$File)
    $p = Join-Path $root 'state\config.active'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($p)) {
        $w = $l -split '\s+'
        if ($w.Count -ge 6 -and $w[0] -ceq 'script' -and $w[5] -ceq $File) {
            $f = Join-Path $root "cache\$($w[2])\$($w[3])\$($File.Replace('/', '\'))"
            if (Test-Path -LiteralPath $f) { return & $sha $f }
        }
    }
    return ''
}

$base = "[vigil]`ninstance = source-test`n`n[scheduler]`ntick = 1s`n`n[backend.file]`npath = metrics\vigil.prom`n`n" +
    "[runner.ps]`ncommand = powershell.exe`narg = -NoProfile`narg = -NonInteractive`narg = -ExecutionPolicy`narg = Bypass`narg = -File`n`n[runners]`n.ps1 = ps`n`n"
function Set-Config { param([string]$Text) [System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'), $Text) }
# A local configuration: source $Name of type $Type with $Lines, and job
# check running $File, pinned by $Sha unless '-'.
function Set-ScriptsConfig {
    param([string]$Type, [string]$Lines, [string]$File, [string]$Sha = '-', [string]$Name = 'repo', [string]$Extra = '')
    $c = "$base[source.$Name]`ntype        = $Type`n$Lines`ncheck_every = 1s`n$Extra`n[job.check]`nsource    = $Name`nfile      = $File`n"
    if ($Sha -cne '-') { $c += "sha256    = $Sha`n" }
    Set-Config "${c}run_every = 3650d`n"
}
$script:rev = ''
# The checks of a failure: it fails, says why, and the last good
# configuration keeps running.
function Test-Failure {
    param([string]$Name, [string]$Why, [string]$Job = 'check', [string]$Runs = 'source_check 1')
    Invoke-Fetch
    Test-Equal "${Name}: the fetch fails" 'failed' (Get-FetchStatus)
    Test-Contains "${Name}: says why" $Why (Get-FetchReason)
    Test-Equal "${Name}: the last good configuration stays active" $script:rev (Get-Revision)
    Test-Equal "${Name}: and its job still runs" $Runs (Invoke-Run $Job)
}
# Remote mode: a pointer to $ConfigFile in source central ($Type, $Lines).
function Set-Pointer {
    param([string]$Type, [string]$Lines, [string]$ConfigFile = 'windows.config')
    Set-Config "[vigil]`nconfig_source = central`nconfig_file   = $ConfigFile`n`n[source.central]`ntype        = $Type`n$Lines`ncheck_every = 1s`n"
}
# Remote mode: v1 activated, broken refused, v2 activated; $Ref gives the
# lines for a version.
function Test-RemoteMode {
    param([string]$Type, [scriptblock]$Ref, [string]$ConfigFile = 'windows.config')
    Write-Output "`n$Target, the configuration from the server (remote mode)"
    Set-Pointer $Type (& $Ref 'v1') $ConfigFile
    Invoke-Fetch
    Test-Equal 'v1: activated' 'succeeded' (Get-FetchStatus)
    Test-Equal 'v1: its job runs version 1' 'source_check 1' (Invoke-Run 'remote_check')
    $script:rev = Get-Revision
    Set-Pointer $Type (& $Ref 'broken') $ConfigFile
    Invoke-Fetch
    Test-Equal 'a configuration invalid outside any job: refused' 'failed' (Get-FetchStatus)
    Test-Equal 'invalid outside any job: the last good one stays active' $script:rev (Get-Revision)
    Test-Equal 'invalid outside any job: and its job still runs version 1' 'source_check 1' (Invoke-Run 'remote_check')
    Set-Pointer $Type (& $Ref 'v2') $ConfigFile
    Invoke-Fetch
    Test-Equal 'v2: the update is activated' 'source_check 2' (Invoke-Run 'remote_check')
}

$v1 = & $sha (Join-Path $fx 'scripts\check-v1.ps1')
$v2 = & $sha (Join-Path $fx 'scripts\check-v2.ps1')
$leaks = @()
try {
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'config'))
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app'), (Join-Path $repo 'vendor') -Destination $root

    switch ($Target) {
        'git-gitea' {
            # Git trusts the test CA and logs in as the reader through a
            # configuration of the test's own.
            $creds = Join-Path $work 'creds'
            $gc = Join-Path $work 'gitconfig'
            [System.IO.File]::WriteAllText($gc, "[http]`n`tsslBackend = openssl`n`tsslCAInfo = $($ca.Replace('\', '/'))`n[credential]`n`thelper = store --file=$($creds.Replace('\', '/'))`n")
            $env:GIT_CONFIG_GLOBAL = $gc
            $setCreds = { param([string]$User, [string]$Pw) [System.IO.File]::WriteAllText($creds, "https://${User}:$Pw@127.0.0.1%3a3443`n") }
            & $setCreds $o['SRC_READER'] $o['SRC_READER_PW']
            $h = $o['SRC_HTTPS']

            Write-Output "`n$Target, git over HTTPS"
            Set-ScriptsConfig git "url  = $h`nref  = v1" 'checks/check.ps1'
            Invoke-Fetch
            Test-Equal 'tag v1: fetched and activated' 'succeeded' (Get-FetchStatus)
            Test-Equal 'tag v1: the job runs version 1' 'source_check 1' (Invoke-Run 'check')
            Test-Equal 'tag v1: the cached file is the fixture' $v1 (Get-CachedSha 'checks/check.ps1')
            Set-ScriptsConfig git "url  = $h`nref  = $($o['SRC_V2'])" 'checks/check.ps1'
            Invoke-Fetch
            Test-Equal 'a commit id (v2): the job runs version 2' 'source_check 2' (Invoke-Run 'check')
            Test-Equal 'a commit id (v2): the cached file is the fixture' $v2 (Get-CachedSha 'checks/check.ps1')
            Set-ScriptsConfig git "url  = $h`nref  = test" 'checks/check.ps1'
            Invoke-Fetch
            Test-Equal 'branch test: the job runs version 1' 'source_check 1' (Invoke-Run 'check')
            Test-Contains 'branch test: reported unpinned' 'W_SCRIPT_UNPINNED' (Find-InFetchLog 'W_SCRIPT_UNPINNED')

            Set-ScriptsConfig git "url  = $h`nref  = v1" 'checks/check.ps1'
            Invoke-Fetch
            $script:rev = Get-Revision
            Set-ScriptsConfig git "url  = $h`nref  = nosuch" 'checks/check.ps1'
            Test-Failure 'a missing ref' "ref 'nosuch' not found"
            Set-ScriptsConfig git "url  = $h`nref  = v1" 'checks/nosuch.ps1'
            Test-Failure 'a missing file' 'nosuch.ps1'
            Set-ScriptsConfig git "url  = https://127.0.0.1:3443/vigil-admin/no-such-repo.git`nref  = v1" 'checks/check.ps1'
            Test-Failure 'a missing repository' 'git fetch failed'
            Set-ScriptsConfig git "url  = $h`nref  = link" 'checks/check.ps1'
            Test-Failure 'a symbolic link out of the tree' 'symbolic link pointing outside'
            & $setCreds $o['SRC_READER'] 'wrong-password'
            Set-ScriptsConfig git "url  = $h`nref  = v2" 'checks/check.ps1'
            Test-Failure 'a wrong password' 'git fetch failed'
            & $setCreds $o['SRC_READER'] $o['SRC_READER_PW']

            Write-Output "`n$Target, git over SSH"
            $ssh = (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe').Replace('\', '/')
            $sshWith = { param([string]$Key, [string]$Known) $env:GIT_SSH_COMMAND = "'$ssh' -i '$($Key.Replace('\', '/'))' -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile='$($Known.Replace('\', '/'))'" }
            & $sshWith (Join-Path $src 'ssh\vigil_sources') (Join-Path $src 'gitea_known_hosts')
            Set-ScriptsConfig git "url  = $($o['SRC_SSH'])`nref  = v1" 'checks/check.ps1'
            Invoke-Fetch
            Test-Equal 'deploy key, tag v1: fetched and activated' 'succeeded' (Get-FetchStatus)
            Test-Equal 'deploy key, tag v1: the job runs version 1' 'source_check 1' (Invoke-Run 'check')
            $script:rev = Get-Revision
            & $sshWith (Join-Path $src 'ssh\vigil_sources_wrong') (Join-Path $src 'gitea_known_hosts')
            Set-ScriptsConfig git "url  = $($o['SRC_SSH'])`nref  = v2" 'checks/check.ps1'
            Test-Failure 'a key the server does not know' 'git fetch failed'
            $empty = Join-Path $work 'empty_known_hosts'
            [System.IO.File]::WriteAllText($empty, '')
            & $sshWith (Join-Path $src 'ssh\vigil_sources') $empty
            Test-Failure 'a host key not in known_hosts' 'git fetch failed'
            Remove-Item Env:GIT_SSH_COMMAND

            Test-RemoteMode git { param($v) "url         = $h`nref         = $v" } 'hosts/windows.config'
            $leaks = @($o['SRC_READER_PW'], $o['SRC_ADMIN_PW'], ([System.IO.File]::ReadAllLines((Join-Path $src 'ssh\vigil_sources')))[1])
        }
        'https-nginx' {
            $u = $o['SRC_URL']
            Write-Output "`n$Target, plain http to this host (allowed)"
            Set-ScriptsConfig https "url = $($o['SRC_HTTP_URL'])/files/" 'check-v1.ps1' $v1 'plain'
            Invoke-Fetch
            Test-Equal 'plain http: fetched and activated' 'succeeded' (Get-FetchStatus)
            Test-Equal 'plain http: the job runs version 1' 'source_check 1' (Invoke-Run 'check')
            Test-Equal 'plain http: the cached file is the fixture' $v1 (Get-CachedSha 'check-v1.ps1')
            $script:rev = Get-Revision

            # Does this account's certificate store trust the test CA?
            $trusted = $true
            try { $r = [System.Net.WebRequest]::Create("$u/healthz"); $r.Timeout = 5000; $r.GetResponse().Close() }
            catch { $trusted = $false; $why = $_.Exception.InnerException.Message }
            if (-not $trusted) {
                Write-NotRun "https: the test CA is not in this account's certificate store ($why); see README.md"
                Set-ScriptsConfig https "url = $u/files/" 'check-v2.ps1' $v2 'untrusted'
                Test-Failure 'without the test CA trusted, a certificate check fails' 'trust'
            }
            else {
                Write-Output "`n$Target, scripts over HTTPS"
                Set-ScriptsConfig https "url = $u/files/" 'check-v1.ps1' $v1 'web'
                Invoke-Fetch
                Test-Equal 'a pinned script: the job runs version 1' 'source_check 1' (Invoke-Run 'check')
                Test-Equal 'a pinned script: the cached file is the fixture' $v1 (Get-CachedSha 'check-v1.ps1')
                $script:rev = Get-Revision
                $n = 0
                foreach ($f in @(
                        @("url = $u/files/", 'check-v2.ps1', $v1, 'a digest that does not match', 'does not match its sha256'),
                        @("url = $u/files/", 'corrupt.txt', $v1, 'corrupted content, never run', 'does not match its sha256'),
                        @("url = $u/files/", 'nosuch.ps1', $v1, 'HTTP 404', 'not found (HTTP 404)'),
                        @("url = $u/forbidden/", 'check-v1.ps1', $v1, 'HTTP 403', 'permission denied (HTTP 403)'),
                        @("url = $u/broken/", 'check-v1.ps1', $v1, 'HTTP 500', 'HTTP 500'),
                        @("url = $u/busy/", 'check-v1.ps1', $v1, 'HTTP 503', 'HTTP 503'),
                        @("url = $u/moved/", 'check-v1.ps1', $v1, 'a redirect (never followed)', 'HTTP 301'),
                        @("url = https://127.0.0.1:9444/files/", 'check-v1.ps1', $v1, 'a refused connection', 'cannot connect'),
                        @("url = $u/auth/", 'check-v2.ps1', $v2, 'no authentication header', 'permission denied (HTTP 401)'))) {
                    $n++
                    Set-ScriptsConfig https $f[0] $f[1] $f[2] "fail$n"
                    Test-Failure $f[3] $f[4]
                }
                $env:VIGIL_SRC_TOKEN = $o['SRC_TOKEN']
                Set-ScriptsConfig https "url = $u/auth/`nheader_name  = X-Vigil-Token`nheader_value = env:VIGIL_SRC_TOKEN" 'check-v1.ps1' $v1 'authok'
                Invoke-Fetch
                Test-Equal 'the right token: the job runs version 1' 'source_check 1' (Invoke-Run 'check')
                Test-RemoteMode https { param($v) "url         = $u/configs/$v/" }
            }
            $leaks = @($o['SRC_TOKEN'])
        }
        'sftp-openssh' {
            $cfg = Join-Path $work 'ssh_config'
            $sshConfig = { param([string]$Key, [string]$Known) [System.IO.File]::WriteAllText($cfg, "Host 127.0.0.1`n  IdentityFile `"$Key`"`n  IdentitiesOnly yes`n  UserKnownHostsFile `"$Known`"`n") }
            $env:VIGIL_TEST_SSH_CONFIG = $cfg
            & $sshConfig (Join-Path $src 'ssh\vigil_sources') (Join-Path $src 'sftp_known_hosts')
            $s = "host        = $($o['SRC_HOST'])`nport        = $($o['SRC_PORT'])`nuser        = $($o['SRC_USER'])"
            Write-Output "`n$Target, scripts over SFTP, with a key"
            Set-ScriptsConfig sftp "$s`npath        = /files`ntimeout     = 10s" 'check-v1.ps1' $v1 'files'
            Invoke-Fetch
            Test-Equal 'a pinned script: fetched and activated' 'succeeded' (Get-FetchStatus)
            Test-Equal 'a pinned script: the job runs version 1' 'source_check 1' (Invoke-Run 'check')
            Test-Equal 'a pinned script: the cached file is the fixture' $v1 (Get-CachedSha 'check-v1.ps1')
            Write-Output '  NOT SUPPORTED  password authentication: Vigil signs in to sftp with a key only (spec 6.9)'
            $script:rev = Get-Revision
            $n = 0
            foreach ($f in @(
                    @('/files', 'nosuch.ps1', $v1, 'a missing file', 'sftp failed', $null),
                    @('/nosuch', 'check-v1.ps1', $v1, 'a missing directory', 'sftp failed', $null),
                    @('/files', 'locked.sh', $v1, 'a file the account may not read', 'sftp failed', $null),
                    @('/files', 'check-v2.ps1', $v1, 'a digest that does not match', 'does not match its sha256', $null),
                    @('/files', 'check-v1.ps1', $v1, 'a key the server does not know', 'sftp failed', 'wrongkey'),
                    @('/files', 'check-v1.ps1', $v1, 'a host key not in known_hosts', 'sftp failed', 'noknown'))) {
                $n++
                if ($f[5] -ceq 'wrongkey') { & $sshConfig (Join-Path $src 'ssh\vigil_sources_wrong') (Join-Path $src 'sftp_known_hosts') }
                if ($f[5] -ceq 'noknown') { $e = Join-Path $work 'empty_known_hosts'; [System.IO.File]::WriteAllText($e, ''); & $sshConfig (Join-Path $src 'ssh\vigil_sources') $e }
                Set-ScriptsConfig sftp "$s`npath        = $($f[0])`ntimeout     = 10s" $f[1] $f[2] "fail$n"
                Test-Failure $f[3] $f[4]
            }
            & $sshConfig (Join-Path $src 'ssh\vigil_sources') (Join-Path $src 'sftp_known_hosts')
            Test-RemoteMode sftp { param($v) "$s`npath        = /files/configs/$v" }
            $leaks = @(([System.IO.File]::ReadAllLines((Join-Path $src 'ssh\vigil_sources')))[1])
        }
        'local' {
            $share = Join-Path $work 'a share with spaces'
            [void](New-Item -ItemType Directory -Force -Path (Join-Path $share 'nested'))
            Copy-Item -LiteralPath (Join-Path $fx 'scripts\check-v1.ps1') -Destination (Join-Path $share 'check.ps1')
            Copy-Item -LiteralPath (Join-Path $fx 'scripts\check-v1.ps1') -Destination (Join-Path $share 'nested\check.ps1')
            Write-Output "`n$Target, scripts from a local directory (its path has spaces)"
            Set-ScriptsConfig local "path        = $share" 'check.ps1' $v1 'share'
            Invoke-Fetch
            Test-Equal 'pinned: fetched and activated' 'succeeded' (Get-FetchStatus)
            Test-Equal 'pinned: the job runs version 1' 'source_check 1' (Invoke-Run 'check')
            $script:rev = Get-Revision
            Copy-Item -LiteralPath (Join-Path $fx 'scripts\check-v2.ps1') -Destination (Join-Path $share 'check.ps1') -Force
            Invoke-Fetch
            Test-Contains 'pinned, the file changed: the new content is refused, logged' 'no longer matches its sha256; the last verified copy stays in use' (Find-InFetchLog 'no longer matches its sha256; the last verified copy stays in use')
            Test-Equal 'pinned, the file changed: the configuration is unchanged' $script:rev (Get-Revision)
            Test-Equal 'pinned, the file changed: the last verified copy keeps running' 'source_check 1' (Invoke-Run 'check')
            Set-ScriptsConfig local "path        = $share" 'check.ps1' $v2 'share'
            Invoke-Fetch
            Test-Equal 'pinned to the new digest: the job runs version 2' 'source_check 2' (Invoke-Run 'check')
            Copy-Item -LiteralPath (Join-Path $fx 'scripts\check-v1.ps1') -Destination (Join-Path $share 'check.ps1') -Force
            Set-ScriptsConfig local "path        = $share" 'check.ps1' '-' 'followed'
            Invoke-Fetch
            Test-Equal 'followed: the job runs version 1' 'source_check 1' (Invoke-Run 'check')
            Copy-Item -LiteralPath (Join-Path $fx 'scripts\check-v2.ps1') -Destination (Join-Path $share 'check.ps1') -Force
            Invoke-Fetch
            Test-Equal 'followed, the file changed: the job runs version 2' 'source_check 2' (Invoke-Run 'check')
            Set-ScriptsConfig local "path        = $share" 'nested/check.ps1' $v1 'nested'
            Invoke-Fetch
            Test-Equal 'a nested path: the job runs version 1' 'source_check 1' (Invoke-Run 'check')
            $script:rev = Get-Revision
            Set-ScriptsConfig local "path        = $share" 'nosuch.ps1' $v1 'fail1'
            Test-Failure 'a missing file' 'nosuch.ps1'
            Set-ScriptsConfig local "path        = $(Join-Path $work 'no such dir')" 'check.ps1' $v1 'fail2'
            Test-Failure 'a missing directory' 'not a directory'
        }
    }

    # Leaks: no password, token or private key under the Vigil root or in
    # its output.
    $found = @(foreach ($f in @(Get-ChildItem -LiteralPath $work -Recurse -File)) {
            $text = try { [System.IO.File]::ReadAllText($f.FullName) } catch { '' }
            foreach ($x in $leaks) { if ($x -and $text.Contains($x)) { $f.FullName.Substring($work.Length + 1); break } }
        })
    if ($found.Count -gt 0) { Write-Fail "a credential was written down: $($found -join ' ')" } else { Write-Pass 'no password, token or private key under the Vigil root or in its output' }
    Write-NotRun 'server down and back: run-source.sh does it on the Docker host'

    Write-Output "`n$script:pass passed, $script:fail failed, $script:notRun not run"
    exit $(if ($script:fail -eq 0) { 0 } else { 1 })
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
