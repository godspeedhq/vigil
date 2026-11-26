// _databases.js - the mongodb pack's databases job, run by databases.sh
// (databases.ps1 on Windows) with mongosh: listDatabases, then dbStats for
// each. Its metrics are in the header of databases.sh.
//
// Copyright (c) Bankole Ogundero and the Vigil contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. Run it at your own risk: review it first, and test it before you
// rely on it. In no event shall the authors or copyright holders be liable
// for any claim, damages or other liability arising from its use. See the
// LICENSE file for the full terms.

globalThis.vigilJob = 'databases';
load(require('path').join(__dirname, '_mongodb.js'));

const admin = vigilConnect();
const list = (vigilRun(admin, { listDatabases: 1 }).databases || []).slice().sort((a, b) => n(b.sizeOnDisk) - n(a.sizeOnDisk) || String(a.name).localeCompare(String(b.name)));
m('databases', list.length);
m('size_bytes', list.reduce((s, d) => s + n(d.sizeOnDisk), 0));
for (const d of list.slice(0, most)) {
    const t = 'db=' + tag(d.name);
    m('db_size_bytes', d.sizeOnDisk, t);
    const st = vigilRun(admin.getSiblingDB(d.name), { dbStats: 1 });
    m('db_data_bytes', st.dataSize, t);
    m('db_index_bytes', st.indexSize, t);
    m('db_collections', st.collections, t);
    m('db_indexes', st.indexes, t);
    m('db_documents', st.objects, t);
}
if (list.length > most) m('databases_not_shown', list.length - most);
