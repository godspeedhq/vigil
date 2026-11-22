#Requires -Version 5.1

<#
.SYNOPSIS
    security.ps1 - a Kafka cluster's ACLs, users and quotas, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the ACLs by resource and permission, the ACLs that grant to every
    principal or every operation, the users with SCRAM credentials, and the
    quotas set. Counts only: never a principal's or a client's name. Read-only:
    it changes nothing in the cluster.

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
      authorizer           1 when the cluster checks ACLs, 0 when it has no
                           authorizer
      all_acls             ACLs
      any_principal_acls   ACLs for every principal (User:*)
      all_operations_acls  ACLs for every operation (ALL)
      acls                 ACLs, tagged resource=<topic, group, cluster, ...>
                           and permission=<allow or deny>
      scram_users          users with SCRAM credentials
      quotas               quotas set, tagged entity=<user or client>

    Example output (the rest are in the same form):
      metric authorizer 1
      metric all_acls 6
      metric any_principal_acls 0
      metric acls 2 resource=cluster permission=allow
      metric scram_users 1

    Reading the results (starting points: tune them to the cluster):
      Healthy  authorizer 1; all_acls and scram_users changing only when you
               change them.
      Watch    any_principal_acls or all_operations_acls above 0: check they are
               meant.
      Act      authorizer 0 on a cluster that should check ACLs; all_acls or
               scram_users changing when no one changed them.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _client.jar,
      beside this script, once it matches its digest (a copy of the pack without
      the jar runs _client.java, which needs a JDK); Kafka's library (KAFKA_HOME
      or KAFKA_LIBS); a user with the ACLs packs/README.md lists
    Exit code: 0 on success, or when the cluster does not answer; 1 if Java or
      Kafka's library is missing, _client.jar does not match its digest, or the
      cluster refuses the login or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'kafka_security'

# _client.jar's SHA-256, written when the pack was released: built from
# _client.java, beside it, by javac @CLIENT_JAR_JAVAC@ (tools/release/client-jar.sh).
$jarSha256 = '@CLIENT_JAR_SHA256@'

# The client, beside this script, run by Java 11 or later: JAVA_HOME's, else
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
    [Console]::Error.WriteLine("${job}: java not found: the kafka pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME")
    exit 1
}

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

# The jar, the client compiled, once it matches the digest above: any Java
# 11 or later runs it. A copy of the pack without one (from the repository,
# not a release) runs the source, which needs a JDK.
$jar = Join-Path $PSScriptRoot '_client.jar'
if (-not [System.IO.File]::Exists($jar)) {
    $client = @('-cp', (Join-Path $libs '*'), (Join-Path $PSScriptRoot '_client.java'))
}
else {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $f = [System.IO.File]::OpenRead($jar)
    try { $sum = -join ($sha.ComputeHash($f) | ForEach-Object { $_.ToString('x2') }) }
    finally { $f.Dispose(); $sha.Dispose() }
    if ($sum -ne $jarSha256) {
        [Console]::Error.WriteLine("${job}: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify kafka says what differs")
        exit 1
    }
    $client = @('-cp', ($jar + ';' + (Join-Path $libs '*')), 'KafkaClient')
}

# A folder of this run's own, for what Java writes while it runs: gone when
# the run ends.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-kafka.' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$code = 1
try {
    # A small JVM, quick to start, that keeps no counters of its own (the
    # jvm pack would find it among the JVMs it watches).
    & $java -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx256m "-Djava.io.tmpdir=$work" @client $job
    $code = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
