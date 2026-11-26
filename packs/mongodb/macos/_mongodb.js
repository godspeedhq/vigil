// _mongodb.js - what the mongodb pack's jobs share: the login, and printing
// a metric. Each job's .js loads it; mongosh runs the job with no
// connection of its own (--nodb), so the login is made here, from the
// environment, and never appears on a command line.
//
// Copyright (c) Bankole Ogundero and the Vigil contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. Run it at your own risk: review it first, and test it before you
// rely on it. In no event shall the authors or copyright holders be liable
// for any claim, damages or other liability arising from its use. See the
// LICENSE file for the full terms.
//
// MONGODB_URL       the server, a mongodb:// URL without a password
//                   (default mongodb://localhost:27017); one server is
//                   read, as it is, unless the URL names a replica set
// MONGODB_USER      the user (default vigil), with the clusterMonitor role;
//                   empty for a server without authentication
// MONGODB_PASSWORD  its password (a secret)
// MONGODB_CACERT    over TLS, the CA file, when the system's are not enough
// MONGODB_MOST      how many of a list to print (default 50)

const env = process.env;
const job = globalThis.vigilJob || 'mongodb';

function fail(msg) {
    process.stderr.write(job + ': ' + msg + '\n');
    quit(1);
}
// A tag's value: no spaces, quotes or control characters, never empty, at
// most 120 characters.
function tag(v) {
    const s = String(v === undefined || v === null ? '' : v).replace(/[^A-Za-z0-9@._:/+-]/g, '_').slice(0, 120);
    return s === '' ? 'none' : s;
}
// A number from anything: MongoDB's Long, Int32, Double and Decimal128
// alike; 0 when there is none. Two decimals at most.
function n(v) {
    if (v === undefined || v === null) return 0;
    if (typeof v === 'boolean') return v ? 1 : 0;
    const x = Number(typeof v === 'object' && typeof v.toString === 'function' && !(v instanceof Date) ? v.toString() : v);
    return isFinite(x) ? Math.round(x * 100) / 100 : 0;
}
function m(name, v, tags) {
    print('metric ' + name + ' ' + n(v) + (tags ? ' ' + tags : ''));
}
const most = (() => {
    const s = env.MONGODB_MOST === undefined || env.MONGODB_MOST === '' ? '50' : env.MONGODB_MOST;
    if (!/^[0-9]+$/.test(s)) fail("MONGODB_MOST is '" + s + "': a number");
    return Number(s);
})();

// vigilConnect(): the admin database, logged in; or, when the server does not
// answer, "metric up 0" and the run ends, successfully: a server down is a
// reading.
function vigilConnect() {
    let url = env.MONGODB_URL || 'mongodb://localhost:27017';
    if (!/^mongodb(\+srv)?:\/\//.test(url)) fail("MONGODB_URL is '" + url + "': a mongodb:// URL");
    if (/^mongodb(\+srv)?:\/\/[^/@]*:[^/@]*@/.test(url)) fail('MONGODB_URL holds a password: set it with vigil secret set MONGODB_PASSWORD instead');
    const opts = [];
    if (!/[?&]serverSelectionTimeoutMS=/.test(url)) opts.push('serverSelectionTimeoutMS=10000');
    if (!/[?&]connectTimeoutMS=/.test(url)) opts.push('connectTimeoutMS=10000');
    // One server, as it is: never moved to the primary.
    if (!/[?&](replicaSet|directConnection)=/.test(url) && !/^mongodb\+srv:/.test(url) && !/,/.test(url.split('/')[2])) opts.push('directConnection=true');
    if (env.MONGODB_CACERT) opts.push('tls=true', 'tlsCAFile=' + encodeURIComponent(env.MONGODB_CACERT));
    if (opts.length) url += (url.includes('?') ? '&' : (/^mongodb(\+srv)?:\/\/[^/]*$/.test(url) ? '/?' : '?')) + opts.join('&');
    let admin;
    try {
        admin = new Mongo(url).getDB('admin');
        admin.runCommand({ ping: 1 });
    } catch (e) {
        if (/ServerSelection|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|EHOSTUNREACH|connect|timed out/i.test(String(e.name) + ' ' + String(e.message))) {
            print('metric up 0');
            quit(0);
        }
        fail(String(e.message).split('\n')[0]);
    }
    const user = env.MONGODB_USER === undefined ? 'vigil' : env.MONGODB_USER;
    if (user !== '') {
        if (!env.MONGODB_PASSWORD) fail('no password for ' + user + ': vigil secret set MONGODB_PASSWORD');
        try { admin.auth(user, env.MONGODB_PASSWORD); }
        catch (e) { fail('MongoDB refused the login: MONGODB_USER or MONGODB_PASSWORD is wrong (' + String(e.message).split('\n')[0] + ')'); }
    }
    print('metric up 1');
    return admin;
}
// vigilRun(db, command): its answer; a user without clusterMonitor ends the run,
// saying so.
function vigilRun(db, cmd) {
    // Assigned, then returned: mongosh awaits the command where it is
    // assigned, so a refusal is caught here, not after the function returns.
    try { const r = db.runCommand(cmd); return r; }
    catch (e) {
        if (e.codeName === 'Unauthorized' || e.code === 13) fail((env.MONGODB_USER || 'vigil') + ' may not run ' + Object.keys(cmd)[0] + ': grant it the clusterMonitor role (packs/mongodb/README.md)');
        throw e;
    }
}
