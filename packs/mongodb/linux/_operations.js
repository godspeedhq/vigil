// _operations.js - the mongodb pack's operations job, run by operations.sh
// (operations.ps1 on Windows) with mongosh: currentOp, every user's, idle
// connections left out. Its metrics are in the header of operations.sh.
// An operation is named by its namespace, kind and ID, never by its text.
//
// Copyright (c) Bankole Ogundero and the Vigil contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. Run it at your own risk: review it first, and test it before you
// rely on it. In no event shall the authors or copyright holders be liable
// for any claim, damages or other liability arising from its use. See the
// LICENSE file for the full terms.

globalThis.vigilJob = 'operations';
load(require('path').join(__dirname, '_mongodb.js'));

const admin = vigilConnect();
const all = vigilRun(admin, { currentOp: 1, $all: true }).inprog || [];
// Operations a client asked for: not MongoDB's own background work, not
// this job's own currentOp.
const ops = all.filter(o => o.active && o.op && o.op !== 'none' && o.client !== undefined
    && !(o.command && o.command.currentOp))
    .sort((a, b) => n(b.microsecs_running) - n(a.microsecs_running));
const secs = o => n(o.microsecs_running) / 1e6;
m('running', ops.length);
m('slow', ops.filter(o => secs(o) > 60).length);
m('longest_seconds', ops.length ? secs(ops[0]) : 0);
m('waiting_for_lock', ops.filter(o => o.waitingForLock).length);
m('transactions_open', all.filter(o => o.transaction).length);
for (const o of ops.slice(0, 5)) {
    m('op_seconds', secs(o), 'ns=' + tag(o.ns) + ' op=' + tag(o.op) + ' id=' + tag(o.opid));
}
