# Fetching configuration and scripts: git, https, sftp, shares

The fetcher for `config_source` and job `source`s (spec 6.8, 6.9): fetch,
verify `sha256`, swap in atomically, keep the last good copy.

## Done when
- Each source type tested against a local server, both twins.
