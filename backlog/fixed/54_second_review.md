# 54. The second engineering review (v0.7.0 to v0.9.0)

Found on 2026-11-16 by a review of v0.8.0 and v0.9.0 against their own
guarantees. Each item below names the code it rests on. The review's other
findings were already met, or are documented limits, and are not repeated
here.

## 1. A standard user can own the system root before Vigil is installed

`C:\ProgramData` lets any user create a folder (`BUILTIN\Users:(CI)(WD,AD)`,
and `CREATOR OWNER` gets full control). `install.ps1` locks a system root
only when its ACL is not already protected, and never sets its owner:

```powershell
if ($mode -ceq 'system' -and -not (Get-Acl -LiteralPath $root).AreAccessRulesProtected) {
```

So a standard user who creates `C:\ProgramData\Vigil` first, with a
protected ACL of their own, keeps it, and with it control of what the
service runs as SYSTEM. Even when the installer does replace the ACL, the
folder's owner can rewrite it. The secret store is under the root.

**Fix:** on a system install, Administrators own the root and its ACL is
always set, keeping the entries Vigil itself adds below it (the `-UpdateBy`
account's, the secret store's). Tested at the console, since it needs an
administrator.

## 2. `vigil doctor` can make runs lose their log lines

Doctor reads job logs with `File.ReadAllLines`, which lets others only read
while it has a file open. A worker appending its `run start` or `run end`
line at that moment fails. Reproduced on Windows 11: 30 runs while a reader
looped on the log; all exited 0, and two runs' lines were missing (29 of 31
each). The same failure, on doctor's side, is swallowed by `catch { }`: that
job's file drops out of the totals, silently.

**Fix:** doctor opens logs as the log forwarder does (`FileShare.ReadWrite,
Delete`), and names a file it cannot read instead of leaving it out. An
integration test runs jobs while doctor reads, and counts the lines.

## 3. Boot ids that a clock step moves

On Windows and macOS the boot id is the boot time, which both kernels give
as "now minus uptime": stepping the clock moves it. A run recorded under a
different boot id is concluded over (§11), so a run still alive could be
concluded and its job started again. Linux reads a real boot id and is not
affected.

**First, reproduce it** (needs an administrator): a 10-minute job, the clock
stepped by 5 minutes, then (Windows) the service restarted. If it
reproduces, compare boot times with a tolerance: another boot is at least
its uptime away.

## 4. Smaller corrections

- **The digest is of what is parsed.** The Windows worker hashes
  `config.valid` and then reads it again to parse. It reads it once.
- **Doctor says what it does not know.** A logging-policy key it cannot read
  is not "none set", and exclusions it cannot read are not "shown only to
  administrators" unless that is why.
- **Doctor says how much of the hour it saw** when the supervisor started
  less than an hour ago, rather than dividing a few minutes of runs by an
  hour without saying so.

## 5. Documentation

- §4.3: without sources, a run gets the last valid configuration when its
  worker starts; with sources, exactly the one it was launched with.
- §10.3: `max_runtime` counts from the run's start in the worker, not the
  launch, and is checked each tick.
- §12.2 and §16.7: a process a job starts and does not wait for is not
  counted; runs still running, and runs whose worker crashed, are not in
  doctor's totals.
- Next to the install one-liner: a bad edit to a local configuration
  followed by a restart leaves Vigil stopped (§16.3); `vigil precheck`
  first.

## Done when

- Items 1, 2 and 4 are fixed, each with a test; item 1's runs at the
  console.
- Item 3 is reproduced or not, on Windows and macOS, and fixed if it is.
- Item 5 is in the specification and the README.

## Built (2026-11-16)

**1. The system root's owner** (#171). `install.ps1` and `Set-VigilRootAcl`
refuse a root whose owner is not SYSTEM, Administrators, TrustedInstaller,
the installing account or a member of Administrators, and put nothing in it.
They replace its ACL every time, keeping only read-only entries on the root
itself (an `-UpdateBy` account's). `Install.ps1`'s elevated section, which
CI's Windows runners run, plants a root owned by Users and locked to it
(refused, nothing installed), and one locked with a write entry for
Authenticated Users (installed, the write entry gone, a read-only one kept).

**2. Doctor's reads** (#171). Job logs are read shared for writing, as the
log forwarder reads them. `Doctor.ps1` runs 20 jobs while doctor's reader
loops on their log: on main's doctor, 20 of 21 `run end` lines; now all 21.
A log doctor cannot read is named with a `WARN`, on both platforms.

**3. Boot ids.** Reproduced on the Mac (macOS 12.7.6), in a scratch Vigil as
vigil-test, without touching the clock: the live run's recorded boot id was
set 300 s ahead, as a clock step makes it:

```text
19:36:00Z INFO supervisor job long: run 20261116T193600Z-32434-291 started
19:36:35Z WARN supervisor job long: run 20261116T193600Z-32434-291 crashed: worker vanished without an outcome
19:37:00Z INFO supervisor job long: run 20261116T193700Z-32434-304 started
== sleep 240 processes (live runs):
   91591 sleep 240
   94124 sleep 240
```

Run 291 held its token and its job ran on; it was concluded crashed, its
token deleted, and run 304 started beside it: two runs of one job at once.
And a step is not needed: `kern.boottime` read `{ sec = 1790391290, usec =
821970 }`, then `usec = 881703` an hour later, with no reboot, as the clock
was corrected. A boot id of whole seconds can cross a second the same way.

The fix is the order of the evidence: a held token is a process alive now,
so it is checked before the boot id (`recovery.sh`, `Recovery.ps1`). The
conformance table's row that said otherwise (`held … changed … crashed`)
now says `alive`, with an unreadable-state twin; main's code fails it. The
boot id still decides everything a held token does not.

**4 and 5** (#171): doctor says when the supervisor started less than an
hour ago, and when a policy or exclusion list is unreadable; the Windows
worker hashes the bytes it parses; SPECIFICATION.md 4.3, 10.3, 11.1, 11.3,
12.2, 16.7 and 18, and the README.
