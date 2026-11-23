#Requires -Version 5.1

<#
.SYNOPSIS
    sessions.ps1 - a Jetty's HTTP sessions, by app, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each app's session cache (sessions now, the most at once, every one
    created) and its session handler (sessions created, how long they live,
    their timeout). Read-only: it reads attributes over JMX, and changes
    nothing.

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
      jmx_up                        1 when JMX answers, else 0, tagged
                                    jetty=<its name> and jmx=<its address>
      current                       sessions in the cache now, tagged
                                    context=<its app>; the most first
      most                          the most at once, tagged the same
      cached_count                  sessions it has held, tagged the same
      created_count                 sessions created, tagged the same
      alive_mean_seconds            how long a session lives, on average, tagged
                                    the same
      alive_max_seconds             the longest a session lived, tagged the same
      timeout_seconds               how long an idle session lives, tagged the
                                    same
      current_not_shown             of current, those past the first 100, left
                                    out (the largest are shown)
      most_not_shown                of most, those past the first 100, left out
                                    (the largest are shown)
      cached_count_not_shown        of cached_count, those past the first 100,
                                    left out (the largest are shown)
      created_count_not_shown       of created_count, those past the first 100,
                                    left out
      alive_mean_seconds_not_shown
                                    of alive_mean_seconds, those past the first
                                    100, left out
      alive_max_seconds_not_shown   of alive_max_seconds, those past the first
                                    100, left out
      timeout_seconds_not_shown     of timeout_seconds, those past the first
                                    100, left out

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your Jetty):
      Healthy  current rising and falling with traffic.
      Watch    current climbing without falling back: sessions created and never
               used again hold memory until they time out.
      Act      current far above what your users explain: a client or a bot
               making a session each request.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _probe.jar,
      beside this script, once it matches its digest; Jetty's JMX
    Exit code: 0 on success, Jetty up or down (jmx_up says which); 1 if Java is
      missing, _probe.jar does not match its digest, or JMX refuses the login or
      its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'jetty_sessions'

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
