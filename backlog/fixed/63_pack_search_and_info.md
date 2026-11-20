# 63. Pack search and info: a table, a card, and the newest index

Raised on 2026-11-20, after the redis pack shipped: `vigil pack search`
printed one long line per pack, `name version: description`, where most
descriptions have a colon of their own, so every line wrapped and nothing
lined up:

```text
mysql 1.0.0: MySQL and MariaDB: up, connections, queries, sessions and locks, replication, InnoDB, database sizes
nginx 1.1.0, no scripts for Windows: nginx: up, connections and requests, from stub_status
```

`vigil pack info` said little more: the versions, and whether the pack was
installed, but nothing of what it needs before it can run.

And `search`, `info` and `list --available` read the index saved by the
last command that fetched one, never a newer one. On a machine that had used
pack commands before packs-2026.11.20.1, Vigil 1.1.1 said

```text
$ vigil pack search redis
no pack matches: redis
```

while `vigil pack install redis` installed it.

## The change

- **`search` and `list --available` print a table** with the columns Name,
  Version, Here and About, a rule under each header, as Scoop does. **Here**
  is `installed`, `<version> installed`, or `not for <platform>`: a pack
  for other platforms stays listed, for a machine prepared from this one. On
  a terminal the description is cut to its width, ending `...`; piped,
  rows are whole. A header names the packs release the list comes from.
- **`info` prints a card:** Name, About, Here (with what to do next),
  Platforms, Works with, Programs, Secrets, Needs, Settings and Docs, then
  every version as a table. Values wrap at 78 columns under themselves; a
  link, and the command of a `needs` line, are never split, so they copy
  whole. Nothing is looked up on the machine (`vigil precheck` does that, as
  the service account).
- **They read the newest index**, as `install` does, and fall back to the one
  saved here only when the repository cannot be reached, saying so.
- **The index carries `info` records**, made by `tools/release/packs.sh`
  from `pack.config`: `works_with`, `programs_linux`, `programs_macos`,
  `programs_windows` and `docs` (new, optional `[pack]` keys), and each
  `needs` line, secret and `env` setting of the jobs. Vigils before this one
  skip them, and read the new `pack.config` keys as nothing.
- Every pack got the new keys, and so a new version: base 1.2.2, mysql
  1.0.1, nginx 1.1.1, postgres 1.2.1, redis 1.0.1. Their scripts are as
  they were.

## Done

- `tests/integration/pack.sh` and `Pack.ps1`, Searching: the table, the
  card with and without `info` records, a pack with no scripts here, a pack
  released after the index was saved (found), and offline (the saved index,
  saying so; none saved, the reason). 114 passed, 0 failed on Fedora 44 and
  on macOS 12 under bash 3.2; 113 passed, 0 failed on Windows 11 under
  Windows PowerShell 5.1 and PowerShell 7 (2026-11-20). On the Lenovo over
  SSH, 112 passed; the one failure, a secret set, is that logon's (Windows
  refuses data protection to an SSH key logon), not this change's.
- The cut, on real terminals: 69 columns of a 70-column terminal and 99 of
  100 on Fedora and macOS; 69 of a 70-column console on Windows, under 5.1
  and 7, against the live repository. Piped: whole rows.
- Vigil 1.1.1 against an index with `info` records and the new
  `pack.config` keys, on Fedora and on Windows: search, info, install and
  enable work as before.
- `tools/check-pack.sh --run`: 5 packs pass.
