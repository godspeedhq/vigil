# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

# A fleet host on Windows, reaching the fleet's servers through SSH tunnels
# on 127.0.0.1 (2223 sftp, 8080 http). Runs in the foreground until its
# session ends: a release server on 127.0.0.1 serving <Dir>\www, Vigil
# installed from it once, a pointer file, then the supervisor. The twin of
# host.sh.
#
#   Host.ps1 -Dir <dir> -Source <https|sftp> -File <file in the source> -Start <first release>
#
# <Dir> holds what fleet.sh made: www\, release.pem, mock-files.py and
# keys\fleet, keys\known_hosts. Nothing outside <Dir> is touched: the user
# PATH the installer changes is put back, and ssh reads <Dir>\ssh_config only.
param([string]$Dir, [string]$Source, [string]$File, [string]$Start)
$ErrorActionPreference = 'Stop'
$Dir = (Resolve-Path -LiteralPath $Dir).ProviderPath
$shell = (Get-Process -Id $PID).Path
$key = Join-Path $Dir 'keys\fleet'
# OpenSSH refuses a private key that others can read.
& icacls.exe $key /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null
[System.IO.File]::WriteAllText("$Dir\ssh_config", "Host 127.0.0.1`n  IdentityFile $($key.Replace('\', '/'))`n  UserKnownHostsFile $("$Dir\keys\known_hosts".Replace('\', '/'))`n  IdentitiesOnly yes`n")
$env:VIGIL_TEST_SSH_CONFIG = "$Dir\ssh_config"
# The release server serves <Dir>\www, and writes its port to <Dir>\port.
Remove-Item -LiteralPath "$Dir\port" -ErrorAction SilentlyContinue
$python = (Get-Command python -CommandType Application | Select-Object -First 1).Source
$m = Start-Process -FilePath $python -ArgumentList @("`"$Dir\mock-files.py`"", "`"$Dir`"") -PassThru -NoNewWindow -RedirectStandardError "$Dir\mock.err"
for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath "$Dir\port"); $i++) { Start-Sleep -Milliseconds 100 }
$env:VIGIL_TEST_RELEASE_URL = "http://127.0.0.1:$([System.IO.File]::ReadAllText("$Dir\port").Trim())"
$env:VIGIL_TEST_RELEASE_KEY = "$Dir\release.pem"
$root = Join-Path $Dir 'root'
if (-not (Test-Path -LiteralPath "$root\app\VERSION")) {
    $saved = [Environment]::GetEnvironmentVariable('Path', 'User')
    '' | & $shell -NoProfile -ExecutionPolicy Bypass -File "$Dir\www\releases\download\v$Start\install.ps1" -User -Version $Start -Prefix $root -NoInit -NoService
    [Environment]::SetEnvironmentVariable('Path', $saved, 'User')
}
[void](New-Item -ItemType Directory -Force -Path "$root\config")
$s = if ($Source -ceq 'https') { "type = https`nurl  = http://127.0.0.1:8080/fleet/`n" }
else { "type = sftp`nhost = 127.0.0.1`nport = 2223`nuser = files`npath = /home/files/fleet`n" }
[System.IO.File]::WriteAllText("$root\config\vigil.config", "[vigil]`nconfig_source = fleet`nconfig_file   = $File`n`n[source.fleet]`n$s" + "check_every = 10s`n")
try { & $shell -NoProfile -ExecutionPolicy Bypass -File "$root\app\vigil.ps1" -Root $root supervise }
finally { if (-not $m.HasExited) { Stop-Process -Id $m.Id -Force } }
