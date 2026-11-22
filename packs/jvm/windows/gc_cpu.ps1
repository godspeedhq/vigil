#Requires -Version 5.1

<#
.SYNOPSIS
    gc_cpu.ps1 - the CPU a JVM's GC uses, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the CPU the garbage collector's own threads have used, against the
    process's, where the JVM keeps it (HotSpot 22 and later): a collector
    quietly eating a core. Read-only: it changes nothing in the JVM, and nothing
    it does pauses one.

    From the JVM's own counters, the hsperfdata file HotSpot JVMs keep (unless
    started with -XX:-UsePerfData): on this machine, readable by the account
    that runs the JVM, or by root or an administrator.
    From JMX, for each JVM given a JMX address in JVM_TARGETS (jmx=host:port, or
    jmxs=host:port for JMX over TLS, its certificate checked against JVM_CACERT
    or Java's own CAs, and against its name), as JVM_JMX_USER with the password
    in JVM_JMX_PASSWORD (a secret line, never a command line). A JVM with an
    address that does not answer reports jmx_up 0.
    JVM_TARGETS names the JVMs: name: key=value, ...; name: ... with main=<its
    main class or jar, or any text on its command line> or pid=<a pid file> to
    find it on this machine, and jmx= or jmxs= for its JMX address. Empty, it
    watches every JVM on this machine, each named by its main class. Each metric
    is tagged jvm=<name>; jvms is how many JVMs the job looked at.

    Metrics:
      jvms                     the JVMs the job looked at (untagged)
      jmx_up                   1 when the JVM answered at its JMX address, 0
                               when not (only for a JVM with one)
      gc_cpu_seconds           the GC threads' CPU, a running total
      process_cpu_seconds      the process's CPU, a running total
      gc_cpu_percent_lifetime  the GC threads' share of it

    Example output:
      metric jvms 8
      metric gc_cpu_seconds 2.6764 jvm=host
      metric process_cpu_seconds 31.29 jvm=host
      metric gc_cpu_percent_lifetime 8.5535 jvm=host

    Reading the results (starting points: tune them to the JVM):
      Healthy  gc_cpu_percent_lifetime under 10.
      Watch    gc_cpu_seconds' rate rising.
      Act      gc_cpu_percent_lifetime above 25: the collector takes a quarter
               of the JVM's CPU.

    Requires: Windows PowerShell 5.1 or PowerShell 7, a JDK 11 or later
      (JAVA_HOME, or java on the PATH) to run _client.java, beside this script
    Exit code: 0 on success, JVMs up or down; 1 if java is missing, JVM_TARGETS
      is wrong, or a JVM refuses the JMX login or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'jvm_gc_cpu'

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
    $cim = $true
    try { $procs = @(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction Stop) }
    catch { $cim = $false; $procs = @() }
    foreach ($p in $procs) {
        $cmd = [string]$p.CommandLine
        if (-not $cmd) { $cmd = [string]$p.ExecutablePath }
        $cmd = $cmd -replace '[\t\r\n]', ' '
        $start = ''
        if ($p.CreationDate) { $start = [string][long](($p.CreationDate.ToUniversalTime() - $epoch).TotalSeconds) }
        $rows.Add((@($p.ProcessId, '', $cmd, $p.WorkingSetSize, $p.VirtualSize, $p.ThreadCount, $p.HandleCount,
                    ([long]$p.KernelModeTime + [long]$p.UserModeTime), $start, $p.ReadTransferCount, $p.WriteTransferCount) -join "`t"))
    }
    # An account CIM refuses (one logged on over the network, not an
    # administrator): the processes without their command lines, which the
    # client reads from each JVM's counters instead.
    if (-not $cim) {
        foreach ($p in @(Get-Process -Name java, javaw -ErrorAction SilentlyContinue)) {
            $cpu = ''; $start = ''
            try { if ($null -ne $p.TotalProcessorTime) { $cpu = [string]$p.TotalProcessorTime.Ticks } } catch { }
            try { if ($null -ne $p.StartTime) { $start = [string][long](($p.StartTime.ToUniversalTime() - $epoch).TotalSeconds) } } catch { }
            $rows.Add((@($p.Id, '', '', $p.WorkingSet64, $p.VirtualMemorySize64, $p.Threads.Count, $p.HandleCount, $cpu, $start, '', '') -join "`t"))
        }
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
