# Sources compatibility matrix

How Vigil's sources (spec 6.8, 6.9, 16.5) work against real servers, and what a test showed (backlog task 25). A result changes only with evidence from a run of `scripts/run-source.sh`, or `run-source.ps1` on Windows. Every run below kept its console output, Vigil's logs and state: see [Real systems](https://godspeedhq.github.io/vigil/real/) on the site, or [`runs/`](runs).

**What counts as evidence.** Never a connection, a login or an HTTP 200 alone. Each check reads Vigil's own record of what happened:
- the fetcher's status and reason
- the activation record (`state/config.active`) and its revision
- the cached file's SHA-256, compared with the fixture's
- the output of the job's actual run

Fixtures are fixed files in `fixtures/sources/`, byte-exact on every checkout.

**Results:** Passed, Failed, Not supported (by Vigil), Not applicable, Not tested, Blocked.

## Matrix

| Source | Backend | Authentication | Retrieval | Updates | Integrity | Recovery | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `git` over HTTPS | Gitea 28.2.0 | **Passed**: a read-only collaborator through a Git credential helper; a wrong password refused | **Passed**: tag, commit, branch; scripts and a configuration (remote mode) | **Passed**: a moved branch, a new tag | **Passed**: a symbolic link out of the tree refused; missing ref, file and repository refused | **Passed**: server down, last good kept, then back | **Passed** |
| `git` over SSH | Gitea 28.2.0 | **Passed**: a read-only deploy key; a wrong key and an unknown host key refused | **Passed** | **Passed** (as HTTPS) | **Passed** (as HTTPS) | **Passed** | **Passed** |
| `git` | GitLab CE | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested (phase 2) |
| `https` | nginx 1.30.5 | **Passed**: an authentication header; missing (401) and wrong (403) refused. Plain http only to this host | **Passed**: scripts pinned by SHA-256, and a configuration | **Passed**: a new version by its digest; a new configuration | **Passed**: a digest mismatch and corrupted content refused, never run | **Passed**: 404, 403, 500, 503, a redirect (not followed), a dropped connection, a timeout, a refused connection, an untrusted certificate; server down and back | **Passed** |
| `https` | Caddy | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested (phase 2) |
| `sftp` | OpenSSH (atmoz/sftp) | **Passed**: a key; a wrong key, an unknown host key and a changed host key refused. Password: **Not supported** by Vigil | **Passed**: scripts, a nested path, a configuration | **Passed**: a new version by its digest; a new configuration | **Passed**: a digest mismatch and corrupted content refused; a missing file or directory and an unreadable file refused | **Passed**: server down and back. An interrupted transfer: **Not tested** | **Passed** |
| `sftp` | SFTPGo | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested (phase 2) |
| `local` | a directory (no server) | Not applicable | **Passed**: a path with spaces, nested and relative paths, a configuration | **Passed**: followed (picked up, reported unpinned) and pinned (new content refused, the verified copy kept) | **Passed**: a digest mismatch; a missing file or directory and an unreadable file refused | Not applicable | **Passed** |

In every failure case, nothing changed: the previous activation record, and every file it names, stayed in force, and the job went on running the last good version (spec 16.5).

## What the runs showed about Vigil

- **A verified copy is never fetched again.** An https or sftp script is named by its `sha256`, and once cached and verified it is never fetched again (spec 16.5). A changed source URL with the same file and digest makes no request at all. The tests give each failure case a source with nothing cached, so that Vigil really fetches.
- **A pinned file whose content changes isn't a failure.** The fetcher logs that the file "no longer matches its sha256; the last verified copy stays in use", and the configuration stays as it is (spec 6.9). It is not reported as a failed fetch.
- **One invalid job doesn't reject the file** (spec 16.3). A fetched configuration whose only fault is in a job is activated with that job skipped and shown INVALID. A fault outside any job (here `tick = soon`) refuses the whole configuration, and the last good one stays.
- **A source has no `ca_file` of its own.** A private CA is trusted the way the system trusts it:
  - git: `http.sslCAInfo`, given here in a Git configuration of the test's own (`GIT_CONFIG_GLOBAL`)
  - curl on Linux and macOS: `CURL_CA_BUNDLE`, which macOS curl (SecureTransport) honours too
  - Windows: the certificate store. Windows adds a root certificate only interactively, so until the test CA is in the test account's store the https checks are NOT RUN, and say why; plain http to this host, and refusing the untrusted certificate, are tested

  Unlike the secret stores and backends, which take `ca_file`. A candidate for the backlog, not a change made here.
- **`W_SCRIPT_UNPINNED`** is logged by the fetcher for a git branch, and reported by validation (`vigil precheck`) for a followed local source.
- **Windows found two bugs in Vigil, fixed in #69:**
  - `taskkill` is refused under a network logon (an SSH session), so a timed-out fetch was never ended. Process trees now end through the kernel where `taskkill` is refused.
  - Windows' OpenSSH `sftp.exe`, and `ssh.exe` under git, never exit after an error while their standard error is a .NET pipe. Each now writes it to a file.
- **And one trap for operators:** Windows' own `ssh.exe`, given to Git for Windows through `GIT_SSH_COMMAND`, hangs even when it succeeds. Git's own `ssh` works, and is what the test uses.

## Runs

| Date | Vigil on | Gitea | nginx | OpenSSH SFTP | local | Notes | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-11-03 | Fedora 44 (the Docker host), bash 5.3, git 2.56 | 54 of 54 | 70 of 70 | 48 of 48, 1 not run | 34 of 34 | restart and recovery included | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/) |
| 2026-11-03 | macOS 12.7.6, bash 3.2, git 2.37, through SSH tunnels | 50 of 50, 1 not run | 66 of 66, 1 not run | 44 of 44, 2 not run | 34 of 34 | restart not run: it needs the Docker host | [macOS](https://godspeedhq.github.io/vigil/real/macos/) |
| 2026-11-03 | Windows 11 23H2, PowerShell 5.1, Git for Windows 2.56, Windows' OpenSSH 9.5, through SSH tunnels | 44 of 44, 1 not run | 8 of 8, 2 not run: https until the test CA is trusted | 34 of 34, 1 not run | 18 of 18, 1 not run | restart not run: it needs the Docker host | [Windows](https://godspeedhq.github.io/vigil/real/windows/) |

**Images:** `gitea/gitea:28.2.0`, `nginx:1.30.5-alpine`, `atmoz/sftp:alpine@sha256:43dd1c02…` (pinned by digest; it has only rolling tags).

All three ran Vigil at commit `4040737`, on main.
