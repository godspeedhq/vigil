# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""Writes the obs packs (tools/obs/DESIGN.md): the packs that watch a
monitoring stack. For each: pack.config; for Linux and macOS, _<pack>.sh
(lib.sh, what the scripts share) and each job's bash script; for Windows,
_<pack>.ps1 (lib.ps1) and each job's script. The jobs are in <pack>.py; each
job's example output in examples-<pack>.txt. Run from the repository:
py tools/obs/gen.py . (OBS_GEN_DRAFT=1 allows a job with no example yet)."""
import importlib
import os
import sys
import textwrap

repo = sys.argv[1]
src = os.path.join(repo, 'tools', 'obs')
sys.path.insert(0, src)
import jobs  # noqa: E402

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

ORDER = ['prometheus', 'alertmanager', 'grafana', 'loki', 'mimir', 'tempo', 'otelcol', 'victoriametrics', 'victorialogs']
PACKS = {}
for name in ORDER:
    if os.path.exists(os.path.join(src, name + '.py')):
        PACKS[name] = importlib.import_module(name).PACK


def subst(text, p):
    d = PACKS[p]
    return text.replace('@P@', d['P']).replace('@E@', d['E']).replace('@p@', p).replace('@URL@', d['url'])


def wrap(text, width, first='', rest=''):
    return textwrap.wrap(text, width, initial_indent=first, subsequent_indent=rest, break_on_hyphens=False) or [first]


def metrics_doc(metrics):
    w = max(len(n) for n, _ in metrics) + 2
    lines = []
    for n, d in metrics:
        lines += wrap(d, 76, first=('  ' + n).ljust(2 + w), rest=' ' * (2 + w))
    return lines


def examples(p):
    ex, cur = {}, None
    path = os.path.join(src, 'examples-%s.txt' % p)
    if not os.path.exists(path):
        return ex
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if line.startswith('== '):
            cur = line[3:].strip()
            ex[cur] = []
        elif cur and line and not line.startswith('#'):
            ex[cur].append(line)
    return ex


def doc(j, p, ex, ps):
    c = []
    c += wrap(subst(j['what'], p) + ' It only reads: every request is a GET, and it changes nothing.', 76)
    c += ['']
    c += wrap(subst(j['reads'], p), 76)
    c += wrap(subst("What the scripts share is in _@p@.%s, beside this one." % ('ps1' if ps else 'sh'), p), 76)
    c += ['', 'Metrics:']
    c += metrics_doc([(n, subst(t, p)) for n, t in jobs.metrics_of(j)])
    e = ex.get(j['job'])
    if not e:
        if os.environ.get('OBS_GEN_DRAFT') != '1':
            sys.exit('no example output for %s in tools/obs/examples-%s.txt' % (j['job'], p))
        e = ['(draft: no example yet)']
    c += ['', 'Example output (the rest are in the same form):']
    c += ['  ' + x for x in e]
    c += ['', 'Reading the results (starting points: tune them to your own):']
    c += wrap(subst(j['healthy'], p), 76, first='  Healthy  ', rest=' ' * 11)
    c += wrap(subst(j['watch'], p), 76, first='  Watch    ', rest=' ' * 11)
    c += wrap(subst(j['act'], p), 76, first='  Act      ', rest=' ' * 11)
    c += ['']
    c += [('Requires: Windows PowerShell 5.1 or PowerShell 7' if ps else 'Requires: ' + ', '.join(['bash'] + j['needs_sh']))]
    c += wrap(subst('Exit code: ' + (j['exit_ps'] if ps else j['exit_sh']), p), 76, rest='  ')
    return c


def rows_text(rows):
    return '\n'.join(line for line, _ in rows)


def sh_body(j):
    out = []
    n = 0
    for s in j['steps']:
        if s[0] == 'page':
            out.append("page '%s'" % s[1])
        elif s[0] == 'answers':
            out.append("answers %s '%s'" % (s[1], s[2]))
        elif s[0] == 'table':
            out.append("readings <<'T'\n%s\nT" % rows_text(s[1]))
        elif s[0] == 'extra':
            n += 1
            out.append("if get '%s' extra%d; then\nreadings \"$work/extra%d\" <<'T'\n%s\nT\nfi" % (s[1], n, n, rows_text(s[2])))
        elif s[0] == 'code':
            out.append(s[1].rstrip('\n'))
    return '\n'.join(out) + '\nexit 0\n'


def ps_body(j):
    out = []
    n = 0
    for s in j['steps']:
        if s[0] == 'page':
            out.append("Read-Page '%s'" % s[1])
        elif s[0] == 'answers':
            out.append("Test-Answers '%s' '%s'" % (s[1], s[2]))
        elif s[0] == 'table':
            out.append("Get-Readings @'\n%s\n'@" % rows_text(s[1]))
        elif s[0] == 'extra':
            n += 1
            out.append("$extra%d = Get-Extra '%s'\nif ($null -ne $extra%d) {\n    Get-Readings @'\n%s\n'@ $extra%d\n}" %
                       (n, s[1], n, rows_text(s[2]), n))
        elif s[0] == 'code':
            out.append(s[2].rstrip('\n'))
    return '\n'.join(out) + '\nexit 0\n'


def sh_script(j, p, ex):
    head = ['#!/usr/bin/env bash', '#', '# %s.sh - %s' % (j['job'], subst(j['title'], p)), '#']
    head += [('# ' + n).rstrip() for n in NOTICE] + ['#']
    head += [('# ' + l).rstrip() for l in doc(j, p, ex, False)]
    need = ' '.join(j['needs_sh'])
    body = ('set -u\n\njob=%s\n# shellcheck source=/dev/null\n. "$(dirname "$0")/_%s.sh"\n' % (j['job'], p) +
            ('needs %s\n' % need if need else '') + '\n' + subst(sh_body(j), p))
    return '\n'.join(head) + '\n\n' + body


def ps_script(j, p, ex):
    head = ['#Requires -Version 5.1', '', '<#', '.SYNOPSIS',
            '    %s.ps1 - %s, on Windows' % (j['job'], subst(j['title'], p)), '.NOTES']
    head += [('    ' + n).rstrip() for n in NOTICE]
    head += ['.DESCRIPTION']
    head += [('    ' + l).rstrip() for l in doc(j, p, ex, True)]
    head += ['#>']
    body = ("$Job = '%s'\n. (Join-Path $PSScriptRoot '_%s.ps1')\n\n" % (j['job'], p)) + subst(ps_body(j), p)
    return '\n'.join(head) + '\n\n' + body


def lib(name, p):
    t = open(os.path.join(src, name), encoding='utf-8').read()
    if name.endswith('.sh'):
        t = t.replace('@NOTICE@', '\n'.join(('# ' + n).rstrip() for n in NOTICE))
    else:
        t = t.replace('@NOTICE@', '\n'.join(('    ' + n).rstrip() for n in NOTICE))
    return subst(t, p)


def pack_config(p, js):
    d = PACKS[p]
    c = ['# ' + l for l in d['head']]
    c += ['# ' + l for l in textwrap.wrap('Linux, macOS and Windows. See SPECIFICATION.md section 18.10 for this format, '
                                          'and tools/obs/DESIGN.md.', 74)]
    c += ['#', '# It only reads: every request is a GET, and it changes nothing on the server.',
          '#', '# Off until enabled: vigil pack enable %s (or one job: vigil pack enable %s_<job>).' % (p, p),
          '# Each job\'s settings are its env lines.', '#']
    c += [('# ' + n).rstrip() for n in NOTICE]
    progs = sorted({x for j in js for x in ['bash'] + j['needs_sh']}, key=lambda x: (x != 'bash', x))
    c += ['',
          '[pack]',
          'version     = ' + d['version'],
          '# vigil: the oldest Vigil this pack runs on. vigil pack update refuses the',
          '# pack on an older one.',
          'vigil       = 0.3.0',
          'description = ' + d['description'],
          '# What vigil pack info shows besides: the servers it is meant for, the',
          '# programs its scripts need on each platform, and where it is explained.',
          'works_with  = ' + d['works'],
          'programs_linux = ' + ', '.join(progs),
          'programs_macos = ' + ', '.join(progs),
          'programs_windows = PowerShell 5.1 or later',
          'docs        = https://github.com/godspeedhq/vigil/blob/main/packs/%s/README.md' % p]
    c += ['needs       = ' + subst(n, p) for n in d['needs']]
    c += ['']
    for j in js:
        c += ['[job.%s]' % j['job'],
              'metric_name = %s' % (p + ('.' + j['metric'] if j['metric'] else '')),
              'metrics     = %s' % ', '.join(n for n, _ in jobs.metrics_of(j)),
              j['when'],
              'max_runtime = %s' % j['runtime'],
              'env         = %s_URL=' % d['E'],
              'env         = %s_USER=' % d['E'],
              'env         = %s_CACERT=' % d['E']]
        c += ['env         = %s=%s' % (subst(k, p), v) for k, v in j['env']]
        # What the job cannot run without, from Vigil's secret store.
        c += ['secret      = %s=secret:%s' % (subst(k, p), subst(k, p)) for k in j['secrets']]
        c += ['']
    return '\n'.join(c).rstrip('\n') + '\n'


only = sys.argv[2:] or list(PACKS)
for p in only:
    js = [j for j in jobs.JOBS if j['pack'] == p]
    out = os.path.join(repo, 'packs', p)
    ex = examples(p)
    for os_ in ('linux', 'macos', 'windows'):
        if os.path.isdir(os.path.join(out, os_)):
            for f in os.listdir(os.path.join(out, os_)):
                os.remove(os.path.join(out, os_, f))
        os.makedirs(os.path.join(out, os_), exist_ok=True)
    sh_lib = lib('lib.sh', p)
    for os_ in ('linux', 'macos'):
        open(os.path.join(out, os_, '_%s.sh' % p), 'w', encoding='utf-8', newline='\n').write(sh_lib)
    open(os.path.join(out, 'windows', '_%s.ps1' % p), 'w', encoding='utf-8', newline='\n').write(lib('lib.ps1', p))
    for j in js:
        s = sh_script(j, p, ex)
        for os_ in ('linux', 'macos'):
            open(os.path.join(out, os_, j['job'] + '.sh'), 'w', encoding='utf-8', newline='\n').write(s)
        open(os.path.join(out, 'windows', j['job'] + '.ps1'), 'w', encoding='utf-8', newline='\n').write(ps_script(j, p, ex))
    open(os.path.join(out, 'pack.config'), 'w', encoding='utf-8', newline='\n').write(pack_config(p, js))
    print('%s: %d jobs, %d metrics' % (p, len(js), sum(len(jobs.metrics_of(j)) for j in js)))
