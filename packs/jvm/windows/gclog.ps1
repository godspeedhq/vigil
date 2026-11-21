#Requires -Version 5.1

<#
.SYNOPSIS
    gclog.ps1 - a JVM's GC pauses, from its log, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the pauses in the last five minutes of a JVM's GC log: how many, the
    longest, the 99th percentile and in all; full collections; allocation stalls
    (ZGC). By the log's own clock, from its last 4 MB. Read-only: it changes
    nothing in the JVM, and nothing it does pauses one.

    From the JVM's GC log, for each JVM given one in JVM_TARGETS (gclog=<path>):
    unified logging (Java 9 and later: -Xlog:gc*:file=<path>; -Xlog:gc alone
    leaves out ZGC's and Shenandoah's pauses) or Java 8's -XX:+PrintGCDetails
    -XX:+PrintGCTimeStamps, readable by this account.
    JVM_TARGETS names the JVMs: name: key=value, ...; name: ... with main=<its
    main class or jar, or any text on its command line> or pid=<a pid file> to
    find it on this machine, and jmx= or jmxs= for its JMX address. Empty, it
    watches every JVM on this machine, each named by its main class. Each metric
    is tagged jvm=<name>; jvms is how many JVMs the job looked at.

    Metrics:
      jvms                      the JVMs the job looked at (untagged)
      window_seconds            the window: 300
      pauses                    pauses in it
      pause_max_ms              the longest
      pause_p99_ms              the 99th percentile
      pause_total_ms            all of them
      full_gcs                  full collections in it
      allocation_stalls_in_log  ZGC allocation stalls in the log read

    Example output:
      (draft: no example yet)

    Reading the results (starting points: tune them to the JVM):
      Healthy  pause_p99_ms small for the collector; full_gcs 0.
      Watch    pause_max_ms rising.
      Act      full_gcs above 0 with G1 or ZGC: they fell back to a full
               collection; allocation_stalls_in_log rising: ZGC could not keep
               up, and threads waited.

    Requires: Windows PowerShell 5.1 or PowerShell 7, a JDK 11 or later
      (JAVA_HOME, or java on the PATH) to run _client.java, beside this script
    Exit code: 0 on success, JVMs up or down; 1 if java is missing, JVM_TARGETS
      is wrong, or a JVM refuses the JMX login or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'jvm_gclog'

# The client, beside this script, run by a JDK: JAVA_HOME's, else the PATH's.
$java = $null
if ($env:JAVA_HOME -and [System.IO.File]::Exists((Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
    $java = Join-Path $env:JAVA_HOME 'bin\java.exe'
}
else {
    $c = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($c) { $java = $c.Source }
}
if (-not $java) {
    [Console]::Error.WriteLine("${job}: java not found: the jvm pack runs its client with a JDK 11 or later, on the PATH or in JAVA_HOME")
    exit 1
}

# A folder of this run's own, for the process table and what Java writes
# while it runs: gone when the run ends.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-jvm.' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$code = 1
try {
    # The JVMs on this machine, as Windows lists them, for the client: one a
    # line, tab-separated. Another account's command line needs an
    # administrator (Vigil's service is one).
    $rows = New-Object System.Collections.Generic.List[string]
    $epoch = [datetime]'1970-01-01'
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue)) {
        $cmd = [string]$p.CommandLine
        if (-not $cmd) { $cmd = [string]$p.ExecutablePath }
        $cmd = $cmd -replace '[\t\r\n]', ' '
        $start = ''
        if ($p.CreationDate) { $start = [string][long](($p.CreationDate.ToUniversalTime() - $epoch).TotalSeconds) }
        $rows.Add((@($p.ProcessId, '', $cmd, $p.WorkingSetSize, $p.VirtualSize, $p.ThreadCount, $p.HandleCount,
                    ([long]$p.KernelModeTime + [long]$p.UserModeTime), $start, $p.ReadTransferCount, $p.WriteTransferCount) -join "`t"))
    }
    $table = Join-Path $work 'procs.tsv'
    [System.IO.File]::WriteAllLines($table, $rows, (New-Object System.Text.UTF8Encoding $false))
    $env:JVM_PROCS_FILE = $table

    # A small JVM, quick to start, that keeps no counters of its own (it
    # would find itself among the JVMs it watches).
    & $java -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m "-Djava.io.tmpdir=$work" (Join-Path $PSScriptRoot '_client.java') $job
    $code = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
