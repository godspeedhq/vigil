# The fleet

A real fleet for `[vigil] version` (SPECIFICATION.md 18.11): hosts that
read their configuration from a source, and move to whatever release the
version line of their file names. Not part of CI: it needs a Docker host,
and for the macOS and Windows hosts, machines reachable over SSH.
`version-config.sh` and `Version-Config.ps1` are the CI tests.

| Host | Where | Source | File |
| --- | --- | --- | --- |
| h1 | Debian container | git over SSH | `hosts/h1.config` (the canary) |
| h2 | Debian container | git over SSH | `groups/git.config` |
| h3, h4 | Debian containers | https, with a CA made for the run | `groups/https.config` |
| h5, h6 | Debian containers | sftp | `groups/sftp.config` |
| h7 | Debian container | local folder | `groups/local.config` |
| mac | macOS, through a tunnel | git over SSH | `mac.config` |
| win https | Windows, through a tunnel | https (as plain http on 127.0.0.1) | `windows-https.config` |
| win sftp | Windows, through a tunnel | sftp | `windows-sftp.config` |

Every file also runs a job, `beat`, whose script comes from the same source.
Releases are builds of the checkout, numbered 99.x, signed with a key made
for the run and served on each host's own 127.0.0.1, the only address the
test release override accepts. GitHub's releases are never touched.

## Running it

On the Docker host, from a checkout:

```sh
bash tests/integration/fleet/fleet.sh up        # h1-h7 on 99.1.0
```

For the macOS and Windows hosts, from a workstation: tunnel the Docker
host's 127.0.0.1 ports 2222 (git), 2223 (sftp) and 8080 (http) to the
workstation (`ssh -L`), then on to each machine (`ssh -R`). Copy
`share/www`, `share/release.pem`, `share/mock-files.py`, `share/keys/fleet`
and `share/keys/known_hosts` to a folder on each, with `remote/host.sh` or
`remote/Host.ps1` and `remote/Status.ps1`, and keep one session open per host:

```sh
bash ~/fleet/host.sh ~/fleet/mac git mac.config 99.1.0
powershell -File fleet\Host.ps1 -Dir fleet\https -Source https -File windows-https.config -Start 99.1.0
```

Then drive it all from the workstation with `drive.sh` (the variables are in
its header), which keeps every command and its output in `FLEET_LOG`:

```sh
drive.sh set 99.2.0 hosts/h1.config      # the canary
drive.sh set 99.2.0 groups/git.config ...  # the rest
drive.sh publish 99.3.0                  # a release the hosts can now have
drive.sh broken 99.3.0 99.9.0            # one that does not run
drive.sh status
```

`fleet.sh down` removes the containers and everything the run made.

## Runs

- [2026-11-05](reports/2026-11-05/console.txt): seven containers on Fedora 44,
  macOS 12.7.6, Windows 11. A canary, the fleet, a downgrade, a release not
  published yet (taken at the 5-minute retry once it was), a release that
  does not run (rolled back everywhere, tried once), `vigil self update`
  refused; no run crashed. Beside it, h2's supervisor log and the
  `vigil_update` logs of h2, the Mac and Windows.

## Configuration from Git, at scale (2026-11-26)

A second kit, beside the first: one host runs the backend (Grafana's LGTM
image) and a Gitea holding the configuration, behind TLS from a CA made for
the run, and every other machine runs Vigil, in Alpine containers and on bare
metal, taking its configuration from Gitea. `scenarios/run-all.sh` then
pushes good and broken configurations, rewrites history, stops Gitea and the
backend, and cuts one container off the network, recording each round.

| Folder | What |
| --- | --- |
| `tls/` | `make-tls.sh`: the CA and the server certificate |
| `backend/` | The compose file, Caddy, `setup.sh` (users, tokens, the repository, the dashboard), `dashboards/` |
| `config/` | `make-configs.sh`: one configuration file per kind of instance |
| `node/` | The container image, `fleet.sh` (containers, Linux), `Start-FleetContainers.ps1` (Windows' Docker Desktop), `start-fleet-mac.sh`, `bare.sh` and `Bare.ps1` (bare metal), and the patch scripts that put a fixed file into running containers |
| `admin/` | What needs an administrator: trusting the CA, opening the backend's firewall |
| `scenarios/` | `push.sh`, `evidence.sh`, `screenshot.sh`, `run-all.sh` |

Secrets (tokens, passwords) and the run's output go to the git-ignored
`out/` folders.

**What each machine can carry.** Containers are capped at half a CPU and
64 MB each, and run the base pack in bash: each uses about a quarter of a core
before its sender sends anything.

| Machine | Use |
| --- | --- |
| Two cores (a 2015 MacBook, an i5-3320M) | Bare metal only. Five containers in Docker Desktop's VM left their senders too little CPU to keep up |
| Four cores, with other work (Fedora 44 running a demo) | Bare metal and two or three containers. Ten took it to load 35 |
| Eight logical CPUs (Windows 11, HP) | Bare metal and five containers |
| Windows Server | Bare metal only: its Docker runs Windows containers, and the image is Linux |

**Runs**

- [2026-11-26, run 1](../backends/reports/runs/2026-11-26/fleet/) and
  [run 2](../backends/reports/runs/2026-11-26/fleet-run2/REPORT.md): 14 and
  24 instances on five machines. Configuration handling passed every round;
  the bugs found are in `fleet-run2/BUGS.md`.
