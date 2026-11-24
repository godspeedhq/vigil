# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""Writes the web packs (tools/web/DESIGN.md): packs/nginx, httpd, caddy,
haproxy and phpfpm. For each: pack.config; for Linux and macOS, _<pack>.sh
(lib.sh, what the scripts share) and each job's bash script; for Windows,
where the pack has PowerShell, _<pack>.ps1 (lib.ps1) and each job's script.
The jobs are in <pack>.py; each job's example output in examples-<pack>.txt.
Run from the repository: py tools/web/gen.py . (WEB_GEN_DRAFT=1 allows a job
with no example yet)."""
import os
import sys
import textwrap

repo = sys.argv[1]
src = os.path.join(repo, 'tools', 'web')
sys.path.insert(0, src)
import jobs  # noqa: E402
import nginx  # noqa: E402,F401
import httpd  # noqa: E402,F401
import caddy  # noqa: E402
import haproxy  # noqa: E402
import phpfpm  # noqa: E402,F401
import iis  # noqa: E402

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

PACKS = {
    'nginx': dict(
        P='nginx', E='NGINX', version='1.2.1',
        description='nginx: connections and requests (stub_status), processes and configuration reloads, '
                    'the access log minute by minute (status, errors, response times, upstream times), '
                    'certificate expiry',
        works='nginx 1.18 and later (tested: 1.30.8 and 1.31.10)',
        head=['nginx - an nginx server on this machine: its stub_status page, its',
              'processes and configuration, its access log minute by minute, and the',
              'certificates it serves.'],
        needs=['its stub_status page, reachable from this machine only: location = /nginx_status { stub_status; '
               'allow 127.0.0.1; deny all; }',
               'for the log job, read access to the access log: on Debian and Ubuntu, usermod -aG adm vigil; '
               'elsewhere, the log folder\'s group (packs/nginx/README.md); with rt=$request_time '
               'urt=$upstream_response_time at the end of the log_format for response times',
               "for nginx's CPU and memory: the base pack's processes job"]),
    'httpd': dict(
        P='Apache httpd', E='HTTPD', version='1.0.0',
        description='Apache httpd: workers and the scoreboard, requests, connections, TLS session cache, '
                    'configuration not reloaded, the access log minute by minute, certificate expiry',
        works='Apache httpd 2.4 (tested: 2.4.71, event and prefork MPMs)',
        head=['httpd - an Apache httpd server on this machine: its server-status page',
              '(workers, the scoreboard, requests, connections), whether its',
              'configuration changed since it last loaded, its access log minute by',
              'minute, and the certificates it serves.'],
        needs=['its server-status page, from this machine only: <Location "/server-status"> SetHandler '
               'server-status; Require local </Location>, and ExtendedStatus On',
               'for the log job, read access to the access log (packs/httpd/README.md); with rtus=%D at the '
               'end of the LogFormat for response times',
               "for httpd's CPU and memory: the base pack's processes job"]),
    'caddy': dict(
        P='Caddy', E='CADDY', version='1.0.0',
        description='Caddy: its configuration and reloads, traffic per server, reverse proxy upstreams and '
                    'their health, certificate expiry for every site, from its admin API',
        works='Caddy 2.6 and later (tested: 2.11.9)',
        head=['caddy - a Caddy server, from its admin API (GET only): its',
              'configuration and reloads, the traffic each server handles, its reverse',
              "proxies' upstreams, and the certificates every site serves."],
        needs=["its admin API, reachable from this machine (Caddy's default, localhost:2019)",
               'for the traffic job, its HTTP metrics: the global option { metrics } in the Caddyfile',
               "for Caddy's CPU and memory: the base pack's processes job"]),
    'haproxy': dict(
        P='HAProxy', E='HAPROXY', version='1.0.0',
        description='HAProxy: connections, rates, TLS and load; frontends, backends and servers with '
                    'their health checks, queues, times and errors, from its runtime API',
        works='HAProxy 2.4 and later (tested: 3.4.8 and 3.2.x)',
        head=['haproxy - an HAProxy process, from its runtime API ("show info" and',
              '"show stat" only): its connections, rates, TLS and load, its frontends,',
              'its backends, and every server with its health checks.'],
        needs=['its runtime API, at level user: stats socket ipv4@127.0.0.1:9999 level user (bash reads a '
               'TCP address itself), or a socket file this account may use, read with socat or nc',
               "for HAProxy's CPU and memory: the base pack's processes job"]),
    'phpfpm': dict(
        P='PHP-FPM', E='PHPFPM', version='1.0.0',
        description='PHP-FPM: each pool\'s workers, listen queue, max_children reached, slow requests, '
                    'and its busiest worker, from its status page',
        works='PHP-FPM 7.4 and later (tested: 8.6.0 and 8.3.37)',
        head=["phpfpm - PHP-FPM's pools, from their status pages: workers, the listen",
              'queue, max_children reached, slow requests and the busiest worker.'],
        needs=["each pool's status page, through a web server, from this machine only: pm.status_path = "
               '/fpm-status in the pool, and a location passing /fpm-status to it (packs/phpfpm/README.md)',
               "for PHP-FPM's CPU and memory: the base pack's processes job"]),
    'iis': dict(
        P='IIS', E='IIS', version='1.0.0',
        description="IIS: sites, application pools and their request queues, worker processes, each site's log "
                    'minute by minute and what HTTP.sys turned away, pools stopped and workers crashed (events), '
                    'certificate expiry; no administrator needed',
        works='IIS 10 (Windows Server 2016 and later; tested: Windows Server 2025)',
        head=['iis - IIS on this Windows machine, as an account that is not an',
              'administrator: its sites, application pools and request queues, its',
              "worker processes, each site's log minute by minute and what HTTP.sys",
              'turned away, its events (pools stopped, workers crashed), and the',
              'certificates it serves.'],
        needs=['the account Vigil runs as in Performance Monitor Users (for the counters) and Event Log Readers '
               "(for the events); LocalSystem, the Vigil service's account, already may",
               r'for the log job, read access to C:\inetpub\logs\LogFiles and C:\Windows\System32\LogFiles\HTTPERR '
               '(packs/iis/README.md has the icacls commands)',
               "for IIS's CPU and memory (w3wp.exe): the base pack's processes job"]),
}
LIB_SH = {'haproxy': haproxy.LIB_SH}
LIB_PS = {'caddy': caddy.LIB_PS, 'iis': iis.LIB_PS}


def subst(text, p):
    d = PACKS[p]
    return text.replace('@P@', d['P']).replace('@E@', d['E']).replace('@p@', p)


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


def needs_of(j):
    return ['bash'] + j['needs_sh']


def doc(j, p, ex, ps):
    c = []
    c += wrap(subst(j['what'], p) + ' It only reads: it changes nothing.', 76)
    c += ['']
    c += wrap(subst(j['reads'], p), 76)
    if ps:
        c += wrap(subst("What the scripts share is in _@p@.ps1, beside this one.", p), 76)
    else:
        c += wrap(subst("What the scripts share is in _@p@.sh, beside this one.", p), 76)
    c += ['', 'Metrics:']
    c += metrics_doc([(n, subst(t, p)) for n, t in j['metrics']])
    e = ex.get(j['job'])
    if not e:
        if os.environ.get('WEB_GEN_DRAFT') != '1':
            sys.exit('no example output for %s in tools/web/examples-%s.txt' % (j['job'], p))
        e = ['(draft: no example yet)']
    c += ['', 'Example output (the rest are in the same form):']
    c += ['  ' + x for x in e]
    c += ['', 'Reading the results (starting points: tune them to the server):']
    c += wrap(subst(j['healthy'], p), 76, first='  Healthy  ', rest=' ' * 11)
    c += wrap(subst(j['watch'], p), 76, first='  Watch    ', rest=' ' * 11)
    c += wrap(subst(j['act'], p), 76, first='  Act      ', rest=' ' * 11)
    c += ['']
    c += [('Requires: Windows PowerShell 5.1 or PowerShell 7' if ps else 'Requires: ' + ', '.join(needs_of(j)))]
    c += wrap(subst('Exit code: ' + (j['exit_ps'] if ps else j['exit_sh']), p), 76, rest='  ')
    return c


def sh_script(j, p, ex):
    head = ['#!/usr/bin/env bash', '#', '# %s.sh - %s' % (j['job'], subst(j['title'], p)), '#']
    head += [('# ' + n).rstrip() for n in NOTICE] + ['#']
    head += [('# ' + l).rstrip() for l in doc(j, p, ex, False)]
    need = ' '.join(j['needs_sh'])
    body = ('set -u\n\njob=%s\n# shellcheck source=/dev/null\n. "$(dirname "$0")/_%s.sh"\n' % (j['job'], p) +
            ('needs %s\n' % need if need else '') + '\n' + subst(j['sh'], p))
    return '\n'.join(head) + '\n\n' + body


def ps_script(j, p, ex):
    head = ['#Requires -Version 5.1', '', '<#', '.SYNOPSIS',
            '    %s.ps1 - %s, on Windows' % (j['job'], subst(j['title'], p)), '.NOTES']
    head += [('    ' + n).rstrip() for n in NOTICE]
    head += ['.DESCRIPTION']
    head += [('    ' + l).rstrip() for l in doc(j, p, ex, True)]
    head += ['#>']
    body = ("$Job = '%s'\n. (Join-Path $PSScriptRoot '_%s.ps1')\n\n" % (j['job'], p)) + subst(j['ps'], p)
    return '\n'.join(head) + '\n\n' + body


def lib(name, p):
    t = open(os.path.join(src, name), encoding='utf-8').read()
    if name.endswith('.sh'):
        t = t.replace('@NOTICE@', '\n'.join(('# ' + n).rstrip() for n in NOTICE)) + LIB_SH.get(p, '')
    else:
        t = t.replace('@NOTICE@', '\n'.join(('    ' + n).rstrip() for n in NOTICE)) + LIB_PS.get(p, '')
    return subst(t, p)


def pack_config(p, js):
    d = PACKS[p]
    windows = any(j['ps'] for j in js)
    unix = any(j['sh'] for j in js)
    plats = 'Linux, macOS and Windows' if windows else 'Linux and macOS: there is no Windows script'
    if windows and not all(j['ps'] for j in js):
        plats = 'Linux, macOS and Windows (on Windows: ' + ', '.join(j['job'] for j in js if j['ps']) + ')'
    if not unix:
        plats = 'Windows: there is no Linux or macOS script'
    c = ['# ' + l for l in d['head']]
    c += ['# ' + l for l in textwrap.wrap(plats + '. See SPECIFICATION.md section 18.10 for this format, and '
                                          'tools/web/DESIGN.md.', 74)]
    c += ['#', '# It only reads: it changes nothing on the server.',
          '#', '# Off until enabled: vigil pack enable %s (or one job: vigil pack enable %s_<job>).' % (p, p),
          '# Each job\'s settings are its env lines.', '#']
    c += [('# ' + n).rstrip() for n in NOTICE]
    progs = sorted({x for j in js if j['sh'] for x in needs_of(j)}, key=lambda x: (x != 'bash', x))
    c += ['',
          '[pack]',
          'version     = ' + d['version'],
          '# vigil: the oldest Vigil this pack runs on. vigil pack update refuses the',
          '# pack on an older one.',
          'vigil       = 0.3.0',
          'description = ' + d['description'],
          '# What vigil pack info shows besides: the servers it is meant for, the',
          '# programs its scripts need on each platform, and where it is explained.',
          'works_with  = ' + d['works']]
    if unix:
        c += ['programs_linux = ' + ', '.join(progs),
              'programs_macos = ' + ', '.join(progs)]
    if windows:
        c += ['programs_windows = PowerShell 5.1 or later']
    c += ['docs        = https://github.com/godspeedhq/vigil/blob/main/packs/%s/README.md' % p]
    c += ['needs       = ' + n for n in d['needs']]
    c += ['']
    for j in js:
        c += ['[job.%s]' % j['job'],
              'metric_name = %s' % (p + ('.' + j['metric'] if j['metric'] else '')),
              'metrics     = %s' % ', '.join(n for n, _ in j['metrics']),
              j['when'],
              'max_runtime = %s' % j['runtime']]
        c += ['env         = %s=%s' % (subst(k, p), v) for k, v in j['env']]
        c += ['']
    return '\n'.join(c).rstrip('\n') + '\n'


only = sys.argv[2:] or list(PACKS)
for p in only:
    js = [j for j in jobs.JOBS if j['pack'] == p]
    out = os.path.join(repo, 'packs', p)
    ex = examples(p)
    windows = any(j['ps'] for j in js)
    unix = any(j['sh'] for j in js)
    want = (('linux', 'macos') if unix else ()) + (('windows',) if windows else ())
    for os_ in ('linux', 'macos', 'windows'):
        if os.path.isdir(os.path.join(out, os_)):
            for f in os.listdir(os.path.join(out, os_)):
                os.remove(os.path.join(out, os_, f))
            if os_ not in want:
                os.rmdir(os.path.join(out, os_))
    for os_ in want:
        os.makedirs(os.path.join(out, os_), exist_ok=True)
    if unix:
        sh_lib = lib('lib.sh', p)
        for os_ in ('linux', 'macos'):
            open(os.path.join(out, os_, '_%s.sh' % p), 'w', encoding='utf-8', newline='\n').write(sh_lib)
    if windows:
        open(os.path.join(out, 'windows', '_%s.ps1' % p), 'w', encoding='utf-8', newline='\n').write(lib('lib.ps1', p))
    for j in js:
        if j['sh']:
            s = sh_script(j, p, ex)
            for os_ in ('linux', 'macos'):
                open(os.path.join(out, os_, j['job'] + '.sh'), 'w', encoding='utf-8', newline='\n').write(s)
        if j['ps']:
            open(os.path.join(out, 'windows', j['job'] + '.ps1'), 'w', encoding='utf-8', newline='\n').write(ps_script(j, p, ex))
    open(os.path.join(out, 'pack.config'), 'w', encoding='utf-8', newline='\n').write(pack_config(p, js))
    print('%s: %d jobs, %d metrics' % (p, len(js), sum(len(j['metrics']) for j in js)))
