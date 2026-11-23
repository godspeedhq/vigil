# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""Writes packs/elasticsearch and packs/opensearch (tools/search/DESIGN.md):
each pack's pack.config; for Linux and macOS, _<pack>.sh (lib.sh: what the
scripts share) and each job's bash script; for Windows, _<pack>.ps1 (lib.ps1)
and each job's PowerShell script. The jobs are in jobs*.py; each job's example
output in examples-<pack>.txt. Run from the repository: py tools/search/gen.py ."""
import os
import sys
import textwrap

repo = sys.argv[1]
src = os.path.join(repo, 'tools', 'search')
sys.path.insert(0, src)
import jobs  # noqa: E402
import jobs2  # noqa: E402,F401
import jobs3  # noqa: E402,F401
import jobs4  # noqa: E402,F401
import jobs5  # noqa: E402,F401

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

ES_LICENSE_SH = r'''get '/_license'
rc=$?
case $rc in
    0) jq -r --argjson now "$now" "$jqlib"'.license |
        "metric license 1 type=\(.type | tag) status=\(.status | tag)",
        (if .expiry_date_in_millis then "metric license_expires_days \((.expiry_date_in_millis / 1000 - $now) / 86400 | floor)" else empty end)
    ' "$work/body" || exit 1 ;;
    3 | 4) ;;
    *) why "$rc" '/_license' ;;
esac
'''
ES_LICENSE_PS = r'''$p = Get-Page '/_license'
if ($p.State -eq 'ok') {
    $l = $p.Data.license
    Write-Output "metric license 1 type=$(Safe $l.type) status=$(Safe $l.status)"
    if ($l.expiry_date_in_millis) { M 'license_expires_days' ([Math]::Floor(((N $l.expiry_date_in_millis) / 1000 - $script:Now) / 86400)) }
} elseif ($p.State -notin 'unsupported', 'forbidden') { Stop-Why $p.State '/_license' }
'''

PRODUCTS = {
    'elasticsearch': dict(
        P='Elasticsearch', E='ELASTICSEARCH', M='master', MT='master', MW='master', MCAT='/_cat/master',
        AUTHDOC=(', as @E@_USER with the password in @E@_PASSWORD (a secret), or with an API key in '
                 '@E@_API_KEY (a secret: the encoded form Elasticsearch gives), with curl and jq. The login '
                 'goes to curl on its standard input, never on a command line.'),
        AUTHDOC_PS=(', as @E@_USER with the password in @E@_PASSWORD (a secret), or with an API key in '
                    '@E@_API_KEY (a secret: the encoded form Elasticsearch gives). The login goes in a header '
                    'made here, never on a command line.'),
        LOGINWHAT='@E@_USER and @E@_PASSWORD, or @E@_API_KEY, are',
        LOGIN_SH='''    if [ -n "${@E@_API_KEY-}" ]; then
        printf 'header = "Authorization: ApiKey %s"\\n' "$(esc "$@E@_API_KEY")"
    elif [ -n "${@E@_USER-}" ]; then
        printf 'user = "%s"\\n' "$(esc "$@E@_USER:${@E@_PASSWORD-}")"
    fi''',
        LOGIN_PS='''if ($env:@E@_API_KEY) { $script:Auth = 'ApiKey ' + $env:@E@_API_KEY }
elseif ($env:@E@_USER) { $script:Auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:@E@_USER):$($env:@E@_PASSWORD)")) }''',
        PRODUCT_SH='''    if ! grep -qi '^x-elastic-product: *Elasticsearch' "$work/head"; then
        echo "metric up 0"
        if jq -e '.version.distribution == "opensearch"' "$work/body" > /dev/null 2>&1; then
            echo "$job: $url is OpenSearch, not Elasticsearch: the opensearch pack reads it" >&2
        else
            echo "$job: $url answers, but not as Elasticsearch (no X-elastic-product header)" >&2
        fi
        exit 1
    fi''',
        PRODUCT_PS='''    if (-not $r.Head['x-elastic-product']) {
        Write-Output 'metric up 0'
        if ($root.version.distribution -eq 'opensearch') { [Console]::Error.WriteLine("${Job}: $($script:Url) is OpenSearch, not Elasticsearch: the opensearch pack reads it") }
        else { [Console]::Error.WriteLine("${Job}: $($script:Url) answers, but not as Elasticsearch (no X-elastic-product header)") }
        exit 1
    }''',
        CLUSTER_EXTRA_WHAT=' And its license: its type and state, and the days until it expires.',
        CLUSTER_EXTRA_ACT=' license_expires_days below 30: renew it.',
        CLUSTER_EXTRA_METRICS=[('license', "always 1, tagged type=<basic, trial, platinum, enterprise...> and status=<active, expired...>"),
                               ('license_expires_days', 'days until the license expires, when it does')],
        CLUSTER_EXTRA_SH=ES_LICENSE_SH, CLUSTER_EXTRA_PS=ES_LICENSE_PS,
        works='Elasticsearch 8.x and 9.x (tested: 8.19.25 and 9.5.5), with security on or off',
        role=('a role that may only monitor: cluster privileges monitor, read_ilm, read_slm and monitor_snapshot; '
              'index privileges monitor and view_index_metadata on *'),
    ),
    'opensearch': dict(
        P='OpenSearch', E='OPENSEARCH', M='cluster_manager', MT='cluster_manager', MW='cluster manager',
        MCAT='/_cat/cluster_manager',
        AUTHDOC=(', as @E@_USER with the password in @E@_PASSWORD (a secret), with curl and jq. The login '
                 'goes to curl on its standard input, never on a command line.'),
        AUTHDOC_PS=(', as @E@_USER with the password in @E@_PASSWORD (a secret). The login goes in a header '
                    'made here, never on a command line.'),
        LOGINWHAT='@E@_USER or @E@_PASSWORD is',
        LOGIN_SH='''    [ -n "${@E@_USER-}" ] && printf 'user = "%s"\\n' "$(esc "$@E@_USER:${@E@_PASSWORD-}")"''',
        LOGIN_PS='''if ($env:@E@_USER) { $script:Auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:@E@_USER):$($env:@E@_PASSWORD)")) }''',
        PRODUCT_SH='''    if ! jq -e '.version.distribution == "opensearch"' "$work/body" > /dev/null 2>&1; then
        echo "metric up 0"
        if grep -qi '^x-elastic-product:' "$work/head"; then
            echo "$job: $url is Elasticsearch, not OpenSearch: the elasticsearch pack reads it" >&2
        else
            echo "$job: $url answers, but not as OpenSearch (its version.distribution is not opensearch)" >&2
        fi
        exit 1
    fi''',
        PRODUCT_PS='''    if ($root.version.distribution -ne 'opensearch') {
        Write-Output 'metric up 0'
        if ($r.Head['x-elastic-product']) { [Console]::Error.WriteLine("${Job}: $($script:Url) is Elasticsearch, not OpenSearch: the elasticsearch pack reads it") }
        else { [Console]::Error.WriteLine("${Job}: $($script:Url) answers, but not as OpenSearch (its version.distribution is not opensearch)") }
        exit 1
    }''',
        CLUSTER_EXTRA_WHAT='', CLUSTER_EXTRA_ACT='', CLUSTER_EXTRA_METRICS=[],
        CLUSTER_EXTRA_SH='', CLUSTER_EXTRA_PS='',
        works='OpenSearch 2.x and 3.x (tested: 2.19.7 and 3.10.0), with the security plugin on or off',
        role=('a role that may only monitor (the security plugin): cluster permissions cluster_monitor and the '
              'reads of snapshots, ISM and snapshot management; index permissions indices_monitor, '
              'indices:admin/get and indices:monitor/settings/get on *'),
    ),
}
ES_ONLY_LINE = 'es'
OS_ONLY_LINE = 'os'


def subst(text, p, d):
    """The product's words and names, in a job's text or code."""
    for k in ('CLUSTER_EXTRA_WHAT', 'CLUSTER_EXTRA_ACT', 'CLUSTER_EXTRA_SH', 'CLUSTER_EXTRA_PS'):
        text = text.replace('@%s@' % k, d[k])
    for k in ('AUTHDOC', 'LOGINWHAT'):
        text = text.replace('@%s@' % k, d[k])
    for k in ('MCAT', 'MW', 'MT', 'M', 'P', 'E'):
        text = text.replace('@%s@' % k, d[k])
    return text.replace('@p@', p)


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


def job_metrics(j, d):
    out = []
    for n, desc in j['metrics']:
        if n == '@CLUSTER_EXTRA_METRICS@':
            out += d['CLUSTER_EXTRA_METRICS']
        else:
            out.append((n, desc))
    return out


def doc(j, p, d, ex, ps):
    c = []
    c += wrap(subst(j['what'], p, d) + ' It only reads: it changes nothing in the cluster.', 76)
    c += ['']
    c += wrap(subst('Reads @P@ at @E@_URL (default https://localhost:9200)' +
                    (d['AUTHDOC_PS'] if ps else d['AUTHDOC']), p, d), 76)
    if ps:
        c += wrap(subst('It speaks HTTP itself, with .NET: nothing to install. Over https, the certificate is checked '
                        "against Windows' trusted CAs, or @E@_CACERT, a CA file, and against the server's name. "
                        'What the scripts share is in _@p@.ps1, beside this one.', p, d), 76)
    else:
        c += wrap(subst('Over https, the certificate is checked against @E@_CACERT, a CA file, when it is set, '
                        "else the system's CAs. What the scripts share is in _@p@.sh, beside this one.", p, d), 76)
    c += ['', 'Metrics:']
    c += metrics_doc([(subst(n, p, d), subst(t, p, d)) for n, t in job_metrics(j, d)])
    e = ex.get(j['job'])
    if not e:
        if os.environ.get('SEARCH_GEN_DRAFT') != '1':
            sys.exit('no example output for %s in tools/search/examples-%s.txt' % (j['job'], p))
        e = ['(draft: no example yet)']
    c += ['', 'Example output (the rest are in the same form):']
    c += ['  ' + x for x in e]
    c += ['', 'Reading the results (starting points: tune them to the cluster):']
    c += wrap(subst(j['healthy'], p, d), 76, first='  Healthy  ', rest=' ' * 11)
    c += wrap(subst(j['watch'], p, d), 76, first='  Watch    ', rest=' ' * 11)
    c += wrap(subst(j['act'], p, d), 76, first='  Act      ', rest=' ' * 11)
    c += ['']
    c += [('Requires: Windows PowerShell 5.1 or PowerShell 7' if ps else 'Requires: bash, curl and jq')]
    c += wrap(subst('Exit code: 0 on success, @P@ up or down; 1 if ' + ('' if ps else 'curl or jq is missing, ') +
                    'a setting is wrong, the login is refused, this user may not read what the job needs, or '
                    'the address is not @P@', p, d), 76, rest='  ')
    return c


def sh_script(j, p, d, ex):
    head = ['#!/usr/bin/env bash', '#', '# %s.sh - %s' % (j['job'], subst(j['title'], p, d)), '#']
    head += [('# ' + n).rstrip() for n in NOTICE] + ['#']
    head += [('# ' + l).rstrip() for l in doc(j, p, d, ex, False)]
    body = ('set -u\n\njob=%s\n# shellcheck source=/dev/null\n. "$(dirname "$0")/_%s.sh"\n\n' % (j['job'], p) +
            subst(j['sh'], p, d))
    return '\n'.join(head) + '\n\n' + body


def ps_script(j, p, d, ex):
    head = ['#Requires -Version 5.1', '', '<#', '.SYNOPSIS',
            '    %s.ps1 - %s, on Windows' % (j['job'], subst(j['title'], p, d)), '.NOTES']
    head += [('    ' + n).rstrip() for n in NOTICE]
    head += ['.DESCRIPTION']
    head += [('    ' + l).rstrip() for l in doc(j, p, d, ex, True)]
    head += ['#>']
    body = ("$Job = '%s'\n. (Join-Path $PSScriptRoot '_%s.ps1')\n\n" % (j['job'], p)) + subst(j['ps'], p, d)
    return '\n'.join(head) + '\n\n' + body


def lib(name, p, d):
    t = open(os.path.join(src, name), encoding='utf-8').read()
    notice = '\n'.join(('# ' + n).rstrip() for n in NOTICE) if name.endswith('.sh') else \
        '\n'.join(('    ' + n).rstrip() for n in NOTICE)
    t = t.replace('@NOTICE@', notice)
    if name.endswith('.sh'):
        t = t.replace('@AUTHDOC@', d['AUTHDOC']).replace('@LOGIN@', d['LOGIN_SH']).replace('@PRODUCT@', d['PRODUCT_SH'])
    else:
        t = t.replace('@AUTHDOC@', d['AUTHDOC_PS']).replace('@LOGIN@', d['LOGIN_PS']).replace('@PRODUCT@', d['PRODUCT_PS'])
    return subst(t, p, d)


def pack_jobs(p):
    tag = 'es' if p == 'elasticsearch' else 'os'
    return [j for j in jobs.JOBS if j.get('only') in (None, tag)]


def pack_config(p, d, js):
    E = d['E']
    c = ['# %s - %s, from its REST API: the cluster\'s health and its own health' % (p, d['P']),
         '# report, nodes, thread pools, circuit breakers, indices, shards and why',
         '# one is unassigned, disks and watermarks, the work each node does, ingest',
         '# pipelines, tasks, lifecycles, snapshots and the cluster as a whole.',
         '# Never its JVM: that is the jvm pack\'s. Linux, macOS and Windows. See',
         '# SPECIFICATION.md section 18.10 for this format, and tools/search/DESIGN.md.',
         '#',
         '# It only reads: every request is a GET, as a user that may only monitor.',
         '# Linux and macOS read with curl and jq; Windows with PowerShell alone.',
         '#',
         '# Off until enabled: vigil pack enable %s. Then set the jobs\' env lines:' % p,
         '#   env = %s_URL=https://es.example.com:9200' % E,
         '#   env = %s_USER=vigil' % E,
         '#   env = %s_CACERT=/etc/ssl/%s-ca.pem   (a private CA; Linux and macOS)' % (E, p),
         '# add a secret line to each job:',
         '#   secret = %s_PASSWORD=secret:%s_PASSWORD' % (E, E)]
    if p == 'elasticsearch':
        c += ['# (or, with an API key instead: secret = ELASTICSEARCH_API_KEY=secret:ELASTICSEARCH_API_KEY)']
    c += ['# and: vigil secret set %s_PASSWORD' % E, '#']
    c = [l.replace("health and its own health\n", '') for l in c]
    if p == 'opensearch':
        c[0] = "# opensearch - OpenSearch, from its REST API: the cluster's health, nodes,"
        c[1] = '# thread pools, circuit breakers, backpressure and admission control,'
        c[2] = '# indices, shards and why one is unassigned, disks and watermarks, the work'
        c[3] = '# each node does, ingest pipelines, tasks, ISM and snapshot management,'
        c[4] = "# snapshots and the cluster as a whole. Never its JVM: that is the jvm pack's."
        c[5] = '# Linux, macOS and Windows. See SPECIFICATION.md section 18.10 for this'
        c.insert(6, '# format, and tools/search/DESIGN.md.')
    c += [('# ' + n).rstrip() for n in NOTICE]
    desc = {'elasticsearch': 'Elasticsearch: cluster health and health report, nodes, thread pools, breakers, indices, '
                             'shards and why unassigned, disk watermarks, node work, ingest, tasks, ILM, SLM, '
                             'snapshots, transforms, license',
            'opensearch': 'OpenSearch: cluster health, nodes, thread pools, breakers, backpressure, admission control, '
                          'indices, shards and why unassigned, disk watermarks, node work, ingest, tasks, ISM, '
                          'snapshot management, snapshots'}[p]
    c += ['',
          '[pack]',
          'version     = 1.0.0',
          '# vigil: the oldest Vigil this pack runs on. vigil pack update refuses the',
          '# pack on an older one.',
          'vigil       = 0.3.0',
          'description = ' + desc,
          '# What vigil pack info shows besides: the servers it is meant for, the',
          '# programs its scripts need on each platform, and where it is explained.',
          'works_with  = ' + d['works'],
          'programs_linux = bash, curl, jq',
          'programs_macos = bash, curl, jq',
          'programs_windows = PowerShell 5.1 or later',
          'docs        = https://github.com/godspeedhq/vigil/blob/main/packs/%s/README.md' % p,
          'needs       = a user with ' + d['role'] + ' (packs/%s/README.md has it), and its password as a secret: '
          'secret = %s_PASSWORD=secret:%s_PASSWORD, then vigil secret set %s_PASSWORD' % (p, E, E, E)]
    if p == 'elasticsearch':
        c += ['needs       = or, instead of a user and password, an API key with the same privileges: '
              'secret = ELASTICSEARCH_API_KEY=secret:ELASTICSEARCH_API_KEY, then vigil secret set ELASTICSEARCH_API_KEY']
    c += ['needs       = for %s\'s JVM (heap, garbage collection, threads): the jvm pack, not this one: '
          'vigil pack install jvm' % d['P'],
          '']
    for j in js:
        names = [subst(n, p, d) for n, _ in job_metrics(j, d)]
        c += ['[job.%s]' % j['job'],
              'metric_name = %s' % (p + ('.' + j['metric'] if j['metric'] else '')),
              'metrics     = %s' % ', '.join(names),
              j['when'],
              'max_runtime = %s' % j['runtime'],
              'env         = %s_URL=' % E,
              'env         = %s_USER=' % E,
              'env         = %s_CACERT=' % E,
              '']
    return '\n'.join(c).rstrip('\n') + '\n'


for p, d in PRODUCTS.items():
    d = {k: (v.replace('@E@', d['E']) if isinstance(v, str) else v) for k, v in d.items()}
    out = os.path.join(repo, 'packs', p)
    ex = examples(p)
    js = pack_jobs(p)
    for os_ in ('linux', 'macos', 'windows'):
        os.makedirs(os.path.join(out, os_), exist_ok=True)
        for f in os.listdir(os.path.join(out, os_)):
            os.remove(os.path.join(out, os_, f))
    sh_lib = lib('lib.sh', p, d)
    ps_lib = lib('lib.ps1', p, d)
    for os_ in ('linux', 'macos'):
        open(os.path.join(out, os_, '_%s.sh' % p), 'w', encoding='utf-8', newline='\n').write(sh_lib)
    open(os.path.join(out, 'windows', '_%s.ps1' % p), 'w', encoding='utf-8', newline='\n').write(ps_lib)
    for j in js:
        s = sh_script(j, p, d, ex)
        for os_ in ('linux', 'macos'):
            open(os.path.join(out, os_, j['job'] + '.sh'), 'w', encoding='utf-8', newline='\n').write(s)
        open(os.path.join(out, 'windows', j['job'] + '.ps1'), 'w', encoding='utf-8', newline='\n').write(ps_script(j, p, d, ex))
    open(os.path.join(out, 'pack.config'), 'w', encoding='utf-8', newline='\n').write(pack_config(p, d, js))
    print('%s: %d jobs, %d metrics' % (p, len(js), sum(len(job_metrics(j, d)) for j in js)))
