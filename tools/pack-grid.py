# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""Writes each pack's grid into its page (packs/<name>/README.md): every
job, every metric it prints and what it measures, and what good, watch and
bad look like, as a plain-text grid. It reads them from the header of each
job's script, so the grid says what the scripts say. The grid goes between
the page's markers, <!-- grid:start --> and <!-- grid:end -->, or, the first
time, before its "## What to alert on".

   python tools/pack-grid.py .              every pack
   python tools/pack-grid.py . tomcat jvm   those named
   python tools/pack-grid.py . --check      changes nothing: exit 1 if a
                                            grid is not what the scripts say
"""
import os
import re
import sys
import textwrap

W = 100          # the grid's width, borders included
START, END = '<!-- grid:start -->', '<!-- grid:end -->'


def jobs_of(cfg):
    """[(job, metric_name, when)] in pack.config's order."""
    out, cur = [], None
    for line in open(cfg, encoding='utf-8'):
        line = line.rstrip('\n')
        m = re.match(r'^\[job\.([A-Za-z0-9_]+)\]$', line)
        if m:
            cur = {'job': m.group(1), 'metric_name': '', 'when': ''}
            out.append(cur)
            continue
        if cur is None or '=' not in line or line.lstrip().startswith('#'):
            continue
        k, v = [x.strip() for x in line.split('=', 1)]
        if k == 'metric_name':
            cur['metric_name'] = v
        elif k == 'run_every':
            cur['when'] = 'every ' + v
        elif k == 'cron':
            cur['when'] = 'cron ' + v
    return out


def header(pack_dir, job):
    """The header's lines of the job's script, without their comment marks:
    the Linux one, else macOS, else Windows."""
    for os_, ext in (('linux', 'sh'), ('macos', 'sh'), ('windows', 'ps1')):
        p = os.path.join(pack_dir, os_, job + '.' + ext)
        if not os.path.exists(p):
            continue
        lines = open(p, encoding='utf-8').read().split('\n')
        if ext == 'sh':
            out = []
            for l in lines[1:]:
                if not l.startswith('#'):
                    break
                out.append(l[2:] if l.startswith('# ') else l[1:])
            return out
        out, inside = [], False
        for l in lines:
            if l.strip() == '.DESCRIPTION':
                inside = True
                continue
            if inside and l.strip() == '#>':
                break
            if inside:
                out.append(l[4:] if l.startswith('    ') else l.strip())
        return out
    return []


def block(lines, title):
    """The lines under 'title' (Metrics:, Reading the results...), to the next blank line."""
    out, inside = [], False
    for l in lines:
        if not inside and l.startswith(title):
            inside = True
            continue
        if inside:
            if not l.strip():
                break
            out.append(l)
    return out


def metrics(lines):
    """[(name, what)]: '  name  what', and what goes on, further in."""
    out = []
    for l in block(lines, 'Metrics:'):
        m = re.match(r'^  (\S+)\s+(.*)$', l)
        if m and not l.startswith('   '):
            out.append([m.group(1), m.group(2).strip()])
        elif m is None and re.match(r'^  (\S+)$', l):
            out.append([l.strip(), ''])
        elif out:
            out[-1][1] = (out[-1][1] + ' ' + l.strip()).strip()
    return out


def reading(lines):
    """{'Healthy': ..., 'Watch': ..., 'Act': ...}"""
    out, cur = {}, None
    for l in block(lines, 'Reading the results'):
        m = re.match(r'^  (Healthy|Watch|Act)\s+(.*)$', l)
        if m:
            cur = m.group(1)
            out[cur] = m.group(2).strip()
        elif cur:
            out[cur] += ' ' + l.strip()
    return out


def row(text):
    return '| ' + text.ljust(W - 4) + ' |'


def wrap(text, width):
    return textwrap.wrap(text, width, break_long_words=True, break_on_hyphens=False) or ['']


def grid(pack, pack_dir):
    rule = '+' + '-' * (W - 2) + '+'
    out = []
    for j in jobs_of(os.path.join(pack_dir, 'pack.config')):
        h = header(pack_dir, j['job'])
        ms = metrics(h)
        rd = reading(h)
        if not ms:
            continue
        # The counts of what a list left out, as one line, not one each.
        capped = [n for n, _ in ms if n.endswith('_not_shown')]
        ms = [m for m in ms if not m[0].endswith('_not_shown')]
        if capped:
            ms.append(['..._not_shown', 'past 100 of a list (%s), how many were left out' % ', '.join(
                n[:-len('_not_shown')] for n in capped)])
        name_w = min(max(len(n) for n, _ in ms), 30)
        what_w = W - 4 - name_w - 3
        sep = '+' + '-' * (name_w + 2) + '+' + '-' * (what_w + 2) + '+'
        title = '%s_%s   %s.<metric>   %s' % (pack, j['job'], j['metric_name'], j['when'])
        out += [rule] + [row(t) for t in wrap(title, W - 4)] + [sep]
        for n, what in ms:
            ws = wrap(what, what_w)
            ns = wrap(n, name_w)
            for k in range(max(len(ws), len(ns))):
                a = ns[k] if k < len(ns) else ''
                b = ws[k] if k < len(ws) else ''
                out.append('| ' + a.ljust(name_w) + ' | ' + b.ljust(what_w) + ' |')
        out.append(sep)
        for key, label in (('Healthy', 'GOOD  '), ('Watch', 'WATCH '), ('Act', 'BAD   ')):
            if key in rd:
                ws = wrap(rd[key], W - 4 - len(label))
                out.append(row(label + ws[0]))
                out += [row(' ' * len(label) + w) for w in ws[1:]]
        out += [rule, '']
    return out


def section(pack, pack_dir):
    g = grid(pack, pack_dir)
    if not g:
        return None
    js = jobs_of(os.path.join(pack_dir, 'pack.config'))
    example = ''
    for j in js:
        ms = [n for n, _ in metrics(header(pack_dir, j['job'])) if n != 'jmx_up' and not n.endswith('_not_shown')]
        if ms:
            example = j['metric_name'] + '.' + ms[0]
            break
    intro = ('Every job, every metric it prints and what it measures, and what good, watch and bad look like. '
             'It is the header of each job\'s script, laid out (`tools/pack-grid.py` writes it), so it says what '
             'the scripts say. A metric\'s full name is its job\'s name, then its own: `%s`.' % example)
    return '\n'.join([START, '## Every metric, at a glance', '', intro, '', '```text'] + g[:-1] + ['```', END])


def main():
    args = sys.argv[1:]
    check = '--check' in args
    args = [a for a in args if a != '--check']
    repo = args[0]
    names = args[1:] or sorted(d for d in os.listdir(os.path.join(repo, 'packs'))
                                if os.path.isfile(os.path.join(repo, 'packs', d, 'pack.config')))
    stale = 0
    for name in names:
        d = os.path.join(repo, 'packs', name)
        page = os.path.join(d, 'README.md')
        sec = section(name, d)
        if sec is None or not os.path.exists(page):
            continue
        text = open(page, encoding='utf-8').read()
        if START in text and END in text:
            new = text[:text.index(START)] + sec + text[text.index(END) + len(END):]
        elif '\n## What to alert on' in text:
            i = text.index('\n## What to alert on')
            new = text[:i] + '\n\n' + sec + '\n' + text[i:]
        else:
            i = text.index('\n---\n\n[All packs]')
            new = text[:i] + '\n\n' + sec + '\n' + text[i:]
        if new != text:
            stale += 1
            if check:
                print('pack-grid: packs/%s/README.md: its grid is not what the scripts say: python tools/pack-grid.py . %s' % (name, name))
            else:
                open(page, 'w', encoding='utf-8', newline='\n').write(new)
                print('pack-grid: wrote packs/%s/README.md' % name)
    if check and stale:
        sys.exit(1)


if __name__ == '__main__':
    main()
