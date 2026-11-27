# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Bare.ps1 - a fleet test instance on this Windows machine itself, as an
# ordinary user, in its own folder (%USERPROFILE%\vigil-fleet-node), beside
# and apart from any Vigil installed here (its service is never touched):
#
#   Bare.ps1 up <backend address> <token file> [<version>]
#       installs Vigil from its release (checked against SHA256SUMS and
#       their signature, with the release key in this repository), points
#       it at the fleet's configuration in Git
#   Bare.ps1 run        runs `vigil supervise` here, until it is stopped:
#                       in a console left open, or as the remote command
#                       of an SSH session kept open (Windows ends what an
#                       SSH session started when the session ends)
#   Bare.ps1 down       stops it (its own pid file, nothing else)
#   Bare.ps1 remove     stops it and deletes the folder and Git's login
#   Bare.ps1 status
#
# Git's login: the read-only token, in a credentials file of its own
# (%USERPROFILE%\.vigil-fleet-credentials, this user's only), used only for
# the backend's URL. Needs Git for Windows.
param([Parameter(Position = 0)][string]$Command, [Parameter(Position = 1)][string]$Address,
      [Parameter(Position = 2)][string]$TokenFile, [Parameter(Position = 3)][string]$Version = '1.5.3')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$root = Join-Path $env:USERPROFILE 'vigil-fleet-node'
$pidf = Join-Path $root 'fleet.pid'
$cred = Join-Path $env:USERPROFILE '.vigil-fleet-credentials'
function Get-Running {
    if (-not (Test-Path $pidf)) { return $null }
    $p = Get-Process -Id ([int](Get-Content $pidf)) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -match '^(powershell|pwsh)$') { $p } else { $null }
}
switch ($Command) {
    'up' {
        if (-not $Address -or -not $TokenFile) { throw 'usage: Bare.ps1 up <backend address> <token file> [<version>]' }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git for Windows is needed: winget install Git.Git' }
        if (-not (Test-Path (Join-Path $root 'app\vigil.ps1'))) {
            $d = Join-Path $env:TEMP ('vigil-fleet-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory $d | Out-Null
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            foreach ($f in 'install.ps1', "vigil-$Version.zip", 'SHA256SUMS', 'SHA256SUMS.sig') {
                Invoke-WebRequest -UseBasicParsing -OutFile (Join-Path $d $f) "https://github.com/godspeedhq/vigil/releases/download/v$Version/$f"
            }
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $d 'install.ps1') -User -Prefix $root -NoService -NoInit `
                -Archive (Join-Path $d "vigil-$Version.zip") -Key (Join-Path $repo 'app\release-key.pem')
            if ($LASTEXITCODE) { throw "install.ps1 failed ($LASTEXITCODE)" }
            Remove-Item -Recurse -Force $d
        }
        New-Item -ItemType Directory -Force (Join-Path $root 'config') | Out-Null
        $check = if ($env:FLEET_CHECK_EVERY) { $env:FLEET_CHECK_EVERY } else { '30s' }
        @"
# The fleet test: this instance's configuration is windows-bare.config in
# the fleet's Git repository, picked up at every check.
[vigil]
config_source = fleet
config_file   = windows-bare.config

[source.fleet]
type        = git
url         = https://${Address}:8443/fleet/config.git
ref         = main
check_every = $check
"@ | Set-Content -Encoding ascii (Join-Path $root 'config\vigil.config')
        $t = (Get-Content -Raw $TokenFile).Trim()
        [IO.File]::WriteAllText($cred, "https://fleet-reader:${t}@${Address}:8443`n")
        & icacls $cred /inheritance:r /grant:r "${env:USERNAME}:F" | Out-Null
        & git config --global "credential.https://${Address}:8443.helper" "store --file '$($cred -replace '\\', '/')'"
        # Git for Windows checks certificates with its own bundle, not the
        # Windows store: give it the fleet's CA (from the store, where
        # admin\Trust-TestCA.ps1 put it), for the backend's URL only.
        $ca = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -eq 'CN=Vigil fleet test CA' | Select-Object -First 1
        if (-not $ca) { throw 'the fleet test CA is not trusted here: run admin\Trust-TestCA.ps1 as Administrator first' }
        $pem = Join-Path $root 'fleet-ca.crt'
        [IO.File]::WriteAllText($pem, "-----BEGIN CERTIFICATE-----`n" + [Convert]::ToBase64String($ca.RawData, 'InsertLineBreaks') + "`n-----END CERTIFICATE-----`n")
        & git config --global "http.https://${Address}:8443/.sslCAInfo" ($pem -replace '\\', '/')
        # MinGit uses schannel, which wants a revocation list the test CA
        # does not publish, and ignores sslCAInfo: OpenSSL, as full Git for
        # Windows uses by default (remove puts it back).
        if ((& git config --get http.sslBackend) -ne 'openssl') {
            & git config --global http.sslBackend openssl
            New-Item -ItemType File -Force (Join-Path $env:USERPROFILE '.vigil-fleet-sslbackend') | Out-Null
        }
        "ready: windows-bare, config from https://${Address}:8443/fleet/config; Bare.ps1 run starts it"
    }
    'run' {
        if ($r = Get-Running) { "already running (pid $($r.Id))"; return }
        $p = Start-Process -PassThru -NoNewWindow -FilePath powershell.exe -WorkingDirectory $root -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$root\app\vigil.ps1`"", '--root', "`"$root`"", 'supervise')
        Set-Content $pidf $p.Id
        "running (pid $($p.Id)), windows-bare"
        $p.WaitForExit()
        Remove-Item -Force $pidf -ErrorAction SilentlyContinue
        "ended ($($p.ExitCode))"
    }
    'down' {
        if ($r = Get-Running) {
            & taskkill /PID $r.Id /T /F 2>&1 | Out-Null
            # Windows refuses (Access denied) a supervisor that another SSH
            # session started: say so, and keep the pid file, rather than
            # report a stop that did not happen.
            for ($i = 0; $i -lt 10 -and -not $r.HasExited; $i++) { Start-Sleep -Seconds 1; $r.Refresh() }
            if (-not $r.HasExited) { "FAILED: supervisor $($r.Id) still runs; stop it as Administrator with Stop-FleetNode.ps1"; exit 1 }
            'stopped'
        }
        else { 'not running' }
        Remove-Item -Force $pidf -ErrorAction SilentlyContinue
    }
    'remove' {
        & $PSCommandPath down
        foreach ($l in (& git config --global --get-regexp '^credential\.https://.*:8443\.helper$' 2> $null)) {
            $k, $v = $l -split ' ', 2
            if ($v -match 'vigil-fleet-credentials') { & git config --global --unset $k }
        }
        foreach ($l in (& git config --global --get-regexp '^http\.https://.*:8443/\.sslcainfo$' 2> $null)) {
            $k, $v = $l -split ' ', 2
            if ($v -match 'vigil-fleet-node/fleet-ca\.crt$') { & git config --global --unset $k }
        }
        $marker = Join-Path $env:USERPROFILE '.vigil-fleet-sslbackend'
        if (Test-Path $marker) { & git config --global --unset http.sslBackend; Remove-Item -Force $marker }
        Remove-Item -Recurse -Force $root, $cred -ErrorAction SilentlyContinue; 'removed'
    }
    'status' { if ($r = Get-Running) { "running (pid $($r.Id)), windows-bare" } else { 'not running' } }
    default { Get-Content $PSCommandPath | Select-Object -Skip 9 -First 19 | ForEach-Object { $_ -replace '^# ?', '' }; exit 64 }
}
