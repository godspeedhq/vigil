# 25. Remote configuration and script sources: a real test environment

Extend the real-backend test environment (`tests/integration/backends/`, tasks 18 and 24) with a tenth logical group, `compose.sources.yaml`, that tests Vigil's existing sources (spec 6.8, 6.9, 16.5) against real, locally hosted servers: Git, HTTPS and SFTP, plus local directories.

## Principles

- Docker first, with genuine protocol implementations.
- Every service independently selectable through its own Compose profile; none starts with the observability environment.
- **No new source types and no change to Vigil's production code** to suit the tests. Only what Vigil already does is tested.
- Dummy credentials only. No production keys or tokens, nothing secret committed.
- Certificate checks and SSH host-key checks are never disabled.
- Ports on 127.0.0.1 only.
- **A download is never counted as a pass on its own.** The evidence is Vigil's own activation record, its cache, and a job's run, checked against fixtures whose content and SHA-256 are known.

## Services

| # | Service | Image | Protocol | Profile | Default set |
| --- | --- | --- | --- | --- | --- |
| 1 | Gitea | `gitea/gitea` | Git over HTTPS and SSH | `git-gitea` | yes |
| 2 | GitLab CE | `gitlab/gitlab-ce` | Git over HTTPS and SSH | `git-gitlab` | no (heavy) |
| 3 | nginx | `nginx` | HTTPS | `https-nginx` | yes |
| 4 | Caddy | `caddy` | HTTPS | `https-caddy` | no |
| 5 | OpenSSH SFTP | `atmoz/sftp` | SFTP | `sftp-openssh` | yes |
| 6 | SFTPGo | `drakkan/sftpgo` | SFTP | `sftp-sftpgo` | no |

`local` needs no container. Each image is checked first for availability, licence and maintenance, then pinned to a tested version or digest. GitLab never starts unless asked for.

## What Vigil supports, so what can be tested

From spec 6.8, 6.9 and 16.5. Anything else is reported **Not supported**, never added:

- **Types:** `local`, `git`, `https` and `sftp`. A source holds scripts, and in remote mode the configuration too (`config_source`, `config_file`).
- **git:** `url` is `https://`, `ssh://` or `user@host:path`, and `ref` is a tag, commit or branch.
  - Credentials come from the service account's Git credential helper or SSH key; never on a command line or in a URL.
  - A branch is followed, and reported unpinned (`W_SCRIPT_UNPINNED`) unless the job sets `sha256`.
  - Fetched as a bare mirror plus `git archive`, so no hook, filter or submodule runs, and a symbolic link out of the tree is rejected.
- **https:** one file per job, pinned by the job's `sha256` (required).
  - An optional authentication header, as a credential reference. No redirects. Certificate verification is never disabled. Plain http only to this host.
  - **No `ca_file` on a source:** the system's trust applies, so a test CA is trusted as an operator would trust a private one: curl's CA bundle variable, git's `http.sslCAInfo`, and the user's certificate store on Windows. To be checked in phase 1.
- **sftp:** one file per job, pinned by `sha256` (required).
  - OpenSSH's `sftp` in batch mode, with `StrictHostKeyChecking=yes`: the host key must already be in `known_hosts`.
  - **Key authentication only.** Password authentication: **Not supported** by Vigil.
- **local:** a copy from a directory (or a share), pinned by `sha256` or followed.
- **Every type:**
  - Nothing activates until the configuration and every script it names are present and verified.
  - Any failure keeps the previous activation (last known good), posts `vigil.source.failures` and is retried at the next check.
  - A fetched configuration over 1 MiB is rejected. An invalid fetched configuration is rejected as a whole, including one that is syntactically valid but semantically wrong (spec 16.3).

## Tests

For each server, what applies of:

- **Retrieval:** a configuration (remote mode) and a script, compared byte for byte with the fixture and by SHA-256, then run.
- **Git:** a branch, a tag and a commit; a new commit detected and fetched.
- **Integrity:** a digest mismatch rejected, the last verified copy kept.
- **Authentication:**
  - Git: a credential helper or an SSH key, and a wrong credential refused.
  - HTTPS: an authentication header, and a wrong one refused (401/403).
  - SFTP: a key, a wrong key refused, and an unknown or changed host key refused.
- **Errors:**
  - Git: a missing repository, ref or file.
  - HTTPS: 404, 403, 500, 503, a refused connection, a timeout, an interrupted transfer, an untrusted certificate.
  - SFTP: a missing file or directory, permission denied, an interrupted transfer.
- **Lifecycle:**
  - publish, fetch, verify and activate
  - publish an update and activate it
  - the source unavailable, with the last known good kept
  - restored, and recovery
- **Invalid updates:** a corrupted or semantically invalid configuration never replaces the active one.
- **No leaks:** no credential or private key in Vigil's logs, state or output.
- **Local:** valid paths, missing files, invalid content, permission denied, updates, digests, paths with spaces, and each platform's path behaviour, on Linux, macOS and Windows.

## Layout

```
tests/integration/backends/
  compose.sources.yaml                 group 10
  configs/sources/{gitea,gitlab,nginx,caddy,openssh,sftpgo}/
  fixtures/sources/{git,https,sftp,local}/
  scripts/start.sh stop.sh reset.sh     the existing commands
  scripts/run-source.sh run-source.ps1  the source tests
  reports/sources-compatibility.md
```

## Report

`reports/sources-compatibility.md`: source, backend, authentication, retrieval, updates, integrity, recovery and result, with the image version, Vigil version, date, OS, authentication mode, evidence and known limitations.

**Results:** Passed, Failed, Not supported, Not applicable, Not tested, or Blocked. Nothing that didn't run is ever marked Passed.

## Phases

1. **Lightweight:** Gitea, nginx, OpenSSH SFTP and local fixtures, with the whole lifecycle.
2. **Alternatives:** GitLab CE, Caddy and SFTPGo, compared with phase 1.
3. **Failure and recovery:** outages, authentication and trust failures, corrupted downloads, invalid updates, restarts.
4. **Report:** the full matrix, and what is not supported.

## Progress

- Written 2026-11-03.
- **Phase 1: done for Linux and macOS (2026-11-03).** Gitea, nginx, OpenSSH SFTP and local, with the whole lifecycle; see `reports/sources-compatibility.md`.
  - **Fedora:** Gitea 54/54, nginx 70/70, SFTP 48/48 (an interrupted transfer not run), local 34/34.
  - **macOS:** the same through tunnels, the restarts not run there.
  - **Not supported by Vigil, as reported:** SFTP password login.
  - **Findings:** a verified copy is never fetched again; a pinned file whose content changes is logged, not failed; one invalid job is skipped while the rest is activated (spec 16.3); a source has no `ca_file`.
- **Next:** `run-source.ps1` for Windows (the test CA in the user's certificate store, for https); then phase 2: GitLab CE, Caddy, SFTPGo.

## Closed

Closed on 2026-11-04, by decision, with the real-backend work (backlog 18): enough is covered. Results and evidence are in `tests/integration/backends/reports/sources-compatibility.md` and on the site's Real systems pages.

**Done:**
- Phase 1, on Fedora, macOS and Windows (`run-source.ps1`): Gitea 28.2 over HTTPS and SSH, nginx 1.30.5 over https, OpenSSH SFTP and a local directory, with the whole lifecycle.
- Phase 3, on Fedora: outages, refused credentials and host keys, untrusted certificates, corrupted and wrong-digest downloads, invalid updates and restarts, with the last good configuration kept every time.
- Phase 4: the matrix, with what Vigil does not support (SFTP password login) said so.
- Found on the way, and fixed in #69: two Windows bugs (a timed-out fetch never ended where `taskkill` is refused, and sftp and git hanging after an error).

**Not done:**
- **Phase 2, the alternatives:** GitLab CE, Caddy and SFTPGo were not run.
- **https sources on Windows:** NOT RUN until the test CA is trusted in the test account's certificate store, which Windows allows only interactively.
- **An interrupted SFTP transfer:** not tested.
- **The restart checks from macOS and Windows:** reported NOT RUN there, as for the secret stores.
