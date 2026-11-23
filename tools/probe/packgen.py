# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""A pack that is only tables for the probe (tools/probe/DESIGN.md), written
from one description: its jobs, each a list of rows. From it, packgen writes
packs/<name>/: pack.config, the tables (_probe.tables), each job's script
for Linux and macOS (bash) and Windows (PowerShell), and _probe.java, as
every pack that carries the probe has it. The rows are written once, so
the tables, the metrics pack.config lists and each script's header always
agree. A pack's tools/<name>/gen.py describes it and calls write();
tools/<name>/examples.txt holds each job's real output, for its header.

A row: (metric, MBean, attribute, words, what it is). The words are the
probe's (tags, +tag=value, -key=pattern, =STATE, @tag, *n, >=n, sum, top,
age); a row whose MBean is a pattern may print <metric>_not_shown too."""
import os
import sys
import textwrap

NOTICE = [
    'Copyright (c) Bankole Ogundero and the Vigil contributors',
    'SPDX-License-Identifier: Apache-2.0',
    '',
    'Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or',
    'implied. Run it at your own risk: review it first, and test it before you',
    'rely on it. In no event shall the authors or copyright holders be liable',
    'for any claim, damages or other liability arising from its use. See the',
    'LICENSE file for the full terms.',
]

READONLY = "Read-only: it reads attributes over JMX, and changes nothing."


def wrap(text, width, first='', rest=''):
    return textwrap.wrap(text, width, initial_indent=first, subsequent_indent=rest, break_on_hyphens=False) or [first]


def is_pattern(mbean):
    return '*' in mbean or '?' in mbean


def metrics_of(p, j):
    """The job's metrics, in order, each once: jmx_up, each row's, and
    <metric>_not_shown for a row of many MBeans."""
    out = [('jmx_up', '1 when JMX answers, else 0, tagged %s=<its name> and jmx=<its address>' % p['tag'])]
    seen = {'jmx_up'}
    for r in j['rows']:
        if r[0] not in seen:
            out.append((r[0], r[4]))
            seen.add(r[0])
    for r in j['rows']:
        n = r[0] + '_not_shown'
        if is_pattern(r[1]) and n not in seen:
            out.append((n, 'of %s, those past the first 100, left out%s' % (
                r[0], ' (the largest are shown)' if 'top' in r[3].split() or any(
                    'top' in x[3].split() for x in j['rows'] if x[1] == r[1]) else '')))
            seen.add(n)
    return out


def metrics_doc(metrics):
    w = min(max(len(n) for n, _ in metrics) + 2, 30)
    lines = []
    for n, d in metrics:
        if len(n) + 2 >= w:
            lines += ['  ' + n]
            lines += wrap(d, 76, first=' ' * (2 + w), rest=' ' * (2 + w))
        else:
            lines += wrap(d, 76, first=('  ' + n).ljust(2 + w), rest=' ' * (2 + w))
    return lines


def examples(src):
    """Each job's example output: examples.txt, '== job' then lines."""
    ex, cur = {}, None
    path = os.path.join(src, 'examples.txt')
    if not os.path.exists(path):
        return ex
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if line.startswith('#') and cur is None:
            continue
        if line.startswith('== '):
            cur = line[3:].strip()
            ex[cur] = []
        elif cur and line:
            ex[cur].append(line)
    return ex


def doc(p, j, ps, ex):
    c = wrap(j['what'] + ' ' + READONLY, 76) + ['']
    c += wrap(p['jmx_doc'], 76) + ['']
    c += wrap("The probe (_probe.jar, tools/probe) reads it, from this pack's _probe.tables, beside this script: "
              "nothing of %s's is needed here." % p['product'], 76)
    c += ['', 'Metrics:'] + metrics_doc(metrics_of(p, j))
    lines = ex.get(j['job'])
    if not lines:
        # <NAME>_GEN_DRAFT=1: scripts to run, before their real output is in.
        if os.environ.get(p['name'].upper() + '_GEN_DRAFT') != '1':
            sys.exit('no example output for %s in tools/%s/examples.txt' % (j['job'], p['name']))
        lines = ['(draft: no example yet)']
    c += ['', 'Example output (the rest are in the same form):'] + ['  ' + e for e in lines]
    c += ['', 'Reading the results (starting points: tune them to your %s):' % p['what_tuned']]
    c += wrap(j['healthy'], 76, first='  Healthy  ', rest=' ' * 11)
    c += wrap(j['watch'], 76, first='  Watch    ', rest=' ' * 11)
    c += wrap(j['act'], 76, first='  Act      ', rest=' ' * 11)
    c += ['']
    c += wrap(('Requires: Windows PowerShell 5.1 or PowerShell 7, ' if ps else 'Requires: bash, ') +
              "Java 11 or later (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _probe.jar, beside this "
              "script, once it matches its digest; %s's JMX" % p['product'], 76, rest='  ')
    c += wrap("Exit code: 0 on success, %s up or down (jmx_up says which); 1 if Java is missing, _probe.jar does "
              "not match its digest, or JMX refuses the login or its certificate" % p['product'], 76, rest='  ')
    return c


SH = r"""set -u

# The probe's SHA-256, written when the pack was released: built from
# _probe.java, beside it, by javac @PROBE_JAR_JAVAC@ (tools/release/client-jar.sh).
probe_sha256=@PROBE_JAR_SHA256@

# The probe, beside this script, run by Java 11 or later: JAVA_HOME's, else
# the PATH's.
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    java=$JAVA_HOME/bin/java
elif command -v java > /dev/null 2>&1; then
    java=$(command -v java)
else
    echo "@JOB@: java not found: the @PACK@ pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "@JOB@: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install @PACK@), or build it (tools/release/client-jar.sh)" >&2
    exit 1
fi
if command -v sha256sum > /dev/null 2>&1; then
    sum=$(sha256sum < "$here/_probe.jar")
elif command -v shasum > /dev/null 2>&1; then
    sum=$(shasum -a 256 < "$here/_probe.jar")
else
    sum=$(openssl dgst -sha256 -r < "$here/_probe.jar")
fi
if [ "${sum%% *}" != "$probe_sha256" ]; then
    echo "@JOB@: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify @PACK@ says what differs" >&2
    exit 1
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-@PACK@.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (the jvm
# pack would find it among the JVMs it watches). The probe reads this job's
# table.
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" @JOB@
exit $?
"""

PS = r"""$ErrorActionPreference = 'Stop'
$job = '@JOB@'

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
    [Console]::Error.WriteLine("${job}: java not found: the @PACK@ pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME")
    exit 1
}

# The jar is run only once it matches its digest.
$probe = Join-Path $PSScriptRoot '_probe.jar'
if (-not [System.IO.File]::Exists($probe)) {
    [Console]::Error.WriteLine("${job}: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install @PACK@), or build it (tools/release/client-jar.sh)")
    exit 1
}
$sha = [System.Security.Cryptography.SHA256]::Create()
$f = [System.IO.File]::OpenRead($probe)
try { $sum = -join ($sha.ComputeHash($f) | ForEach-Object { $_.ToString('x2') }) }
finally { $f.Dispose(); $sha.Dispose() }
if ($sum -ne $probeSha256) {
    [Console]::Error.WriteLine("${job}: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify @PACK@ says what differs")
    exit 1
}

# A folder of this run's own, for what Java writes while it runs: gone when
# the run ends.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-@PACK@.' + [guid]::NewGuid().ToString('N'))
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
"""


def sh_script(p, j, ex):
    head = ['#!/usr/bin/env bash', '#', '# %s.sh - %s' % (j['job'], j['title']), '#']
    head += [('# ' + n).rstrip() for n in NOTICE] + ['#']
    head += [('# ' + l).rstrip() for l in doc(p, j, False, ex)]
    body = SH.replace('@JOB@', p['name'] + '_' + j['job']).replace('@PACK@', p['name'])
    return '\n'.join(head) + '\n\n' + body


def ps_script(p, j, ex):
    head = ['#Requires -Version 5.1', '', '<#', '.SYNOPSIS', '    %s.ps1 - %s, on Windows' % (j['job'], j['title']), '.NOTES']
    head += [('    ' + n).rstrip() for n in NOTICE]
    head += ['.DESCRIPTION'] + [('    ' + l).rstrip() for l in doc(p, j, True, ex)] + ['#>']
    body = PS.replace('@JOB@', p['name'] + '_' + j['job']).replace('@PACK@', p['name'])
    return '\n'.join(head) + '\n\n' + body


def tables(p):
    s = p['name'].upper()
    t = ['# _probe.tables - the %s pack\'s jobs, as tables the probe reads' % p['name'],
         '# (tools/probe/DESIGN.md), written by tools/%s/gen.py: edit that, not this.' % p['name'],
         '# A row: metric, MBean, attribute, then tags from the MBean\'s name (key/',
         '# for its value after the last /), +tag=value, -key=pattern, =STATE, @tag,',
         '# *scale, >=floor, sum, top, age. An MBean a server does not have prints',
         '# nothing.', '#']
    t += [('# ' + n).rstrip() for n in NOTICE] + ['']
    t += ['targets   %s_JMX' % s, 'user      %s_JMX_USER' % s, 'password  %s_JMX_PASSWORD' % s, 'cacert    %s_CACERT' % s]
    t += ['# ' + l for l in wrap(p['name_doc'], 74)]
    t += ['name      ' + p['name_row']]
    for j in p['jobs']:
        t += ['', '[%s]' % j['job']]
        w0 = max(len(r[0]) for r in j['rows'])
        w1 = max(len(r[1]) for r in j['rows'])
        w2 = max(len(r[2]) for r in j['rows'])
        for r in j['rows']:
            t.append((r[0].ljust(w0) + '  ' + r[1].ljust(w1) + '  ' + r[2].ljust(w2) + '  ' + r[3]).rstrip())
    return '\n'.join(t) + '\n'


def pack_config(p):
    s = p['name'].upper()
    c = [('# ' + l).rstrip() for l in p['config_head']] + ['#']
    c += [('# ' + n).rstrip() for n in NOTICE]
    c += ['', '[pack]', 'version     = %s' % p['version'],
          '# vigil: the oldest Vigil this pack runs on. vigil pack update refuses the',
          '# pack on an older one.',
          'vigil       = 0.3.0',
          'description = %s' % p['description'],
          '# What vigil pack info shows besides: the servers it is meant for, the',
          '# programs its scripts need on each platform, and where it is explained.',
          'works_with  = %s' % p['works_with']]
    for o in ('linux', 'macos', 'windows'):
        c += ['programs_%s = Java 11 or later, a JDK or a JRE, to run the probe' % o]
    c += ['docs        = https://github.com/godspeedhq/vigil/blob/main/packs/README.md#%s' % p['name']]
    c += ['needs       = %s' % n for n in p['needs']]
    c += ['']
    for j in p['jobs']:
        c += ['[job.%s]' % j['job'],
              'metric_name = %s' % j['metric_name'],
              'metrics     = %s' % ', '.join(n for n, _ in metrics_of(p, j)),
              j['when'],
              'max_runtime = %s' % j.get('max_runtime', '90s'),
              'env         = %s_JMX=' % s,
              'env         = %s_JMX_USER=' % s,
              'env         = %s_CACERT=' % s, '']
    return '\n'.join(c).rstrip('\n') + '\n'


def write(repo, p):
    src = os.path.join(repo, 'tools', p['name'])
    out = os.path.join(repo, 'packs', p['name'])
    ex = examples(src)
    files = {'_probe.java': open(os.path.join(repo, 'tools', 'probe', '_probe.java'), encoding='utf-8').read(),
             '_probe.tables': tables(p)}
    names = [j['job'] for j in p['jobs']]
    for d in ('linux', 'macos', 'windows'):
        os.makedirs(os.path.join(out, d), exist_ok=True)
        for f in os.listdir(os.path.join(out, d)):
            if f.endswith(('.sh', '.ps1')) and f.rsplit('.', 1)[0] not in names:
                os.remove(os.path.join(out, d, f))
        for f, text in files.items():
            open(os.path.join(out, d, f), 'w', encoding='utf-8', newline='\n').write(text)
    open(os.path.join(out, 'pack.config'), 'w', encoding='utf-8', newline='\n').write(pack_config(p))
    for j in p['jobs']:
        s = sh_script(p, j, ex)
        for d in ('linux', 'macos'):
            open(os.path.join(out, d, j['job'] + '.sh'), 'w', encoding='utf-8', newline='\n').write(s)
        open(os.path.join(out, 'windows', j['job'] + '.ps1'), 'w', encoding='utf-8', newline='\n').write(ps_script(p, j, ex))
    n = sum(len(metrics_of(p, j)) for j in p['jobs'])
    print('wrote %d jobs, %d metrics' % (len(p['jobs']), n))
