#Requires -Version 5.1

<#
.SYNOPSIS
    jdbc.ps1 - a Tomcat's database connection pools, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each connection pool Tomcat makes from a Resource (DBCP, Tomcat's
    default, and Tomcat's JDBC pool) and HikariCP's when it registers its
    MBeans: connections in use, idle and at most; for Tomcat's JDBC pool,
    threads waiting for one and the connections borrowed, returned, created,
    released and abandoned. A pool at its most makes requests wait. Read-only:
    it reads attributes over JMX, and changes nothing.

    Reads each Tomcat's JMX, at TOMCAT_JMX: jmx=host:port, or jmxs=host:port
    over TLS, separated by ; or , each with a name first if you like (web1:
    jmxs=host:port); with TOMCAT_JMX_USER and the password in
    TOMCAT_JMX_PASSWORD when JMX asks for them; a certificate is checked against
    TOMCAT_CACERT, a PEM file of CAs, or Java's own, and against the server's
    name. With no TOMCAT_JMX, it prints nothing. Tomcat's JVM (heap, garbage
    collection, threads, CPU, open files) is the jvm pack's, not this one's.

    The probe (_probe.jar, tools/probe) reads it, from this pack's
    _probe.tables, beside this script: nothing of Tomcat's is needed here.

    Metrics:
      jmx_up                       1 when JMX answers, else 0, tagged
                                   tomcat=<its name> and jmx=<its address>
      active                       connections in use, tagged context=<the app,
                                   or none for a global one> and name=<its JNDI
                                   name>
      idle                         connections idle in the pool, tagged the same
      max                          the most it may open (DBCP maxTotal, the JDBC
                                   pool maxActive), tagged the same
      max_idle                     the most it keeps idle, tagged the same
      min_idle                     the fewest it keeps idle, tagged the same
      max_wait_seconds             how long a request waits for a connection
                                   before it fails, tagged the same
      size                         connections open, in use or idle (the JDBC
                                   pool), tagged the same
      waiting                      threads waiting for a connection now (the
                                   JDBC pool), tagged the same
      borrowed_count               connections taken from it (the JDBC pool),
                                   tagged the same
      returned_count               connections given back (the JDBC pool),
                                   tagged the same
      created_count                connections opened (the JDBC pool), tagged
                                   the same
      released_count               connections closed (the JDBC pool), tagged
                                   the same
      abandoned_count              connections taken back from code that never
                                   returned them (the JDBC pool,
                                   removeAbandoned), tagged the same
      reconnected_count            connections reopened (the JDBC pool), tagged
                                   the same
      hikari_active                a HikariCP pool's connections in use, tagged
                                   type=<Pool (its name)>
      hikari_idle                  its connections idle, tagged the same
      hikari_total                 its connections open, tagged the same
      hikari_waiting               threads waiting for one of its connections,
                                   tagged the same
      active_not_shown             of active, those past the first 100, left out
      idle_not_shown               of idle, those past the first 100, left out
      max_not_shown                of max, those past the first 100, left out
      max_idle_not_shown           of max_idle, those past the first 100, left
                                   out
      min_idle_not_shown           of min_idle, those past the first 100, left
                                   out
      max_wait_seconds_not_shown   of max_wait_seconds, those past the first
                                   100, left out
      size_not_shown               of size, those past the first 100, left out
      waiting_not_shown            of waiting, those past the first 100, left
                                   out
      borrowed_count_not_shown     of borrowed_count, those past the first 100,
                                   left out
      returned_count_not_shown     of returned_count, those past the first 100,
                                   left out
      created_count_not_shown      of created_count, those past the first 100,
                                   left out
      released_count_not_shown     of released_count, those past the first 100,
                                   left out
      abandoned_count_not_shown    of abandoned_count, those past the first 100,
                                   left out
      reconnected_count_not_shown
                                   of reconnected_count, those past the first
                                   100, left out
      hikari_active_not_shown      of hikari_active, those past the first 100,
                                   left out
      hikari_idle_not_shown        of hikari_idle, those past the first 100,
                                   left out
      hikari_total_not_shown       of hikari_total, those past the first 100,
                                   left out
      hikari_waiting_not_shown     of hikari_waiting, those past the first 100,
                                   left out

    Example output (the rest are in the same form):
      metric jmx_up 1 tomcat=tc11 jmx=localhost:19303
      metric active 4 tomcat=tc11 jmx=localhost:19303 context=/shop name=jdbc/orders
      metric idle 0 tomcat=tc11 jmx=localhost:19303 context=/shop name=jdbc/orders
      metric max 4 tomcat=tc11 jmx=localhost:19303 context=/shop name=jdbc/shop
      metric max_idle 2 tomcat=tc11 jmx=localhost:19303 context=/shop name=jdbc/orders
      metric min_idle 0 tomcat=tc11 jmx=localhost:19303 context=/shop name=jdbc/orders
      metric max_wait_seconds 1 tomcat=tc11 jmx=localhost:19303 context=/shop name=jdbc/shop
      metric size 4 tomcat=tc11 jmx=localhost:19303 context=/shop name=jdbc/orders
      metric waiting 0 tomcat=tc11 jmx=localhost:19303 context=/shop name=jdbc/orders
      metric borrowed_count 4 tomcat=tc11 jmx=localhost:19303 context=/shop name=jdbc/orders
      metric returned_count 0 tomcat=tc11 jmx=localhost:19303 context=/shop name=jdbc/orders
      metric created_count 4 tomcat=tc11 jmx=localhost:19303 context=/shop name=jdbc/orders
      metric released_count 0 tomcat=tc11 jmx=localhost:19303 context=/shop name=jdbc/orders
      metric abandoned_count 0 tomcat=tc11 jmx=localhost:19303 context=/shop name=jdbc/orders

    Reading the results (starting points: tune them to your Tomcat):
      Healthy  active well below max; waiting and hikari_waiting 0;
               abandoned_count flat.
      Watch    active at max now and then; waiting above 0: requests queue for a
               connection.
      Act      active at max and waiting above 0 for minutes: requests fail
               after max_wait_seconds. Either the database is slow or code keeps
               connections (abandoned_count rising says code leaks them).

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _probe.jar,
      beside this script, once it matches its digest; Tomcat's JMX
    Exit code: 0 on success, Tomcat up or down (jmx_up says which); 1 if Java is
      missing, _probe.jar does not match its digest, or JMX refuses the login or
      its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'tomcat_jdbc'

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
    [Console]::Error.WriteLine("${job}: java not found: the tomcat pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME")
    exit 1
}

# The jar is run only once it matches its digest.
$probe = Join-Path $PSScriptRoot '_probe.jar'
if (-not [System.IO.File]::Exists($probe)) {
    [Console]::Error.WriteLine("${job}: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install tomcat), or build it (tools/release/client-jar.sh)")
    exit 1
}
$sha = [System.Security.Cryptography.SHA256]::Create()
$f = [System.IO.File]::OpenRead($probe)
try { $sum = -join ($sha.ComputeHash($f) | ForEach-Object { $_.ToString('x2') }) }
finally { $f.Dispose(); $sha.Dispose() }
if ($sum -ne $probeSha256) {
    [Console]::Error.WriteLine("${job}: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify tomcat says what differs")
    exit 1
}

# A folder of this run's own, for what Java writes while it runs: gone when
# the run ends.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-tomcat.' + [guid]::NewGuid().ToString('N'))
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
