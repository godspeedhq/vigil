# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""How a job of the obs packs is written, for tools/obs/gen.py
(tools/obs/DESIGN.md). Each pack's jobs are in <pack>.py.

A job is a list of steps, run in order, the same on every platform:

  page(path)                 the page of metrics every reading below is taken
                             from; "up" says whether it answered
  answers(name, path, doc)   a health or readiness page: 1 when it answers 200
  table(rows)                readings from the page: rows of (line, doc), the
                             line as lib.sh's readings() takes it; doc None
                             for a line that is only worked out. A line's
                             fields are separated by "|", so a filter's
                             regex cannot use one: ^[JLP] for three words
  extra(path, rows)          readings from another page, when it is given
  code(sh, ps, metrics)      what no table says, written for each shell

In the text and the code, @P@ is the service's name, @p@ the pack's, @E@
the prefix of its settings."""

JOBS = []


def page(path):
    return ('page', path)


def answers(name, path, doc):
    return ('answers', name, path, doc)


def table(*rows):
    return ('table', list(rows))


def extra(path, *rows):
    return ('extra', path, list(rows))


def code(sh, ps, metrics):
    return ('code', sh, ps, list(metrics))


def job(**j):
    j.setdefault('env', [])
    j.setdefault('needs_sh', ['curl', 'awk'])
    j.setdefault('exit_sh', "0, whatever it reads, and when @P@ does not answer (up 0 is the reading); 1 when it "
                            "answers wrong (a login refused, not HTTP), said on stderr, or curl or awk is missing")
    j.setdefault('exit_ps', "0, whatever it reads, and when @P@ does not answer (up 0 is the reading); 1 when it "
                            "answers wrong (a login refused, not HTTP), said on stderr")
    JOBS.append(j)


def metrics_of(j):
    """The readings a job prints, with what each is, in the order printed."""
    out = []
    for s in j['steps']:
        if s[0] == 'page':
            out.append(('up', '1 when @P@ answered its metrics page, else 0 (and nothing more is read)'))
        elif s[0] == 'answers':
            out.append((s[1], s[3]))
        elif s[0] in ('table', 'extra'):
            for line, doc in s[-1]:
                f = line.split('|')
                if f[0].startswith('_'):
                    continue
                if doc is None:
                    raise SystemExit('%s %s: %s has no description' % (j['pack'], j['job'], f[0]))
                out.append((f[0], doc))
                if f[1].rstrip('?') in ('by', 'countby'):
                    out.append((f[0] + '_not_shown', 'how many more there were than the 20 shown'))
        elif s[0] == 'code':
            out += s[3]
    # A reading may have two lines (two names for one thing, of which a
    # version has one): it is listed once.
    seen, once = set(), []
    for n, d in out:
        if n not in seen:
            seen.add(n)
            once.append((n, d))
    return once
