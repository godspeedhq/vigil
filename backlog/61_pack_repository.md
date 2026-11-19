# 61. Packs from a repository: search, install, then enable

Today `vigil pack update` downloads one archive holding every pack
(`vigil-packs-<version>-<os>`) from the latest Vigil release, and puts
every pack in `packs/`, the ones nobody asked for too. With many packs to
come, a machine should hold only the packs it was asked for, and a new pack
should not wait for a Vigil release. Agreed on 2026-11-19: packs work like
an apt repository.

## Commands

| Command | What it does |
| --- | --- |
| `vigil pack update [--check]` | Fetches the signed pack index, and updates the packs installed here, never going back a version. It installs nothing new |
| `vigil pack search [<words>]` | Packs in the index whose name or description has every word; all of them with none. From the index fetched last: works offline |
| `vigil pack info <name>` | One pack: its description, versions, platforms, the oldest Vigil it runs on, and the version installed here |
| `vigil pack install <name>[@<version>]… [--from <folder>]` | Downloads the pack, verifies it, and puts it in `packs/<name>/`. Nothing runs until `vigil pack enable`. `@<version>` installs that version, older too; without it, the newest this Vigil can run |
| `vigil pack remove <name>…` | Deletes a pack's scripts; refused while any of its jobs is in the configuration |
| `vigil pack download <name>[@<version>]… [--os linux\|macos\|windows] --to <folder>` | Writes the packs, the index and its signature to a folder, for a machine that cannot reach the repository: `vigil pack install <name> --from <folder>` there. `--os` defaults to this machine's |
| `vigil pack list [--available]` | The packs installed, as today; with `--available`, the index's packs not installed |
| `vigil pack enable`, `vigil pack disable` | Unchanged |

## The repository

- **Each pack is its own archive per platform:** `vigil-pack-<name>-<version>-linux.tar.gz`, `-macos.tar.gz` and `-windows.zip`, holding the pack flat (`pack.config` and that platform's scripts), as `packs/<name>/` holds it. A pack with no scripts for a platform has no archive for it.
- **The index, `packs.index`, lists every version of every pack,** with the release each version's archives are in and their SHA-256. One tab-separated record per line:

  ```text
  format	1
  release	packs-2026.11.20
  pack	postgres	1.2.0	0.3.0	packs-2026.11.20	PostgreSQL: up, connections, …
  file	postgres	1.2.0	linux	vigil-pack-postgres-1.2.0-linux.tar.gz	<sha256>
  ```

  `pack` is name, version, oldest Vigil, the release holding it, description; `file` is name, version, platform, archive, SHA-256.
- **The index is signed** (`packs.index.sig`) with the release key, as `SHA256SUMS` is: one signature check vouches for every archive through its SHA-256.

## Packs releases, apart from Vigil's

- A tag `packs-<YYYY.MM.DD>` (`.2`, `.3` for more in a day) on a commit on main runs a workflow of its own: `tools/release/packs.sh` builds the archives of each pack whose version is new since the previous packs release, carries the older entries over from its index, and writes and signs the new index. A pack whose files changed with the same version is refused: its version must go up.
- The release is not marked latest, so `vigil self update` and the installers never take it for a Vigil release. Like every release, it starts as a draft.
- **Finding the newest:** from GitHub, the API's list of releases (the first tag starting `packs-`); from a copy (`release_url` or `release_path`), `packs/latest/RELEASE`, one line naming it, beside `releases/latest/VERSION`. Files come from `releases/download/<packs tag>/…` either way, so a copy holds packs releases as it holds Vigil's.

## What ships, and what keeps working

- **The base pack ships inside Vigil,** in the release archives and the packages, as today, so a new machine has metrics without a network. The other packs do not: they are installed.
- **Nothing breaks.** The configuration and `pack enable`/`disable` are unchanged. A root holding every pack keeps them, and `pack update` updates them all, being installed. Vigil releases keep their all-in-one `vigil-packs-<version>-<os>` archives for 1.0.x, whose `pack update` reads them, until 2.0.
- **Versions are ordered** (x.y.z): `pack update` never installs an older version than the one installed; `install @<version>` may, being asked to.

## Offline

`vigil pack download` writes the archives, `packs.index` and `packs.index.sig` to a folder, flat; `vigil pack install <name> --from <folder>` verifies the index's signature against this machine's release key and each archive against the index, exactly as online. A site always offline can point `release_path` at a full copy instead, and then plain `pack install` and `pack update` work.

## Not now

- Other repositories (`pack source add`): only Vigil's signed index, one key vouching for every pack.
- Automatic pack updates: as for Vigil, only when asked.

## Steps

1. Both twins: the index (fetch, verify, cache in `packs/.index` with its signature), `search`, `info`, `install`, `remove`, `download`, `list --available`, `update` on installed packs only with versions ordered; `--from`.
2. `tools/release/packs.sh` and `.github/workflows/packs.yml`; `package.sh`, the installers and the packages ship the base pack only.
3. The specification (§18.10, and §18.7 for copies), README, `packs/README.md`, CONTRIBUTING (how a pack ships).
4. Tests, both twins: the pack tests against a mock repository (index, signatures, a tampered archive, a refused signature, `@version`, a pack too new for this Vigil, never going back on update, remove refused while on, download and `--from` offline), and the copies (`release_url`, `release_path`).
