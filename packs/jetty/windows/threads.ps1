#Requires -Version 5.1

<#
.SYNOPSIS
    threads.ps1 - a Jetty's thread pool, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports Jetty's thread pool: threads, busy, idle and ready, the most it may
    have, jobs waiting for a thread, how much of it is in use, whether it is low
    on threads, and the threads leased to Jetty's own work (acceptors and
    selectors) and reserved. Read-only: it reads attributes over JMX, and
    changes nothing.

    Reads each Jetty's JMX, at JETTY_JMX: jmx=host:port, or jmxs=host:port over
    TLS, separated by ; or , each with a name first if you like (web1:
    jmxs=host:port); with JETTY_JMX_USER and the password in JETTY_JMX_PASSWORD
    when JMX asks for them; a certificate is checked against JETTY_CACERT, a PEM
    file of CAs, or Java's own, and against the server's name. Jetty's MBeans
    are there with its jmx module. With no JETTY_JMX, it prints nothing. Jetty's
    JVM (heap, garbage collection, threads, CPU, open files) is the jvm pack's,
    not this one's.

    The probe (_probe.jar, tools/probe) reads it, from this pack's
    _probe.tables, beside this script: nothing of Jetty's is needed here.

    Metrics:
      jmx_up                     1 when JMX answers, else 0, tagged jetty=<its
                                 name> and jmx=<its address>
      threads                    threads it has, tagged id=<the pool>
      busy                       busy threads, tagged the same
      idle                       idle threads, tagged the same
      ready                      threads ready for a job now, tagged the same
      utilized                   threads running a job of the application,
                                 tagged the same
      max_threads                the most it may have, tagged the same
      min_threads                the fewest it keeps, tagged the same
      queue                      jobs waiting for a thread, tagged the same
      utilization_pct            how much of the pool is in use, tagged the same
      low_on_threads             1 when it is low on threads, else 0, tagged the
                                 same
      leased                     threads leased to Jetty's own work (acceptors,
                                 selectors), tagged the same
      reserved                   threads reserved and available, tagged the same
      max_available              the most that could run the application, tagged
                                 the same
      threads_not_shown          of threads, those past the first 100, left out
      busy_not_shown             of busy, those past the first 100, left out
      idle_not_shown             of idle, those past the first 100, left out
      ready_not_shown            of ready, those past the first 100, left out
      utilized_not_shown         of utilized, those past the first 100, left out
      max_threads_not_shown      of max_threads, those past the first 100, left
                                 out
      min_threads_not_shown      of min_threads, those past the first 100, left
                                 out
      queue_not_shown            of queue, those past the first 100, left out
      utilization_pct_not_shown
                                 of utilization_pct, those past the first 100,
                                 left out
      low_on_threads_not_shown   of low_on_threads, those past the first 100,
                                 left out
      leased_not_shown           of leased, those past the first 100, left out
      reserved_not_shown         of reserved, those past the first 100, left out
      max_available_not_shown    of max_available, those past the first 100,
                                 left out

    Example output (the rest are in the same form):
      metric jmx_up 1 jetty=j121 jmx=localhost:19314
      metric threads 24 jetty=j121 jmx=localhost:19314 id=0
      metric busy 18 jetty=j121 jmx=localhost:19314 id=0
      metric idle 2 jetty=j121 jmx=localhost:19314 id=0
      metric ready 6 jetty=j121 jmx=localhost:19314 id=0
      metric utilized 16 jetty=j121 jmx=localhost:19314 id=0
      metric max_threads 24 jetty=j121 jmx=localhost:19314 id=0
      metric min_threads 4 jetty=j121 jmx=localhost:19314 id=0
      metric queue 0 jetty=j121 jmx=localhost:19314 id=0
      metric utilization_pct 72.7273 jetty=j121 jmx=localhost:19314 id=0
      metric low_on_threads 0 jetty=j121 jmx=localhost:19314 id=0
      metric leased 2 jetty=j121 jmx=localhost:19314 id=0
      metric reserved 4 jetty=j121 jmx=localhost:19314 id=0
      metric max_available 22 jetty=j121 jmx=localhost:19314 id=0

    Reading the results (starting points: tune them to your Jetty):
      Healthy  busy well below max_threads; queue 0; low_on_threads 0.
      Watch    utilization_pct above 80 for minutes; queue above 0 now and then.
      Act      queue growing and low_on_threads 1: every thread is busy and
               requests wait. Find what holds them (the jvm pack's threads and
               deadlocks).

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _probe.jar,
      beside this script, once it matches its digest; Jetty's JMX
    Exit code: 0 on success, Jetty up or down (jmx_up says which); 1 if Java is
      missing, _probe.jar does not match its digest, or JMX refuses the login or
      its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'jetty_threads'

# The probe's SHA-256, written when the pack was released: built from
# _probe.java, beside it, by javac @PROBE_JAR_JAVAC@ (tools/release/client-jar.sh).
$probeSha256 = '@PROBE_JAR_SHA256@'

# The probe, beside this script, run by Java 11 or later: JAVA_HOME's, else
# the PATH's.
$java = $null
if ($env:JAVA_HOME -and [System.IO.File]::Exists((Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
    $java = Join-Path $env:JAVA_HOME 'bin\java.exe'
}
else {
    $c = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($c) { $java = $c.Source }
}
if (-not $java) {
    [Console]::Error.WriteLine("${job}: java not found: the jetty pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME")
    exit 1
}

# The jar is run only once it matches its digest.
$probe = Join-Path $PSScriptRoot '_probe.jar'
if (-not [System.IO.File]::Exists($probe)) {
    [Console]::Error.WriteLine("${job}: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install jetty), or build it (tools/release/client-jar.sh)")
    exit 1
}
$sha = [System.Security.Cryptography.SHA256]::Create()
$f = [System.IO.File]::OpenRead($probe)
try { $sum = -join ($sha.ComputeHash($f) | ForEach-Object { $_.ToString('x2') }) }
finally { $f.Dispose(); $sha.Dispose() }
if ($sum -ne $probeSha256) {
    [Console]::Error.WriteLine("${job}: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify jetty says what differs")
    exit 1
}

# A folder of this run's own, for what Java writes while it runs: gone when
# the run ends.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-jetty.' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$code = 1
try {
    # A small JVM, quick to start, that keeps no counters of its own (the
    # jvm pack would find it among the JVMs it watches). The probe reads
    # this job's table.
    & $java -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m "-Djava.io.tmpdir=$work" `
        -cp $probe Probe (Join-Path $PSScriptRoot '_probe.tables') $job
    $code = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
