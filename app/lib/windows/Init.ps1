# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Init.ps1 - vigil init: a starting configuration (SPECIFICATION.md 19).
#
#   Invoke-VigilInit -Root -Instance -Backends -Refs
#
# Writes config\vigil.config, commented, with runners for the PowerShell
# hosts found on this machine and the chosen backends, and no jobs: those are
# the packs' and the operator's. Never overwrites a configuration, never
# holds a secret value. -Backends lists file, datadog and otel, and may be
# empty. -Refs gives a backend's credential reference, or none: otherwise
# env: placeholders.

function Invoke-VigilInit {
    param([string]$Root, [string]$Instance, [string[]]$Backends, [hashtable]$Refs = @{})
    $cfg = Join-Path $Root 'config\vigil.config'
    if ([System.IO.File]::Exists($cfg)) { throw "$cfg exists; init never overwrites a configuration" }
    if ($Instance -cnotmatch '^[A-Za-z0-9_.-]+$') { throw "the instance name may contain only letters, digits and . _ -: '$Instance'" }
    foreach ($b in $Backends) {
        if ($b -cnotin @('file', 'datadog', 'otel')) { throw "init knows the backends file, datadog and otel, not '$b'; add others to the configuration by hand" }
    }
    foreach ($d in @('config', 'scripts')) { [void](New-Item -ItemType Directory -Force -Path (Join-Path $Root $d)) }
    $pwsh = @(Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue)
    $envNames = New-Object System.Collections.Generic.List[string]

    $sb = New-Object System.Text.StringBuilder
    $w = { param([string]$Line) [void]$sb.Append($Line).Append("`n") }
    & $w "# vigil.config - written by vigil init on $((Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)) for Windows."
    & $w '#'
    & $w '# The format and every key: https://godspeedhq.github.io/vigil/spec/06/'
    & $w '# Check it after every change: vigil precheck'
    & $w '#'
    & $w '# Secrets never go in this file. Credentials are references: env:NAME'
    & $w '# (the service environment), secret:NAME (vigil secret set NAME) or'
    & $w '# store:<store>/<name> (an external secret store).'
    & $w ''
    & $w '[vigil]'
    & $w '# Names this deployment; becomes the "instance" tag on every metric.'
    & $w "instance = $Instance"
    & $w ''
    & $w '[scheduler]'
    & $w '# How often the supervisor wakes to start due jobs.'
    & $w 'tick = 10s'
    & $w ''
    foreach ($b in $Backends) {
        switch ($b) {
            'file' {
                & $w "# Prometheus text file, for windows_exporter's textfile collector."
                & $w '[backend.file]'
                & $w 'path = metrics\vigil.prom'
            }
            'datadog' {
                $ref = if ($Refs['datadog']) { $Refs['datadog'] } else { 'env:DATADOG_API_KEY' }
                & $w '# Datadog. An env: credential goes in the machine environment.'
                & $w '[backend.datadog]'
                & $w 'endpoint = https://api.datadoghq.com'
                & $w "api_key  = $ref"
                & $w 'timeout  = 10s'
                if ($ref.StartsWith('env:')) { $envNames.Add($ref.Substring(4)) }
            }
            'otel' {
                & $w '# OpenTelemetry collector, OTLP/HTTP. Remove api_key if the'
                & $w '# collector needs no bearer token.'
                & $w '[backend.otel]'
                & $w 'endpoint = http://localhost:4318/v1/metrics'
                $ref = if ($Refs['otel']) { $Refs['otel'] } else { 'env:OTEL_API_KEY' }
                if ($ref -cne 'none') { & $w "api_key  = $ref" }
                & $w 'timeout  = 10s'
                if ($ref.StartsWith('env:')) { $envNames.Add($ref.Substring(4)) }
            }
        }
        & $w ''
    }
    & $w '# Runners: how files are run, by extension. .cmd and .bat need none.'
    & $w '[runner.ps]'
    & $w 'command = powershell.exe'
    foreach ($a in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File')) { & $w "arg     = $a" }
    & $w ''
    if ($pwsh.Count -gt 0) {
        & $w '# PowerShell 7, for jobs that need it: runner = pwsh in the job.'
        & $w '[runner.pwsh]'
        & $w "command = $($pwsh[0].Source)"
        foreach ($a in @('-NoProfile', '-NonInteractive', '-File')) { & $w "arg     = $a" }
        & $w ''
    }
    & $w '[runners]'
    & $w '.ps1 = ps'
    & $w ''
    & $w "# Your jobs: one [job.<name>] section each. A job's file is the script it runs:"
    & $w "#   file = scripts\backup.ps1        in this install's scripts folder, $Root\scripts"
    & $w '#   file = D:\ops\backup.ps1         or anywhere else, by its full path'
    & $w "# A relative path always starts from $Root,"
    & $w "# so a bare backup.ps1 means $Root\backup.ps1: write the scripts\ out."
    & $w '# Wherever the script is, the account the service runs as must be able to'
    & $w "# read and run it: vigil precheck, run as that account, checks every job's file."
    & $w '# [job.backup]'
    & $w '# file        = scripts\backup.ps1'
    & $w '# run_every   = 1h'
    & $w '# max_runtime = 30m'
    Write-VigilFileAtomic -Path $cfg -Text $sb.ToString()
    Write-Output "wrote $cfg"

    if ($envNames.Count -gt 0) {
        Write-Output ''
        Write-Output 'Set these in the machine environment before starting Vigil:'
        foreach ($n in $envNames) { Write-Output "  $n" }
    }
}
