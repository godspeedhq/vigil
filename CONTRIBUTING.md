# Contributing to Vigil

Thank you for helping. This guide is mostly about the scripts in [`packs/`](packs), which most contributions are, then briefly about Vigil itself.

You sign nothing and hold no keys. A contribution is a pull request: it is reviewed, it must pass every test, and once merged it is signed by the release pipeline with the rest of the release. A signature on a pack means the project reviewed what is in it, not that you vouched for it.

## How a script reaches a release

1. You open a pull request against `main`.
2. The tests run on Linux, macOS and Windows (PowerShell 5.1 and 7). `main` accepts nothing that has not passed all four, and nothing but a pull request: no direct pushes, no force-pushes, no deleting the branch.
3. A maintainer reviews it, against the checklist below, and merges it.
4. A release is built and signed only from a commit on `main` (the release workflow refuses any other), so nothing unreviewed is ever signed.

## What a pack script must be

A pack is a folder in `packs/` with a `pack.config` and a folder of scripts for each platform, `linux/`, `macos/` and `windows/` ([SPECIFICATION.md](SPECIFICATION.md), section 18.10). A job runs `<job>.sh` on Linux and macOS and `<job>.ps1` on Windows.

- **Only what ships with the operating system.** bash 3.2 (macOS's) on Linux and macOS, Windows PowerShell 5.1 on Windows. No Python, no extra modules, nothing to install. A command the system may lack is checked for, and its absence reported, not assumed.
- **Read, never change.** A script reports on the machine. It never writes outside its own temporary files, starts or stops anything, or changes a setting.
- **Every platform it claims.** A job with a script for one platform only is left out on the others, and that is fine; but a script must work on every version the specification supports for its platform.
- **No secrets in the script.** A pack that needs a credential, such as a database login, takes it through a `secret:` reference in the job, with a read-only account, never in the script or its arguments.
- **Quick and bounded.** It finishes well within the job's `max_runtime`, and it handles a slow or missing data source by reporting it, not by hanging.
- **Exit 0 when it worked.** A high reading is not a failure. Exit 1 when the data cannot be read, with the reason on standard error.
- **Plain ASCII output,** as metric lines: `metric <name> <value> [key=value ...]`.

### Naming metrics

A job's `metric_name` in `pack.config` is the base (`system.cpu`), and each line the script prints adds its own part (`used_pct`), giving `system.cpu.used_pct`.

- Lower case, with words joined by `_`, and parts joined by `.`.
- The unit at the end of the name: `_pct` (0 to 100), `_bytes`, `_seconds`, `_count`. A total that only grows, such as bytes since boot, is reported as it stands, and its header says so and to graph it as a rate (as `network` does).
- A dimension, such as a disk or an interface, is a tag (`mount=/`, `iface=eth0`), never part of the name.
- `metrics` in `pack.config` lists every name the job can print.
- Names stay stable: renaming one breaks every dashboard built on it, so it needs a new name and the old one kept for a release.

### The header

Each script starts with the same header as the others in `packs/base/`:

- what it does, and how
- its metrics, with an example of its output
- what healthy, watch and act look like
- what it needs, and its exit codes
- the copyright, licence and disclaimer lines

CI checks that every script carries the licence and disclaimer.

### Tests

- A new pack gets an integration test of its own, in both shells, like `tests/integration/base-pack.sh` and `Base-Pack.ps1`: the pack enabled with `vigil pack enable`, each job run, and each listed metric reaching a backend.
- A pack for a service, such as a database or a web server, is tested against the real service in CI.

## Review checklist

The maintainer merging a script checks:

- [ ] It only reads, and uses only what ships with each platform.
- [ ] It works on bash 3.2 and PowerShell 5.1, and the tests prove it on all four CI jobs.
- [ ] Its metrics are named as above, listed in `pack.config`, and documented in its header.
- [ ] Any credential comes through a `secret:` reference, for a read-only account.
- [ ] It is bounded in time, and reports, rather than hides, a source it cannot read.
- [ ] It has the header, the licence and the disclaimer.

## Vigil itself

Changes to Vigil are welcome too, and follow the same path. Vigil is written twice, in bash (`app/lib/posix/`) and PowerShell (`app/lib/windows/`), and the two must behave the same:

- A change is made in both twins, or says why it applies to one.
- `tests/run-conformance.sh` and `tests/Run-Conformance.ps1` run the same cases through both, and must pass.
- Behaviour follows [SPECIFICATION.md](SPECIFICATION.md); a change of behaviour changes the specification in the same pull request.
- Secrets never appear in configuration, logs, state, the spool, command lines, temporary files or URLs.

## Licence

Contributions are made under the [Apache License 2.0](LICENSE), the project's licence. By opening a pull request you agree that your contribution is licensed under it.
