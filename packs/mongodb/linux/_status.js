// _status.js - the mongodb pack's status job, run by status.sh (status.ps1
// on Windows) with mongosh: one serverStatus. Its metrics are in the
// header of status.sh.
//
// Copyright (c) Bankole Ogundero and the Vigil contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. Run it at your own risk: review it first, and test it before you
// rely on it. In no event shall the authors or copyright holders be liable
// for any claim, damages or other liability arising from its use. See the
// LICENSE file for the full terms.

globalThis.vigilJob = 'status';
load(require('path').join(__dirname, '_mongodb.js'));

const admin = vigilConnect();
const s = vigilRun(admin, { serverStatus: 1 });
const g = (o, ...k) => k.reduce((x, y) => (x === undefined || x === null ? undefined : x[y]), o);
print('metric info 1 version=' + tag(s.version) + ' engine=' + tag(g(s, 'storageEngine', 'name')));
m('uptime_seconds', s.uptime);
const c = s.connections || {};
m('connections', c.current);
m('connections_available', c.available);
if (n(c.current) + n(c.available) > 0) m('connections_pct', 100 * n(c.current) / (n(c.current) + n(c.available)));
if (c.active !== undefined) m('connections_active', c.active);
m('connections_created_count', c.totalCreated);
for (const k of ['insert', 'query', 'update', 'delete', 'getmore', 'command']) m('operations_count', g(s, 'opcounters', k), 'op=' + k);
// The time operations took, since the server started: its total over its
// count, in milliseconds.
for (const k of ['reads', 'writes', 'commands']) {
    const l = g(s, 'opLatencies', k);
    if (l) m('latency_avg_ms', n(l.ops) > 0 ? n(l.latency) / n(l.ops) / 1000 : 0, 'op=' + k);
}
m('queued', g(s, 'globalLock', 'currentQueue', 'readers'), 'for=read');
m('queued', g(s, 'globalLock', 'currentQueue', 'writers'), 'for=write');
m('memory_resident_bytes', n(g(s, 'mem', 'resident')) * 1048576);
const wc = g(s, 'wiredTiger', 'cache');
if (wc) {
    const used = n(wc['bytes currently in the cache']), max = n(wc['maximum bytes configured']), dirty = n(wc['tracked dirty bytes in the cache']);
    m('cache_bytes', used);
    m('cache_max_bytes', max);
    if (max > 0) {
        m('cache_pct', 100 * used / max);
        m('cache_dirty_pct', 100 * dirty / max);
    }
    m('cache_evicted_by_threads_count', wc['pages evicted by application threads']);
}
m('cursors_open', g(s, 'metrics', 'cursor', 'open', 'total'));
m('cursors_timed_out_count', g(s, 'metrics', 'cursor', 'timedOut'));
for (const k of ['regular', 'warning', 'msg', 'user']) m('asserts_count', g(s, 'asserts', k), 'kind=' + k);
m('page_faults_count', g(s, 'extra_info', 'page_faults'));
m('network_in_bytes_count', g(s, 'network', 'bytesIn'));
m('network_out_bytes_count', g(s, 'network', 'bytesOut'));
const tx = s.transactions;
if (tx) {
    m('transactions_open', tx.currentOpen);
    m('transactions_aborted_count', tx.totalAborted);
}
