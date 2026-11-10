# 38. Say what a pack needs when it is turned on

Asked by the owner on 2026-11-10: "I don't want someone to enable a pack and
be blind till the metrics are failing."

## The problem

`vigil pack enable postgres` prints `on: postgres_status` and
`on: postgres_size`, exits 0, and says nothing else. The jobs need a secret
(`POSTGRES_MONITOR_PASSWORD`) and a read-only role in the database, and they
fail every run until both are there. The steps are in `packs/README.md` and
in `pack.config`'s comments, but the README never reaches the machine (a
release ships each pack's `pack.config` and scripts only), and nobody reads
comments at the moment they turn a pack on. `vigil precheck` does name the
missing secret, if one thinks to run it.

`pack.config`'s `vigil = 0.3.0`, the oldest Vigil the pack runs on, does not
say so either.

## Proposed

1. **`vigil pack enable` says what the pack's jobs need,** after its `on:`
   lines, and again when the pack is already on. The pack stays on and the
   command exits 0: turning it on first and setting it up after is the
   normal order on a system install, where the secret is set as the service
   account.

   ```
   $ vigil pack enable postgres
   on: postgres_status
   on: postgres_size
   needs secret:POSTGRES_MONITOR_PASSWORD: not set: vigil secret set POSTGRES_MONITOR_PASSWORD, as the account Vigil runs as
   needs a read-only role, as a database administrator: CREATE ROLE vigil_monitor LOGIN PASSWORD '...' IN ROLE pg_monitor
   settings in vigil.config: PGHOST=localhost PGPORT=5432 PGUSER=vigil_monitor PGDATABASE=postgres
   ```

2. **Secrets are read from the jobs, not declared again.** Each `secret =`
   line of the pack's jobs, as they are in `vigil.config` (so a reference
   the operator changed to `env:` or `store:` is the one shown):
   - `secret:NAME`: `set` or `not set`, by whether the file is in Vigil's
     store, never by reading it. When this account cannot look in the store
     (an admin prompt, a LocalSystem service's store on Windows), it says
     so, and points at `vigil precheck` as the service account, rather than
     a false `not set`.
   - `env:NAME`: from the environment Vigil runs in.
   - `store:...`: not asked, which could take seconds: `vigil precheck`
     checks it.

3. **Settings are the jobs' `env` lines,** which are never secrets, so the
   operator sees what can be changed without opening the file.

4. **`needs` in `[pack]`,** optional, one line per thing Vigil cannot see
   from the jobs: a database role, nginx's `stub_status` page. Plain text,
   repeated per line. A pack that needs nothing (base) prints only its `on:`
   lines, as now. A Vigil that does not know the key ignores it.

5. **`vigil pack list` shows the same lines** under each pack, so what a
   pack needs can be read later without turning it on again.

6. **`vigil =` keeps its name,** with a comment above it in every
   `pack.config` and in `tools/new-pack.sh`'s: the oldest Vigil the pack
   runs on. A rename (`min_vigil_version`) was weighed and set aside: a
   released Vigil reading only the new name would lose the check.

7. **postgres and nginx get `needs` lines;** each pack's version goes up,
   as its `pack.config` changes.

## Not included

- **Checking what Vigil cannot see:** whether the role exists, whether
  nginx serves its page. The job's first run reports those.
- **Refusing to turn on a pack until its secret is set.**

## Tests

- `pack.sh` and `Pack.ps1`: a pack with `needs`, `env` and a `secret:`
  reference: the lines after `enable`, `set` once the secret is, the
  reference changed to `env:` and to `store:`, the lines under
  `pack list`; a pack with none of them says only what is on.
- `tools/check-pack.sh` accepts `needs`, and `new-pack.sh` writes a
  placeholder for it.

## Done when

- `vigil pack enable` and `vigil pack list` say, on Linux, macOS and
  Windows, what a pack's jobs need and whether each secret is there.
- Specification §18.10, `packs/README.md` and CONTRIBUTING describe
  `needs` and the comment on `vigil`.
