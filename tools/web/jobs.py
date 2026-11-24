# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The web packs' jobs, for tools/web/gen.py (tools/web/DESIGN.md): what each
reports, its metrics, how to read them, its settings, and its code for bash
and, where it has one, PowerShell. Each pack's own jobs are in <pack>.py; the
access log and certificate jobs, which nginx and httpd share (and Caddy the
certificates), are made here. In the text and the code, @P@ is the server's
name, @p@ the pack's, @E@ the prefix of its settings."""

M = lambda *pairs: list(pairs)

JOBS = []


def job(**j):
    j.setdefault('ps', None)
    j.setdefault('env', [])
    j.setdefault('needs_sh', ['curl'])
    JOBS.append(j)


LOG_METRICS = M(
    ('log_found', '1 when the access log is there, else 0'),
    ('log_readable', '1 when this account may read it, else 0 (and nothing more is read)'),
    ('log_bytes', "the log's size"),
    ('window_complete', '1 when the whole minute was read; 0 when the log grew faster than @E@_LOG_MAX_MB '
                        'a minute, and the counts are of its end only'),
    ('requests', 'requests logged in the last whole minute'),
    ('status_1xx', 'of those, answered 1xx'),
    ('status_2xx', 'answered 2xx'),
    ('status_3xx', 'answered 3xx'),
    ('status_4xx', 'answered 4xx: the client asked wrong (not found, refused, too many)'),
    ('status_5xx', 'answered 5xx: the server failed'),
    ('errors_4xx_pct', '4xx, as a percentage of the requests'),
    ('errors_5xx_pct', '5xx, as a percentage of the requests'),
    ('bytes_sent', 'bytes sent in answers'),
    ('clients', 'client addresses seen'),
    ('status', 'requests answered with one status, tagged code=<it> (each one seen)'),
    ('method', 'requests by method, tagged method=<GET, POST, HEAD, PUT, DELETE, PATCH, OPTIONS or other>'),
    ('response_avg_ms', 'time to answer, on average, when the log records it (@LOGTIME@)'),
    ('response_p50_ms', 'half the requests were answered within this'),
    ('response_p90_ms', '90% were answered within this'),
    ('response_p99_ms', '99% were answered within this'),
    ('response_max_ms', 'the slowest'),
)
UPSTREAM_METRICS = M(
    ('upstream_avg_ms', "the upstream's time to answer, on average, when the log records it (urt=$upstream_response_time)"),
    ('upstream_p50_ms', "half the upstream's answers came within this"),
    ('upstream_p90_ms', '90% came within this'),
    ('upstream_p99_ms', '99% came within this'),
    ('upstream_max_ms', 'the slowest'),
)

LOG_PS = r'''$f = $env:@E@_ACCESS_LOG; if (-not $f) { $f = '@LOGWIN@' }
$cap = 32; if ($env:@E@_LOG_MAX_MB) { $cap = [int]$env:@E@_LOG_MAX_MB }
Read-LogMinute $f $cap
exit 0
'''


def log_job(pack, logdefault, logwin, logtime, upstream, healthy_extra=''):
    metrics = [(n, d.replace('@LOGTIME@', logtime)) for n, d in LOG_METRICS] + (UPSTREAM_METRICS if upstream else [])
    job(pack=pack, job='log', metric='log', when='run_every   = 1m', runtime='50s',
        env=[('@E@_ACCESS_LOG', '' if ' ' in logdefault else logdefault), ('@E@_LOG_MAX_MB', '32')],
        needs_sh=[],
        title="@P@'s access log, minute by minute",
        what="Reads the last whole minute of @P@'s access log, in the combined format, and reports the "
             "requests in it: by status class and status, by method, the bytes sent, the clients, and, "
             "when the log records it, how long the answers took (" + logtime + ")" +
             (" and how long the upstream took (urt=$upstream_response_time)" if upstream else '') +
             ". It reads only the end of the log, at most @E@_LOG_MAX_MB (32 by default), so it costs the "
             "same on a log of any size, and keeps nothing between runs. It never prints a path, a query "
             "or an address: only counts.",
        reads="Reads @E@_ACCESS_LOG (default " + (' '.join(logdefault.split()) if ' ' not in logdefault else
                                                  'the first of ' + ', '.join(logdefault.split()) + ' that is there') +
              " on Linux and macOS, " + logwin +
              " on Windows). The account Vigil runs as must be allowed to read it (packs/@p@/README.md "
              "says how); until it is, the job reports log_readable 0 and nothing else.",
        metrics=metrics,
        healthy='window_complete 1; errors_5xx_pct below 1; response_p99_ms steady.' + healthy_extra,
        watch='errors_4xx_pct climbing (a broken link, a client retrying, a scan); response_p99_ms '
              'rising while requests do not; window_complete 0 (raise @E@_LOG_MAX_MB).',
        act='errors_5xx_pct above a few percent: the server or its upstream is failing (status says which: '
            '500, 502 bad gateway, 503 unavailable, 504 timed out); requests 0 on a busy site: nothing '
            'reaches it, or it stopped logging.',
        sh=r'''f=${@E@_ACCESS_LOG-}
if [ -z "$f" ]; then
    for f in @LOGDEFAULT@; do [ -e "$f" ] && break; done
fi
log_minute "$f" "${@E@_LOG_MAX_MB:-32}"
exit 0
'''.replace('@LOGDEFAULT@', logdefault),
        ps=LOG_PS.replace('@LOGWIN@', logwin),
        exit_sh='0, whatever the log holds; 1 never (an unreadable log is a reading)',
        exit_ps='0, whatever the log holds; 1 never (an unreadable log is a reading)')


TLS_METRICS = M(
    ('tls_up', '1 when the endpoint finished a TLS handshake, else 0; tagged endpoint=<host:port, or '
               'host:port/name>'),
    ('cert_expires_days', 'days until the certificate it served expires (below 0: expired), tagged endpoint'),
    ('cert_valid', '1 when today is within its dates, else 0, tagged endpoint'),
    ('cert_verified', '1 when it checks against the trusted CAs (or @E@_CACERT) and the name, else 0; '
                      "tagged endpoint and reason=<openssl's, or Windows' word>"),
    ('cert_info', 'always 1, tagged endpoint, issuer=<its CN> and protocol=<the TLS version agreed>'),
    ('certs_not_shown', 'endpoints past the first 50, left out'),
)

TLS_PS = r'''$list = @(@TLSLIST@)
Read-Certs $list
exit 0
'''


def tls_job(pack, endpoints_sh, endpoints_ps, default, what_extra="", reads_extra="", extra_env=(), needs=("openssl",),
            env_default=None, extra_metrics=()):
    job(pack=pack, job='tls', metric='tls', when='run_every   = 15m', runtime='2m',
        env=list(extra_env) + [("@E@_TLS", default if env_default is None else env_default), ("@E@_CACERT", "")],
        needs_sh=list(needs),
        title="the certificates @P@ serves",
        what="Makes a TLS handshake with each of @P@'s https endpoints and reports the certificate it "
             "serves: the days until it expires, whether it is within its dates, and whether it checks "
             "against the trusted CAs and the name asked for. It reads what clients get, so it also "
             "catches a certificate renewed on disk that @P@ has not loaded yet." + what_extra +
             " Nothing is sent but the handshake.",
        reads=reads_extra + "@E@_TLS lists the endpoints, separated by spaces: host:port, or host:port/name to "
              "ask for a name (SNI) other than the host (default " + default + "). @E@_CACERT, a CA file, "
              "checks a private CA.",
        metrics=list(extra_metrics) + TLS_METRICS,
        healthy='tls_up 1; cert_expires_days above 30; cert_valid 1; cert_verified 1.',
        watch='cert_expires_days below 30: renewal should have happened by now.',
        act='cert_expires_days below 7, or cert_valid 0: clients will refuse it; cert_verified 0: clients '
            'that check (all browsers) refuse it now (reason says why); tls_up 0: nothing answers TLS there.',
        # ${list[@]+...}: an empty list under set -u, on bash 3.2 (macOS).
        sh=endpoints_sh + '\ncerts ${list[@]+"${list[@]}"}\nexit 0\n',
        ps=TLS_PS.replace('@TLSLIST@', endpoints_ps),
        exit_sh='0, whatever the certificates; 1 if openssl is missing',
        exit_ps='0, whatever the certificates')
