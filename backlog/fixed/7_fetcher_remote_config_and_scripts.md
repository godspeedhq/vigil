# Fetching configuration and scripts: git, https, sftp, shares

The fetcher for `config_source` and job `source`s (spec 6.8, 6.9): fetch,
verify `sha256`, swap in atomically, keep the last good copy.

## Done when
- Each source type tested against a local server, both twins.

## Status
Done: `vigil_fetch` (fetch.sh, Fetch.ps1) with git, https, sftp and local
sources and the activation record in `state/config.active`, tested against
local servers by `tests/integration/fetch.sh` and `Fetch.ps1`. The sftp
part runs where an OpenSSH server is installed: Linux and macOS in CI, and
Windows when the OpenSSH server capability installs.
