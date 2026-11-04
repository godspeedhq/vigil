# Service packs

Optional monitoring for what a server runs: `postgres` and `nginx` first,
as they are easy to test in CI, then others such as `mssql`.

## Scope
- Vigil may detect a service and suggest its pack; only the user enables it
  (`vigil pack enable postgres`). Monitoring never starts touching a database
  uninvited.
- Database packs log in through `secret:` references, with a read-only
  account.

## Done when
- Each pack is tested against the real service in CI.

## Closed

Closed on 2026-11-04 (#88).

**Done:**
- `packs/postgres`: `postgres_status` and `postgres_size`, on Linux, macOS and Windows, as a read-only `pg_monitor` role whose password is a `secret:` reference.
- `packs/nginx`: `nginx_status` from `stub_status`, on Linux and macOS.
- Tested against the real services in CI: PostgreSQL 18 and nginx in Docker on Ubuntu (34 passed), and the runner's PostgreSQL 17 on Windows with PowerShell 5.1 and 7 (19 passed each).
- On Fedora, against the backends environment's `postgres-pack` and `nginx-pack`: 34 passed, with evidence in `tests/integration/backends/reports/runs/2026-11-04/fedora/pack-postgres-nginx`.
- Setup and readings in `packs/README.md`.

**Not done:**
- **Detecting a service and suggesting its pack:** not built. A pack is enabled by name only.
- **nginx on Windows:** no script.
- **Other services** such as `mssql`: not started.
