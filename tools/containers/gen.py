#!/usr/bin/env python3
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""gen.py - writes the docker and podman packs' scripts and pack.config.

  py tools/containers/gen.py <repository> [<pack>]

A job is its body (tools/containers/<pack>/<linux|windows>/<job>.body), under
a header made here from spec.py: what it reads, every metric, an example
(tools/containers/examples/<pack>.<job>.txt, as the job printed it against
the tests' containers), and how to read the results. The Linux scripts are
the macOS ones too. Each pack's library (_<pack>.sh, _<pack>.ps1) is copied
as it is. The pack's page (packs/<pack>/README.md) is written by hand; its
grid by tools/pack-grid.py.
"""
import os
import sys
import textwrap

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import spec  # noqa: E402

NOTICE = '''Copyright (c) Bankole Ogundero and the Vigil contributors
SPDX-License-Identifier: Apache-2.0

Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
implied. Run it at your own risk: review it first, and test it before you
rely on it. In no event shall the authors or copyright holders be liable
for any claim, damages or other liability arising from its use. See the
LICENSE file for the full terms.'''


def wrap(text, width, first='', rest=''):
    return textwrap.wrap(text, width, initial_indent=first, subsequent_indent=rest, break_long_words=False, break_on_hyphens=False)


def read(*parts):
    return open(os.path.join(here, *parts), encoding='utf-8', newline='').read().replace('\r\n', '\n')


def example(pack, job):
    p = os.path.join(here, 'examples', '%s.%s.txt' % (pack, job))
    if not os.path.exists(p):
        if os.environ.get('CONTAINERS_GEN_DRAFT'):
            return ['metric up 1']
        sys.exit('no example for %s %s: %s' % (pack, job, p))
    return [l for l in read('examples', '%s.%s.txt' % (pack, job)).split('\n') if l.strip()]


def doc(pack, job, j, width, how, requires, exits):
    """The header's text, without comment marks."""
    names = [m[0] for m in j['metrics']]
    pad = max(len(n) for n in names) + 3
    out = []
    for para in j['about']:
        out += wrap(para, width) + ['']
    out += wrap(how, width) + ['']
    out.append('Metrics:')
    for name, text in j['metrics']:
        out += wrap(text, width, '  ' + name.ljust(pad), '  ' + ' ' * pad)
    out += ['', 'Example output:'] + ['  ' + l for l in example(pack, job)]
    out += ['', 'Reading the results (starting points: tune them to the machine):']
    for key in ('Healthy', 'Watch', 'Act'):
        out += wrap(j['reading'][key], width, '  ' + key.ljust(9), '  ' + ' ' * 9)
    out += ['', 'Requires: ' + requires]
    out += wrap('Exit code: ' + exits, width, '', '  ')
    return out


def sh_script(pack, job, j):
    p = spec.PACKS[pack]
    lines = ['#!/usr/bin/env bash', '#', '# %s.sh - %s' % (job, j['title']), '#']
    lines += ['# ' + l if l else '#' for l in NOTICE.split('\n')] + ['#']
    lines += ['# ' + l if l else '#' for l in doc(pack, job, j, 76, p['how_sh'], p['requires_sh'], p['exits_sh'])]
    return '\n'.join(lines) + '\n\n' + read(pack, 'linux', job + '.body')


def ps_script(pack, job, j):
    p = spec.PACKS[pack]
    ind = lambda ls: ['    ' + l if l else '' for l in ls]  # noqa: E731
    lines = ['#Requires -Version 5.1', '', '<#', '.SYNOPSIS', '    %s.ps1 - %s' % (job, j['title']), '.NOTES']
    lines += ind(NOTICE.split('\n')) + ['.DESCRIPTION']
    lines += ind(doc(pack, job, j, 74, p['how_ps'], p['requires_ps'], p['exits_ps'])) + ['#>', '']
    return '\n'.join(lines) + '\n' + read(pack, 'windows', job + '.body')


def pack_config(pack):
    p = spec.PACKS[pack]
    out = ['# ' + l for l in wrap(p['config_about'], 76)] + ['#']
    out += ['# It only reads, and changes nothing: no container is started, stopped or', '# removed, and nothing is pruned.', '#']
    out += ['# Off until enabled: vigil pack enable %s (or one job: vigil pack enable' % pack, '# %s_<job>). Each job\'s settings are its env lines.' % pack, '#']
    out += ['# ' + l if l else '#' for l in NOTICE.split('\n')] + ['']
    out += ['[pack]', 'version     = ' + p['version'],
            '# vigil: the oldest Vigil this pack runs on. vigil pack update refuses the', '# pack on an older one.',
            'vigil       = 0.3.0', 'description = ' + p['description'],
            '# What vigil pack info shows besides: the engines it is meant for, the', '# programs its scripts need on each platform, and where it is explained.',
            'works_with  = ' + p['works_with']]
    for os_ in p['platforms']:
        out.append('programs_%s = %s' % (os_, p['programs'][os_]))
    out.append('docs        = https://github.com/godspeedhq/vigil/blob/main/packs/%s/README.md' % pack)
    out += ['needs       = ' + n for n in p['needs']]
    for job, j in p['jobs'].items():
        names = []
        for name, _ in j['metrics']:
            if name not in names:
                names.append(name)
        out += ['', '[job.%s]' % job, 'metric_name = ' + (pack if job == 'status' else '%s.%s' % (pack, job)),
                'metrics     = ' + ', '.join(names), 'run_every   = ' + j['every'], 'max_runtime = ' + j['max']]
        out += ['env         = %s=' % e for e in p['env']]
    return '\n'.join(out) + '\n'


def main():
    repo = sys.argv[1]
    for pack in ([sys.argv[2]] if len(sys.argv) > 2 else list(spec.PACKS)):
        p = spec.PACKS[pack]
        out = os.path.join(repo, 'packs', pack)
        n = 0
        for os_ in p['platforms']:
            d = os.path.join(out, os_)
            os.makedirs(d, exist_ok=True)
            src = 'windows' if os_ == 'windows' else 'linux'
            ext = 'ps1' if os_ == 'windows' else 'sh'
            lib = '_%s.%s' % (pack, ext)
            open(os.path.join(d, lib), 'w', encoding='utf-8', newline='\n').write(read(pack, src, lib))
            for job, j in p['jobs'].items():
                text = ps_script(pack, job, j) if os_ == 'windows' else sh_script(pack, job, j)
                open(os.path.join(d, '%s.%s' % (job, ext)), 'w', encoding='utf-8', newline='\n').write(text)
                n += 1
        open(os.path.join(out, 'pack.config'), 'w', encoding='utf-8', newline='\n').write(pack_config(pack))
        print('%s: %d jobs, %d scripts, %d metrics' % (pack, len(p['jobs']), n, sum(len(set(m[0] for m in j['metrics'])) for j in p['jobs'].values())))


main()
