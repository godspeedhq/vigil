# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The otelcol pack's jobs (tools/obs/DESIGN.md).

The Collector has named its counters with and without "_total" over the
years: each total here is the sum of both names, of which a version has
one."""
from jobs import job, page, table

PACK = dict(
    P='the OpenTelemetry Collector', E='OTELCOL', url='http://localhost:8888', version='1.0.0',
    description='the OpenTelemetry Collector: what its receivers accepted and refused, what its exporters sent '
                'and failed to send (for each exporter), and how full their queues are, for traces, metrics '
                'and logs',
    works='the OpenTelemetry Collector 0.100 and later, core and contrib (tested: contrib 0.166.0)',
    head=['otelcol - an OpenTelemetry Collector, from its own metrics page: what',
          'its receivers accept and refuse, what its exporters send and fail to',
          'send, and how full their queues are.'],
    needs=["its own metrics page, which it serves on localhost:8888 by default (service::telemetry::metrics); "
           'where it is elsewhere: env = OTELCOL_URL=... on each job',
           'for every reading: service::telemetry::metrics::level: detailed (the default, normal, leaves out '
           'the queue readings on some versions)',
           'where it asks for a login (a proxy in front of it): OTELCOL_USER and secret = '
           'OTELCOL_PASSWORD=secret:OTELCOL_PASSWORD, or secret = OTELCOL_TOKEN=secret:OTELCOL_TOKEN',
           "for the Collector's CPU: the base pack's processes job"])

READS = "Reads @E@_URL (default @URL@): /metrics, the Collector's page about itself"
SIGNALS = (('spans', 'spans'), ('metric_points', 'metric points'), ('log_records', 'log records'))


def total(name, metric, doc, filters=''):
    """A running total, whichever of metric and metric_total this version has."""
    return [('_a_%s|sum|%s|%s' % (name, metric, filters), None),
            ('_b_%s|sum|%s_total|%s' % (name, metric, filters), None),
            ('%s|add|_a_%s|_b_%s' % (name, name, name), doc)]


def each(name, metric, label, tag, doc):
    """The same total, for each value of a label."""
    return [('%s|by?|%s||%s:%s' % (name, metric, label, tag), doc),
            ('%s|by?|%s_total||%s:%s' % (name, metric, label, tag), doc)]


job(pack='otelcol', job='status', metric='', when='run_every   = 1m', runtime='30s',
    title='is the Collector up',
    what="Reports whether the Collector answers, its version, how long it has run, and the memory it holds.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('version|info|target_info||service_version:version,service_name:name',
             'always 1, tagged version=<its version> and name=<the distribution: otelcol, otelcol-contrib ...>'),
            ('_u1|sum|otelcol_process_uptime', None),
            ('_u2|sum|otelcol_process_uptime_total', None),
            ('_u3|sum|otelcol_process_uptime_seconds_total', None),
            ('_u12|add|_u1|_u2', None),
            ('uptime_seconds|add|_u12|_u3', 'seconds since it started'),
            ('_m1|sum|otelcol_process_memory_rss', None),
            ('_m2|sum|otelcol_process_memory_rss_bytes', None),
            ('memory_rss_bytes|add|_m1|_m2', 'memory it holds (resident)'),
            ('heap_bytes|sum|otelcol_process_runtime_heap_alloc_bytes', 'of that, its heap in use'),
        ),
    ],
    healthy='up 1; uptime_seconds growing from one run to the next.',
    watch='memory_rss_bytes climbing towards the memory_limiter\'s limit (it will start refusing data).',
    act='up 0: nothing it receives goes anywhere; uptime_seconds going back to a small number again and again: '
        'it is restarting (out of memory, or a configuration it cannot start with).',
    # The page lists everything at once, however large the pipeline.
    )

RX = []
for key, words in SIGNALS:
    RX += total('accepted_%s_count' % key, 'otelcol_receiver_accepted_%s' % key, '%s its receivers took (a running total)' % words)
    RX += total('refused_%s_count' % key, 'otelcol_receiver_refused_%s' % key,
                '%s its receivers refused: the pipeline behind them would not take them (a running total)' % words)
    RX += total('failed_%s_count' % key, 'otelcol_receiver_failed_%s' % key,
                '%s its receivers could not process: an error of its own (a running total)' % words)
for key, words in SIGNALS:
    RX += each('refused_%s' % key, 'otelcol_receiver_refused_%s' % key, 'receiver', 'receiver',
               '%s refused, for each receiver, tagged receiver=<its name>' % words)

job(pack='otelcol', job='receivers', metric='receivers', when='run_every   = 1m', runtime='30s',
    title="what the Collector's receivers accept and refuse",
    what="Reports what the Collector's receivers accepted, refused and failed to process, for spans, metric "
         "points and log records, and the refusals for each receiver. A receiver refuses what the pipeline "
         "behind it will not take: the memory limiter is over its limit, or an exporter with no queue failed.",
    reads=READS + ".",
    steps=[page('/metrics'), table(*RX)],
    healthy='the accepted counts moving; the refused and failed counts not moving.',
    watch='an accepted count that stops moving while its senders run (they cannot reach the Collector).',
    act='a refused count moving: senders are told to retry, and lose data when they give up; refused_spans, '
        'refused_metric_points or refused_log_records says which receiver, and the exporters job why (a queue '
        'that is full, sends that fail), or the memory limiter is refusing.')

TX = []
for key, words in SIGNALS:
    TX += total('sent_%s_count' % key, 'otelcol_exporter_sent_%s' % key, '%s its exporters delivered (a running total)' % words)
    TX += total('send_failed_%s_count' % key, 'otelcol_exporter_send_failed_%s' % key,
                '%s its exporters could not deliver: lost, once the retries are spent (a running total)' % words)
    TX += total('enqueue_failed_%s_count' % key, 'otelcol_exporter_enqueue_failed_%s' % key,
                '%s dropped at once: the exporter\'s queue was full (a running total)' % words)
for key, words in SIGNALS:
    TX += each('send_failed_%s' % key, 'otelcol_exporter_send_failed_%s' % key, 'exporter', 'exporter',
               '%s that could not be delivered, for each exporter, tagged exporter=<its name>' % words)
TX += [
    ('queue_size|sum|otelcol_exporter_queue_size', 'batches waiting in the exporters\' queues'),
    ('queue_capacity|sum|otelcol_exporter_queue_capacity', 'how many may wait'),
    ('queue_fullest_pct|maxpct|otelcol_exporter_queue_size||otelcol_exporter_queue_capacity',
     'how full the fullest queue is, as a percentage of its own capacity'),
    ('queue|by|otelcol_exporter_queue_size||exporter', 'batches waiting, for each exporter, tagged exporter'),
    ('in_flight|sum|otelcol_exporter_in_flight_requests', 'requests its exporters are waiting on now'),
]

job(pack='otelcol', job='exporters', metric='exporters', when='run_every   = 1m', runtime='30s',
    title="what the Collector's exporters send, and what they lose",
    what="Reports what the Collector's exporters delivered and what they could not, for spans, metric points "
         "and log records and for each exporter, what was dropped because a queue was full, and how full the "
         "queues are. A queue fills when its destination is down or slower than what arrives.",
    reads=READS + ".",
    steps=[page('/metrics'), table(*TX)],
    healthy='the sent counts moving; the send_failed and enqueue_failed counts not moving; queue_fullest_pct near 0.',
    watch='queue_fullest_pct climbing: a destination is slower than what arrives, and queue says which '
          'exporter; when it reaches 100, everything new for that exporter is dropped.',
    act='a send_failed count moving: data is being lost, and send_failed_spans, send_failed_metric_points or '
        'send_failed_log_records says which exporter (its destination is down, refuses it, or answers too '
        'slowly); an enqueue_failed count moving: a queue is full and everything new for it is dropped.')
