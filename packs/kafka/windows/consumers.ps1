#Requires -Version 5.1

<#
.SYNOPSIS
    consumers.ps1 - consumer group lag, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each consumer group's lag: how far its committed offsets are behind
    the end of each partition, summed and the worst partition, per group and
    topic; partitions with no committed offset; and each group's total.
    Read-only: it changes nothing in the cluster.

    Connects to KAFKA_BOOTSTRAP (host:port, comma-separated) through Kafka's
    admin API, as KAFKA_USER with the password in KAFKA_PASSWORD, set by the
    job: never on a command line, never in a file. KAFKA_SECURITY is PLAINTEXT,
    SSL, SASL_PLAINTEXT or SASL_SSL; KAFKA_SASL_MECHANISM SCRAM-SHA-512,
    SCRAM-SHA-256 or PLAIN. With TLS, the brokers' certificates are checked
    against KAFKA_CACERT, a PEM file of CAs, or Java's own, and against their
    names; KAFKA_CERT and KAFKA_KEY give a client certificate.
    KAFKA_CLIENT_CONFIG, a client properties file of your own, comes first, for
    a login this pack does not build (Kerberos, OAuth).

    Kafka's library is not in the pack: KAFKA_HOME, a Kafka download (its
    libs/), or KAFKA_LIBS, a folder of its jars, any kafka-clients from 3.x or
    4.x.

    Metrics:
      groups                groups with committed offsets
      total_lag             all groups' lag, in messages
      lag                   a group's lag on a topic, in messages, tagged
                            group=<name> and topic=<name> (at most 150 pairs)
      lag_max               its worst partition, tagged the same
      no_offset_partitions  partitions the group has no committed offset for,
                            tagged the same; left out when none
      pairs_not_shown       group and topic pairs past the first 150, left out
      group_lag             a group's lag on all its topics, tagged group=<name>
                            (at most 150)

    Example output (the rest are in the same form):
      metric groups 3
      metric lag 21387 group=billing topic=orders
      metric lag_max 4732 group=billing topic=orders
      metric lag 64 group=shipping topic=orders
      metric lag_max 64 group=shipping topic=orders
      metric lag 700 group=vigil_it_billing_684283 topic=vigil_it_orders_684283
      metric lag_max 294 group=vigil_it_billing_684283 topic=vigil_it_orders_684283
      metric total_lag 22151

    Reading the results (starting points: tune them to the cluster):
      Healthy  lag steady or falling: consumers keep up.
      Watch    lag rising for minutes: consumers fall behind; lag_max far above
               lag divided by partitions: one partition is stuck, or one
               consumer is slow.
      Act      lag rising with the group empty (kafka_groups): nothing consumes;
               lag near what retention keeps: consumers are about to lose
               messages they never read.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _client.jar and
      _probe.jar, beside this script, once they match their digests; Kafka's
      library (KAFKA_HOME or KAFKA_LIBS); a user with the ACLs packs/README.md
      lists
    Exit code: 0 on success, or when the cluster does not answer; 1 if Java or
      Kafka's library is missing, _client.jar does not match its digest, or the
      cluster refuses the login or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'kafka_consumers'

# The jars' SHA-256s, written when the pack was released: each built from
# its source, beside it, by javac @PROBE_JAR_JAVAC@ (tools/release/client-jar.sh).
$probeSha256 = '@PROBE_JAR_SHA256@'
$clientSha256 = '@CLIENT_JAR_SHA256@'
# The jars, beside this script, run by Java 11 or later: JAVA_HOME's, else
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
    [Console]::Error.WriteLine("${job}: java not found: the kafka pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME")
    exit 1
}

# A jar is run only once it matches its digest.
function Test-Jar {
    param([string]$Jar, [string]$Want)
    $n = [System.IO.Path]::GetFileName($Jar)
    if (-not [System.IO.File]::Exists($Jar)) {
        [Console]::Error.WriteLine("${job}: ${n} not found: this copy of the pack has none: install the pack from a packs release (vigil pack install kafka), or build it (tools/release/client-jar.sh)")
        exit 1
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $f = [System.IO.File]::OpenRead($Jar)
    try { $sum = -join ($sha.ComputeHash($f) | ForEach-Object { $_.ToString('x2') }) }
    finally { $f.Dispose(); $sha.Dispose() }
    if ($sum -ne $Want) {
        [Console]::Error.WriteLine("${job}: $n does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify kafka says what differs")
        exit 1
    }
}
$probe = Join-Path $PSScriptRoot '_probe.jar'
Test-Jar $probe $probeSha256
$client = Join-Path $PSScriptRoot '_client.jar'
Test-Jar $client $clientSha256

# Kafka's library, the user's: KAFKA_LIBS, else a Kafka download's libs\.
$libs = $env:KAFKA_LIBS
if (-not $libs -and $env:KAFKA_HOME) { $libs = Join-Path $env:KAFKA_HOME 'libs' }
if (-not $libs) {
    [Console]::Error.WriteLine("${job}: no Kafka library: set KAFKA_HOME to a Kafka download, or KAFKA_LIBS to a folder of its jars")
    exit 1
}
if (-not [System.IO.Directory]::Exists($libs) -or @([System.IO.Directory]::GetFiles($libs, 'kafka-clients-*.jar')).Count -eq 0) {
    [Console]::Error.WriteLine("${job}: no kafka-clients-*.jar in ${libs}: KAFKA_HOME is a Kafka download (its libs\), KAFKA_LIBS a folder of its jars")
    exit 1
}
$run = @('-cp', ($client + ';' + $probe + ';' + (Join-Path $libs '*')), 'KafkaClient')

# A folder of this run's own, for what Java writes while it runs: gone when
# the run ends.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-kafka.' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$code = 1
try {
    # A small JVM, quick to start, that keeps no counters of its own (the
    # jvm pack would find it among the JVMs it watches).
    & $java -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx256m "-Djava.io.tmpdir=$work" @run $job
    $code = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
