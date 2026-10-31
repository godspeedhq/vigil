# Init.ps1 - vigil init: a starting configuration (SPECIFICATION.md 19).
#
#   Invoke-VigilInit -Root -Instance -Backends -Sample
#
# Writes config\vigil.config, commented, with runners for the PowerShell
# hosts found on this machine, the chosen backends with env: placeholders
# for their credentials, and one sample job (scripts\disk.ps1) unless
# -Sample is false. Never overwrites a configuration, never asks for or
# stores a secret value. -Backends lists file, datadog and otel.

function Invoke-VigilInit {
    param([string]$Root, [string]$Instance, [string[]]$Backends, [bool]$Sample)
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
                & $w '# Datadog. Set DATADOG_API_KEY in the machine environment.'
                & $w '[backend.datadog]'
                & $w 'endpoint = https://api.datadoghq.com'
                & $w 'api_key  = env:DATADOG_API_KEY'
                & $w 'timeout  = 10s'
                $envNames.Add('DATADOG_API_KEY')
            }
            'otel' {
                & $w '# OpenTelemetry collector, OTLP/HTTP. Remove api_key if the'
                & $w '# collector needs no bearer token.'
                & $w '[backend.otel]'
                & $w 'endpoint = http://localhost:4318/v1/metrics'
                & $w 'api_key  = env:OTEL_API_KEY'
                & $w 'timeout  = 10s'
                $envNames.Add('OTEL_API_KEY')
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
    if ($Sample) {
        & $w "# A sample job: the system drive's use, every 5 minutes."
        & $w '[job.disk]'
        & $w 'metric_name = os.disk'
        & $w 'file        = scripts\disk.ps1'
        & $w 'run_every   = 5m'
        & $w 'max_runtime = 30s'
    }
    else {
        & $w '# Jobs: one [job.<name>] section each. For example:'
        & $w '# [job.disk]'
        & $w '# file        = scripts\disk.ps1'
        & $w '# run_every   = 5m'
        & $w '# max_runtime = 30s'
    }
    Write-VigilFileAtomic -Path $cfg -Text $sb.ToString()
    Write-Output "wrote $cfg"

    $disk = Join-Path $Root 'scripts\disk.ps1'
    if ($Sample -and -not [System.IO.File]::Exists($disk)) {
        [System.IO.File]::WriteAllText($disk, (@(
                    "# disk.ps1 - the system drive's use, as a metric (vigil init sample).",
                    '# Prints: metric used_pct <percent>. Fails above 95%.',
                    '$d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID=''$env:SystemDrive''"',
                    '$used = [int][Math]::Round(100 * ($d.Size - $d.FreeSpace) / $d.Size)',
                    'Write-Output "metric used_pct $used"',
                    'if ($used -gt 95) { exit 1 }',
                    'exit 0') -join "`r`n") + "`r`n")
        Write-Output "wrote $disk"
    }

    if ($envNames.Count -gt 0) {
        Write-Output ''
        Write-Output 'Set these in the machine environment before starting Vigil:'
        foreach ($n in $envNames) { Write-Output "  $n" }
    }
    Write-Output ''
    Write-Output 'Next: vigil precheck, then vigil service install'
}
