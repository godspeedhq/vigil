#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - a Kafka cluster's health, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports whether the cluster answers, its id, whether it runs on KRaft or
    ZooKeeper, its brokers and how many are fenced, and which node is the active
    controller. Read-only: it changes nothing in the cluster.

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
      up              1 when the cluster answers, else 0
      info            always 1, tagged cluster_id=<its id> and kraft=<yes or no>
      brokers         brokers the cluster lists
      brokers_fenced  of those, brokers fenced: registered, but not serving
      controller_id   the node that is the active controller (KRaft)

    Example output (the rest are in the same form):
      metric up 1
      metric info 1 cluster_id=MkU3OEVBNTcwNTJENDM2Qg kraft=yes
      metric brokers 3
      metric brokers_fenced 0
      metric controller_id 2

    Reading the results (starting points: tune them to the cluster):
      Healthy  up 1; brokers steady at as many as you run; brokers_fenced 0.
      Watch    controller_id changing often: the controllers keep electing a new
               leader.
      Act      up 0; brokers below what you run: a broker is down;
               brokers_fenced above 0 for minutes.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _client.jar and
      _probe.jar, beside this script, once they match their digests; Kafka's
      library (KAFKA_HOME or KAFKA_LIBS); a user with the ACLs packs/README.md
      lists
    Exit code: 0 on success, cluster up or down; 1 if Java or Kafka's library is
      missing, _client.jar does not match its digest, or the cluster refuses the
      login or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'kafka_status'

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
