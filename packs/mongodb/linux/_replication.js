// _replication.js - the mongodb pack's replication job, run by
// replication.sh (replication.ps1 on Windows) with mongosh: hello,
// replSetGetStatus, and the oplog's first and last entries. Its metrics
// are in the header of replication.sh.
//
// Copyright (c) Bankole Ogundero and the Vigil contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. Run it at your own risk: review it first, and test it before you
// rely on it. In no event shall the authors or copyright holders be liable
// for any claim, damages or other liability arising from its use. See the
// LICENSE file for the full terms.

globalThis.vigilJob = 'replication';
load(require('path').join(__dirname, '_mongodb.js'));

const admin = vigilConnect();
let st;
try { st = admin.runCommand({ replSetGetStatus: 1 }); }
catch (e) {
    // A server not started with --replSet: a reading, not an error.
    if (e.code === 76 || e.codeName === 'NoReplicationEnabled') {
        print('metric info 1 set=none role=standalone');
        m('replicated', 0);
        quit(0);
    }
    if (e.code === 94 || e.codeName === 'NotYetInitialized') {
        print('metric info 1 set=none role=uninitialized');
        m('replicated', 0);
        quit(0);
    }
    if (e.codeName === 'Unauthorized' || e.code === 13) fail((env.MONGODB_USER || 'vigil') + ' may not run replSetGetStatus: grant it the clusterMonitor role (packs/mongodb/README.md)');
    throw e;
}
// A member's state, as words: "(not reachable/healthy)" is not_reachable_healthy.
const state = s => String(s || 'unknown').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'unknown';
const members = st.members || [];
const me = members.find(x => x.self) || {};
print('metric info 1 set=' + tag(st.set) + ' role=' + state(me.stateStr));
m('replicated', 1);
const primary = members.find(x => x.stateStr === 'PRIMARY');
// How far behind: against the primary's last write, or, with no primary,
// the furthest ahead of those that answer.
const t = x => (x.optimeDate instanceof Date ? x.optimeDate.getTime() : 0);
const ahead = primary ? t(primary) : Math.max(0, ...members.filter(x => n(x.health) === 1).map(t));
const data = members.filter(x => ['PRIMARY', 'SECONDARY', 'RECOVERING', 'STARTUP2', 'ROLLBACK'].includes(x.stateStr));
const lag = x => (t(x) > 0 && ahead > 0 ? Math.max(0, (ahead - t(x)) / 1000) : 0);
m('members', members.length);
m('members_healthy', members.filter(x => n(x.health) === 1).length);
m('members_down', members.filter(x => n(x.health) !== 1).length);
m('primary', primary ? 1 : 0);
m('secondaries', members.filter(x => x.stateStr === 'SECONDARY').length);
m('lag_seconds_max', Math.max(0, ...data.filter(x => n(x.health) === 1 && x.stateStr !== 'PRIMARY').map(lag)));
if (me.stateStr === 'SECONDARY') m('lag_seconds', lag(me));
for (const x of members.slice(0, most)) {
    const tags = 'member=' + tag(x.name) + ' state=' + state(x.stateStr);
    m('member_health', x.health, tags);
    if (n(x.health) === 1 && data.includes(x)) m('member_lag_seconds', lag(x), tags);
}
if (members.length > most) m('members_not_shown', members.length - most);
// The oplog: how much of its history this server keeps, as time.
const oplog = admin.getSiblingDB('local').getCollection('oplog.rs');
try {
    const first = oplog.find({}, { ts: 1 }).sort({ $natural: 1 }).limit(1).toArray()[0];
    const last = oplog.find({}, { ts: 1 }).sort({ $natural: -1 }).limit(1).toArray()[0];
    if (first && last) m('oplog_window_hours', (last.ts.getHighBits() - first.ts.getHighBits()) / 3600);
    const cs = admin.getSiblingDB('local').runCommand({ collStats: 'oplog.rs' });
    m('oplog_bytes', cs.size);
    m('oplog_max_bytes', cs.maxSize);
} catch (e) {
    if (e.codeName === 'Unauthorized' || e.code === 13) fail((env.MONGODB_USER || 'vigil') + ' may not read the oplog: grant it the clusterMonitor role (packs/mongodb/README.md)');
    throw e;
}
