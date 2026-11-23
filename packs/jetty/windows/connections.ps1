#Requires -Version 5.1

<#
.SYNOPSIS
    connections.ps1 - a Jetty's connections, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports Jetty's connections, every connector's added up (the connection
    statistics module): open now and at most, opened since, how long they last,
    the bytes and messages in and out; the connection limit (its module) and
    connections waiting for it; and the QoS handler's limit (12): requests
    suspended, refused and expired. Read-only: it reads attributes over JMX, and
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
      jmx_up                        1 when JMX answers, else 0, tagged
                                    jetty=<its name> and jmx=<its address>
      open                          connections open now
      open_max                      the most open at once
      opened_count                  connections opened
      duration_max_seconds          the longest a connection lasted
      duration_mean_seconds         how long a connection lasts, on average
      received_bytes                bytes received
      sent_bytes                    bytes sent
      received_messages_count       messages received (requests, frames)
      sent_messages_count           messages sent
      limited                       connections the connection limit counts
      limit                         its limit
      limit_pending                 connections accepted but waiting for it (12)
      qos_max                       the QoS handler's limit of requests at once
                                    (12)
      qos_suspended                 requests suspended for it now (12)
      qos_exceeded_count            requests refused for it (12)
      qos_expired_count             requests that waited too long for it (12)
      qos_requests_count            requests it has seen (12)
      qos_suspended_count           requests it has suspended (12)
      qos_max_suspended             the most it suspends, then it refuses (12)
      selector_keys                 connections Jetty's selectors watch, every
                                    one added up
      selects_count                 times they have selected
      open_not_shown                of open, those past the first 100, left out
      open_max_not_shown            of open_max, those past the first 100, left
                                    out
      opened_count_not_shown        of opened_count, those past the first 100,
                                    left out
      duration_max_seconds_not_shown
                                    of duration_max_seconds, those past the
                                    first 100, left out
      duration_mean_seconds_not_shown
                                    of duration_mean_seconds, those past the
                                    first 100, left out
      received_bytes_not_shown      of received_bytes, those past the first 100,
                                    left out
      sent_bytes_not_shown          of sent_bytes, those past the first 100,
                                    left out
      received_messages_count_not_shown
                                    of received_messages_count, those past the
                                    first 100, left out
      sent_messages_count_not_shown
                                    of sent_messages_count, those past the first
                                    100, left out
      limited_not_shown             of limited, those past the first 100, left
                                    out
      limit_not_shown               of limit, those past the first 100, left out
      limit_pending_not_shown       of limit_pending, those past the first 100,
                                    left out
      qos_max_not_shown             of qos_max, those past the first 100, left
                                    out
      qos_suspended_not_shown       of qos_suspended, those past the first 100,
                                    left out
      qos_exceeded_count_not_shown
                                    of qos_exceeded_count, those past the first
                                    100, left out
      qos_expired_count_not_shown   of qos_expired_count, those past the first
                                    100, left out
      qos_requests_count_not_shown
                                    of qos_requests_count, those past the first
                                    100, left out
      qos_suspended_count_not_shown
                                    of qos_suspended_count, those past the first
                                    100, left out
      qos_max_suspended_not_shown   of qos_max_suspended, those past the first
                                    100, left out
      selector_keys_not_shown       of selector_keys, those past the first 100,
                                    left out
      selects_count_not_shown       of selects_count, those past the first 100,
                                    left out

    Example output (the rest are in the same form):
      metric jmx_up 1 jetty=j121 jmx=localhost:19314
      metric open 40 jetty=j121 jmx=localhost:19314
      metric open_max 40 jetty=j121 jmx=localhost:19314
      metric opened_count 97 jetty=j121 jmx=localhost:19314
      metric duration_max_seconds 1.345 jetty=j121 jmx=localhost:19314
      metric duration_mean_seconds 0.0293 jetty=j121 jmx=localhost:19314
      metric received_bytes 5259 jetty=j121 jmx=localhost:19314
      metric sent_bytes 37333 jetty=j121 jmx=localhost:19314
      metric received_messages_count 57 jetty=j121 jmx=localhost:19314
      metric sent_messages_count 57 jetty=j121 jmx=localhost:19314
      metric limited 40 jetty=j121 jmx=localhost:19314
      metric limit 40 jetty=j121 jmx=localhost:19314
      metric limit_pending 0 jetty=j121 jmx=localhost:19314
      metric qos_max 16 jetty=j121 jmx=localhost:19314
      metric qos_suspended 24 jetty=j121 jmx=localhost:19314
      metric qos_exceeded_count 0 jetty=j121 jmx=localhost:19314
      metric qos_expired_count 0 jetty=j121 jmx=localhost:19314

    Reading the results (starting points: tune them to your Jetty):
      Healthy  open well below limit; limit_pending 0; qos_exceeded_count flat.
      Watch    open near limit; qos_suspended above 0: requests wait for the QoS
               handler.
      Act      limited at limit with limit_pending above 0: Jetty is not
               accepting more; qos_exceeded_count rising: requests refused.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _probe.jar,
      beside this script, once it matches its digest; Jetty's JMX
    Exit code: 0 on success, Jetty up or down (jmx_up says which); 1 if Java is
      missing, _probe.jar does not match its digest, or JMX refuses the login or
      its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'jetty_connections'

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
