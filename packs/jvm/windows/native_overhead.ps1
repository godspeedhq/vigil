#Requires -Version 5.1

<#
.SYNOPSIS
    native_overhead.ps1 - a JVM's memory outside its heap, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports how much of a JVM's resident memory is outside its heap: its
    resident memory, less the heap it holds. Off-heap buffers, native libraries,
    threads' stacks, metaspace and the JVM itself are in it, and a native leak
    shows here when no Java figure moves. Read-only: it changes nothing in the
    JVM, and nothing it does pauses one.

    From the operating system: the JVM's process, which needs nothing set up.
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
      jvms                  the JVMs the job looked at (untagged)
      jmx_up                1 when the JVM answered at its JMX address, 0 when
                            not (only for a JVM with one)
      rss_bytes             resident memory
      heap_committed_bytes  the heap it holds
      outside_heap_bytes    resident memory less that heap
      outside_heap_percent  that, against resident memory

    Example output:
      (draft: no example yet)

    Reading the results (starting points: tune them to the JVM):
      Healthy  outside_heap_bytes steady once started.
      Watch    outside_heap_bytes rising over hours with a steady heap.
      Act      outside_heap_bytes rising without end: a native leak
               (jvm_buffers, jvm_native).

    Requires: Windows PowerShell 5.1 or PowerShell 7, a JDK 11 or later
      (JAVA_HOME, or java on the PATH) to run _client.java, beside this script
    Exit code: 0 on success, JVMs up or down; 1 if java is missing, JVM_TARGETS
      is wrong, or a JVM refuses the JMX login or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'jvm_native_overhead'

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
