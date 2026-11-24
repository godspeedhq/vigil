# Backlog 67, end to end: packs on two hosts whose configuration comes from Git

2026-11-24, on this branch's Vigil (`pack-config`), user mode on both hosts.

- **The source:** a bare Git repository on Fedora, `vigil-test@…:fleet-e2e/fleet.git`, read over SSH. Each host has a key of its own, restricted in `authorized_keys` to `git-shell`. Each host's pointer file names its own file: `hosts/fedora.config` or `hosts/mac.config`.
- **Fedora (Linux):** the postgres pack, against PostgreSQL 17 on 127.0.0.1:55432. Its monitor password is in OpenBao, at `secret/POSTGRES_MONITOR_PASSWORD`, read with a token whose policy reads only that path. The block was printed by `vigil pack config postgres` and pasted in. Then, by hand, as an operator would: `PGHOST`/`PGPORT` for this host, and its `secret:` lines changed to `store:bao/…`.
- **Mac (macOS 12, Intel):** the nginx pack. Its block was printed on Fedora, which has no nginx pack, by `vigil pack config nginx --os macos`, from the signed index. It was committed **before** the Mac had the pack: the order the tools have to explain.

| File | What it shows |
| --- | --- |
| `fleet-a.sh` | Fedora's setup: the Git server and its keys, PostgreSQL and its role, the OpenBao secret, policy and token (all through stdin, never argv or output), install, pointer file, `pack enable` refused, `pack config`, and the commit. |
| `fleet-b.sh` | On either host: fetch from the source, `precheck`, a run of each job, `status`, and the job log lines of any run that failed. |
| `fedora/1-setup.txt` | Install (a local configuration), then the pointer file, `vigil pack enable postgres` refused with exit 1, and `vigil pack config postgres`. |
| `fedora/2-from-the-source.txt` | The fetched revision active, `precheck passed`, and all 7 postgres jobs `succeeded`, their password from OpenBao. |
| `source/mac-jobs-printed-on-fedora.txt` | `vigil pack config nginx --os macos` on a host without the pack: `from packs-2026.11.24.2`. |
| `source/fedora.config`, `source/mac.config`, `source/git-log.txt` | What was committed: the pasted blocks, the store, and no secret. |
| `mac/1-before-install.txt` | The Mac fetches over SSH. `precheck` fails the 4 jobs, and each job's log ends its run with the reason: `(pack nginx is not installed here: vigil pack install nginx)`. `status` shows them failed. |
| `mac/2-after-install.txt` | `vigil pack install nginx` says where the configuration comes from, and that its jobs run once it names them. Then `precheck passed`, and all 4 jobs `succeeded`. The failed lines at the end are the runs from before the install (14:19; the successes are at 14:20). |
| `*/jobs.log`, `*/supervisor.log` | Each host's supervisor files. |

The Mac runs no nginx, so its nginx jobs succeed and report it down (`nginx_up 0`). This test is about where their configuration comes from, not about nginx, which #260 tested.

Seen here and not fixed in this change: on a host with a pointer file, `vigil precheck` notes `no metrics backend`. It looks for one in the pointer file, not in the fetched configuration. Both hosts' metrics reached their file backend all the same (`postgres_up{…} 1` on Fedora).
