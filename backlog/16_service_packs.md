# Service packs

Optional monitoring for what a server runs: `postgres` and `nginx` first,
as they are easy to test in CI, then others such as `mssql`.

## Scope
- Vigil may detect a service and suggest its pack; only the user enables it
  (`vigil pack add postgres`). Monitoring never starts touching a database
  uninvited.
- Database packs log in through `secret:` references, with a read-only
  account.

## Done when
- Each pack is tested against the real service in CI.
