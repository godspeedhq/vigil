#!/usr/bin/env bash
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Backlog 67 end to end, part A, on Fedora (vigil-test): a Git source served
# over SSH (a bare repository, keys restricted to git-shell), a PostgreSQL to
# watch, its monitor password in OpenBao, and this host's Vigil reading its
# configuration from the source. Secrets travel through stdin or a 600 file,
# never argv, and are never printed.
set -u
W=$HOME/fleet-e2e
R=$W/fedora
BK=$HOME/vigil-demo/tests/integration/backends
bao() { "$HOME/vigil-demo-work/bao.sh" "$@"; }
v() { bash "$R/app/vigil" --root "$R" "$@" < /dev/null; }
say() { printf '\n$ %s\n' "$*"; }

mkdir -p "$W" && cd "$W" || exit 1
rm -rf "$R" fleet.git admin && mkdir -p "$R"
tar -xzf "$HOME/fleet-bundle.tgz" -C "$R"

# The Git server: a bare repository; this host's key may only run git-shell.
[ -f key ] || ssh-keygen -q -t ed25519 -N '' -f key -C fleet-e2e-fedora
git init -q --bare -b main fleet.git
grep -qF "$(cut -d' ' -f2 key.pub)" ~/.ssh/authorized_keys ||
    printf 'restrict,command="git-shell -c \\"$SSH_ORIGINAL_COMMAND\\"" %s\n' "$(cat key.pub)" >> ~/.ssh/authorized_keys
printf '[core]\n\tsshCommand = ssh -i %s/key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=%s/known_hosts\n[user]\n\tname = fleet admin\n\temail = fleet@example.invalid\n' "$W" "$W" > gitconfig
export GIT_CONFIG_GLOBAL=$W/gitconfig
URL=vigil-test@127.0.0.1:fleet-e2e/fleet.git

# PostgreSQL 17, on 127.0.0.1:55432, with a read-only monitor role.
docker rm -f fleet-e2e-pg > /dev/null 2>&1
(umask 077 && printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 16)" > pg.env)
docker run -d -q --name fleet-e2e-pg --env-file pg.env -p 127.0.0.1:55432:5432 postgres:17-alpine > /dev/null
rm -f pg.env
# The image starts a server to initialise, stops it, then starts the real
# one: wait for that one, on TCP.
for i in $(seq 90); do docker exec fleet-e2e-pg pg_isready -q -h 127.0.0.1 -U postgres 2> /dev/null && break; sleep 1; done
pw=$(openssl rand -hex 16)
for i in $(seq 10); do
    printf "CREATE ROLE vigil_monitor LOGIN PASSWORD '%s' IN ROLE pg_monitor;\n" "$pw" | docker exec -i fleet-e2e-pg psql -q -h 127.0.0.1 -U postgres > /dev/null 2>&1 && { echo 'PostgreSQL: role vigil_monitor created'; break; }
    sleep 2
done

# Its password in OpenBao, at the name the pack expects; a token that reads
# only that, into this host's Vigil secret store.
printf '%s' "$pw" | bao kv put -mount=secret POSTGRES_MONITOR_PASSWORD value=- > /dev/null && echo 'OpenBao: secret/POSTGRES_MONITOR_PASSWORD written'
unset pw
printf 'path "secret/data/POSTGRES_MONITOR_PASSWORD" { capabilities = ["read"] }\n' | bao policy write fleet-e2e - > /dev/null
v init empty --instance fedora-e2e --backend file > /dev/null
bao token create -policy=fleet-e2e -ttl=24h -field=token | bash "$R/app/vigil" --root "$R" secret set BAO_TOKEN --stdin
cp "$BK/.secrets/tls/ca.pem" "$R/config/store-ca.pem"

# Install first (each host, as a deployment tool would), then commit.
say 'vigil pack install postgres        # before the pointer file: a local configuration'
v pack install postgres | head -n 2
printf '[vigil]\nconfig_source = central\nconfig_file   = hosts/fedora.config\n\n[source.central]\ntype        = git\nurl         = %s\nref         = main\ncheck_every = 30s\n' "$URL" > "$R/config/vigil.config"
say 'cat config/vigil.config'
cat "$R/config/vigil.config"
say 'vigil pack enable postgres         # now its configuration comes from a source'
v pack enable postgres; echo "(exit $?)"

say 'vigil pack config postgres     # printed, then pasted into hosts/fedora.config'
v pack config postgres > "$W/postgres.jobs"
sed -n '1,12p' "$W/postgres.jobs"; echo '...'

mkdir admin && git -C admin init -q -b main && git -C admin remote add origin "$URL"
mkdir -p admin/hosts
base='[scheduler]\ntick = 10s\n\n[backend.file]\npath = metrics/vigil.prom\n\n[runner.sh]\ncommand = /bin/bash\n\n[runners]\n.sh = sh\n'
{
    printf '[vigil]\ninstance = fedora-e2e\n\n'"$base"'\n'
    printf '[secret_store.bao]\ntype     = hashicorp_vault\nurl      = https://127.0.0.1:8200\nauth     = token\ntoken    = secret:BAO_TOKEN\nca_file  = config/store-ca.pem\n\n'
    # What differs on this host: PostgreSQL on 127.0.0.1:55432, and its
    # password in OpenBao (secret: changed to store:bao/, as an operator would).
    sed 's/^env = PGHOST=localhost$/env = PGHOST=127.0.0.1/; s/^env = PGPORT=5432$/env = PGPORT=55432/; s#^\(secret = [A-Z_]*=\)secret:#\1store:bao/#' "$W/postgres.jobs"
} > admin/hosts/fedora.config
git -C admin add -A && git -C admin commit -q -m 'fedora: the postgres pack' && git -C admin push -q origin main 2>&1 | grep -v '^Warning: Permanently added'
say 'git log --oneline     # the source'
git -C admin log --oneline
