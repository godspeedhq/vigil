# 42. Secrets the service can read, on a system install

Found in the engineering-challenges review of 2026-11-10 (challenge 6.4,
[the review](reviews/2026-11-10_engineering_challenges.md)).

## The problem

Vigil's own store (`secret:NAME`) is kept for one account: on Linux and
macOS the file must be owned by the account reading it
(`_vigil_secret_safe`, `app/lib/posix/secrets.sh`); on Windows it is
encrypted with `ConvertFrom-SecureString`, DPAPI for the account that ran
`vigil secret set` (`app/lib/windows/Secrets.ps1`). On a system install that
account must be the service's, and the documented ways do not get there:

- **Windows.** The service runs as LocalSystem. Nobody types commands as
  LocalSystem, so a secret set from an elevated prompt is the
  administrator's, and the service cannot decrypt it. README.md (line 428)
  says so and points to `env:` or `store:`. But `vigil pack enable postgres`
  says `needs secret:POSTGRES_MONITOR_PASSWORD: not set: vigil secret set
  POSTGRES_MONITOR_PASSWORD, as the account Vigil runs as`, packs/README.md
  says to run `vigil secret set`, and once it is set from the admin prompt,
  `pack enable` says `set` and `precheck` (run elevated, as README.md line 830
  advises) passes, while the service's runs fail. In practice `secret:` does
  not work for a Windows system install, and two messages say it does.
- **Linux, `release_header_value = secret:...` with `--update-by`.** The
  supervisor's `vigil_update` worker runs as the service account (`vigil`)
  and resolves the release source (`vigil_release_source`,
  `app/lib/posix/selfupdate.sh`) before handing over to
  `sudo -n app/vigil self update --from-config`, which resolves it again as
  root. Each refuses a file the other owns. README.md line 317 (`sudo vigil
  secret set VIGIL_RELEASES_AUTH`) gives a root-owned one, which the worker
  refuses; set as `vigil`, root refuses it. And one `config/secrets` folder
  cannot be owned by both, so release and job secrets cannot share it either.
  Found by reading; reproduced 2026-11-14 (below).

Linux and macOS job secrets, set with `sudo -u vigil vigil secret set`, are
fine: one account sets and reads them.

## To decide

The smallest change that gives each system install one documented way that
works. Candidates, to weigh before building:

- Windows: `vigil secret set` from an elevated prompt on a system install
  encrypts for the machine (DPAPI `LocalMachine`) in a folder only SYSTEM and
  Administrators can open, so the service and administrators can read it and
  nobody else can; or it hands the value to the service's own account through
  the `Vigil Update`-style task. The first is simpler; its protection is the
  folder's permissions, as on Linux.
- Linux: the release secret is read only by the process that downloads (root
  under `--update-by`), not by the worker first; or the worker passes the
  header to the root child on stdin. Either way, one owner per secret.
- Until then, the messages stop promising what does not work: `pack enable`
  and precheck on a Windows system install say a `secret:` must be readable
  by LocalSystem, and point to `env:`/`store:`.

## Done when

- On a Windows system install and a Linux system install with
  `--update-by`, a `secret:` set the documented way is read by the service:
  shown by a test that runs as the service's account, and on the test
  machines.
- README.md, packs/README.md and the `pack enable` messages agree with it.

## Decided (2026-11-14)

**Reproduced on Linux,** in a `fedora:44` container laid out as a system
install (`config/` owned by `vigil`), with `release_header_value =
secret:VIGIL_RELEASES_AUTH`, running `vigil self update --check`:

- Set as root, as README.md says: the worker, as `vigil`, gets `cannot read
  /opt/vigil/config/secrets from this account`; root reads it.
- Set as `vigil`: the worker reads it; root gets `refused: its file is owned
  by another account`.

Setting it as root also leaves `config/secrets` owned by root, closing it to
the service's job secrets as well.

**Windows also found:** `secret set` on a system install closes
`config\secrets` to all but the account that ran it, so SYSTEM cannot even
open the folder, before DPAPI is reached.

**The change, one documented way each:**

- **Windows.** On a system install (the root closed to SYSTEM and
  Administrators by `service install --system`), `vigil secret set` from an
  elevated prompt encrypts with DPAPI's machine scope
  (`ProtectedData`, `LocalMachine`) and gives `config\secrets` to SYSTEM and
  Administrators only, as the root is. The service and administrators can
  read it, nobody else can open it: the folder's permissions protect it, as
  a 0600 file does on Linux. Each file says which scope encrypted it, so
  secrets already set stay readable; a user install is unchanged.
- **Linux and macOS.** Root may read a store whose files belong to another
  account: root can read any file anyway, so refusing it protects nothing.
  The one documented way is to set secrets as the service account (`sudo -u
  vigil vigil secret set NAME`), release secrets included; the worker and
  the root updater then both read it.
- **Messages and docs:** `pack enable`, precheck, README.md and
  packs/README.md say that way for each platform, and stop pointing a
  Windows system install at something that cannot work.

**Tests:** the Windows twin and the bash twin each read a secret as the
service would (SYSTEM on Windows; root reading another account's store on
Linux), and the test machines show it: Fedora's service, and the Server 2025
machine's service with a secret set at the console.
