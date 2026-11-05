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
