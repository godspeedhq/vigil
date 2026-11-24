# Packs on hosts whose configuration comes from a source

A fleet keeps its configuration in Git (or another source, §6.8): each host's
`vigil.config` is a pointer file, and the configuration is whatever the
source serves. `vigil pack enable` refuses there, rightly, since a
configuration from a source is never edited (§18.10), but it leaves the
operator to copy a pack's job block by hand, and nothing catches a job whose
pack a host does not have. This item makes deploying a pack to 100 hosts
simple, without Vigil ever writing the central configuration.

## Decided (2026-11-24)

1. **Installing stays per host, and off.** `vigil pack install` puts the
   scripts on the host and turns nothing on, as now. Nothing in a
   configuration, central or local, makes a host download or install a pack:
   a commit to Git must never make a fleet fetch and run new code, signed or
   not. A fleet installs with its own tool (Ansible, an install script, an
   image).
2. **Vigil never writes the central configuration, or a secret.** It helps the
   operator write it: it prints, and it checks.
3. **Loud, at the moment it matters.** On a host whose configuration comes
   from a source, `vigil pack install` ends with, and `vigil pack enable`
   refuses with (exit 1, so scripts notice):

   ```
   pack nginx 1.2.0 is installed here, and off.
   This host's configuration comes from [source.central] (hosts/web01.config):
   Vigil does not edit it. To turn the pack on, add its jobs there:
     vigil pack config nginx --os linux     prints them, ready to paste
   ```

4. **`vigil pack config <name>`** prints the block `vigil pack enable` would
   have written, ready to paste into the central configuration:
   - **From the signed index, without the pack installed.** The block comes
     from the pack's `pack.config`, not the host: run it once, on a laptop,
     for 100 hosts. With the pack installed and no network, it reads the
     installed `pack.config`.
   - **The verb comes first,** like every pack command: `vigil pack config
     nginx`, not `vigil pack nginx config`.
   - **Per platform.** A job names its script with its platform's extension
     (`packs/nginx/status.sh`, `packs/nginx/status.ps1`), and Linux and
     Windows hosts read different files from the source (each pointer file
     names its own `config_file`). `--os linux|macos|windows`, by default this
     host's. A job with no script for that platform is left out, and said so
     in a comment.
   - **Every line it needs, marked:** the `# pack nginx` block markers, each
     job's settings (`env` lines, with the pack's defaults), its `secret`
     lines, and above them, as comments, the pack's `needs` lines and which
     settings usually differ per host.
   - **Each job's `secret` lines, with the names the pack expects**
     (`secret = POSTGRES_MONITOR_PASSWORD=secret:POSTGRES_MONITOR_PASSWORD`),
     so the fleet's own tool knows exactly what to set on each host.
   - **`--store <name>`**, a plain option, writes them as
     `store:<name>/<NAME>` instead, for those who keep a fleet's secrets in a
     `[secret_store.<name>]`.
   - It changes nothing, and needs no configuration, on any host.
5. **`vigil precheck` and `vigil status` catch a pack missing or too old.**
   A job whose `file` is under `packs/<name>/` on a host where:
   - the pack is not installed: `job nginx_log: pack nginx is not installed
     here: vigil pack install nginx` (precheck: an error; status: the job's
     line says it, instead of a run that failed for want of a script);
   - the installed version has no such job (an older one): `job nginx_log:
     pack nginx 1.1.1 has no job log (1.2.0 and later): vigil pack update
     nginx`.

   So the order a fleet follows, install first, then commit, is the one the
   tools explain when it is not followed.

## Secrets across a fleet (decided 2026-11-24)

**Vigil enforces nothing, and nudges nothing.** A job's `secret` line is a
reference resolved when the run starts: Vigil does not care whether a fleet's
tool (Ansible, Puppet, Chef) set it with `vigil secret set`, wrote it to the
service's environment, or keeps it in a store, only that it exists and is
right. A fleet already has what tells it when one is not:

- **Missing:** `vigil precheck` names, on each host, a secret that is not set,
  and `vigil pack enable` says `needs secret:X: not set`.
- **Wrong:** the job fails, saying why (a refused login is a failed run with
  its reason, never a quiet `up 0`).

What the fleet guide says, and nothing more:

- `vigil secret set` runs as the account Vigil runs as, and takes the value
  on `--stdin`, never the command line: a fleet's tool must do both.
- An `env:` value reaches Linux and macOS runs only after Vigil restarts
  (§6.5.1): a tool that rotates one must restart Vigil; `secret:` and `store:`
  are read at each run.
- A secret can never be in the configuration itself (only references are
  allowed), so never in the source's repository.
- Packs with no secret (nginx, httpd, caddy, haproxy, phpfpm, iis) roll out
  with install, then commit.

## Not in scope

- Vigil installing packs because a configuration names them.
- Vigil editing a configuration that comes from a source, or writing to a
  secret store.
- Per-host overrides of a job received from a source (§26 lists it as future
  work); per-host files cover it today.

## Done when

- `vigil pack config <name>` prints, from the index and with the pack not
  installed, a block that, pasted into a source's configuration, validates
  and runs on Linux, macOS and Windows (`--os`), with `--store` and without.
- `vigil pack install` and `vigil pack enable` on a host with a pointer file
  say what to do, and `enable` exits 1.
- `vigil precheck` and `vigil status` name a missing pack and a pack too old
  for a job, on all three platforms.
- The spec (§6.8, §18.10) and `packs/README.md` say how a fleet deploys a
  pack, with the order: install, then commit.
- Tested through a Git source with two hosts on different platforms, one
  secret in a store, and a host missing the pack.
